# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ScheduledAction, type: :model do
  it 'routes numeric legacy deal targets to the compatibility column' do
    action = described_class.new(deal_id: 42)

    action.valid?

    expect(action[:deal_id]).to be_nil
    expect(action.legacy_deal_id).to eq(42)
    expect(action.canonical_deal_id).to eq(42)
  end

  it 'keeps UUID deal targets in the canonical deal_id column' do
    deal_id = SecureRandom.uuid
    action = described_class.new(deal_id: deal_id)

    expect(action[:deal_id]).to eq(deal_id)
    expect(action.legacy_deal_id).to be_nil
    expect(action.canonical_deal_id).to eq(deal_id)
  end
end
