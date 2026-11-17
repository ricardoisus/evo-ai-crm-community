# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::IncomingMessageEvolutionService, 'contact identity' do
  include ActiveJob::TestHelper

  let(:channel) do
    Channel::Whatsapp.create!(provider: 'evolution', phone_number: '+15550000001', provider_connection: { connection: 'open' },
                              provider_config: { instance_name: 'synthetic-evo' })
  end
  let(:box) { Inbox.create!(name: 'Synthetic Evo', channel: channel, enable_auto_assignment: false) }

  def upsert(id:, push_name:, jid: '15550000002@s.whatsapp.net')
    { event: 'messages.upsert', instance: 'synthetic-evo', data: {
      key: { id: id, fromMe: false, remoteJid: jid }, message: { conversation: 'Olá' }, pushName: push_name
    } }.with_indifferent_access
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config)
    allow_any_instance_of(Channel::Whatsapp).to receive(:sync_templates)
    allow_any_instance_of(Channel::Whatsapp).to receive(:subscribe)
    allow(ActionCableListener.instance).to receive(:message_created)
    allow_any_instance_of(Channel::Whatsapp).to receive(:received_messages)
    box
  end

  def deliver(params)
    described_class.new(inbox: box, params: params).perform
  end

  it 'gives a pre-existing e-mail-named lead its WhatsApp name and queues the photo' do
    lead = Contact.new(name: 'lauriane@example.com', phone_number: '+15550000002')
    lead.skip_default_pipeline_assignment = true
    lead.save!
    deliver(upsert(id: 'u1', push_name: 'Lauriane'))
    expect(lead.reload.name).to eq('Lauriane')
    expect(enqueued_jobs.count { |j| j[:job] == Evolution::FetchContactAvatarJob }).to eq(1)
  end

  it 'updates the name when the pushName changes but keeps a human edit' do
    deliver(upsert(id: 'u2', push_name: 'Ana'))
    contact = box.contact_inboxes.sole.contact
    deliver(upsert(id: 'u3', push_name: 'Ana Paula'))
    expect(contact.reload.name).to eq('Ana Paula')
    contact.update!(name: 'Ana Paula (cliente)')
    deliver(upsert(id: 'u4', push_name: 'Ana Souza'))
    expect(contact.reload.name).to eq('Ana Paula (cliente)')
  end

  it 'processes contacts.update with the same name policy' do
    deliver(upsert(id: 'u5', push_name: 'Beto'))
    contact = box.contact_inboxes.sole.contact
    deliver({ event: 'contacts.update', instance: 'synthetic-evo',
              data: { remoteJid: '15550000002@s.whatsapp.net', pushName: 'Beto Lima' } }.with_indifferent_access)
    expect(contact.reload.name).to eq('Beto Lima')
  end
end
