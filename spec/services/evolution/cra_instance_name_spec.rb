require 'rails_helper'
require 'webmock/rspec'
RSpec.describe Evolution::ExistingInstanceClient do
  it 'validates names, encodes spaces in every request and never decodes input' do
    client = described_class.new(api_url: 'https://evolution.example.test', token: 'synthetic')
    %w[CR].each { |n| expect(described_class.valid_name?(n)).to be(true) }
    expect(described_class.valid_name?('CR Advogados')).to be(true)
    [' CR', 'CR ', '.', '..', 'a/b', 'a\\b', 'a?b', 'a#b', '%2e%2e', "a\nb", 'a' * 101].each do |name|
      expect(described_class.valid_name?(name)).to be(false)
      expect { client.webhook(name) }.to raise_error(described_class::Error)
    end
    stub_request(:get, 'https://evolution.example.test/instance/fetchInstances?instanceName=CR%20Advogados').to_return(body: '[]')
    stub_request(:get, 'https://evolution.example.test/webhook/find/CR%20Advogados').to_return(body: '{}')
    stub_request(:post, 'https://evolution.example.test/webhook/set/CR%20Advogados').to_return(body: '{}')
    client.instances('CR Advogados'); client.webhook('CR Advogados'); client.set_webhook('CR Advogados', {})
  end
end
