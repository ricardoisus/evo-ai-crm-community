require 'rails_helper'
RSpec.describe 'Public lead intake', type: :request do
  include ActiveJob::TestHelper
  let(:user) { User.create!(name: 'Synthetic', email: "intake-#{SecureRandom.hex(6)}@example.com") }
  let(:pipeline) { Pipeline.create!(name: 'Synthetic', created_by: user) }
  let(:token) { 'synthetic-only-intake-token' }
  let(:rule) { LeadAutomationRule.create!(name: 'Domain', active: true, pipeline_id: pipeline.id, pipeline_stage_id: (pipeline.pipeline_stages.first || pipeline.pipeline_stages.create!(name: "New", position: 1)).id, intake_token_digest: Digest::SHA256.hexdigest(token), conditions: { version: 1, operator: 'any', domain: { enabled: true, host: 'co.example.com' } }) }
  let(:path) { "/public/lead_automation_rules/#{rule.id}/leads" }
  let(:event_id) { SecureRandom.uuid }
  let(:payload) { { event_id: event_id, page_url: 'https://co.example.com/form', contact: { name: 'Synthetic form', phone_number: '+15550000009' } } }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Origin' => 'https://co.example.com', 'Idempotency-Key' => event_id } }
  def submit(body = payload, h = headers)
    post path, params: body, headers: h, as: :json
  end
  before do
    ActiveJob::Base.queue_adapter = :test
    allow(LeadAutomations::IntakeRateLimit).to receive(:allowed?).and_return(true)
    rule
  end

  it 'accepts, persists, creates a deal asynchronously, and returns the same acceptance on replay' do
    expect_any_instance_of(Contact).not_to receive(:publish_contact_created)
    expect_any_instance_of(Contact).not_to receive(:trigger_contact_created_automation)
    expect_any_instance_of(PipelineItem).not_to receive(:publish)
    count = Contact.count
    submit
    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to eq({ 'accepted' => true, 'event_id' => event_id })
    event = LeadAutomationEvent.sole
    expect(Contact.count).to eq(count + 1)
    expect(PipelineItem.count).to eq(0)
    LeadAutomations::ProcessEvent.call(event.id)
    expect(rule.runs.sole.status).to eq('created')
    expect(Conversation.count).to eq(0)
    2.times { submit }
    expect(response).to have_http_status(:accepted)
    expect(Contact.count).to eq(count + 1)
    expect(LeadAutomationEvent.count).to eq(1)
    expect(rule.runs.count).to eq(1)
    expect(response.headers['Access-Control-Allow-Origin']).to eq('https://co.example.com')
    expect(response.headers['Access-Control-Allow-Credentials']).to be_nil
  end

  it 'preserves old contacts without edits and logs old_contact' do
    contact = Contact.new(name: 'Original synthetic', phone_number: payload[:contact][:phone_number]); contact.passive_observation = true; contact.save!
    contact.update_column(:created_at, 1.day.ago)
    submit
    expect(response).to have_http_status(:accepted)
    LeadAutomations::ProcessEvent.call(LeadAutomationEvent.sole.id)
    expect(rule.runs.sole.reason_code).to eq('old_contact')
    expect(contact.reload.name).to eq('Original synthetic')
    expect(pipeline.pipeline_items.count).to eq(0)
  end

  it 'refuses invalid token, origin, inactive/deleted rules and does not create contacts' do
    count = Contact.count
    [headers.except('Authorization'), headers.merge('Authorization' => 'Bearer wrong'), headers.except('Origin'),
     headers.merge('Origin' => 'https://co.example.com.evil.test'), headers.merge('Origin' => 'https://co.example.com:443')].each do |h|
      submit(payload, h)
      expect(response).to have_http_status(:forbidden)
    end
    rule.update!(active: false)
    submit
    expect(response).to have_http_status(:forbidden)
    rule.update_columns(active: true, deleted_at: Time.current)
    submit
    expect(response).to have_http_status(:forbidden)
    expect(Contact.count).to eq(count)
  end

  it 'rejects host tricks, injected fields, non-E164, invalid UUID and mismatched idempotency key' do
    invalid = %w[http://co.example.com https://co.example.com.evil.test https://user@co.example.com https://co.example.com:444].map { |url| payload.merge(page_url: url) }
    invalid += [payload.merge(contact_id: SecureRandom.uuid), payload.merge(event_id: 'invalid'),
                payload.merge(contact: payload[:contact].merge(created_at: Time.current)),
                payload.merge(contact: payload[:contact].merge(phone_number: '15550000009')),
                payload.merge(event_id: SecureRandom.uuid)]
    invalid.each do |body|
      submit(body)
      expect(response).to have_http_status(:unprocessable_entity)
    end
    expect(LeadAutomationEvent.count).to eq(0)
  end

  it 'limits before creating contacts and fails closed when Redis is unavailable' do
    allow(LeadAutomations::IntakeRateLimit).to receive(:allowed?).with(anything, 20).and_return(false)
    submit(payload, headers.merge('Authorization' => 'Bearer invalid'))
    expect(response).to have_http_status(:too_many_requests)
    expect(response.headers['Retry-After']).to eq('60')
    allow(LeadAutomations::IntakeRateLimit).to receive(:allowed?).and_raise(Redis::CannotConnectError)
    submit
    expect(response).to have_http_status(:service_unavailable)
    expect(LeadAutomationEvent.count).to eq(0)
  end

  it 'returns 503 without writes when the Redis pool is missing' do
    allow(LeadAutomations::IntakeRateLimit).to receive(:allowed?).and_call_original
    original_pool = $velma
    $velma = nil
    count = Contact.count
    submit
    expect(response).to have_http_status(:service_unavailable)
    expect(Contact.count).to eq(count)
    expect(LeadAutomationEvent.count).to eq(0)
  ensure
    $velma = original_pool
  end

  it 'checks the rule limit, JSON content type and size' do
    allow(LeadAutomations::IntakeRateLimit).to receive(:allowed?).with(anything, 60).and_return(false)
    submit
    expect(response).to have_http_status(:too_many_requests)
    allow(LeadAutomations::IntakeRateLimit).to receive(:allowed?).and_return(true)
    post path, params: payload.to_json, headers: headers.merge('Content-Type' => 'text/plain')
    expect(response).to have_http_status(:unprocessable_entity)
    submit(payload.merge(contact: payload[:contact].merge(name: 'x' * 17000)))
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'allows only the exact origin, POST and allowed headers in preflight' do
    h = headers.merge('Access-Control-Request-Method' => 'POST', 'Access-Control-Request-Headers' => 'authorization,content-type,idempotency-key')
    options path, headers: h
    expect(response).to have_http_status(:no_content)
    expect(response.headers['Access-Control-Allow-Origin']).to eq('https://co.example.com')
    options path, headers: h.merge('Access-Control-Request-Headers' => 'cookie')
    expect(response).to have_http_status(:forbidden)
    options path, headers: h.merge('Origin' => 'https://elsewhere.example.com')
    expect(response).to have_http_status(:forbidden)
  end

  it 'rolls back contact creation when event persistence fails and returns 503' do
    allow(LeadAutomations::CaptureEvent).to receive(:call).and_return(nil)
    count = Contact.count
    submit
    expect(response).to have_http_status(:service_unavailable)
    expect(Contact.count).to eq(count)
  end
end
