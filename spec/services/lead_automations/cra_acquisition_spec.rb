require 'rails_helper'
require 'webmock/rspec'
WebMock.disable_net_connect!(allow_localhost: true)

RSpec.describe 'CRA scoped acquisition' do
  include ActiveJob::TestHelper
  let(:user) { User.create!(name: 'Synthetic', email: "cra-#{SecureRandom.hex(5)}@example.com") }
  let(:pipeline) { Pipeline.create!(name: 'CRA synthetic', created_by: user) }
  let(:channel) { Channel::Whatsapp.create!(provider: 'evolution', phone_number: '+15550000001', provider_config: { instance_name: 'CR Advogados', attached_instance_id: LeadAutomations::CraAcquisition::INSTANCE_ID, existing_instance_attached: true, attachment_state: 'active', attachment_started_at: 1 }) }
  let(:box) { Inbox.create!(name: 'CRA synthetic', channel: channel, enable_auto_assignment: false) }
  let(:rule) { LeadAutomationRule.create!(name: 'CRA', active: true, acquisition_scope_key: 'client:cra', pipeline_id: pipeline.id, pipeline_stage_id: (pipeline.pipeline_stages.first || pipeline.pipeline_stages.create!(name: "New", position: 1)).id, owner_id: user.id, conditions: { version: 1, operator: 'any', ctwa: { enabled: true, inbox_id: box.id, instance_name: 'CR Advogados' }, domain: { enabled: true, host: 'carolineribeiroadvogados.com' } }) }
  let(:visitor) { 'a1' * 24 }
  def raw(click: 'synthetic-ctwa', id: SecureRandom.hex(8), visitor: nil)
    encoded = visitor ? "\uFEFF" + visitor.bytes.map { |b| b.to_s(2).rjust(8, '0').tr('01', "\u200C\u200B") }.join + "\uFEFF" : ''
    { key: { fromMe: false, id: id, remoteJid: '15550000002@s.whatsapp.net' }, messageTimestamp: Time.current.to_f,
      message: { conversation: "Synthetic#{encoded}" }, contextInfo: { externalAdReply: { ctwaClid: click, sourceId: '123', title: 'Synthetic ad', sourceUrl: 'https://fb.me/synthetic', thumbnail: 'PRIVATE' } } }.deep_stringify_keys
  end
  def ingest(r = raw)
    Whatsapp::AttachedEvolutionMessageService.new(inbox: box, params: { instance: 'CR Advogados', event: 'messages.upsert', lead_automation_received_at: Time.current.iso8601(6), data: r }.with_indifferent_access).perform
    LeadAcquisitionScopeEvent.first
  end
  def process(e)
    LeadAutomations::ProcessScopedEvent.call(e.id)
  end
  def payload(e, **changes)
    { 'version' => 1, 'acquisition_id' => SecureRandom.uuid, 'revision' => 1, 'phone_number' => Contact.find(e.contact_id).phone_number,
      'instance_id' => LeadAutomations::CraAcquisition::INSTANCE_ID, 'provider_message_id' => e.signal['provider_message_id'],
      'source' => 'ctwa', 'ctwa_clid' => 'synthetic-ctwa', 'occurred_at' => e.occurred_at.iso8601(6),
      'resolution' => { 'ad_id' => '123', 'ad_name' => 'Synthetic ad', 'campaign_id' => '789', 'campaign_name' => 'Synthetic campaign', 'status' => 'resolved' } }.merge(changes.stringify_keys)
  end
  def enrich(p)
    expect(LeadAutomations::ReceiveEnrichment.call(rule, p)).to eq(:accepted)
    LeadAutomations::ReconcileEnrichment.call(LeadAcquisitionEnrichment.order(:created_at).last.id)
  end
  before do
    ActiveJob::Base.queue_adapter = :test
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config)
    stub_const('ENV', ENV.to_h.merge('CRA_ACQUISITION_ENABLED' => 'true'))
    rule
  end

  it 'captures only CRA, retains the CTWA and projects without sending, reading or changing ownership' do
    expect(Whatsapp::SendOnWhatsappService).not_to receive(:new)
    expect_any_instance_of(PipelineItem).not_to receive(:publish)
    e = ingest
    expect(LeadAutomationEvent.count).to eq(0)
    expect(e.source).to eq('ctwa')
    expect(e.signal).to include('ctwa_clid' => 'synthetic-ctwa', 'source_id' => '123')
    expect(e.signal.to_json).not_to include('PRIVATE')
    expect(box.messages.sole.content_attributes['lead_acquisition']).to include('ctwa_clid' => 'synthetic-ctwa')
    process(e)
    deal = pipeline.pipeline_items.sole
    expect(rule.runs.sole.status).to eq('created')
    expect(deal.custom_fields).to include('cra_source' => 'ctwa')
    p = payload(e); enrich(p)
    expect(deal.reload.custom_fields).to include('cra_campaign_name' => 'Synthetic campaign', 'cra_ad_id' => '123')
    expect(deal.owner_id).to eq(user.id)
    expect(deal.custom_fields.to_json).not_to include('synthetic-ctwa')
    expect(box.messages.sole.content_attributes_for_egress.to_json).not_to include('synthetic-ctwa')
    expect(enqueued_jobs.map { |j| j[:job].name }.grep(/SendReply|BotRuntime|Read|Agent/)).to be_empty
  end

  it 'preserves organic first touch against a later CTWA' do
    e = ingest(raw(click: nil)); process(e)
    ingest(raw); process(e)
    expect(e.reload.source).to eq('none')
    expect(rule.runs.sole.status).to eq('skipped')
    expect(pipeline.pipeline_items.count).to eq(0)
  end

  it 'accepts a new CRA entry of an old global contact but refuses an old CRA conversation' do
    contact = Contact.new(name: 'Existing human', phone_number: '+15550000002'); contact.passive_observation = true; contact.skip_default_pipeline_assignment = true; contact.save!
    contact.update_column(:created_at, 1.year.ago)
    e = ingest; process(e)
    expect(rule.runs.sole.status).to eq('created')
    expect(contact.reload.name).to eq('Existing human')
  end

  it 'keeps a deal closed without creating a new deal on replay' do
    e = ingest; process(e)
    pipeline.pipeline_items.sole.update_column(:completed_at, Time.current)
    ingest; process(e)
    expect(pipeline.pipeline_items.count).to eq(1)
    expect(rule.runs.count).to eq(1)
  end

  it 'requires proof of the same first encoded message and then creates one deal' do
    e = ingest(raw(click: nil, visitor: visitor)); process(e)
    expect(e.reload.status).to eq('waiting')
    expect(e.signal['visitor_id']).to eq(visitor)
    p = payload(e, source: 'website', visitor_id: visitor, ctwa_clid: nil, site_event_id: SecureRandom.uuid,
      page_url: 'https://carolineribeiroadvogados.com/', consent: { 'basis' => 'explicit', 'version' => 'v1', 'at' => Time.current.iso8601, 'analytics' => true, 'ads' => true })
    enrich(p); process(e)
    expect(e.reload.source).to eq('none')
    expect(rule.runs.sole.status).to eq('created')
    expect(pipeline.pipeline_items.sole.custom_fields['cra_source']).to eq('website')
    process(e)
    expect(pipeline.pipeline_items.count).to eq(1)
  end

  it 'rejects late proof of another message' do
    e = ingest(raw(click: nil, visitor: visitor)); process(e)
    p = payload(e, source: 'website', visitor_id: visitor, provider_message_id: 'ANOTHER', ctwa_clid: nil,
      site_event_id: SecureRandom.uuid, page_url: 'https://carolineribeiroadvogados.com/', consent: { 'basis' => 'explicit', 'version' => 'v1', 'at' => Time.current.iso8601, 'analytics' => true, 'ads' => true })
    enrich(p); process(e)
    expect(LeadAcquisitionEnrichment.sole.status).to eq('review')
    expect(pipeline.pipeline_items.count).to eq(0)
  end

  it 'does not overwrite a manual campaign edit or technical identity' do
    e = ingest; process(e); p = payload(e); enrich(p)
    deal = pipeline.pipeline_items.sole
    deal.lead_automation_context = true
    deal.update!(custom_fields: deal.custom_fields.merge('cra_campaign_name' => 'Human', 'cra_ad_id' => 'evil'))
    expect(deal.custom_fields['cra_ad_id']).to eq('123')
    enrich(p.merge('revision' => 2, 'resolution' => p['resolution'].merge('campaign_name' => 'Refreshed', 'ad_name' => 'New ad name')))
    expect(deal.reload.custom_fields).to include('cra_campaign_name' => 'Human', 'cra_ad_name' => 'New ad name')
  end

  it 'deduplicates identical revisions and refuses conflicting identities or payloads' do
    e = ingest; process(e); p = payload(e); enrich(p)
    expect(LeadAutomations::ReceiveEnrichment.call(rule, p.deep_dup)).to eq(:duplicate)
    expect(LeadAutomations::ReceiveEnrichment.call(rule, p.merge('headline' => 'different'))).to eq(:conflict)
    expect(LeadAutomations::ReceiveEnrichment.call(rule, p.merge('revision' => 2, 'phone_number' => '+15550000099'))).to eq(:conflict)
    enrich(p.merge('revision' => 3, 'headline' => 'new'))
    enrich(p.merge('revision' => 2))
    expect(LeadAcquisitionEnrichment.find_by(revision: 2).status).to eq('superseded')
    expect(pipeline.pipeline_items.sole.custom_fields['cra_headline']).to eq('new')
  end

  it 'keeps the pipeline catalog local and does not expose technical identifiers' do
    LeadAutomations::CraProjection.configure_pipeline!(rule)
    definitions = Pipelines::CardConfiguration.definitions(pipeline.reload).pluck(:id)
    expect(definitions).to include('deal_attribute:cra_campaign_name')
    expect(definitions).not_to include('deal_attribute:cra_ctwa_clid', 'deal_attribute:cra_first_touch')
    other = Pipeline.create!(name: 'Other synthetic', created_by: user)
    expect(Pipelines::CardConfiguration.definitions(other).pluck(:id).grep(/cra_/)).to be_empty
  end

  it 'does not requalify an organic message with no encoded journey' do
    e = ingest(raw(click: nil)); process(e)
    p = payload(e, source: 'website', ctwa_clid: nil, site_event_id: SecureRandom.uuid,
      page_url: 'https://carolineribeiroadvogados.com/', consent: { 'basis' => 'explicit', 'version' => 'v1', 'at' => Time.current.iso8601, 'analytics' => true, 'ads' => true })
    enrich(p)
    expect(LeadAcquisitionEnrichment.sole.status).to eq('review')
    expect(pipeline.pipeline_items.count).to eq(0)
  end

  it 'does not create from a conversation that existed before CRA activation' do
    e = ingest
    Conversation.find(e.conversation_id).update_column(:created_at, rule.activated_at - 1.day)
    process(e)
    expect(rule.runs.sole.reason_code).to eq('old_conversation')
    expect(pipeline.pipeline_items.count).to eq(0)
  end

  it 'decodes base64url CTWA without persisting the encoded wrapper' do
    r = raw(click: nil)
    clid = 'Af' + 'aB_9' * 30
    r['contextInfo']['conversionData'] = Base64.urlsafe_encode64(clid, padding: false)
    e = ingest(r)
    expect(e.source).to eq('ctwa')
    expect(e.signal['ctwa_clid']).to eq(clid)
    expect(e.signal).not_to have_key('conversionData')
  end

  it 'turns CRA off without falling through to the legacy event' do
    stub_const('ENV', ENV.to_h.merge('CRA_ACQUISITION_ENABLED' => 'false'))
    ingest
    expect(LeadAcquisitionScopeEvent.count).to eq(0)
    expect(LeadAutomationEvent.count).to eq(0)
    expect(PipelineItem.count).to eq(0)
  end
end
