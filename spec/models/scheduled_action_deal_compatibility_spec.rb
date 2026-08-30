# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ScheduledAction, type: :model do
  it 'keeps numeric legacy deal targets in the rollback-compatible columns' do
    action = described_class.new(deal_id: 42)

    action.valid?

    expect(action[:deal_id]).to eq(42)
    expect(action.legacy_deal_id).to eq(42)
    expect(action.deal_uuid).to be_nil
    expect(action.canonical_deal_id).to eq(42)
  end

  it 'routes UUID deal targets to the additive canonical column' do
    deal_id = SecureRandom.uuid
    action = described_class.new(deal_id: deal_id)

    expect(action[:deal_id]).to be_nil
    expect(action.legacy_deal_id).to be_nil
    expect(action.deal_uuid).to eq(deal_id)
    expect(action.canonical_deal_id).to eq(deal_id)
  end
end
