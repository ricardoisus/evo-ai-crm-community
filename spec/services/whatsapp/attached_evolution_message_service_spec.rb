require 'rails_helper'
require 'webmock/rspec'
WebMock.disable_net_connect!(allow_localhost: true)

RSpec.describe 'Attached Evolution ingress' do
  include ActiveJob::TestHelper
  let(:channel) do
    Channel::Whatsapp.create!(provider: 'evolution', phone_number: '+15550000001', provider_connection: { connection: 'open' },
      provider_config: { instance_name: 'synthetic-vetorial', existing_instance_attached: true, attachment_state: 'active',
                         attachment_token: 'synthetic-token', attachment_started_at: 100 })
  end
  let(:box) { Inbox.create!(name: 'Synthetic Vetorial', channel: channel, enable_auto_assignment: false) }
  let(:job) { Webhooks::EvolutionAttachedJob.new }

  def payload(id: 'synthetic-msg-1', from_me: false, jid: '15550000002@s.whatsapp.net', message: { conversation: 'Olá, teste sintético' })
    { instance: 'synthetic-vetorial', event: 'messages.upsert', data: {
      key: { id: id, fromMe: from_me, remoteJid: jid }, message: message, messageTimestamp: 200, pushName: 'Contato sintético'
    } }
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config)
    allow(ActionCableListener.instance).to receive(:message_created)
    allow(ActionCableListener.instance).to receive(:message_updated)
  end

  it 'persists received text, deduplicates by ID and never triggers replies or contact/conversation automations' do
    box
    expect_any_instance_of(Contact).not_to receive(:trigger_contact_created_automation)
    expect_any_instance_of(Conversation).not_to receive(:notify_conversation_creation)
    expect_any_instance_of(Message).not_to receive(:execute_after_create_commit_callbacks)
    expect(Whatsapp::SendOnWhatsappService).not_to receive(:new)
    2.times { job.perform(channel.id, payload) }
    expect(box.messages.count).to eq(1)
    m = box.messages.sole
    expect(m).to be_incoming
    expect(m.content).to eq('Olá, teste sintético')
    expect(m).to be_whatsapp_observed
    SendReplyJob.perform_now(m.id)
    expect(enqueued_jobs.none? { |j| j[:job] == SendReplyJob }).to eq(true)
  end

  it 'shows the phone echo as outgoing without sending it again' do
    box
    expect(Whatsapp::SendOnWhatsappService).not_to receive(:new)
    job.perform(channel.id, payload(from_me: true))
    m = box.messages.sole
    expect(m).to be_outgoing
    expect(m).to be_sent
    expect(m.content_attributes['evolution_origin']).to eq('human_device')
    SendReplyJob.perform_now(m.id)
  end

  it 'persists base64 media as a real attachment and deduplicates its replay' do
    box
    data = payload(message: { imageMessage: { caption: 'Imagem sintética', mimetype: 'image/png' }, base64: Base64.strict_encode64('synthetic image bytes') })
    2.times { job.perform(channel.id, data) }
    expect(box.messages.sole.attachments.count).to eq(1)
    file = box.messages.sole.attachments.sole.file
    expect(file.download).to eq('synthetic image bytes')
  end

  it 'ignores groups, broadcasts, missing direction, another instance and history' do
    box
    ['123456@g.us', 'status@broadcast', '123456@newsletter'].each { |jid| job.perform(channel.id, payload(jid: jid)) }
    job.perform(channel.id, payload(from_me: nil))
    job.perform(channel.id, payload.merge(instance: 'other'))
    data = payload; data[:data][:messageTimestamp] = 10
    job.perform(channel.id, data)
    job.perform(channel.id, payload.merge(event: 'messages.set'))
    expect(box.messages.count).to eq(0)
    expect(box.contact_inboxes.count).to eq(0)
  end

  it 'updates delivery/read status only and never creates an empty bubble or regresses status' do
    box
    job.perform(channel.id, payload(from_me: true))
    status = { instance: 'synthetic-vetorial', event: 'messages.update', data: { keyId: 'synthetic-msg-1', fromMe: true, status: 'READ' } }
    job.perform(channel.id, status)
    status[:data][:status] = 'DELIVERY_ACK'
    job.perform(channel.id, status)
    status[:data][:keyId] = 'unknown'
    job.perform(channel.id, status)
    expect(box.messages.sole).to be_read
  end

  it 'refuses the legacy unauthenticated endpoint for an attached channel' do
    box
    Webhooks::WhatsappEventsJob.new.perform(payload)
    expect(box.messages.count).to eq(0)
  end

  it 'uses an explicit phone alternate for a LID without treating the LID as a phone' do
    box
    data = payload(jid: '999999999@lid')
    data[:data][:key][:remoteJidAlt] = '15550000002@s.whatsapp.net'
    job.perform(channel.id, data)
    expect(box.messages.sole.conversation.contact.phone_number).to eq('+15550000002')
  end

  it 'stops processing queued events after detach' do
    box
    channel.update!(provider_config: channel.provider_config.merge('attachment_state' => 'detached'))
    job.perform(channel.id, payload)
    expect(box.messages.count).to eq(0)
  end
end
