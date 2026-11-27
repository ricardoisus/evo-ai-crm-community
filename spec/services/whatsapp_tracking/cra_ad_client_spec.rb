# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WhatsappTracking::CraAdClient do
  let(:client) { described_class.new(token: 'synthetic') }
  let(:http) { double('HTTP') }
  let(:response) { double('response', code: '200') }
  let(:payload) do
    { id: '100', account_id: described_class::ACCOUNT_ID, name: 'Synthetic ad',
      adset: { id: '200', name: 'Synthetic adset', targeting: { publisher_platforms: %w[facebook instagram] } },
      campaign: { id: '300', name: 'Synthetic campaign' },
      creative: { id: '400', name: 'Synthetic creative', instagram_permalink_url: 'https://instagram.com/p/synthetic/' },
      text: 'private response details' }
  end

  before do
    allow(Net::HTTP).to receive(:start).and_yield(http)
    allow(http).to receive(:request).and_yield(response).and_return(response)
    allow(response).to receive(:[]).and_return(nil)
  end

  it 'projects only allowlisted ad metadata from the CRA ad account' do
    allow(response).to receive(:read_body).and_yield(payload.to_json)
    result = client.fetch('100')
    expect(result).to include(status: 'resolved', cooldown: false)
    expect(result[:resolution]).to include('ad_name' => 'Synthetic ad', 'adset_id' => '200', 'campaign_id' => '300',
                                           'platforms' => 'facebook,instagram', 'creative_id' => '400')
    expect(result[:resolution].to_json).not_to include('private response details', 'placement')
  end

  it 'rejects another ad account and stops new lookups when usage is high' do
    allow(response).to receive(:read_body).and_yield(payload.merge(account_id: '999').to_json)
    allow(response).to receive(:[]).with('x-app-usage').and_return('{"call_count":93}')
    expect(client.fetch('100')).to eq(status: 'conflict', cooldown: true)
  end
end
