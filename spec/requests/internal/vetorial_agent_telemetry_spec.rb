require 'rails_helper'

RSpec.describe 'Internal Vetorial telemetry API', type: :request do
  self.use_transactional_tests = false

  let(:secret) { "synthetic-telemetry-#{('x' * 32)}" }
  let(:path) { '/internal/vetorial_agent/telemetry' }

  before do
    [VetorialAgent::TelemetryEvent, VetorialAgent::Usage, VetorialAgent::Execution,
     VetorialAgent::RuntimeStatus, VetorialAgent::Audit, VetorialAgent::Profile,
     VetorialAgent::Revision, VetorialAgent::Deployment].each(&:delete_all)
    AgentBot.where(name: 'Synthetic telemetry').delete_all
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).with('VETORIAL_AGENT_SECRET_FILE').and_return(nil)
    allow(ENV).to receive(:fetch).with('VETORIAL_AGENT_SECRET', '').and_return(secret)
  end

  after do
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

  it 'serializes concurrent requests with the same idempotency key and stores one response for 24 hours' do
    event = execution
    results = Queue.new
    threads = Array.new(4) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          results << VetorialAgent::Telemetry.new([event], idempotency_key: 'concurrent-key').call
        end
      end
    end
    threads.each(&:join)

    expect(Array.new(4) { results.pop }.uniq).to eq([{ 'acknowledged' => [event[:event_id]] }])
    expect(VetorialAgent::Execution.count).to eq(1)
    audit = deployment.audits.find_by!(action: 'telemetry', idempotency_key: 'concurrent-key')
    expect(audit.expires_at).to be_within(5.seconds).of(24.hours.from_now)
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
      expect(Time.iso8601(metrics[:from])).to eq(Time.utc(2026, 11, 1, 3))
      expect(deployment.reload.runtime_statuses.first).to have_attributes(revision: 1, policy_epoch: 1, sha256: 'a' * 64)
    end
  end
end
