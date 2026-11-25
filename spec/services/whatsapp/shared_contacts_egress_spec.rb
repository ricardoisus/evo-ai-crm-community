# frozen_string_literal: true

require 'rails_helper'

# Telefones de contato compartilhado seguem a política dos demais dados de contato (mask_contact_pii).
RSpec.describe 'Shared contacts PII egress' do
  let(:account) { { 'settings' => { 'mask_contact_pii' => true } } }
  let(:contact) { Contact.create!(name: 'Lead', email: "lead-#{SecureRandom.hex(4)}@test.com") }
  let(:inbox) do
    Inbox.create!(name: 'Egress Inbox', channel: Channel::WebWidget.create!(website_url: "https://w-#{SecureRandom.hex(4)}.example.com"))
  end
  let(:conversation) do
    Conversation.create!(inbox: inbox, contact: contact,
                         contact_inbox: ContactInbox.create!(inbox: inbox, contact: contact, source_id: "src-#{SecureRandom.hex(4)}"))
  end
  let(:shared) do
    [{ 'name' => '+55 11 99999-8888', 'phones' => ['+55 11 99999-8888', '11-999998888'], 'organization' => 'Tel 11999998888' },
     { 'name' => 'Ana', 'phones' => [], 'organization' => nil }]
  end
  let(:message) do
    Message.create!(conversation: conversation, inbox: inbox, sender: contact, message_type: :incoming, content: 'Ana',
                    content_attributes: { 'shared_contacts' => shared,
                                          'contacts' => [{ 'vcard' => 'TEL:+5511999998888' }] })
  end
  let(:user) { nil }

  before do
    Current.account = account
    allow(RuntimeConfig).to receive(:account).and_return(account)
    message # criada antes de haver usuário na requisição
    Current.user = user
  end

  after do
    Current.account = nil
    Current.user = nil
  end

  def egress_outputs
    [message.push_event_data[:content_attributes], message.webhook_data[:content_attributes],
     MessageSerializer.serialize(message)['content_attributes'],
     message.content_attributes_for_egress(audience: :per_request)]
  end

  it 'masks phones, and phone-like name and organization, on every egress, dropping the legacy raw vCard' do
    egress_outputs.each do |attributes|
      expect(attributes.to_json).not_to include('99999')
      expect(attributes.stringify_keys).not_to have_key('contacts')
      first, second = attributes.stringify_keys['shared_contacts'].map { |c| c.to_h.stringify_keys }
      expect(first['phones']).to eq(['+*********8888', '*******8888'])
      expect(second).to eq('name' => 'Ana', 'phones' => [], 'organization' => nil)
    end
    expect(message.reload.content_attributes['shared_contacts'].first['phones'].first).to eq('+55 11 99999-8888')
  end

  context 'when masking is off' do
    let(:account) { { 'settings' => {} } }

    it 'delivers the phones as received' do
      expect(message.push_event_data[:content_attributes]['shared_contacts'].map(&:to_h)).to eq(shared)
    end
  end

  context 'when an administrator reads over REST' do
    let(:user) { instance_double(User, administrator?: true) }

    it 'sees the raw phones, while the account-wide broadcast stays masked' do
      expect(message.content_attributes_for_egress(audience: :per_request)['shared_contacts'].map(&:to_h)).to eq(shared)
      expect(message.content_attributes_for_egress['shared_contacts'].to_json).not_to include('99999')
    end
  end
end
