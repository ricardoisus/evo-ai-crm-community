require 'rails_helper'

RSpec.describe 'Managed synthetic test sessions', type: :request do
  let(:user) { User.create!(name: 'Synthetic J10', email: "j10-#{SecureRandom.hex(4)}@example.invalid") }
  let(:deployment) { VetorialAgent::Deployment.create!(agent_bot: AgentBot.create!(name: 'J10'), slug: 'j10', control_source: 'crm') }
  let(:payload) do
    data = JSON.parse(File.read(Rails.root.join('spec/fixtures/vetorial_agent/snapshot.json')))['payload'].merge('deployment_id' => deployment.id)
    schema = { 'type' => 'object', 'properties' => {
      'acao' => { 'type' => 'string' }, 'mensagens' => { 'type' => 'array', 'items' => { 'type' => 'string' } },
      'motivo_interno' => { 'type' => 'string' } }, 'required' => %w[acao mensagens motivo_interno] }
    data['roles']['atendimento'].merge!('output_schema' => schema, 'actions' => { 'actions' => {}, 'output_schema' => schema })
    data['limits'] = { 'max_output_tokens' => 2500, 'max_tool_rounds' => 8, 'blocks_per_reply' => 5, 'chars_per_block' => 300 }
    data['runtime'] = { 'safety_addendum' => 'Somente simulação.' }
    data['provider'] = { 'project_id' => 'proj_synthetic', 'service_tier' => 'default', 'reasoning' => 'low' }
    data
  end
  let!(:revision) do
    published = deployment.revisions.create!(number: 1, status: 'published', payload: payload, sha256: VetorialAgent::Snapshot.digest(payload))
    deployment.update!(active_revision: published)
    deployment.revisions.create!(number: 2, status: 'draft', payload: payload, sha256: VetorialAgent::Snapshot.digest(payload))
  end
  let!(:profile) { deployment.profiles.create!(role: 'atendimento', name: 'J10') }
  let(:path) { "/api/v1/vetorial_agents/#{profile.id}/test_sessions" }
  let(:key) { SecureRandom.uuid }
  let(:input) { { revision_id: revision.id, purpose: 'Conferir resposta', criteria: 'Somente sintético', sample_count: 3 } }
  let(:requests) { [] }

  before do
    allow_any_instance_of(Api::V1::BaseController).to receive(:authenticate_request!) { Current.user = user }
    allow_any_instance_of(Api::V1::BaseController).to receive(:has_user_permission?).and_return(true)
    allow(user).to receive(:administrator?).and_return(false)
    allow(user).to receive(:assigned_inboxes).and_return(double(pluck: payload['binding']['inbox_ids']))
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('VETORIAL_AGENT_URL').and_return('http://runtime.invalid')
    allow(VetorialAgent::Policy).to receive(:secret).and_return('synthetic-j10-secret-' * 3)
    allow(HTTParty).to receive(:post) do |url, body:, headers:, timeout:|
      route = URI(url).path
      expect(VetorialAgent::Signature.valid?(body, headers, method: 'POST', path: route)).to be(true)
      data = JSON.parse(body)
      requests << [route, data]
      result = route.end_with?('/turns') ? { 'mensagens' => ['Resposta simulada'] } : { 'mode' => 'simulation', 'ceiling_micro_usd' => 50000, 'spent_reserved_micro_usd' => 0 }
      double(code: 200, body: { data: result }.to_json)
    end
  end
  after { Current.reset }

  def start_test_session
    post path, params: input, headers: { 'Idempotency-Key' => key }, as: :json
    expect(response.status).to eq(200)
    response.parsed_body.dig('data', 'id')
  end

  it 'pins the requested draft, allocates once and keeps history without live effects or a CRM ledger' do
    expect(VetorialAgent::Transport).not_to receive(:new)
    expect(VetorialAgent::Capture).not_to receive(:persist)
    sid = start_test_session
    expect(start_test_session).to eq(sid)
    expect(requests.count { |_, data| data['action'] == 'create' }).to eq(1)
    creation = requests.find { |_, data| data['action'] == 'create' }.last
    expect(creation.slice('actor_id', 'role', 'snapshot')).to eq('actor_id' => user.id, 'role' => 'atendimento', 'snapshot' => payload)
    rid = SecureRandom.uuid
    2.times do
      post "#{path}/#{sid}/messages", params: { text: 'Olá' }, headers: { 'Idempotency-Key' => rid }, as: :json
      expect(response.status).to eq(200)
    end
    expect(requests.count { |route, _| route.end_with?('/turns') }).to eq(1)
    expect(response.parsed_body.dig('data', 'messages').sole).to include('text' => 'Olá', 'status' => 'completed')
    post "#{path}/#{sid}/messages", params: { text: 'Alterado' }, headers: { 'Idempotency-Key' => rid }, as: :json
    expect(response.status).to eq(409)
    post "#{path}/#{sid}/close", as: :json
    expect(response.status).to eq(200)
    post "#{path}/#{sid}/messages", params: { text: 'Mais' }, headers: { 'Idempotency-Key' => SecureRandom.uuid }, as: :json
    expect(response.status).to eq(429)
    expect(VetorialAgent::Usage.count).to eq(0)
    expect(VetorialAgent::Execution.count).to eq(0)
    expect(VetorialAgent::TestSession.column_names).not_to include('spent', 'reserved', 'budget')
  end

  it 'keeps unknown intents after a lost ACK' do
    sid = start_test_session
    allow(HTTParty).to receive(:post).and_raise(Timeout::Error)
    post "#{path}/#{sid}/messages", params: { text: 'Olá' }, headers: { 'Idempotency-Key' => SecureRandom.uuid }, as: :json
    expect(response.status).to eq(503)
    expect(VetorialAgent::TestSession.find(sid).messages.sole['status']).to eq('unknown')
  end

  it 'enforces ownership and inbox scope, allowing an admin to inspect only an authorized inbox' do
    sid = start_test_session
    other = User.create!(name: 'Other', email: 'other-j10@example.invalid')
    VetorialAgent::TestSession.find(sid).update!(owner: other)
    get "#{path}/#{sid}"
    expect(response.status).to eq(404)
    allow(user).to receive(:administrator?).and_return(true)
    get "#{path}/#{sid}"
    expect(response.status).to eq(200)
    allow(user).to receive(:assigned_inboxes).and_return(double(pluck: []))
    get "#{path}/#{sid}"
    expect(response.status).to eq(404)
  end

  it 'maps runtime exhaustion to 429 and refuses missing grants' do
    allow(HTTParty).to receive(:post).and_return(double(code: 429))
    post path, params: input, headers: { 'Idempotency-Key' => key }, as: :json
    expect(response.status).to eq(429)
    expect(VetorialAgent::TestSession.sole.state).to eq('pending')
    allow_any_instance_of(Api::V1::BaseController).to receive(:has_user_permission?).and_return(false)
    post path, params: input, headers: { 'Idempotency-Key' => key }, as: :json
    expect(response.status).to eq(403)
  end

  it 'rejects out-of-scope revisions and conflicting creation keys before HTTP' do
    sid = start_test_session
    post path, params: input.merge(purpose: 'Outro propósito'), headers: { 'Idempotency-Key' => key }, as: :json
    expect(response.status).to eq(409)
    post path, params: input.merge(revision_id: SecureRandom.uuid), headers: { 'Idempotency-Key' => SecureRandom.uuid }, as: :json
    expect(response.status).to eq(404)
    expect(requests.count { |_, data| data['action'] == 'create' }).to eq(1)
    expect(VetorialAgent::TestSession.find(sid).sha256).to eq(revision.sha256)
  end

  if ENV['VETORIAL_TEST_HTTP_URL']
    it 'exercises real HMAC HTTP through the existing runtime sandbox' do
      allow(HTTParty).to receive(:post).and_call_original
      allow(ENV).to receive(:[]).with('VETORIAL_AGENT_URL').and_return(ENV.fetch('VETORIAL_TEST_HTTP_URL'))
      sid = start_test_session
      expect(response.parsed_body.dig('data', 'budget', 'mode')).to eq('simulation')
      rid = SecureRandom.uuid
      2.times do
        post "#{path}/#{sid}/messages", params: { text: 'Teste sintético integrado' }, headers: { 'Idempotency-Key' => rid }, as: :json
        expect(response.status).to eq(200), response.body
      end
      data = response.parsed_body['data']
      expect(data['messages'].size).to eq(1)
      expect(data.dig('messages', 0, 'response', 'mensagens')).to eq(['Simulação sem chamada ao modelo.'])
      expect(data.dig('budget', 'spent_reserved_micro_usd')).to eq(0)
      post "#{path}/#{sid}/close", as: :json
      expect(response.parsed_body.dig('data', 'budget', 'closed')).to be(true)
      expect(VetorialAgent::Usage.count).to eq(0)
      expect(VetorialAgent::Execution.count).to eq(0)
    end
  end

end
