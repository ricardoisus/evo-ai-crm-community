# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WhatsappTracking::DeliverJob do
  let(:inbox) { Inbox.create!(name: 'Tracking test', channel: Channel::WebWidget.create!(website_url: 'https://test.example.com')) }
  let(:delivery) do
    WhatsappTrackingDelivery.enqueue!(
      inbox_id: inbox.id, dataset_id: '123', credential_ref: 'WHATSAPP_TRACKING_META_TEST_TOKEN',
      event_name: 'Lead', event_id: 'c' * 64, occurred_at: Time.current, mode: 'test',
      attribution: { action_source: 'chat', ads_consent: true, phone: '+5511999999999' }
    )
  end

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('WHATSAPP_TRACKING_DELIVERY_ENABLED').and_return('true')
    allow(ENV).to receive(:[]).with('WHATSAPP_TRACKING_META_TEST_TOKEN').and_return('synthetic-token')
    allow(ENV).to receive(:[]).with('WHATSAPP_TRACKING_META_TEST_CODE').and_return('TEST_SYNTHETIC')
  end

  it 'leaves a delivery pending for inboxes outside the configured rollout' do
    allow(ENV).to receive(:fetch).with('WHATSAPP_TRACKING_DELIVERY_INBOX_IDS', '').and_return(SecureRandom.uuid)
    expect(WhatsappTracking::MetaClient).not_to receive(:new)
    described_class.perform_now(delivery.id)
    expect(delivery.reload.status).to eq('pending')
  end

  it 'requires the test code before processing a test delivery' do
    allow(ENV).to receive(:fetch).with('WHATSAPP_TRACKING_DELIVERY_INBOX_IDS', '').and_return(inbox.id)
    allow(ENV).to receive(:[]).with('WHATSAPP_TRACKING_META_TEST_CODE').and_return(nil)
    expect(WhatsappTracking::MetaClient).not_to receive(:new)
    described_class.perform_now(delivery.id)
    expect(delivery.reload.status).to eq('configuration_error')
  end

  it 'passes the test code to Meta and persists the classified receipt' do
    allow(ENV).to receive(:fetch).with('WHATSAPP_TRACKING_DELIVERY_INBOX_IDS', '').and_return(inbox.id)
    client = instance_double(WhatsappTracking::MetaClient)
    allow(WhatsappTracking::MetaClient).to receive(:new).with(dataset_id: '123', token: 'synthetic-token').and_return(client)
    expect(client).to receive(:deliver).with(delivery.event, test_code: 'TEST_SYNTHETIC').and_return(status: :accepted, http_status: 200)
    described_class.perform_now(delivery.id)
    expect(delivery.receipts.sole).to have_attributes(status: 'accepted', http_status: 200)
  end
end
