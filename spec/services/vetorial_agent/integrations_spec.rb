require 'rails_helper'

RSpec.describe VetorialAgent::Integrations do
  let(:channel) { Channel::Whatsapp.new(provider: 'evolution', provider_config: { 'instance_name' => 'synthetic', 'existing_instance_attached' => true }) }
  let(:box) { double('inbox', channel: channel) }
  let(:deployment) { double('deployment', payload: { 'binding' => { 'inbox_ids' => ['box'] } }) }
  let(:client) { instance_double(Evolution::ExistingInstanceClient) }
  let(:service) { described_class.new(deployment) }

  before do
    allow(Inbox).to receive(:where).with(id: ['box']).and_return([box])
    allow(GlobalConfigService).to receive(:load).with('EVOLUTION_API_URL', '').and_return('https://synthetic.invalid')
    allow(GlobalConfigService).to receive(:load).with('EVOLUTION_ADMIN_SECRET', '').and_return('token-j8-canary')
    allow(Evolution::ExistingInstanceClient).to receive(:new).and_return(client)
  end

  it 'uses only the read-only instance probe and discards phone, credentials and arbitrary fields' do
    allow(client).to receive(:instances).with('synthetic').and_return([
      { 'name' => 'synthetic', 'connectionStatus' => 'open', 'ownerJid' => '+5511987654321', 'token' => 'sk-j8-secret-canary' }
    ])
    expect(service.evolution).to eq('configured')
  end

  it 'reports absent without making an external request for a missing binding or secret' do
    allow(Inbox).to receive(:where).and_return([])
    expect(client).not_to receive(:instances)
    expect(service.evolution).to eq('absent')
  end

  it 'reduces disconnection and provider exceptions to error' do
    allow(client).to receive(:instances).and_return([{ 'name' => 'synthetic', 'connectionStatus' => 'close' }])
    expect(service.evolution).to eq('error')
    allow(client).to receive(:instances).and_raise(StandardError, 'sk-j8-secret-canary +5511987654321')
    expect(service.evolution).to eq('error')
  end
end
