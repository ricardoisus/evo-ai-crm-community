# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'
WebMock.disable_net_connect!(allow_localhost: true)

RSpec.describe 'Evolution shared contacts ingress' do
  include ActiveJob::TestHelper

  let(:channel) do
    Channel::Whatsapp.create!(provider: 'evolution', phone_number: '+15550000001', provider_connection: { connection: 'open' },
                              provider_config: provider_config)
  end
  let(:box) { Inbox.create!(name: 'Synthetic Vetorial', channel: channel, enable_auto_assignment: false) }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config)
    allow(ActionCableListener.instance).to receive(:message_created)
    allow(ActionCableListener.instance).to receive(:message_updated)
    box
  end

  def card(name, phone)
    { displayName: name, vcard: "BEGIN:VCARD\nVERSION:3.0\nFN:#{name}\nORG:Clínica Exemplo\n" \
                                "TEL;type=CELL;waid=#{phone.delete('+')}:#{phone}\nEND:VCARD" }
  end

  def payload(message, id: 'contact-1')
    { instance: 'synthetic-vetorial', event: 'messages.upsert', data: {
      key: { id: id, fromMe: false, remoteJid: '15550000002@s.whatsapp.net' }, messageTimestamp: 200,
      pushName: 'Contato sintético', message: message
    } }
  end

  shared_examples 'shared contact ingress' do
    it 'stores shared_contacts and the name, without the raw vCard, once' do
      data = payload({ contactMessage: card('Ana Sintética', '+15550000010') })
      2.times { deliver(data) }

      message = box.messages.sole
      expect(message.content).to eq('Ana Sintética')
      expect(message.content_attributes['shared_contacts'].map(&:to_h)).to eq(
        [{ 'name' => 'Ana Sintética', 'phones' => ['+15550000010'], 'waids' => ['15550000010'], 'organization' => 'Clínica Exemplo' }]
      )
      expect(message.content_attributes).not_to have_key('contacts')
      expect(message.attachments).to be_empty
    end

    it 'stores every contact of a contactsArrayMessage and lists the names' do
      deliver(payload({ contactsArrayMessage: { displayName: '2 contatos', contacts: [
                        card('Ana Sintética', '+15550000010'), card('Beto Sintético', '+15550000011')
                      ] } }))

      message = box.messages.sole
      expect(message.content).to eq('Ana Sintética, Beto Sintético')
      expect(message.content_attributes['shared_contacts'].map { |c| c['phones'] }).to eq([['+15550000010'], ['+15550000011']])
    end

    it 'keeps the text bubble when there is nothing usable in the vCard' do
      deliver(payload({ contactMessage: { vcard: 'lixo' } }))

      message = box.messages.sole
      expect(message.content).to eq('Contact')
      expect(message.content_attributes).not_to have_key('shared_contacts')
    end

    it 'does not break on an empty contacts array' do
      deliver(payload({ contactsArrayMessage: { contacts: [] } }))

      expect(box.messages.sole.content).to eq('Contact')
    end
  end

  context 'with the attached inbox' do
    let(:provider_config) do
      { instance_name: 'synthetic-vetorial', existing_instance_attached: true, attachment_state: 'active',
        attachment_token: 'synthetic-token', attachment_started_at: 100 }
    end

    def deliver(data)
      Webhooks::EvolutionAttachedJob.new.perform(channel.id, data)
    end

    include_examples 'shared contact ingress'
  end

  context 'with the regular Evolution handler' do
    let(:provider_config) { { instance_name: 'synthetic-vetorial', api_url: 'https://evo.example.com', admin_token: 'synthetic' } }

    before { stub_request(:any, /evo\.example\.com/).to_return(status: 404, body: '{}') }

    def deliver(data)
      Whatsapp::IncomingMessageEvolutionService.new(inbox: box.reload, params: data.with_indifferent_access).perform
    end

    include_examples 'shared contact ingress'
  end
end
