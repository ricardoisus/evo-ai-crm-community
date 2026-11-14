require 'rails_helper'

RSpec.describe 'Internal Vetorial telemetry API', type: :request do
  let(:secret) { "synthetic-telemetry-#{('x' * 32)}" }
  let(:path) { '/internal/vetorial_agent/telemetry' }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).with('VETORIAL_AGENT_SECRET_FILE').and_return(nil)
    allow(ENV).to receive(:fetch).with('VETORIAL_AGENT_SECRET', '').and_return(secret)
  end

  def delete_telemetry_fixtures
    [VetorialAgent::TelemetryEvent, VetorialAgent::Usage, VetorialAgent::Execution,
     VetorialAgent::RuntimeStatus, VetorialAgent::Audit, VetorialAgent::Profile,
     VetorialAgent::Revision, VetorialAgent::Deployment].each(&:delete_all)
    AgentBot.where(name: 'Synthetic telemetry').delete_all
  end

  def deployment
    @deployment ||= VetorialAgent::Deployment.create!(
      agent_bot: AgentBot.create!(name: 'Synthetic telemetry', outgoing_url: 'http://agent.invalid'),
      slug: "telemetry-#{SecureRandom.hex(4)}"
    )
  end

  def execution(outcome: 'send_confirmed', status: 'succeeded', conversation_id: SecureRandom.uuid,
                occurred_at: Time.utc(2026, 11, 1, 3), event_id: SecureRandom.uuid, execution_id: SecureRandom.uuid)
    { event_id: event_id, deployment_id: deployment.id, kind: 'execution', occurred_ms: (occurred_at.to_f * 1000).to_i,
      execution_id: execution_id, conversation_id: conversation_id, role: 'atendimento', source: 'live', revision: 1,
      policy_epoch: 1, status: status, latency_ms: 250, outcome: outcome }
  end

  def usage(cost:, state: 'known', occurred_at: Time.utc(2026, 11, 1, 3), event_id: SecureRandom.uuid,
            call_id: SecureRandom.uuid, execution_id: SecureRandom.uuid)
    { event_id: event_id, deployment_id: deployment.id, kind: 'usage', occurred_ms: (occurred_at.to_f * 1000).to_i,
      call_id: call_id, execution_id: execution_id, source: 'live', provider: 'openai', model: 'gpt-6.1-sol',
      input_tokens: 100, cached_tokens: 20, output_tokens: 40, reasoning_tokens: 10,
      cost_micro_usd: cost, usage_state: state }
  end

  def heartbeat(occurred_at: Time.utc(2026, 11, 1, 3))
    { event_id: SecureRandom.uuid, deployment_id: deployment.id, kind: 'heartbeat',
      occurred_ms: (occurred_at.to_f * 1000).to_i, instance_id: SecureRandom.uuid,
      revision: 1, policy_epoch: 1, sha256: 'a' * 64,
      integrations: { openai: 'configured', groq: 'absent', calendly: 'unverified', google_gateway: 'error' } }
  end

  def post_events(events, key:, valid_signature: true)
    body = { events: events }.to_json
    headers = VetorialAgent::Signature.headers(body, method: 'POST', path: path).merge('Idempotency-Key' => key)
    headers['X-Vetorial-Signature'] = '0' * 64 unless valid_signature
    post path, params: body, headers: headers
  end

  it 'rejects an invalid HMAC before persisting anything' do
    post_events([execution], key: 'invalid-hmac', valid_signature: false)
    expect(response).to have_http_status(:unauthorized)
    expect(VetorialAgent::TelemetryEvent.count).to eq(0)
  end

  it 'acknowledges a redelivered event without counting it twice' do
    event = execution
    post_events([event], key: 'first-delivery')
    expect(response).to have_http_status(:ok)
    post_events([event], key: 'lost-ack-retry')
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq('acknowledged' => [event[:event_id]])
    expect(VetorialAgent::Execution.count).to eq(1)
  end

  context 'with concurrent database connections' do
    self.use_transactional_tests = false

    before { delete_telemetry_fixtures }
    after { delete_telemetry_fixtures }

    it 'serializes concurrent requests with the same idempotency key and stores one response for 24 hours' do
      event = execution
      pool = ActiveRecord::Base.connection_pool
      warmed_connections = Array.new(4) { pool.checkout.tap(&:verify!) }
      warmed_connections.each { |connection| pool.checkin(connection) }

      ready = Queue.new
      start = Queue.new
      results = Queue.new
      threads = Array.new(4) do
        Thread.new do
          pool.with_connection do |connection|
            ready << true
            start.pop
            response = VetorialAgent::Telemetry.new([event], idempotency_key: 'concurrent-key').call
            results << [connection.select_value('SELECT pg_backend_pid()'), response]
          end
        end
      end
      4.times { ready.pop }
      4.times { start << true }
      threads.each(&:value)

      connection_results = Array.new(4) { results.pop }
      expect(connection_results.map(&:first).uniq.size).to eq(4)
      expect(connection_results.map(&:last).uniq).to eq([{ 'acknowledged' => [event[:event_id]] }])
      expect(VetorialAgent::Execution.count).to eq(1)
      audit = deployment.audits.find_by!(action: 'telemetry', idempotency_key: 'concurrent-key')
      expect(audit.expires_at).to be_within(5.seconds).of(24.hours.from_now)
    end
  end

  it 'returns correct live aggregates with a Sao Paulo month and integer micro-USD costs' do
    travel_to Time.utc(2026, 11, 13, 12) do
      conversation = SecureRandom.uuid
      events = [
        execution(conversation_id: conversation), execution(conversation_id: conversation),
        execution(outcome: 'paused'), execution(outcome: 'resumed'),
        execution(outcome: 'booking_confirmed'), execution(status: 'failed', outcome: 'none'),
        usage(cost: 125), usage(cost: 75), usage(cost: nil, state: 'unknown'), heartbeat
      ]
      post_events(events, key: 'aggregate-fixture')
      expect(response).to have_http_status(:ok)

      metrics = VetorialAgent::Metrics.new(deployment, source: 'live', now: Time.current).call
      expect(metrics).to include(timezone: 'America/Sao_Paulo', conversations: 1, responses: 2,
                                 pauses: 1, returns: 1, appointments: 1, errors: 1,
                                 cost_micro_usd: 200, month_cost_micro_usd: 200,
                                 usage_known: 2, usage_unknown: 1)
      expect(metrics[:month_cost_micro_usd]).to be_a(Integer)
      expect(metrics[:latency]).to eq(n: 2, p50_ms: 250, p95_ms: 250)
      expect(metrics[:recent_executions].size).to eq(6)
      expect(metrics[:recent_executions].map { |row| row[:cost_micro_usd] }).to all(be_nil)
      expect(metrics[:recent_executions].first.keys).to match_array(%i[role status revision occurred_at latency_ms cost_micro_usd])
      empty = VetorialAgent::Metrics.new(deployment, source: 'test', now: Time.current).call
      expect(empty[:latency]).to eq(n: 0, p50_ms: nil, p95_ms: nil)
      expect(empty[:recent_executions]).to eq([])
      expect(Time.iso8601(metrics[:from])).to eq(Time.utc(2026, 11, 1, 3))
      expect(deployment.reload.runtime_statuses.first).to have_attributes(revision: 1, policy_epoch: 1, sha256: 'a' * 64)
    end
  end

  it 'derives health from applied ack and heartbeat age, ignoring late redelivery' do
    travel_to Time.utc(2026, 11, 13, 12) do
      payload = JSON.parse(File.read(Rails.root.join('spec/fixtures/vetorial_agent/snapshot.json')))['payload']
      payload['deployment_id'] = deployment.id
      revision = deployment.revisions.create!(number: 1, payload: payload,
        sha256: VetorialAgent::Snapshot.digest(payload), status: 'published')
      deployment.update!(active_revision: revision, policy_epoch: payload['policy_epoch'])
      profile = deployment.profiles.create!(role: 'atendimento', name: 'Synthetic heartbeat')
      view = -> { VetorialAgent::ProfileView.summary(profile) }
      expect(view.call[:health]).to eq('unavailable')
      event = heartbeat(occurred_at: Time.current).merge(sha256: revision.sha256, policy_epoch: deployment.policy_epoch)
      post_events([event], key: 'healthy-ack')
      expect(response).to have_http_status(:ok)
      expect(view.call).to include(health: 'healthy', applied_revision: revision.id, applied_version: 1)
      travel 45.seconds
      expect(view.call[:health]).to eq('healthy')
      travel 1.second
      expect(view.call[:health]).to eq('delayed')
      travel 44.seconds
      expect(view.call[:health]).to eq('delayed')
      travel 1.second
      expect(view.call[:health]).to eq('unavailable')

      divergent = event.merge(event_id: SecureRandom.uuid, occurred_ms: (Time.current.to_f * 1000).to_i, revision: 2)
      post_events([divergent], key: 'divergent-ack')
      expect(view.call).to include(health: 'awaiting_configuration', applied_version: 2, desired_version: 1, applied_revision: nil)
      late = event.merge(event_id: SecureRandom.uuid)
      post_events([late], key: 'late-heartbeat')
      expect(view.call[:applied_version]).to eq(2)
      epoch = event.merge(event_id: SecureRandom.uuid, occurred_ms: ((Time.current.to_f + 1) * 1000).to_i,
                          policy_epoch: deployment.policy_epoch + 1)
      travel 1.second
      post_events([epoch], key: 'divergent-epoch')
      expect(view.call[:health]).to eq('awaiting_configuration')
    end
  end

  it 'persists the version consulted for unknown usage without inventing a zero cost' do
    event = usage(cost: nil, state: 'unknown').merge(pricing_version: '2026-11-13.v1')
    post_events([event], key: 'j8-unknown-version')
    expect(response).to have_http_status(:ok)
    saved = deployment.usages.find_by!(call_id: event[:call_id])
    expect(saved.attributes).to include('pricing_version' => '2026-11-13.v1', 'cost_micro_usd' => nil, 'usage_state' => 'unknown')
    event[:event_id] = SecureRandom.uuid
    event[:pricing_version] = 'sk-j8-secret-canary'
    post_events([event], key: 'j8-invalid-version')
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'accepts all five probed states and exposes only their allowlisted values' do
    event = heartbeat(occurred_at: Time.current)
    event[:integrations] = { openai: 'configured', groq: 'absent', calendly: 'error', google_gateway: 'configured', evolution: 'error' }
    post_events([event], key: 'j8-five-integrations')
    expect(response).to have_http_status(:ok)
    expect(VetorialAgent::Integrations.new(deployment).call).to eq(event[:integrations].stringify_keys)
  end

end
