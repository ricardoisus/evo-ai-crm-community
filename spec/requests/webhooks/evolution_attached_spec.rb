require 'rails_helper'
require 'webmock/rspec'
WebMock.disable_net_connect!(allow_localhost: true)

RSpec.describe 'Authenticated attachment callback', type: :request do
  include ActiveJob::TestHelper
  before do
    ActiveJob::Base.queue_adapter = :test
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config)
    @channel = Channel::Whatsapp.create!(provider: 'evolution', phone_number: '+15550000001', provider_config: {
      instance_name: 'synthetic-vetorial', existing_instance_attached: true, attachment_state: 'active', attachment_token: 'synthetic-only'
    })
  end

  it 'rejects missing/wrong tokens and unknown instances before enqueue' do
    [nil, 'wrong'].each do |token|
      post '/webhooks/evolution_attached', params: { instance: 'synthetic-vetorial', event: 'messages.upsert', data: {} },
           headers: { 'X-Evo-Attach-Token' => token }.compact, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
    post '/webhooks/evolution_attached', params: { instance: 'foreign' }, headers: { 'X-Evo-Attach-Token' => 'synthetic-only' }, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(enqueued_jobs).to be_empty
  end

  it 'queues authenticated events without the Evolution API key and stops on detach' do
    data = { instance: 'synthetic-vetorial', event: 'messages.upsert', data: {}, apikey: 'synthetic-do-not-store' }
    post '/webhooks/evolution_attached', params: data, headers: { 'X-Evo-Attach-Token' => 'synthetic-only' }, as: :json
    expect(response).to have_http_status(:ok)
    expect(enqueued_jobs.last[:job]).to eq(Webhooks::EvolutionAttachedJob)
    expect(enqueued_jobs.last[:args].to_json).not_to include('synthetic-do-not-store')
    @channel.update!(provider_config: @channel.provider_config.merge('attachment_state' => 'detached'))
    post '/webhooks/evolution_attached', params: data, headers: { 'X-Evo-Attach-Token' => 'synthetic-only' }, as: :json
    expect(response).to have_http_status(:conflict)
  end

  it 'rejects destructive native authorization for vetorial before any external request' do
    # Permission/auth are enforced first; direct controller coverage verifies the
    # safety boundary independently of the session provider.
    controller = Api::V1::Evolution::AuthorizationsController.new
    allow(controller).to receive(:params).and_return(ActionController::Parameters.new(authorization: { instance_name: 'vetorial' }))
    allow(controller).to receive(:render)
    expect(controller).not_to receive(:check_and_delete_existing_instance)
    controller.create
    expect(controller).to have_received(:render).with(json: { error: 'Use anexar instância existente; recriação recusada' }, status: :conflict)
  end
end
