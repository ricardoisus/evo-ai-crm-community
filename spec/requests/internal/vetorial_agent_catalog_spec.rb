require 'rails_helper'
RSpec.describe 'Agent catalog C2', type: :request do
  let(:user) { User.new(id: SecureRandom.uuid) }
  let(:payload) { JSON.parse(File.read(Rails.root.join('spec/fixtures/vetorial_agent/snapshot.json')))['payload'] }
  let(:native) { { 'data' => [{ 'id' => 'core', 'custom' => true }], 'meta' => { 'total' => 41, 'page' => 2 }, 'extra' => 'preserved' } }
  before do
    allow_any_instance_of(Api::V1::BaseController).to receive(:authenticate_request!) { Current.user = user }
    allow_any_instance_of(Api::V1::BaseController).to receive(:has_user_permission?).and_return(true)
    allow(user).to receive(:assigned_inboxes).and_return(double(pluck: payload['binding']['inbox_ids']))
    allow(EvoAiCoreService).to receive(:catalog_agents).and_return(status: 200, body: native)
    deployment = VetorialAgent::Deployment.create!(agent_bot: AgentBot.create!(name: 'Catalog'), slug: 'catalog')
    data = payload.merge('deployment_id' => deployment.id)
    revision = deployment.revisions.create!(number: 1, status: 'published', payload: data, sha256: VetorialAgent::Snapshot.digest(data))
    deployment.update!(active_revision: revision)
    %w[atendimento analista].each { |role| deployment.profiles.create!(role: role, name: role) }
  end
  after { Current.reset }
  [1, 2, 3].each do |page|
    it "preserves Core and fixed managed group on page #{page}" do
      filters = { 'page' => page.to_s, 'pageSize' => '20', 'filters' => { 'operator' => 'OR', 'conditions' => ['native'] } }
      expect(EvoAiCoreService).to receive(:catalog_agents).with(hash_including(filters), anything).and_return(status: 200, body: native)
      get '/api/v1/agent_catalog', params: filters
      expect(response.status).to eq(200)
      data = response.parsed_body['data']
      expect(data['native']).to eq(native)
      expect(data['managed'].map { |p| p['role'] }.sort).to eq(%w[analista atendimento])
      expect(data['managed'].map { |p| p['catalog_id'] }.uniq.size).to eq(2)
      expect(data['native']['meta']['total'] + data['managed'].size).to eq(43)
    end
  end
  it 'forwards only explicit Core query and filter fields' do
    accepted = { 'page' => '2', 'page_size' => '24', 'search' => 'test', 'folder_id' => 'folder',
      'filters' => { '0' => { 'attribute_key' => 'type', 'filter_operator' => 'equal_to', 'values' => 'llm', 'query_operator' => 'and' } } }
    supplied = accepted.deep_dup
    supplied['admin'] = 'true'
    supplied['account_id'] = 'other'
    supplied['filters']['0']['admin'] = 'true'
    expect(EvoAiCoreService).to receive(:catalog_agents).with(accepted, anything).and_return(status: 200, body: native)
    get '/api/v1/agent_catalog', params: supplied
    expect(response.status).to eq(200)
  end

  it 'accepts exactly MAX_MANAGED profiles and rejects excess before Core' do
    4.times do |i|
      deployment = VetorialAgent::Deployment.create!(agent_bot: AgentBot.create!(name: "Catalog #{i}"), slug: "catalog-#{i}")
      data = payload.merge('deployment_id' => deployment.id)
      revision = deployment.revisions.create!(number: 1, status: 'published', payload: data, sha256: VetorialAgent::Snapshot.digest(data))
      deployment.update!(active_revision: revision)
      %w[atendimento analista].each { |role| deployment.profiles.create!(role: role, name: role) }
    end
    get '/api/v1/agent_catalog'
    expect(response.parsed_body.dig('data', 'managed').size).to eq(10)
    deployment = VetorialAgent::Deployment.create!(agent_bot: AgentBot.create!(name: 'Excess'), slug: 'catalog-excess')
    deployment.profiles.create!(role: 'atendimento', name: 'Excess')
    expect(EvoAiCoreService).not_to receive(:catalog_agents)
    get '/api/v1/agent_catalog'
    expect(response.status).to eq(500)
  end

  it 'filters managed by search/mode/health/source without changing native' do
    get '/api/v1/agent_catalog', params: { search: 'ANALISTA', mode: 'pilot', health: 'unavailable' }
    expect(response.parsed_body.dig('data', 'managed').map { |p| p['role'] }).to eq(['analista'])
    expect(response.parsed_body.dig('data', 'native')).to eq(native)
    get '/api/v1/agent_catalog', params: { mode: 'all' }
    expect(response.parsed_body.dig('data', 'managed')).to eq([])
    get '/api/v1/agent_catalog', params: { source: 'core' }
    expect(response.parsed_body.dig('data', 'managed')).to eq([])
    expect(EvoAiCoreService).not_to receive(:catalog_agents)
    get '/api/v1/agent_catalog', params: { source: 'vetorial_runtime' }
    expect(response.parsed_body.dig('data', 'managed').size).to eq(2)
    expect(response.parsed_body.dig('data', 'native')).to be_nil
    expect(response.parsed_body.dig('meta', 'partial')).to be(false)
  end
  it 'hides managed for folders and unauthorized inboxes' do
    get '/api/v1/agent_catalog', params: { folder_id: 'folder', filters: { operator: 'AND' } }
    expect(response.parsed_body.dig('data', 'managed')).to eq([])
    allow(user).to receive(:assigned_inboxes).and_return(double(pluck: []))
    get '/api/v1/agent_catalog'
    expect(response.parsed_body.dig('data', 'managed')).to eq([])
  end
  it 'returns partial on 503 and propagates Core 401/403' do
    allow(EvoAiCoreService).to receive(:catalog_agents).and_return(status: 503, body: nil)
    get '/api/v1/agent_catalog'
    expect(response.parsed_body.dig('data', 'managed').size).to eq(2)
    expect(response.parsed_body['meta']).to eq('partial' => true, 'unavailable_sources' => ['core'])
    [401, 403].each do |status|
      allow(EvoAiCoreService).to receive(:catalog_agents).and_return(status: status, body: {})
      get '/api/v1/agent_catalog'
      expect(response.status).to eq(status)
      expect(response.body).to be_empty
    end
  end
  it 'denies missing permission before contacting Core' do
    allow_any_instance_of(Api::V1::BaseController).to receive(:has_user_permission?).and_return(false)
    expect(EvoAiCoreService).not_to receive(:catalog_agents)
    get '/api/v1/agent_catalog'
    expect(response.status).to eq(403)
  end
  [true, false].each do |admin|
    it "allows catalog reads for #{admin ? 'admin' : 'agent'} with the read grant" do
      allow(user).to receive(:administrator?).and_return(admin)
      get '/api/v1/agent_catalog'
      expect(response.status).to eq(200)
      expect(response.parsed_body.dig('data', 'native')).to eq(native)
    end
  end

end
