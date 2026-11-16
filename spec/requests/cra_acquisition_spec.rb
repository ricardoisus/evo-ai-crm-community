require 'rails_helper'
RSpec.describe 'CRA authenticated contracts', type: :request do
  let(:user) { User.create!(name: 'Synthetic', email: "cra-request-#{SecureRandom.hex(5)}@example.com") }
  let(:pipeline) { Pipeline.create!(name: 'CRA request', created_by: user) }
  let(:channel) { Channel::Whatsapp.create!(provider: 'evolution', phone_number: '+15550000001', provider_config: { instance_name: 'CR Advogados', attached_instance_id: LeadAutomations::CraAcquisition::INSTANCE_ID, existing_instance_attached: true, attachment_state: 'active' }) }
  let(:box) { Inbox.create!(name: 'CRA request', channel: channel) }
  let(:rule) { LeadAutomationRule.create!(name: 'CRA', active: true, acquisition_scope_key: 'client:cra', pipeline_id: pipeline.id, pipeline_stage_id: pipeline.pipeline_stages.create!(name: 'New', position: 1).id, intake_token_digest: Digest::SHA256.hexdigest('synthetic-intake'), enrichment_token_digest: Digest::SHA256.hexdigest('synthetic-enrichment'), conditions: { version: 1, operator: 'any', ctwa: { enabled: true, inbox_id: box.id, instance_name: 'CR Advogados' }, domain: { enabled: true, host: 'carolineribeiroadvogados.com' } }) }
  let(:event_id) { SecureRandom.uuid }
  let(:payload) { { version: 2, event_id: event_id, page_url: 'https://carolineribeiroadvogados.com/', contact: { name: 'Synthetic request', phone_number: '+15550000009' }, contact_consent: { accepted: true, version: 'cra-contact-v1', at: Time.current.iso8601 }, acquisition: { visitor_id: 'aa' * 24, first_touch: { utm_source: 'MetaAds' }, last_touch: { utm_campaign: '123', utm_placement: 'feed' }, analytics: true, ads: true, consent_basis: 'explicit', consent_version: 'v1', consent_at: Time.current.iso8601 } } }
  let(:headers) { { 'Authorization' => 'Bearer synthetic-intake', 'Origin' => 'https://carolineribeiroadvogados.com', 'Idempotency-Key' => event_id } }
  def submit(p = payload, h = headers)
    post "/public/lead_automation_rules/#{rule.id}/leads", params: p, headers: h, as: :json
  end
  before do
    ActiveJob::Base.queue_adapter = :test
    stub_const('ENV', ENV.to_h.merge('CRA_ACQUISITION_ENABLED' => 'true'))
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config)
    allow(LeadAutomations::IntakeRateLimit).to receive(:allowed?).and_return(true)
    rule
  end
  it 'accepts v2, preserves a human name, projects attribution and replays without messages' do
    contact = Contact.new(name: 'Human', phone_number: '+15550000009'); contact.passive_observation = true; contact.skip_default_pipeline_assignment = true; contact.save!
    contact.update_column(:created_at, 1.year.ago)
    submit
    expect(response).to have_http_status(:accepted)
    expect(LeadAutomationEvent.count).to eq(0)
    e = LeadAcquisitionScopeEvent.sole
    expect(e.signal['acquisition']).to include('visitor_id' => 'aa' * 24)
    LeadAutomations::ProcessScopedEvent.call(e.id)
    expect(rule.runs.sole.status).to eq('created')
    expect(pipeline.pipeline_items.sole.custom_fields).to include('cra_utm_campaign' => '123')
    submit
    expect(response).to have_http_status(:accepted)
    expect(LeadAcquisitionScopeEvent.count).to eq(1)
    expect(contact.reload.name).to eq('Human')
    expect(Message.count).to eq(0)
    expect(Conversation.count).to eq(0)
  end
  it 'rejects missing opt-in, arbitrary attribution keys, wrong origin/token, v1 on scoped and flag off' do
    submit(payload.except(:contact_consent)); expect(response).to have_http_status(:bad_request)
    submit(payload.merge(acquisition: payload[:acquisition].merge(first_touch: { body: 'PRIVATE' }))); expect(response).to have_http_status(:bad_request)
    submit(payload, headers.merge('Authorization' => 'Bearer synthetic-enrichment')); expect(response).to have_http_status(:forbidden)
    submit(payload, headers.merge('Origin' => 'https://carolineribeiroadvogados.com.evil.test')); expect(response).to have_http_status(:forbidden)
    submit(payload.except(:version, :acquisition, :contact_consent)); expect(response).to have_http_status(:bad_request)
    stub_const('ENV', ENV.to_h.merge('CRA_ACQUISITION_ENABLED' => 'false'))
    submit; expect(response).to have_http_status(:service_unavailable)
    expect(Contact.count).to eq(0)
  end
  it 'rejects 7..9 digit phones in both CRA APIs before persisting' do
    %w[+1234567 +12345678 +123456789].each do |phone|
      submit(payload.deep_merge(contact: { phone_number: phone }))
      expect(response).to have_http_status(:bad_request)
      p = { version: 1, acquisition_id: SecureRandom.uuid, revision: 1, phone_number: phone,
            instance_id: LeadAutomations::CraAcquisition::INSTANCE_ID, source: 'ctwa', occurred_at: Time.current.iso8601 }
      post "/public/lead_automation_rules/#{rule.id}/acquisitions", params: p,
           headers: { 'Authorization' => 'Bearer synthetic-enrichment', 'Idempotency-Key' => "#{p[:acquisition_id]}:1" }, as: :json
      expect(response).to have_http_status(:bad_request)
    end
    expect(Contact.count).to eq(0)
    expect(LeadAcquisitionEnrichment.count).to eq(0)
  end
  it 'persists enrichment before ingress, waits for the event, uses its own token and refuses CORS' do
    p = { version: 1, acquisition_id: SecureRandom.uuid, revision: 1, phone_number: '+15550000009', instance_id: LeadAutomations::CraAcquisition::INSTANCE_ID,
      source: 'website', occurred_at: Time.current.iso8601, visitor_id: 'aa' * 24, first_touch: { utm_source: 'MetaAds' } }
    h = { 'Authorization' => 'Bearer synthetic-enrichment', 'Idempotency-Key' => "#{p[:acquisition_id]}:1" }
    path = "/public/lead_automation_rules/#{rule.id}/acquisitions"
    post path, params: p, headers: h.merge('Authorization' => 'Bearer synthetic-intake'), as: :json
    expect(response).to have_http_status(:forbidden)
    post path, params: p, headers: h.merge('Origin' => 'https://carolineribeiroadvogados.com'), as: :json
    expect(response).to have_http_status(:forbidden)
    post path, params: p, headers: h, as: :json
    expect(response).to have_http_status(:accepted)
    LeadAutomations::ReconcileEnrichment.call(LeadAcquisitionEnrichment.sole.id)
    expect(LeadAcquisitionEnrichment.sole.status).to eq('pending')
    expect(Contact.count).to eq(0)
    submit
    LeadAutomations::ProcessScopedEvent.call(LeadAcquisitionScopeEvent.sole.id)
    LeadAutomations::ReconcileEnrichment.call(LeadAcquisitionEnrichment.sole.id)
    expect(LeadAcquisitionEnrichment.sole.status).to eq('applied')
    post path, params: p, headers: h, as: :json
    expect(response).to have_http_status(:accepted)
    post path, params: p.merge(headline: 'conflict'), headers: h, as: :json
    expect(response).to have_http_status(:conflict)
  end
end

RSpec.describe 'CRA technical identifiers RBAC', type: :request do
  it 'refuses a non administrator before querying the deal' do
    user = User.create!(name: 'Synthetic agent', email: "cra-rbac-#{SecureRandom.hex(5)}@example.com")
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) { Current.user = user; Current.evo_permission_cache = {} }
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission).and_return(true)
    allow(user).to receive(:administrator?).and_return(false)
    get "/api/v1/pipelines/#{SecureRandom.uuid}/pipeline_items/#{SecureRandom.uuid}/acquisition"
    expect(response).to have_http_status(:forbidden)
  ensure
    Current.reset
  end
end
