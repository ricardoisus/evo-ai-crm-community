require 'rails_helper'

RSpec.describe Api::V1::VetorialAgentsController, type: :controller do
  let(:user) { User.new(id: SecureRandom.uuid) }
  let(:data) { JSON.parse(File.read(Rails.root.join('spec/fixtures/vetorial_agent/snapshot.json')))['payload'] }
  let(:bot) { AgentBot.create!(name: 'Synthetic controller', outgoing_url: 'http://agent.invalid') }
  let(:deployment) { VetorialAgent::Deployment.create!(agent_bot: bot, slug: 'synthetic') }
  let(:profile) do
    payload = data.merge('deployment_id' => deployment.id)
    revision = deployment.revisions.create!(number: 1, status: 'published', payload: payload, sha256: VetorialAgent::Snapshot.digest(payload))
    deployment.update!(active_revision: revision)
    deployment.profiles.create!(role: 'atendimento', name: 'Synthetic')
  end

  before do
    allow(user).to receive(:administrator?).and_return(false)
    allow(controller).to receive(:authenticate_request!) { Current.user = user }
    allow(controller).to receive(:check_permission!).and_return(true)
    allow(user).to receive(:assigned_inboxes).and_return(Inbox.where(id: []))
  end

  after { Current.reset }

  it 'returns 404 outside the authorized inbox scope' do
    get :show, params: { id: profile.id }
    expect(response.status).to eq(404)
    expect(response.body).not_to include(data['roles']['atendimento']['prompt'])
  end

  it 'allows read-only profile access and rejects editing by a non-admin' do
    record = profile
    scope = double('inbox scope', pluck: data['binding']['inbox_ids'])
    allow(user).to receive(:assigned_inboxes).and_return(scope)
    get :show, params: { id: record.id }
    expect(response.status).to eq(200)
    expect(response.parsed_body.dig('data', 'source')).to eq('vetorial_runtime')
    post :create_revision, params: { id: record.id, payload: data }
    expect(response.status).to eq(403)
  end

  it 'serves inbox-scoped telemetry metrics to a read-only user' do
    record = profile
    allow(user).to receive(:assigned_inboxes).and_return(double('inbox scope', pluck: data['binding']['inbox_ids']))
    deployment.executions.create!(execution_id: SecureRandom.uuid, conversation_id: SecureRandom.uuid,
                                  role: 'atendimento', source: 'live', revision: 1, policy_epoch: 1,
                                  status: 'succeeded', latency_ms: 100, outcome: 'send_confirmed', occurred_at: Time.current)

    get :metrics, params: { id: record.id, source: 'live' }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('data', 'conversations')).to eq(1)
  end
  it 'serves only closed integration states to an inbox-scoped reader, including stale and poisoned status' do
    record = profile
    allow(user).to receive(:assigned_inboxes).and_return(double('inbox scope', pluck: data['binding']['inbox_ids']))
    poison = 'sk-j8-secret-canary token-j8-canary +5511987654321 https://private.invalid/auth'
    status = VetorialAgent::RuntimeStatus.create!(deployment: deployment, instance_id: SecureRandom.uuid,
      revision: 1, policy_epoch: 1, sha256: 'a' * 64, heartbeat_at: Time.current,
      integrations: { openai: 'configured', groq: 'absent', calendly: 'error', google_gateway: poison, evolution: 'configured', token: poison })
    replies = []
    get :integrations, params: { id: record.id }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['data']).to eq('openai' => 'configured', 'groq' => 'absent', 'calendly' => 'error',
                                              'google_gateway' => 'error', 'evolution' => 'configured')
    replies << response.body.dup
    status.update!(heartbeat_at: 91.seconds.ago)
    get :integrations, params: { id: record.id }
    expect(response.parsed_body['data'].values.uniq).to eq(['error'])
    replies << response.body.dup
    status.destroy!
    get :integrations, params: { id: record.id }
    expect(response.parsed_body['data'].values.uniq).to eq(['error'])
    replies << response.body.dup
    allow(user).to receive(:assigned_inboxes).and_return(Inbox.none)
    get :integrations, params: { id: record.id }
    expect(response).to have_http_status(:not_found)
    replies << response.body.dup
    replies.each do |body|
      poison.split.each { |value| expect(body).not_to include(value) }
      expect(body).not_to match(/\+?55\d{10,11}/)
    end
  end

end
