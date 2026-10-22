ENV['RAILS_ENV'] = 'test'
require_relative '../../../config/environment'
require 'webmock/rspec'

RSpec.describe Instagram::AmhGraph do
  let(:graph) do
    value = described_class.initial
    value['nodes'].find { |n| n['type'] == 'scope' }['data'] = { 'account' => '90001', 'media' => '90004' }
    value
  end
  it 'validates the initial graph and both condition outputs without any transport' do
    expect { described_class.validate!(graph) }.not_to raise_error
    yes = described_class.simulate(graph, fixture: 'eligible', text: 'Quero AMH!')
    no = described_class.simulate(graph, fixture: 'negative')
    expect(yes[:outcome]).to eq('simulated_accepted')
    expect(no[:trace].map { |t| t[:node] }).to eq(%w[comment scope keyword stop])
    expect(no[:outcome]).to eq('blocked')
    expect(yes[:outbound_calls]).to eq(0)
  end
  it 'allows incomplete drafts but blocks disconnected, cyclic and unconfirmed publication' do
    graph['edges'].reject! { |e| e['source'] == 'keyword' }
    expect { described_class.validate_draft!(graph) }.not_to raise_error
    expect { described_class.validate!(graph) }.to raise_error(described_class::Invalid) { |e| expect(e.issues).to include(hash_including(node: 'keyword')) }
    graph['edges'] << { 'id' => 'cycle', 'source' => 'keyword', 'sourceHandle' => 'match', 'target' => 'scope' }
    expect { described_class.validate!(graph) }.to raise_error(described_class::Invalid)
  end
  it 'refuses a delivery that bypasses the real click' do
    graph['edges'].find { |e| e['source'] == 'like' && e['sourceHandle'] == 'success' }['target'] = 'delivery'
    expect { described_class.validate!(graph) }.to raise_error(described_class::Invalid) { |e| expect(e.issues.any? { |i| i[:message].include?('clique real') }).to be true }
  end
  it 'keeps functional digest stable across positions, node order and edge IDs' do
    moved = graph.deep_dup
    moved['nodes'].reverse!
    moved['nodes'].first['position']['x'] = 999
    moved['edges'].reverse!
    moved['edges'].first['id'] = 'new-id'
    expect(described_class.digest(moved)).to eq(described_class.digest(graph))
    moved['nodes'].find { |n| n['type'] == 'invitation' }['data']['text'] = 'Outra mensagem'
    expect(described_class.digest(moved)).not_to eq(described_class.digest(graph))
  end
  it 'uses the real inventory and caption resolver in the inert simulator' do
    graph['nodes'].find { |n| n['type'] == 'material' }['data'] = { 'mode' => 'context', 'mappings' => [], 'routes' => [{ 'material' => 'amh', 'keywords' => ['highlights'] }] }
    expect(described_class.simulate(graph, fixture: 'eligible')[:outcome]).to eq('blocked')
    expect(described_class.simulate(graph, fixture: 'eligible', context: { 'caption' => 'highlights' })[:material]).to eq('amh')
  end
  it 'rejects missing or non-string comment text in the v2 registration binding' do
    [nil, 123, {}].each do |text|
      expect { Instagram::AmhRegistrationBinding.send(:validate_graph_context!, { 'comment_text' => text }, graph) }
        .to raise_error(Instagram::AmhShortLink::Unavailable)
    end
  end
  it 'never follows a connection on uncertain results or repeated comments' do
    %w[timeout repeated].each do |fixture|
      result = described_class.simulate(graph, fixture: fixture)
      expect(result[:trace].none? { |t| t[:type] == 'delivery' }).to be true
    end
  end
end

