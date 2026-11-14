require 'rails_helper'
RSpec.describe 'Lead automation rules', type: :request do
  include ActiveJob::TestHelper
  let(:user) { User.create!(name: 'Synthetic Admin', email: "l4-#{SecureRandom.hex(6)}@example.com") }
  let(:pipeline) { Pipeline.create!(name: 'Synthetic pipeline', created_by: user) }
  let(:stage) { pipeline.pipeline_stages.first || pipeline.pipeline_stages.create!(name: 'New', position: 1) }
  let(:payload) { { name: 'Synthetic rule', conditions: { version: 1, operator: 'any', domain: { enabled: true, host: 'co.example.com' } }, pipeline_id: pipeline.id, pipeline_stage_id: stage.id } }
  let(:rule) { LeadAutomationRule.create!(payload) }
  let(:base) { '/api/v1/lead_automation_rules' }
  before do
    actor = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) { Current.user = actor; Current.evo_permission_cache = {} }
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission).and_return(true)
    allow_any_instance_of(User).to receive(:administrator?).and_return(true)
  end
  after { Current.reset }
  def data; response.parsed_body['data']; end

  it 'creates, lists, shows, updates and soft deletes without exposing secrets' do
    post base, params: payload, as: :json
    expect(response).to have_http_status(:created)
    id = data['id']
    expect(data).not_to have_key('intake_token_digest')
    get base
    expect(data.pluck('id')).to include(id)
    get "#{base}/#{id}"
    expect(data['revision']).to eq(1)
    patch "#{base}/#{id}", params: { name: 'Edited', revision: 1 }, as: :json
    expect(data['revision']).to eq(2)
    delete "#{base}/#{id}", params: { revision: 2 }, as: :json
    expect(response).to have_http_status(:ok)
    expect(LeadAutomationRule.find(id).deleted_at).to be_present
    get "#{base}/#{id}"
    expect(response).to have_http_status(:not_found)
  end

  it 'locks revisions and renews activation cutoff only on reactivation' do
    patch "#{base}/#{rule.id}/activation", params: { active: true, revision: 1 }, as: :json
    expect(response).to have_http_status(:ok)
    cutoff = rule.reload.activated_at
    patch "#{base}/#{rule.id}", params: { name: 'Edited', revision: 1 }, as: :json
    expect(response).to have_http_status(:conflict)
    patch "#{base}/#{rule.id}", params: { name: 'Edited', revision: 2 }, as: :json
    expect(rule.reload.activated_at).to eq(cutoff)
    patch "#{base}/#{rule.id}/activation", params: { active: false, revision: 3 }, as: :json
    travel 2.seconds do
      patch "#{base}/#{rule.id}/activation", params: { active: true, revision: 4 }, as: :json
    end
    expect(rule.reload.activated_at).to be > cutoff
  end

  it 'rotates a 256 bit token once and returns only presence thereafter' do
    post "#{base}/#{rule.id}/rotate_token", params: { revision: 1 }, as: :json
    expect(response).to have_http_status(:ok)
    token = data['token']
    expect(token.length).to eq(64)
    expect(response.headers['Cache-Control']).to include('no-store')
    expect(rule.reload.token_valid?(token)).to be(true)
    expect(rule.token_valid?('wrong')).to be(false)
    get "#{base}/#{rule.id}"
    expect(data['has_intake_token']).to be(true)
    expect(data).not_to have_key('token')
  end

  it 'tests synthetically without database or job writes and lists safe runs' do
    rule.update!(active: true)
    counts = [LeadAutomationRule.count, LeadAutomationEvent.count, LeadAutomationRun.count, PipelineItem.count]
    queued = enqueued_jobs.size
    expect(LeadAutomationRun).not_to receive(:create!)
    expect(ActiveJob::Base).not_to receive(:perform_later)
    post "#{base}/#{rule.id}/test", params: { event: { source: 'domain', page_url: 'https://co.example.com/form', occurred_at: Time.current.iso8601(6), contact_created_at: Time.current.iso8601(6) } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(data).to include('matched' => true, 'dry_run' => true)
    expect(enqueued_jobs.size).to eq(queued)
    expect([LeadAutomationRule.count, LeadAutomationEvent.count, LeadAutomationRun.count, PipelineItem.count]).to eq(counts)
    get "#{base}/#{rule.id}/runs", params: { per_page: 999 }
    expect(data).to eq([])
    expect(response.parsed_body.dig('meta', 'pagination', 'per_page')).to eq(100)
  end

  %w[index show create update destroy activation test runs rotate_token].each do |action|
    it "denies non-admin #{action}" do
      rule
      allow_any_instance_of(User).to receive(:administrator?).and_return(false)
      path = %w[index create].include?(action) ? base : "#{base}/#{rule.id}"
      path += "/#{action}" if %w[activation test runs rotate_token].include?(action)
      verb = { 'create' => :post, 'update' => :patch, 'destroy' => :delete, 'activation' => :patch, 'test' => :post, 'rotate_token' => :post }.fetch(action, :get)
      if verb == :get
        get path
      else
        public_send(verb, path, params: payload.merge(revision: 1), as: :json)
      end
      expect(response).to have_http_status(:forbidden)
    end
  end

  it 'requires authentication with the real authentication filter' do
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!).and_call_original
    get base
    expect(response).to have_http_status(:unauthorized)
  end

  it 'respects pipeline policy for direct API access' do
    allow_any_instance_of(PipelinePolicy).to receive(:show?).and_return(false)
    get "#{base}/#{rule.id}"
    expect(response).to have_http_status(:forbidden)
    post base, params: payload, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  %w[index show create update destroy activation test runs rotate_token].each do |action|
    it "denies missing permission for admin #{action}" do
      rule
      allow_any_instance_of(EvoAuthService).to receive(:check_user_permission).and_return(false)
      path = %w[index create].include?(action) ? base : "#{base}/#{rule.id}"
      path += "/#{action}" if %w[activation test runs rotate_token].include?(action)
      verb = { 'create' => :post, 'update' => :patch, 'destroy' => :delete, 'activation' => :patch, 'test' => :post, 'rotate_token' => :post }.fetch(action, :get)
      if verb == :get
        get path
      else
        public_send(verb, path, params: payload.merge(revision: 1), as: :json)
      end
      expect(response).to have_http_status(:forbidden)
    end
  end

  it 'rejects invalid configuration and out-of-pipeline stages' do
    post base, params: payload.merge(pipeline_id: SecureRandom.uuid), as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    post base, params: payload.deep_merge(conditions: { version: 2 }), as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end
end
