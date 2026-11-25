# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'
WebMock.disable_net_connect!(allow_localhost: true)

RSpec.describe 'POST /api/v1/conversations/:conversation_id/messages/:id/reaction', type: :request do
  include ActiveJob::TestHelper

  let(:channel) do
    Channel::Whatsapp.create!(provider: 'evolution', phone_number: '+15550000001', provider_connection: { connection: 'open' },
                              provider_config: { instance_name: 'synthetic-vetorial', api_url: 'https://evo.example.com',
                                                 admin_token: 'synthetic-admin' })
  end
  let(:inbox) { Inbox.create!(name: 'Synthetic Vetorial', channel: channel, enable_auto_assignment: false) }
  let(:contact) do
    Contact.new(name: 'Contato sintético', phone_number: '+15550000002').tap do |c|
      c.skip_default_pipeline_assignment = true
      c.save!
    end
  end
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: '15550000002') }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:message) do
    conversation.messages.create!(inbox: inbox, content: 'Mensagem alvo', message_type: :incoming, sender: contact,
                                  source_id: 'target-1')
  end
  let(:user) { User.create!(name: 'Atendente sintético', email: "atendente-#{SecureRandom.hex(4)}@example.com") }
  let(:granted) { ['conversations.read', 'conversations.update'] }
  let(:evolution) do
    stub_request(:post, 'https://evo.example.com/message/sendReaction/synthetic-vetorial').to_return(status: 201)
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config)
    allow(ActionCableListener.instance).to receive(:message_updated)
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
      Current.evo_can_read_all_inboxes = true
    end
    permissions = granted
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission) do |_service, _user_id, permission|
      permissions.include?(permission)
    end
    evolution
    message
  end

  after { Current.reset }

  def react(emoji, id: message.id, conversation_id: conversation.id)
    post "/api/v1/conversations/#{conversation_id}/messages/#{id}/reaction", params: { emoji: emoji }, as: :json
  end

  def reactions
    Array(message.reload.content_attributes['reactions'])
  end

  def body
    JSON.parse(response.body)
  end

  it 'sends to WhatsApp, stores the reaction as "me" and returns the message' do
    expect { react('👍') }.not_to change(Message, :count)

    expect(response).to have_http_status(:ok)
    expect(evolution.with do |request|
      JSON.parse(request.body) == {
        'key' => { 'remoteJid' => '15550000002@s.whatsapp.net', 'fromMe' => false, 'id' => 'target-1' }, 'reaction' => '👍'
      }
    end).to have_been_made.once
    returned = body.dig('data', 'content_attributes', 'reactions')
    expect(returned).to eq([{ 'emoji' => '👍', 'from' => 'me', 'user_id' => user.id, 'at' => returned.first['at'] }])
    expect(returned.first['at']).to be_within(60).of(Time.current.to_i)
    expect(body.dig('data', 'id')).to eq(message.id)
    expect(ActionCableListener.instance).to have_received(:message_updated).once
  end

  it 'replaces my reaction, keeps the contact one and removes mine with an empty emoji' do
    message.update_columns(content_attributes: { 'reactions' => [{ 'emoji' => '🙏', 'from' => 'contact' }] })
    react('👍')
    react('❤️')
    expect(reactions.map { |r| r.values_at('from', 'emoji') }).to eq([%w[contact 🙏], %w[me ❤️]])
    react('')
    expect(response).to have_http_status(:ok)
    expect(reactions.map { |r| r['from'] }).to eq(['contact'])
  end

  it 'keeps the CRM author when the phone echo of the same reaction arrives' do
    react('👍')
    Whatsapp::IncomingMessageEvolutionService.new(inbox: inbox, params: {
      instance: 'synthetic-vetorial', event: 'messages.upsert', data: {
        key: { id: 'echo-1', fromMe: true, remoteJid: '15550000002@s.whatsapp.net' }, messageTimestamp: Time.current.to_i,
        message: { reactionMessage: { key: { id: 'target-1' }, text: '👍' } }
      }
    }.with_indifferent_access).perform
    expect(reactions.sole['user_id']).to eq(user.id)
  end

  it 'records the CRM author even when the echo was stored before the send returned' do
    message.update_columns(content_attributes: { 'reactions' => [{ 'emoji' => '👍', 'from' => 'me', 'user_id' => nil, 'at' => 200 }] })
    react('👍')
    expect(reactions.sole.to_h).to include('user_id' => user.id, 'at' => 200)
  end

  it 'answers 422 without saving when the provider fails' do
    stub_request(:post, 'https://evo.example.com/message/sendReaction/synthetic-vetorial').to_return(status: 400)
    react('👍')
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body.dig('error', 'code')).to eq(ApiErrorCodes::VALIDATION_ERROR)
    expect(reactions).to eq([])
  end

  [nil, 'oi', '👍👍', 5].each do |invalid|
    it "answers 422 for an invalid emoji (#{invalid.inspect}) without calling the provider" do
      react(invalid)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(evolution).not_to have_been_requested
    end
  end

  it 'answers 422 for a message without WhatsApp id and for a private note' do
    message.update_columns(source_id: nil)
    react('👍')
    expect(response).to have_http_status(:unprocessable_entity)

    message.update_columns(source_id: 'target-1', private: true)
    react('👍')
    expect(response).to have_http_status(:unprocessable_entity)
    expect(evolution).not_to have_been_requested
  end

  it 'answers 422 on another channel' do
    web = Inbox.create!(name: 'Web', channel: Channel::WebWidget.create!(website_url: 'https://react.example.com'))
    other = Conversation.create!(inbox: web, contact: contact,
                                 contact_inbox: ContactInbox.create!(contact: contact, inbox: web, source_id: SecureRandom.hex(8)))
    note = other.messages.create!(inbox: web, content: 'Oi', message_type: :incoming, sender: contact, source_id: 'web-1')

    react('👍', id: note.id, conversation_id: other.id)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(note.reload.content_attributes['reactions']).to be_nil
  end

  it 'answers 404 for a message of another conversation' do
    other = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    react('👍', conversation_id: other.id)
    expect(response).to have_http_status(:not_found)
    expect(evolution).not_to have_been_requested
  end

  context 'without the permission to send messages' do
    let(:granted) { ['conversations.read'] }

    it 'is forbidden' do
      react('👍')
      expect(response).to have_http_status(:forbidden)
      expect(evolution).not_to have_been_requested
    end
  end
end
