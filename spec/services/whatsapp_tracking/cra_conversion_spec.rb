# frozen_string_literal: true

require_relative '../../../app/services/whatsapp_tracking/cra_conversion'
require_relative '../../../app/services/whatsapp_tracking/meta_event'

RSpec.describe WhatsappTracking::CraConversion do
  subject(:converter) { described_class.new(dedup_secret: 'synthetic-test-secret') }

  let(:occurrence) { Time.utc(2026, 11, 27, 12) }
  let(:common) { { phone: '+5511999999999', occurred_at: occurrence } }

  it 'preserves the CRA site and CTWA identifiers and dataset routing' do
    site = converter.attributes(**common, action_source: 'website')
    ctwa = converter.attributes(**common, action_source: 'business_messaging')
    expect(site.values_at(:event_id, :event_name, :dataset_id)).to eq(
      %w[2f785214a8330d81563f3562765b70d7e7cf4e8df61801095a4103c4d03159a2 Lead 1810107146920833]
    )
    expect(ctwa.values_at(:event_id, :event_name, :dataset_id)).to eq(
      %w[e394675da6ac03f8c9ec1052483cd946b1d30b37a1029216f56649cbc11d63e1 LeadSubmitted 1163151943355821]
    )
  end

  it 'uses the same qualified identity for both acquisition families' do
    chat = converter.attributes(**common, action_source: 'chat', qualified: true)
    ctwa = converter.attributes(**common, action_source: 'business_messaging', qualified: true)
    expect(chat.values_at(:event_id, :event_name)).to eq(
      %w[8acd92a690c7c8bd86c3ecd657e1184a750a6a67fbbe49720680b4a9279627de QualifiedLead]
    )
    expect(ctwa[:event_id]).to eq(chat[:event_id])
  end

  it 'includes the hashed visitor and omits an expired click identifier and case details' do
    attributes = converter.attributes(
      **common, action_source: 'website', ads_consent: true, visitor_id: 'a' * 48,
      page_url: 'https://carolineribeiroadvogados.com/consulta?case=private', fbp: "fb.1.#{occurrence.to_i * 1000}.browser",
      fbc: 'fb.1.1234567890123.expired', text: 'private'
    )
    payload = WhatsappTracking::MetaEvent.new(**attributes.except(:dataset_id)).to_h
    expect(payload[:user_data]).to include(external_id: [Digest::SHA256.hexdigest("cra:#{'a' * 48}")], fbp: attributes.dig(:attribution, :fbp))
    expect(payload[:user_data]).not_to have_key(:fbc)
    expect(payload[:event_source_url]).to eq('https://carolineribeiroadvogados.com/consulta')
    expect(payload.to_s).not_to include('private')
  end
end
