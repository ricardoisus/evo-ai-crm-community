# frozen_string_literal: true

require_relative '../../../app/services/whatsapp_tracking/journey_marker'

RSpec.describe WhatsappTracking::JourneyMarker do
  def marker(value)
    "\uFEFF#{value.unpack1('B*').tr('10', "\u200B\u200C")}\uFEFF"
  end

  it 'decodes the existing CRA website marker embedded in a message' do
    visitor_id = '0123456789abcdef' * 3
    expect(described_class.decode("Olá #{marker(visitor_id)}!")).to eq(tracking: :journey, visitor_id: visitor_id)
  end

  it 'distinguishes messages without a marker from malformed markers' do
    expect(described_class.decode('Olá')).to eq(tracking: :absent)
    expect(described_class.decode(marker('abc'))).to eq(tracking: :invalid)
  end

  it 'rejects duplicate blocks and invalid identifier bytes' do
    valid_marker = marker('a' * 48)
    expect(described_class.decode("#{valid_marker} #{valid_marker}")).to eq(tracking: :invalid)
    expect(described_class.decode(marker("\xff".b * 48))).to eq(tracking: :invalid)
  end
end
