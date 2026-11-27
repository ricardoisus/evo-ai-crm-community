# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WhatsappTrackingDelivery do
  include ActiveSupport::Testing::TimeHelpers

  let(:inbox) { Inbox.create!(name: 'Tracking test inbox', channel: Channel::WebWidget.create!(website_url: 'https://test.example.com')) }
  let(:attributes) do
    {
      inbox_id: inbox.id, dataset_id: '123', credential_ref: 'WHATSAPP_TRACKING_META_TEST_TOKEN',
      event_name: 'Lead', event_id: 'a' * 64, occurred_at: Time.current,
      attribution: { action_source: 'chat', ads_consent: true, phone: '+5511999999999', text: 'private case details' }
    }
  end

  it 'deduplicates by inbox, event and destination and stores only the built Meta payload' do
    first = described_class.enqueue!(**attributes)
    expect(described_class.enqueue!(**attributes).id).to eq(first.id)
    expect(described_class.enqueue!(**attributes.merge(dataset_id: '456')).id).not_to eq(first.id)
    expect(first.reload.event.to_json).not_to include('private case details', '5511999999999')
  end

  it 'claims each attempt once and retains only numeric receipt identifiers' do
    delivery = described_class.enqueue!(**attributes)
    duplicate_worker = described_class.find(delivery.id)
    expect(delivery.claim).to eq(1)
    expect(duplicate_worker.claim).to be_nil

    delivery.finish!(1, status: :retryable, http_status: 429, error_code: 4, raw: 'do not retain')
    expect(delivery.receipts.sole).to have_attributes(status: 'retryable', http_status: 429, error_code: 4)
    expect(delivery.claim).to be_nil

    travel 3.minutes do
      expect(duplicate_worker.claim).to eq(2)
      delivery.finish!(1, status: :accepted)
      expect(delivery.reload.status).to eq('sending')
      duplicate_worker.finish!(2, status: :accepted, http_status: 200)
    end
    expect(delivery.reload.status).to eq('accepted')
    expect(delivery.claim).to be_nil
  end

  it 'leaves an abandoned claim uncertain and excludes it from retry' do
    delivery = described_class.enqueue!(**attributes)
    delivery.claim
    travel 11.minutes do
      delivery.expire_claim!
      expect(delivery.receipts.sole.status).to eq('uncertain')
      expect(delivery.claim).to be_nil
      expect(described_class.ready).not_to include(delivery)
    end
  end
end