RSpec.describe 'Instagram v2 graph transport and persistence' do
  let(:reserved) { 'c683ea27-bad5-4c83-9573-e4aca4bcc28a' }
  let(:graph) do
    g = Instagram::AmhGraph.initial
    g['nodes'].find { |n| n['type'] == 'scope' }['data'] = { 'account' => '90001', 'media' => '90004' }
    g
  end
  let(:proof) do
    p = Instagram::AmhVisualProof.create!(name: 'Graph QA', draft: graph, create_key: SecureRandom.uuid)
    p.publish_version!(p.lock_version, 'qa')
    p.reload.update!(active_version_id: p.versions.last['id'], audience: 'test', activated_at: 1.hour.ago)
    p
  end
  let(:contract) { { 'identity' => { 'professional_account_id' => '90001', 'app_id' => '90003', 'igsid' => '90002' }, 'kind' => 'comment', 'event_id' => '90009', 'occurred_at' => 5.minutes.ago.iso8601, 'time_source' => 'webhook_entry', 'media_id' => '90004', 'comment_text' => 'Quero AMH!' } }
  let(:event) { Instagram::AmhInboundEvent.create!(inbox_id: reserved, event_key: SecureRandom.hex(32), encrypted_contract: Instagram::AmhInboundEvent.encryptor.encrypt_and_sign(contract)) }
  around do |example|
    raise 'Isolated DB required' unless ActiveRecord::Base.connection_db_config.database == 'instagram_amh_safety_test'
    keys = %w[INSTAGRAM_AMH_EXECUTION_ENABLED INSTAGRAM_AMH_LINK_QA_ENABLED INSTAGRAM_AMH_TEST_IGSIDS INSTAGRAM_AMH_PROFESSIONAL_ACCOUNT_ID INSTAGRAM_AMH_RESERVED_INBOX_ID INSTAGRAM_AMH_INBOX_IDS INSTAGRAM_AMH_APP_ID INSTAGRAM_AMH_LIKES_ENABLED]
    previous = ENV.to_h.slice(*keys)
    ENV.update('INSTAGRAM_AMH_EXECUTION_ENABLED' => 'true', 'INSTAGRAM_AMH_LINK_QA_ENABLED' => 'true', 'INSTAGRAM_AMH_TEST_IGSIDS' => '90002', 'INSTAGRAM_AMH_PROFESSIONAL_ACCOUNT_ID' => '90001', 'INSTAGRAM_AMH_RESERVED_INBOX_ID' => reserved, 'INSTAGRAM_AMH_INBOX_IDS' => reserved, 'INSTAGRAM_AMH_APP_ID' => '90003', 'INSTAGRAM_AMH_LIKES_ENABLED' => 'false')
    WebMock.disable_net_connect!
    ActiveRecord::Base.transaction { example.run; raise ActiveRecord::Rollback }
  ensure
    keys.each { |k| ENV[k] = previous[k] }
    Current.reset
    WebMock.allow_net_connect!
  end
  before do
    allow(GlobalConfigService).to receive(:load).with('INSTAGRAM_APP_ID', '').and_return('90003')
    channel = Channel::Instagram.create!(instagram_id: '90001', access_token: 'inert-qa', expires_at: 1.day.from_now)
    Inbox.create!(id: reserved, channel: channel, name: 'QA')
    stub_request(:get, 'https://graph.instagram.com/v23.0/90002?fields=name').to_return(status: 200, body: '{"name":"Jonas"}', headers: { 'Content-Type' => 'application/json' })
  end
  def run_graph
    Instagram::AmhExecutor.call(event: event, proof: proof, explicit_test: true)
  end
  def click(row)
    c = { 'kind' => 'dm', 'identity' => contract['identity'], 'event_id' => SecureRandom.uuid, 'occurred_at' => Time.current.iso8601(6), 'confirmation_source' => 'quick_reply', 'amh_confirmation' => Instagram::AmhConfirmationToken.issue(row) }
    Instagram::AmhInboundEvent.create!(inbox_id: reserved, event_key: SecureRandom.hex(32), encrypted_contract: Instagram::AmhInboundEvent.encryptor.encrypt_and_sign(c))
  end
  it 'follows the drawn path, continues after public failure/like block, waits for a real click and deduplicates' do
    messages = stub_request(:post, 'https://graph.instagram.com/v23.0/90001/messages').to_return(status: 200, body: '{"message_id":"qa"}', headers: { 'Content-Type' => 'application/json' })
    public_reply = stub_request(:post, 'https://graph.instagram.com/v23.0/90009/replies').to_return(status: 400, body: '{"error":{"code":1}}', headers: { 'Content-Type' => 'application/json' })
    row = run_graph.reload
    expect(row.state).to eq('awaiting_confirmation')
    expect(row.graph_cursor).to eq('confirmation')
    expect(row.public_reply_state).to eq('failed')
    expect(row.like_state).to eq('blocked')
    expect(row.execution_trace.any? { |t| t['node'] == 'public_reply' && t['port'] == 'failed' }).to be true
    run_graph
    expect(messages).to have_been_requested.once
    callback = click(row)
    Instagram::AmhConfirmation.call(event: callback)
    expect(row.reload.state).to eq('accepted')
    expect(row.graph_cursor).to be_nil
    Instagram::AmhConfirmation.call(event: callback)
    expect(messages).to have_been_requested.twice
    expect(public_reply).to have_been_requested.once
    expect(Instagram::AmhShortLink.count).to eq(1)
  end
  it 'stops uncertain invitations and never repeats a reserved request' do
    request = stub_request(:post, 'https://graph.instagram.com/v23.0/90001/messages').to_timeout
    row = run_graph.reload
    expect(row.state).to eq('uncertain')
    expect(row.graph_cursor).to be_nil
    run_graph
    expect(request).to have_been_requested.once
  end
  it 'restores the complete published graph without changing execution and refuses stale discard' do
    published = proof.versions.last['graph'].deep_dup
    proof.update!(draft: graph.merge('nodes' => graph['nodes'].reverse))
    active_id = proof.active_version_id
    expect { proof.discard_draft!(proof.lock_version - 1) }.to raise_error(ActiveRecord::StaleObjectError)
    proof.discard_draft!(proof.lock_version)
    expect(proof.reload.draft).to eq(published)
    expect(proof.active_version_id).to eq(active_id)
    expect(proof.audience).to eq('test')
  end
  it 'follows the negative keyword branch into another configured condition' do
    graph['nodes'] << { 'id' => 'guide', 'type' => 'keyword', 'position' => { 'x' => 300, 'y' => 500 },
                       'data' => { 'keywords' => ['GUIA'], 'mode' => 'word', 'ignoreCase' => true, 'ignoreAccents' => true } }
    graph['edges'].find { |e| e['source'] == 'keyword' && e['sourceHandle'] == 'no_match' }['target'] = 'guide'
    graph['edges'] += [{ 'id' => 'guide-yes', 'source' => 'guide', 'sourceHandle' => 'match', 'target' => 'material' },
                      { 'id' => 'guide-no', 'source' => 'guide', 'sourceHandle' => 'no_match', 'target' => 'stop' }]
    contract['comment_text'] = 'Quero o GUIA'
    stub_request(:post, 'https://graph.instagram.com/v23.0/90001/messages').to_return(status: 200, body: '{"message_id":"qa"}', headers: { 'Content-Type' => 'application/json' })
    stub_request(:post, 'https://graph.instagram.com/v23.0/90009/replies').to_return(status: 400, body: '{}')
    row = run_graph
    expect(row.state).to eq('awaiting_confirmation')
    expect(row.execution_trace).to include(hash_including('node' => 'keyword', 'port' => 'no_match'))
    expect(row.execution_trace).to include(hash_including('node' => 'guide', 'port' => 'match'))
    simulated = Instagram::AmhGraph.simulate(graph, fixture: 'eligible', text: contract['comment_text'])
    expect(simulated[:trace].map { |t| t[:node] }.take(5)).to eq(%w[comment scope keyword guide material])
  end

  it 'executes the material blocked branch using the same resolution rules as simulation' do
    graph['nodes'].find { |n| n['type'] == 'material' }['data'] = { 'mode' => 'context', 'mappings' => [], 'routes' => [{ 'material' => 'amh', 'keywords' => ['highlights'] }] }
    graph['nodes'] << { 'id' => 'fallback', 'type' => 'material', 'position' => { 'x' => 500, 'y' => 500 }, 'data' => { 'material' => 'amh-consultorio' } }
    graph['edges'].find { |e| e['source'] == 'material' && e['sourceHandle'] == 'blocked' }['target'] = 'fallback'
    graph['edges'] += [{ 'id' => 'fallback-yes', 'source' => 'fallback', 'sourceHandle' => 'success', 'target' => 'invitation' },
                      { 'id' => 'fallback-no', 'source' => 'fallback', 'sourceHandle' => 'blocked', 'target' => 'stop' }]
    stub_request(:get, 'https://graph.instagram.com/v23.0/90004?fields=id,caption').to_return(status: 200, body: '{"id":"90004","caption":"Outro assunto"}', headers: { 'Content-Type' => 'application/json' })
    stub_request(:post, 'https://graph.instagram.com/v23.0/90001/messages').to_return(status: 200, body: '{"message_id":"qa"}', headers: { 'Content-Type' => 'application/json' })
    stub_request(:post, 'https://graph.instagram.com/v23.0/90009/replies').to_return(status: 400, body: '{}')
    row = run_graph
    expect(row.resolved_material).to eq('amh-consultorio')
    expect(row.execution_trace).to include(hash_including('node' => 'material', 'port' => 'blocked'))
    simulated = Instagram::AmhGraph.simulate(graph, fixture: 'eligible', context: { 'caption' => 'Outro assunto' })
    expect(simulated[:material]).to eq(row.resolved_material)
  end

  it 'keeps layout-only publication eligible after a successful real controlled receipt' do
    stub_request(:post, 'https://graph.instagram.com/v23.0/90001/messages').to_return(status: 200, body: '{"message_id":"qa"}', headers: { 'Content-Type' => 'application/json' })
    stub_request(:post, 'https://graph.instagram.com/v23.0/90009/replies').to_return(status: 200, body: '{"id":"public-qa"}', headers: { 'Content-Type' => 'application/json' })
    row = run_graph
    Instagram::AmhConfirmation.call(event: click(row))
    changed = graph.deep_dup
    changed['nodes'].first['position']['x'] = 999
    proof.reload.update!(draft: changed)
    proof.publish_version!(proof.lock_version, 'qa')
    expect(proof.activation_readiness(proof.versions.last)['eligible']).to be true
    changed['nodes'].find { |n| n['type'] == 'invitation' }['data']['text'] = 'Novo convite'
    proof.update!(draft: changed)
    proof.publish_version!(proof.lock_version, 'qa')
    expect(proof.activation_readiness(proof.versions.last)['eligible']).to be false
  end

  it 'refuses forged callbacks and stops pending callbacks when paused' do
    messages = stub_request(:post, 'https://graph.instagram.com/v23.0/90001/messages').to_return(status: 200, body: '{"message_id":"qa"}', headers: { 'Content-Type' => 'application/json' })
    stub_request(:post, 'https://graph.instagram.com/v23.0/90009/replies').to_return(status: 400, body: '{}')
    row = run_graph
    callback = click(row)
    original = callback.contract
    original['identity']['igsid'] = '90099'
    callback.update!(encrypted_contract: Instagram::AmhInboundEvent.encryptor.encrypt_and_sign(original))
    expect { Instagram::AmhConfirmation.call(event: callback) }.to raise_error(Instagram::AmhExecutor::Unavailable)
    callback = click(row)
    proof.update!(audience: 'paused')
    expect { Instagram::AmhConfirmation.call(event: callback) }.to raise_error(Instagram::AmhExecutor::Unavailable)
    expect(messages).to have_been_requested.once
  end

  it 'saves incomplete drafts over HTTP, returns node issues, and discards with optimistic locking' do
    client = ActionDispatch::Integration::Session.new(Rails.application)
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = User.new(id: 'cf931b4c-d5ef-4358-8688-4631b284fe8b', name: 'QA', email: 'qa@example.invalid')
      Current.evo_permission_cache = {}
    end
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission).and_return(true)
    key = proof.id
    revision = proof.lock_version
    incomplete = graph.deep_dup
    incomplete['edges'].reject! { |e| e['source'] == 'keyword' }
    client.patch("/api/v1/instagram_amh_proofs/#{key}", params: { graph: incomplete, lock_version: revision }, as: :json)
    expect(client.response.status).to eq(200)
    saved = JSON.parse(client.response.body)['data']
    client.post("/api/v1/instagram_amh_proofs/#{key}/publish", params: { lock_version: saved['lock_version'] }, as: :json)
    expect(client.response.status).to eq(422)
    expect(JSON.parse(client.response.body).dig('error', 'details')).to include(hash_including('node' => 'keyword'))
    client.post("/api/v1/instagram_amh_proofs/#{key}/discard", params: { lock_version: revision }, as: :json)
    expect(client.response.status).to eq(409)
    client.post("/api/v1/instagram_amh_proofs/#{key}/discard", params: { lock_version: saved['lock_version'] }, as: :json)
    expect(client.response.status).to eq(200)
    expect(proof.reload.draft).to eq(proof.versions.last['graph'])
    expect(proof.audience).to eq('test')
  end

end
