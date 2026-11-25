# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'
WebMock.disable_net_connect!(allow_localhost: true)

RSpec.describe 'Evolution reactions ingress' do
  include ActiveJob::TestHelper

  let(:channel) do
    Channel::Whatsapp.create!(provider: 'evolution', phone_number: '+15550000001', provider_connection: { connection: 'open' },
                              provider_config: provider_config)
  end
  let(:box) { Inbox.create!(name: 'Synthetic Vetorial', channel: channel, enable_auto_assignment: false) }
  let(:contact) do
    Contact.new(name: 'Contato sintético', phone_number: '+15550000002').tap do |c|
      c.skip_default_pipeline_assignment = true
      c.save!
    end
  end
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: box, source_id: '15550000002') }
  let(:conversation) { Conversation.create!(inbox: box, contact: contact, contact_inbox: contact_inbox) }
  let(:target) do
    conversation.messages.create!(inbox: box, content: 'Mensagem alvo', message_type: :incoming, sender: contact,
                                  source_id: 'target-1', content_attributes: observed_attributes)
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config)
    allow(ActionCableListener.instance).to receive(:message_created)
    allow(ActionCableListener.instance).to receive(:message_updated)
    target
    clear_enqueued_jobs
  end

  def payload(emoji, from_me: false, target_id: 'target-1', at: 200, id: "reaction-#{at}", jid: '15550000002@s.whatsapp.net')
    { instance: 'synthetic-vetorial', event: 'messages.upsert', data: {
      key: { id: id, fromMe: from_me, remoteJid: jid }, messageTimestamp: at, pushName: 'Contato sintético',
      message: { reactionMessage: { key: { id: target_id, remoteJid: jid, fromMe: false }, text: emoji } }
    } }
  end

  def reactions
    Array(target.reload.content_attributes['reactions']).map { |r| r.to_h.stringify_keys }
  end

  shared_examples 'reaction ingress' do
    it 'stores the contact reaction on the target without creating a message' do
      expect { deliver(payload('👍')) }.not_to change(Message, :count)
      expect(reactions).to eq([{ 'emoji' => '👍', 'from' => 'contact', 'user_id' => nil, 'at' => 200 }])
    end

    it 'records a reaction made on the phone (fromMe) as "me", next to the contact one' do
      deliver(payload('👍'))
      deliver(payload('❤️', from_me: true, at: 210))
      expect(reactions.map { |r| r.values_at('from', 'emoji') }).to eq([%w[contact 👍], %w[me ❤️]])
    end

    it 'keeps one reaction per author, replacing and removing it' do
      deliver(payload('👍'))
      deliver(payload('😂', at: 210))
      expect(reactions.map { |r| r['emoji'] }).to eq(['😂'])
      deliver(payload('', at: 220))
      expect(reactions).to eq([])
    end

    it 'is idempotent for a repeated webhook and broadcasts the update once' do
      expect(ActionCableListener.instance).to receive(:message_updated)
        .with(satisfy { |event| event.data[:message].push_event_data[:content_attributes]['reactions'].size == 1 }).once
      2.times { deliver(payload('👍')) }
      expect(reactions.size).to eq(1)
    end

    it 'does not resurrect an older reaction delivered again after a removal' do
      deliver(payload('👍'))
      deliver(payload('', at: 220))
      deliver(payload('👍'))
      expect(reactions).to eq([])
    end

    it 'ignores a reaction to a message the CRM does not have' do
      expect { deliver(payload('👍', target_id: 'before-attachment')) }.not_to change(Message, :count)
      expect(reactions).to eq([])
      expect(ActionCableListener.instance).not_to have_received(:message_updated)
    end

    it 'does not trigger agent, automation, webhooks, jobs, unread count or conversation activity' do
      before = conversation.reload.attributes.slice('status', 'last_activity_at', 'updated_at')
      unread = conversation.unread_incoming_messages_count
      clear_enqueued_jobs
      expect(Rails.configuration.dispatcher).not_to receive(:dispatch)
      expect(VetorialAgent::Capture).not_to receive(:message)
      expect(LeadAutomations::CaptureEvent).not_to receive(:persist_message)

      deliver(payload('👍'))

      expect(enqueued_jobs).to eq([])
      expect(conversation.reload.attributes.slice(*before.keys)).to eq(before)
      expect(conversation.unread_incoming_messages_count).to eq(unread)
    end

    it 'keeps the internal ordering marks out of what leaves the server' do
      deliver(payload('👍'))
      expect(target.reload.content_attributes_for_egress.keys).not_to include('reaction_marks')
      expect(MessageSerializer.serialize(target)['content_attributes']['reactions'].size).to eq(1)
    end
  end

  context 'with the attached inbox' do
    let(:provider_config) do
      { instance_name: 'synthetic-vetorial', existing_instance_attached: true, attachment_state: 'active',
        attachment_token: 'synthetic-token', attachment_started_at: 100 }
    end
    let(:observed_attributes) { { 'whatsapp_observed' => true } }

    def deliver(data)
      Webhooks::EvolutionAttachedJob.new.perform(channel.id, data)
    end

    include_examples 'reaction ingress'

    it 'accepts a LID jid without an explicit phone and ignores groups' do
      deliver(payload('👍', jid: '999999999@lid'))
      deliver(payload('❤️', from_me: true, jid: '123456@g.us', at: 210))
      expect(reactions.map { |r| r['emoji'] }).to eq(['👍'])
    end

    it 'ignores a reaction without a direction' do
      deliver(payload('👍', from_me: nil))
      expect(reactions).to eq([])
    end
  end

  context 'with the regular Evolution handler' do
    let(:provider_config) { { instance_name: 'synthetic-vetorial' } }
    let(:observed_attributes) { {} }

    def deliver(data)
      Whatsapp::IncomingMessageEvolutionService.new(inbox: box.reload, params: data.with_indifferent_access).perform
    end

    include_examples 'reaction ingress'
  end
end
