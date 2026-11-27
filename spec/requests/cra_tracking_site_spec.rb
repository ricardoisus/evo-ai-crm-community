# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'CRA native site tracking' do
  let(:visitor_id) { 'a' * 48 }
  let(:event_id) { SecureRandom.uuid }
  let(:headers) { { 'X-CRA-Tracking-Token' => 'synthetic-site-token', 'X-CRA-Rate-Key' => 'e' * 64 } }
  let(:base) { { client: 'cra', version: 1, visitor_id: visitor_id } }
  let(:batch) do
    base.merge(kind: 'site_batch', consent: { analytics: true, ads: false, version: WhatsappTracking::CraSiteContract::VERSION,
                                              basis: 'explicit', at: (Time.current.to_f * 1000).to_i },
               events: [{ event_id: event_id, type: 'whatsapp_click', path: '/', target: 'hero',
                          page_url: 'https://carolineribeiroadvogados.com/?fbclid=private', occurred_at: Time.current.iso8601 }],
               first_touch: {}, last_touch: { utm_placement: 'facebook', fbc: 'never save without ads' })
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('WHATSAPP_TRACKING_CRA_SITE_ENABLED').and_return('true')
    allow(ENV).to receive(:[]).with('WHATSAPP_TRACKING_CRA_SITE_MODE').and_return('native')
    allow(ENV).to receive(:[]).with('WHATSAPP_TRACKING_CRA_SITE_TOKEN').and_return('synthetic-site-token')
    allow(ENV).to receive(:[]).with('WHATSAPP_TRACKING_CRA_DEDUP_SECRET').and_return('synthetic-dedup-secret')
    allow(LeadAutomations::IntakeRateLimit).to receive(:allowed?).and_return(true)
  end

  it 'accepts and deduplicates the existing site wire format, with no ad identifiers when ads are disabled' do
    submit(batch)
    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to include('accepted' => true, 'http' => 202)
    submit(batch)
    expect(response).to have_http_status(:accepted)
    expect(CraTrackingSiteEvent.sole.path).to eq('/')
    expect(CraTrackingSiteVisitor.sole.last_touch).to eq('utm_posicionamento' => 'facebook', 'utm_placement' => 'facebook')
    expect(CraTrackingSiteVisitor.sole.visitor_key).not_to eq(visitor_id)
    submit(batch.merge(events: [batch[:events].first.merge(target: 'direct')]))
    expect(response).to have_http_status(:conflict)
  end

  it 'commits revocation before acknowledging and blocks already queued or replayed events' do
    submit(batch)
    submit(base.merge(kind: 'revoke', analytics: false, ads: false, revoked_at: Time.current.iso8601),
           headers.except('X-CRA-Rate-Key'))
    expect(response).to have_http_status(:accepted)
    expect(CraTrackingSiteVisitor.sole).to have_attributes(analytics: false, ads: false, last_touch: {})
    expect(CraTrackingSiteEvent.count).to eq(0)
    submit(batch)
    expect(response).to have_http_status(:conflict)
  end

  it 'rejects bad authentication, malformed fields and foreign URLs without creating rows' do
    submit(batch, headers.merge('X-CRA-Tracking-Token' => 'wrong'))
    expect(response).to have_http_status(:forbidden)
    submit(batch.merge(visitor_id: {}))
    expect(response).to have_http_status(422)
    submit(batch.merge(events: [batch[:events].first.merge(page_url: 'https://other.example/')]))
    expect(response).to have_http_status(422)
    expect(CraTrackingSiteVisitor.count).to eq(0)
  end

  def submit(payload, request_headers = headers)
    post '/webhook/cra-whatsapp-site-v1', params: payload, headers: request_headers, as: :json
  end
end
