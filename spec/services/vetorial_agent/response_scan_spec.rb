require 'rails_helper'

RSpec.describe VetorialResponseScan do
  it 'detects opaque secret and token canaries, provider token patterns and full phones' do
    ['sk-j8-secret-canary', 'token-j8-canary', 'sk-proj-' + 'x' * 32, 'gsk_' + 'x' * 32,
     'Bearer ' + 'x' * 32, '+15559999999'].each do |value|
      expect { described_class.check!({ data: value }.to_json, phones: true) }.to raise_error(/Sensitive value/)
    end
    expect { described_class.check!({ openai: 'configured', groq: 'error' }.to_json, phones: true) }.not_to raise_error
  end
end
