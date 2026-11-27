# frozen_string_literal: true

require_relative '../../../app/services/whatsapp_tracking/meta_event'

RSpec.describe WhatsappTracking::MetaEvent do
  def build(attribution, name: 'QualifiedLead')
    described_class.new(event_name: name, event_id: 'a' * 64, occurred_at: Time.at(123), attribution: {
      phone: '+5511999999999', text: 'synthetic confidential message'
    }.merge(attribution))
  end

  it 'sends only allowlisted attribution and strips the query and fragment' do
    event = build({
      action_source: 'website', ads_consent: true, website_host: 'example.com',
      page_url: 'https://example.com/landing?private=value#private', fbp: 'fb.1.1234567890123.123'
    }).to_h
    expect(event).to eq(
      event_name: 'QualifiedLead', event_id: 'a' * 64, event_time: 123, action_source: 'website',
      event_source_url: 'https://example.com/landing',
      user_data: { ph: [Digest::SHA256.hexdigest('5511999999999')], fbp: 'fb.1.1234567890123.123' }
    )
  end

  it 'requires consent for site-origin conversions' do
    expect { build({ action_source: 'chat', ads_consent: false }).to_h }.to raise_error(ArgumentError, 'missing advertising consent')
  end

  it 'requires the click and WABA identifiers for business messaging' do
    attribution = { action_source: 'business_messaging', whatsapp_business_account_id: '123', ctwa_clid: 'Af-synthetic' }
    expect(build(attribution, name: 'LeadSubmitted').to_h).to include(messaging_channel: 'whatsapp')
    expect { build(attribution.reject { |key| key == :ctwa_clid }).to_h }.to raise_error(ArgumentError)
    expect { build(attribution, name: 'Lead').to_h }.to raise_error(ArgumentError)
  end
end
