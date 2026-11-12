require 'rails_helper'
require 'webmock/rspec'
WebMock.disable_net_connect!(allow_localhost: true)

RSpec.describe 'Internal Vetorial bridge API', type: :request do
  let(:secret) { 'synthetic-hmac-' + 'x' * 32 }
  let(:channel) do
    Channel::Whatsapp.create!(provider: 'evolution', phone_number: '+15550000001',
      provider_config: { instance_name: 'synthetic-vetorial', existing_instance_attached: true, attachment_state: 'active' })
  end
  let(:box) { Inbox.create!(name: 'Sintético', channel: channel, enable_auto_assignment: false) }
  let(:conversation) do
    contact = Contact.new(name: 'Teste', phone_number: '+15550000002')
    contact.passive_observation = true; contact.skip_default_pipeline_assignment = true; contact.save!
    ci = ContactInbox.create!(inbox: box, contact: contact, source_id: '15550000002')
    Conversation.create!(inbox: box, contact: contact, contact_inbox: ci, source: :imported)
  end
  let(:path) { "/internal/vetorial_agent/#{conversation.id}" }
  before do
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).with('VETORIAL_AGENT_INBOX_ID').and_return(box.id)
    allow(ENV).to receive(:[]).with('VETORIAL_AGENT_SECRET_FILE').and_return(nil)
    allow(ENV).to receive(:fetch).with('VETORIAL_AGENT_SECRET', '').and_return(secret)
    allow(ENV).to receive(:fetch).with('VETORIAL_AGENT_ALLOWLIST', '').and_return('+15550000002')
  end
  it 'requires a valid fresh signature bound to HTTP method and conversation path' do
    get path
    expect(response).to have_http_status(:unauthorized)
    get path, headers: VetorialAgent::Signature.headers('', method: 'GET', path: path)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['allowed']).to eq(true)
    get path, headers: VetorialAgent::Signature.headers('', method: 'GET', path: path + '-other')
    expect(response).to have_http_status(:unauthorized)
    get path, headers: VetorialAgent::Signature.headers('', method: 'POST', path: path)
    expect(response).to have_http_status(:unauthorized)
  end
  it 'paginates messages sharing the same timestamp without omission and excludes private notes' do
    conversation
    at = Time.current.change(usec: 123456)
    51.times { |i| conversation.messages.create!(inbox: box, source: :imported, message_type: :incoming, content: "Msg #{i}", created_at: at) }
    first = nil
    get path, headers: VetorialAgent::Signature.headers('', method: 'GET', path: path)
    first = response.parsed_body
    expect(first['messages'].size).to eq(50)
    get path, params: { before: first['next_before'] }, headers: VetorialAgent::Signature.headers('', method: 'GET', path: path)
    expect(response.parsed_body['messages'].size).to eq(1)
    all = first['messages'] + response.parsed_body['messages']
    expect(all.pluck('id').uniq.size).to eq(51)
  end
  it 'rejects tampered bodies and a correctly signed stale command' do
    data = { command: { key: 'test', version: 99, kind: 'send', text: 'Test' } }.to_json
    post path, params: data, headers: VetorialAgent::Signature.headers('{}', method: 'POST', path: path)
    expect(response).to have_http_status(:unauthorized)
    post path, params: data, headers: VetorialAgent::Signature.headers(data, method: 'POST', path: path)
    expect(response).to have_http_status(:conflict)
  end
  it 'excludes unconfirmed agent drafts from history; accepted provider IDs are included' do
    bot = AgentBot.create!(name: 'Sintético', outgoing_url: 'http://agent.invalid')
    draft = conversation.messages.create!(inbox: box, sender: bot, source: :imported, message_type: :outgoing, status: :failed,
                                          content: 'Ainda não enviado', content_attributes: { vetorial_agent: 'draft' })
    get path, headers: VetorialAgent::Signature.headers('', method: 'GET', path: path)
    expect(response.parsed_body['messages']).to eq([])
    draft.update!(source_id: 'accepted-provider-id', status: :sent)
    get path, headers: VetorialAgent::Signature.headers('', method: 'GET', path: path)
    expect(response.parsed_body['messages'].pluck('id')).to eq([draft.id])
  end

end
