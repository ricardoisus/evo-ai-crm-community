require 'rails_helper'

RSpec.describe 'Core catalog transparent proxy' do
  it 'keeps native payload and query intact' do
    body = { data: [{ id: 'native' }], meta: { total: 99, page: 2 }, custom: ['preserved'] }.to_json
    query = { 'page' => '2', 'filters' => { 'operator' => 'AND' } }
    allow(EvoAiCoreService).to receive(:build_headers).and_return({})
    expect(EvoAiCoreService).to receive(:get).with('/api/v1/agents', query: query, headers: {}, timeout: 2).and_return(double(code: 200, body: body))
    expect(EvoAiCoreService.catalog_agents(query)).to eq(status: 200, body: JSON.parse(body))
  end

  [Timeout::Error, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError].each do |failure|
    it "treats #{failure} as a partial Core outage" do
      allow(EvoAiCoreService).to receive(:get).and_raise(failure)
      expect(EvoAiCoreService.catalog_agents).to eq(status: 503, body: nil)
    end
  end
end
