# frozen_string_literal: true

require_relative '../../../app/services/whatsapp_tracking/meta_client'

RSpec.describe WhatsappTracking::MetaClient do
  subject(:client) { described_class.new(dataset_id: '123', token: 'synthetic') }

  let(:http) { double('HTTP') }

  before do
    allow(Net::HTTP).to receive(:start).and_yield(http)
  end

  def respond(code, body)
    response = double('response', code: code.to_s)
    allow(response).to receive(:read_body).and_yield(body)
    allow(http).to receive(:request).and_yield(response).and_return(response)
  end

  it 'keeps the stable event id and sets the test code without placing the token in the URL' do
    respond(200, '{"events_received":1}')
    event = { event_id: 'stable-id' }
    expect(client.deliver(event, test_code: 'TEST')).to include(status: :accepted, http_status: 200)
    expect(http).to have_received(:request) do |request|
      expect(request.path).to eq('/v25.0/123/events')
      expect(request['Authorization']).to eq('Bearer synthetic')
      expect(JSON.parse(request.body)).to eq('data' => [{ 'event_id' => 'stable-id' }], 'test_event_code' => 'TEST')
    end
  end

  it 'keeps only numeric error fields from a rejected receipt' do
    respond(400, '{"error":{"code":100,"error_subcode":7,"message":"private input"}}')
    expect(client.deliver({})).to eq(status: :rejected, http_status: 400, error_code: 100, error_subcode: 7)
  end

  it 'classifies a throttled request as retryable' do
    respond(429, '{}')
    expect(client.deliver({})).to include(status: :retryable)
  end

  it 'preserves uncertainty for a response missing an acceptance count' do
    respond(200, '{}')
    expect(client.deliver({})).to include(status: :uncertain)
  end

  it 'preserves uncertainty after a read timeout' do
    allow(http).to receive(:request).and_raise(Net::ReadTimeout)
    expect(client.deliver({})).to eq(status: :uncertain, http_status: nil)
  end
end
