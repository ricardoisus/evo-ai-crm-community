# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'
WebMock.disable_net_connect!(allow_localhost: true)

RSpec.describe 'POST /api/v1/conversations/:conversation_id/messages/:id/forward', type: :request do
  include ActiveJob::TestHelper

  let(:channel) { whatsapp_channel('+15550000001', 'synthetic-vetorial') }
  let(:inbox) { Inbox.create!(name: 'Synthetic Vetorial', channel: channel, enable_auto_assignment: false) }
  let(:origin) { conversation_with('15550000002') }
  let(:first_target) { conversation_with('15550000003') }
  let(:second_target) { conversation_with('15550000004') }
  let(:source) { incoming(content: 'Mensagem para encaminhar') }
  let(:user) { User.create!(name: 'Atendente sintético', email: "atendente-#{SecureRandom.hex(4)}@example.com") }
  let(:granted) { ['conversations.read', 'conversations.update'] }
  let(:read_all) { true }
  let(:send_text) { stub_send('sendText') }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config)
    probe = user
    all = read_all
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
      Current.evo_can_read_all_inboxes = all
    end
    permissions = granted
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission) do |_service, _user_id, permission|
      permissions.include?(permission)
    end
    send_text
    source
    first_target
  end

  after { Current.reset }

  def whatsapp_channel(phone, instance, provider: 'evolution')
    Channel::Whatsapp.create!(provider: provider, phone_number: phone, provider_connection: { connection: 'open' },
                              provider_config: { instance_name: instance, api_url: 'https://evo.example.com',
                                                 admin_token: 'synthetic-admin' })
  end

  def conversation_with(number, in_inbox: inbox)
    contact = Contact.new(name: "Contato #{number}", phone_number: "+#{number}")
    contact.skip_default_pipeline_assignment = true
    contact.save!
    contact_inbox = ContactInbox.create!(contact: contact, inbox: in_inbox, source_id: number)
    Conversation.create!(inbox: in_inbox, contact: contact, contact_inbox: contact_inbox)
  end

  def incoming(**attributes)
    origin.messages.create!({ inbox: inbox, message_type: :incoming, sender: origin.contact,
                              source_id: "wamid-#{SecureRandom.hex(4)}" }.merge(attributes))
  end

  def with_file(message, file_type: 'image', filename: 'foto.png', content_type: 'image/png')
    attachment = message.attachments.build(file_type: file_type)
    attachment.file.attach(io: StringIO.new('conteudo sintetico'), filename: filename, content_type: content_type)
    attachment.save!
    attachment
  end

  def stub_send(endpoint)
    stub_request(:post, "https://evo.example.com/message/#{endpoint}/synthetic-vetorial")
      .to_return(status: 201, body: ->(_) { { key: { id: "sent-#{SecureRandom.hex(4)}" } }.to_json },
                 headers: { 'Content-Type' => 'application/json' })
  end

  def forward(targets, message: source, conversation: origin)
    perform_enqueued_jobs(only: SendReplyJob) do
      post "/api/v1/conversations/#{conversation.id}/messages/#{message.id}/forward",
           params: { target_conversation_ids: targets }, as: :json
    end
  end

  def body
    JSON.parse(response.body)
  end

  def outgoing(conversation)
    conversation.messages.reload.outgoing.to_a
  end

  def expect_refusal(details)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body.dig('error', 'code')).to eq(ApiErrorCodes::VALIDATION_ERROR)
    expect(body.dig('error', 'details')).to eq(details)
    expect(send_text).not_to have_been_requested
  end

  it 'creates one outgoing forwarded message per target and sends each to WhatsApp' do
    forward([first_target.id, second_target.display_id])

    expect(response).to have_http_status(:created)
    [first_target, second_target].each do |target|
      copy = outgoing(target).sole
      expect(copy).to have_attributes(content: 'Mensagem para encaminhar', sender: user, private: false)
      expect(copy.content_attributes).to eq('forwarded' => true)
      expect(copy.source_id).to start_with('sent-')
    end
    expect(body['data'].map { |m| m['conversation_id'] }).to eq([first_target.id, second_target.id])
    expect(body['data'].map { |m| m.dig('content_attributes', 'forwarded') }).to eq([true, true])
    %w[15550000003 15550000004].each do |number|
      expect(a_request(:post, 'https://evo.example.com/message/sendText/synthetic-vetorial')
        .with(body: { number: number, text: 'Mensagem para encaminhar' }.to_json)).to have_been_made.once
    end
  end

  it 'forwards a message sent by the CRM, dropping its quote and reactions' do
    sent = origin.messages.create!(inbox: inbox, message_type: :outgoing, sender: user, content: 'Resposta enviada',
                                   source_id: 'mine-1',
                                   content_attributes: { 'in_reply_to' => source.id, 'reactions' => [{ 'emoji' => '👍' }] })
    forward([first_target.id], message: sent)

    expect(response).to have_http_status(:created)
    expect(outgoing(first_target).sole.content_attributes).to eq('forwarded' => true, 'forwarded_markup' => true)
  end

  it 'sends the text literally, without expanding Liquid with the destination data' do
    message = incoming(content: 'Meu número é {{contact.phone_number}}')
    forward([first_target.id], message: message)

    expect(outgoing(first_target).sole.content).to eq('Meu número é {{contact.phone_number}}')
  end

  def sent_text_body(message, number: '15550000003')
    forward([first_target.id], message: message)
    a_request(:post, 'https://evo.example.com/message/sendText/synthetic-vetorial')
      .with { |request| (@sent = JSON.parse(request.body))['number'] == number }.then { |pattern| expect(pattern).to have_been_made.once }
    @sent['text']
  end

  describe 'what actually goes to WhatsApp' do
    let(:literal) { "https://ex.com/a?x=1&y=2 | se a<b e c>d | <3 | <b>cru</b>\n\n\n\nfim  duplo" }

    it 'sends received text and links byte for byte' do
      expect(sent_text_body(incoming(content: literal))).to eq(literal)
    end

    it 'sends text typed on the phone byte for byte' do
      message = origin.messages.create!(inbox: inbox, message_type: :outgoing, sender: user, content: 'antes',
                                        source_id: 'phone-1', content_attributes: { 'external_created_at' => 1_788_000_000 })
      message.update_columns(content: literal)
      expect(sent_text_body(message)).to eq(literal)
    end

    it 'keeps formatting CRM-composed text, without escaping links' do
      message = origin.messages.create!(inbox: inbox, message_type: :outgoing, sender: user, source_id: 'crm-1',
                                        content: '<p><strong>Oferta</strong> https://ex.com/a?x=1&y=2</p>')
      expect(sent_text_body(message)).to eq('*Oferta* https://ex.com/a?x=1&y=2')
      expect(outgoing(first_target).sole.content_attributes).to eq('forwarded' => true, 'forwarded_markup' => true)
    end

    it 'sends a received caption byte for byte' do
      message = incoming(content: literal)
      with_file(message)
      send_media = stub_send('sendMedia')
      forward([first_target.id], message: message)
      expect(send_media.with { |request| JSON.parse(request.body)['caption'] == literal }).to have_been_made.once
    end

    it 'keeps the literal text on retry' do
      forward([first_target.id], message: incoming(content: literal))
      copy = outgoing(first_target).sole
      copy.update_columns(source_id: nil, status: Message.statuses[:failed])
      post "/api/v1/conversations/#{first_target.id}/messages/#{copy.id}/retry", as: :json
      expect(a_request(:post, 'https://evo.example.com/message/sendText/synthetic-vetorial')
        .with { |request| JSON.parse(request.body)['text'] == literal }).to have_been_made.twice
    end

    it 'sends the text that came with an audio as its own message' do
      message = incoming(content: 'Texto junto do áudio')
      with_file(message, file_type: 'audio', filename: 'a.ogg', content_type: 'audio/ogg')
      send_audio = stub_send('sendWhatsAppAudio')
      forward([first_target.id], message: message)

      copies = outgoing(first_target)
      expect(copies.map { |m| [m.content.to_s, m.attachments.size] }).to contain_exactly(['Texto junto do áudio', 0], ['', 1])
      expect(send_audio).to have_been_requested.once
      expect(a_request(:post, 'https://evo.example.com/message/sendText/synthetic-vetorial')
        .with(body: { number: '15550000003', text: 'Texto junto do áudio' }.to_json)).to have_been_made.once
    end
  end

  describe 'retry of a failed reply' do
    it 'keeps the quote' do
      reply = origin.messages.create!(inbox: inbox, message_type: :outgoing, sender: user, content: 'Resposta',
                                      content_attributes: { 'in_reply_to' => source.id, 'external_error' => 'x' })
      reply.update_columns(status: Message.statuses[:failed])

      post "/api/v1/conversations/#{origin.id}/messages/#{reply.id}/retry", as: :json

      expect(reply.reload.content_attributes).to include('in_reply_to' => source.id)
      expect(reply.content_attributes).not_to include('external_error')
      expect(a_request(:post, 'https://evo.example.com/message/sendText/synthetic-vetorial')
        .with { |request| JSON.parse(request.body).dig('quoted', 'key', 'id') == source.source_id }).to have_been_made.once
    end
  end

  it 'forwards once to a target repeated by uuid and display_id' do
    forward([first_target.id, first_target.id, first_target.display_id])

    expect(response).to have_http_status(:created)
    expect(outgoing(first_target).size).to eq(1)
  end

  describe 'attachments' do
    let(:send_media) { stub_send('sendMedia') }

    it 'reuses the stored blob and sends it as media' do
      message = incoming(content: 'Legenda')
      original = with_file(message)
      send_media

      expect { forward([first_target.id, second_target.id], message: message) }.not_to change(ActiveStorage::Blob, :count)

      expect(response).to have_http_status(:created)
      [first_target, second_target].each do |target|
        copy = outgoing(target).sole
        expect(copy.content).to eq('Legenda')
        expect(copy.attachments.sole.file.blob).to eq(original.file.blob)
        expect(copy.attachments.sole.file_type).to eq('image')
      end
      expect(send_media).to have_been_requested.twice
    end

    it 'creates one message per file, with the caption on the first only' do
      message = incoming(content: 'Legenda')
      with_file(message)
      with_file(message, file_type: 'file', filename: 'guia.pdf', content_type: 'application/pdf')
      send_media

      forward([first_target.id], message: message)

      copies = outgoing(first_target)
      expect(copies.map { |m| m.content.to_s }).to contain_exactly('Legenda', '')
      expect(copies.map { |m| m.attachments.sole.file_type }).to contain_exactly('image', 'file')
      expect(send_media).to have_been_requested.twice
    end

    it 'refuses media that was never downloaded' do
      message = incoming(content: 'Legenda', content_attributes: { 'media_unavailable' => true })
      forward([first_target.id], message: message)
      expect_refusal('unsupported_content')
    end

    it 'refuses an attachment that is not a file, such as a location' do
      message = incoming(content: 'Local')
      message.attachments.create!(file_type: 'location', coordinates_lat: 1.0, coordinates_long: 2.0)
      forward([first_target.id], message: message)
      expect_refusal('unsupported_content')
    end
  end

  describe 'contact cards' do
    let(:send_contact) { stub_send('sendContact') }
    let(:card) do
      incoming(content: 'Ana Sintética, +55 11 90000-0009', content_attributes: { 'shared_contacts' => [
                 { 'name' => 'Ana Sintética', 'phones' => ['3000', '+55 11 90000-0001', '+551130000000'],
                   'organization' => 'Clínica Exemplo' },
                 { 'name' => '', 'phones' => ['+55 11 90000-0009'], 'organization' => nil }
               ] })
    end
    let(:sent_contacts) do
      [{ 'name' => 'Ana Sintética', 'phones' => ['+55 11 90000-0001'], 'organization' => 'Clínica Exemplo' },
       { 'name' => '+55 11 90000-0009', 'phones' => ['+55 11 90000-0009'], 'organization' => nil }]
    end
    let(:payload) do
      { number: '15550000003', contact: [
        { fullName: 'Ana Sintética', phoneNumber: '+55 11 90000-0001', wuid: '5511900000001', organization: 'Clínica Exemplo' },
        { fullName: '+55 11 90000-0009', phoneNumber: '+55 11 90000-0009', wuid: '5511900000009' }
      ] }
    end

    before { send_contact }

    it 'sends through sendContact with the stored values and keeps what was sent' do
      forward([first_target.id], message: card)

      expect(response).to have_http_status(:created)
      copy = outgoing(first_target).sole
      expect(copy.content_attributes).to eq('forwarded' => true, 'shared_contacts' => sent_contacts)
      expect(copy.content).to eq(card.content)
      expect(send_contact.with { |request| request.body == payload.to_json }).to have_been_made.once
      expect(send_text).not_to have_been_requested
    end

    it 'is still sent as a contact card on retry' do
      forward([first_target.id], message: card)
      copy = outgoing(first_target).sole
      copy.update_columns(source_id: nil, status: Message.statuses[:failed])

      post "/api/v1/conversations/#{first_target.id}/messages/#{copy.id}/retry", as: :json

      expect(response).to have_http_status(:ok)
      expect(copy.reload.content_attributes).to eq('forwarded' => true, 'shared_contacts' => sent_contacts)
      expect(send_contact).to have_been_requested.twice
      expect(send_text).not_to have_been_requested
    end

    it 'uses the WhatsApp id of the card (waid), not the digits of the written phone' do
      vcard = "BEGIN:VCARD\nFN:Ana\nTEL;type=CELL;waid=553190000001:+55 31 99000-0001\nEND:VCARD"
      parsed = Whatsapp::SharedContactsParser.parse([{ displayName: 'Ana', vcard: vcard }])
      forward([first_target.id], message: incoming(content: 'Ana', content_attributes: { 'shared_contacts' => parsed }))

      expected = { number: '15550000003', contact: [{ fullName: 'Ana', phoneNumber: '+55 31 99000-0001', wuid: '553190000001' }] }
      expect(send_contact.with { |request| request.body == expected.to_json }).to have_been_made.once
      expect(outgoing(first_target).sole.content_attributes['shared_contacts'].sole['waids']).to eq(['553190000001'])
    end

    context 'when the account masks contact data' do
      before do
        allow(RuntimeConfig).to receive(:account).and_return({ 'settings' => { 'mask_contact_pii' => true } })
      end

      it 'refuses an agent who only sees the masked phone' do
        allow_any_instance_of(User).to receive(:administrator?).and_return(false)
        forward([first_target.id], message: card)

        expect_refusal('masked_contact')
        expect(send_contact).not_to have_been_requested
        expect(outgoing(first_target)).to be_empty
      end

      it 'lets an administrator forward the card' do
        allow_any_instance_of(User).to receive(:administrator?).and_return(true)
        forward([first_target.id], message: card)

        expect(response).to have_http_status(:created)
        expect(send_contact.with { |request| request.body == payload.to_json }).to have_been_made.once
      end

      it 'still lets the agent forward plain text' do
        allow_any_instance_of(User).to receive(:administrator?).and_return(false)
        forward([first_target.id])

        expect(response).to have_http_status(:created)
      end
    end

    it 'refuses when any contact has no usable phone' do
      message = incoming(content: 'Beto', content_attributes: { 'shared_contacts' => [
                           { 'name' => 'Ana', 'phones' => ['+55 11 90000-0001'] }, { 'name' => 'Beto', 'phones' => [] }
                         ] })
      forward([first_target.id], message: message)

      expect_refusal('unsupported_content')
      expect(send_contact).not_to have_been_requested
    end
  end

  describe 'what cannot be forwarded' do
    {
      'a private note' => { message_type: :outgoing, private: true },
      'an activity' => { message_type: :activity },
      'a deleted message' => { content_attributes: { 'deleted' => true } },
      'a message revoked by the contact' => { content_attributes: { 'revoked_by_contact' => true } },
      'an old reaction bubble' => { content_attributes: { 'is_reaction' => true } }
    }.each do |label, attributes|
      it "refuses #{label}" do
        message = incoming(content: 'Conteúdo', **attributes)
        forward([first_target.id], message: message)

        expect_refusal('unsupported_message')
        expect(outgoing(first_target)).to be_empty
      end
    end

    it 'refuses a message with nothing to send' do
      forward([first_target.id], message: incoming(content: ''))
      expect_refusal('unsupported_content')
    end

    it 'answers 404 for a message of another conversation' do
      forward([second_target.id], conversation: first_target)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'targets' do
    def expect_nothing_created(details)
      expect_refusal(details)
      expect(outgoing(first_target)).to be_empty
    end

    [nil, [], 'abc'].each do |invalid|
      it "refuses #{invalid.inspect} as the list" do
        forward(invalid)
        expect_nothing_created('invalid_targets')
      end
    end

    it 'refuses more than 5 targets' do
      others = (10..14).map { |n| conversation_with("155500000#{n}") }
      forward([first_target.id, *others.map(&:id)])
      expect_nothing_created('invalid_targets')
    end

    it 'refuses the whole request when one target does not exist' do
      forward([first_target.id, SecureRandom.uuid])
      expect_nothing_created('invalid_target')
    end

    it 'does not read a malformed id as a display_id' do
      forward(["#{first_target.display_id}abc"])
      expect_nothing_created('invalid_target')
    end

    it 'refuses a target that is not WhatsApp' do
      web = Inbox.create!(name: 'Web', channel: Channel::WebWidget.create!(website_url: 'https://forward.example.com'))
      forward([first_target.id, conversation_with('15550000020', in_inbox: web).id])
      expect_nothing_created('unsupported_channel')
    end

    it 'refuses a WhatsApp target on a provider other than Evolution' do
      other_channel = whatsapp_channel('+15550000030', 'other', provider: 'zapi')
      allow_any_instance_of(Whatsapp::Providers::ZapiService).to receive(:subscribe_to_webhooks)
      other = Inbox.create!(name: 'Zapi', channel: other_channel, enable_auto_assignment: false)
      forward([first_target.id, conversation_with('15550000031', in_inbox: other).id])
      expect_nothing_created('unsupported_channel')
    end

    it 'creates nothing when one of the creations fails' do
      second_target
      allow(Limits).to receive(:conversation_message_per_minute_limit).and_return(1)
      second_target.messages.create!(inbox: inbox, message_type: :incoming, sender: second_target.contact, content: 'Oi')

      forward([first_target.id, second_target.id])

      expect_nothing_created('creation_failed')
    end

    context 'when the agent only sees some inboxes' do
      let(:read_all) { false }
      let(:closed_inbox) do
        Inbox.create!(name: 'Fechada', channel: whatsapp_channel('+15550000040', 'closed'), enable_auto_assignment: false)
      end

      before { InboxMember.create!(user: user, inbox: inbox) }

      it 'forwards to a conversation of an assigned inbox' do
        forward([first_target.id])
        expect(response).to have_http_status(:created)
      end

      it 'refuses a conversation of another inbox, answering as if it did not exist' do
        forward([first_target.id, conversation_with('15550000041', in_inbox: closed_inbox).id])
        expect_nothing_created('invalid_target')
      end
    end
  end

  context 'without the permission to send messages' do
    let(:granted) { ['conversations.read'] }

    it 'is forbidden' do
      forward([first_target.id])
      expect(response).to have_http_status(:forbidden)
      expect(outgoing(first_target)).to be_empty
    end
  end
end
