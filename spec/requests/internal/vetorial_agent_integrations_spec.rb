require 'rails_helper'

RSpec.describe 'Private read-only Evolution probe', type: :request do
  let(:secret) { 'synthetic-j8-' + 'x' * 40 }
  let(:deployment) { VetorialAgent::Deployment.create!(agent_bot: AgentBot.create!(name: 'Synthetic J8'), slug: 'synthetic-j8') }
  let(:path) { "/internal/vetorial_agent/integrations/#{deployment.id}" }

  before do
    allow(VetorialAgent::Policy).to receive(:secret).and_return(secret)
  end

  it 'requires HMAC and exposes no provider response for any integration state' do
    get path
    expect(response).to have_http_status(:unauthorized)
    service = instance_double(VetorialAgent::Integrations)
    allow(VetorialAgent::Integrations).to receive(:new).with(deployment).and_return(service)
    { 'configured' => 200, 'absent' => 204, 'error' => 503 }.each do |state, code|
      allow(service).to receive(:evolution).and_return(state)
      get path, headers: VetorialAgent::Signature.headers('', method: 'GET', path: path)
      expect(response.status).to eq(code)
      expect(response.body).to eq('')
      expect(response.headers.to_json).not_to match(/sk-j8-secret-canary|token-j8-canary|\+?55\d{10,11}/)
    end
  end
end
