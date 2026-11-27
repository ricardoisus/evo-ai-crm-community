# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WhatsappTracking::Capture do
  let(:channel) { Channel::Whatsapp.create!(provider: 'evolution', phone_number: '+15550000001', provider_config: { instance_name: 'CRA' }) }
  let(:inbox) { Inbox.create!(name: 'CRA tracking observation', channel: channel) }
  let(:contact) { Contact.create!(name: 'Synthetic contact', phone_number: '+15550000002') }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: '15550000002') }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:destination) do
    WhatsappTrackingDestination.create!(inbox: inbox, name: 'CTWA', dataset_id: WhatsappTracking::CraConversion::MESSAGING_DATASET,
                                        credential_ref: 'WHATSAPP_TRACKING_META_TEST_TOKEN')
  end
  let(:signal) do
    { 'inbox_id' => inbox.id, 'instance_id' => LeadAutomations::CraAcquisition::INSTANCE_ID,
      'ctwa_clid' => 'synthetic_click', 'tracking_click_verified' => true }
  end

  before do
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config)
    allow(WhatsappTracking::DeliveryMode).to receive(:capture_inbox_ids).and_return([inbox.id])
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('WHATSAPP_TRACKING_CRA_DEDUP_SECRET').and_return('synthetic-dedup-secret')
  end

  it 'captures real inbox message creation only for eligible input and omits private message data' do
    publish('message_received', 'LeadSubmitted')
    message = { inbox: inbox, conversation: conversation, content: 'synthetic private case', message_type: 'incoming',
                content_attributes: { lead_acquisition: signal } }
    Message.create!(**message, source_id: 'private', private: true)
    Message.create!(**message, source_id: 'imported', source: 'imported')
    Message.create!(**message, source_id: 'failed', status: 'failed')
    Message.create!(**message, source_id: 'fallback', content_attributes: { lead_acquisition: signal.except('tracking_click_verified') })
    expect(WhatsappTrackingDelivery.count).to eq(0)

    Message.create!(**message, source_id: 'first')
    Message.create!(**message, source_id: 'second')
    row = WhatsappTrackingDelivery.sole
    expect(row).to have_attributes(mode: 'observation', status: 'observed')
    expect(row.event).to include('event_name' => 'LeadSubmitted')
    expect(row.event.to_json).not_to include('synthetic private case', 'synthetic_click', '15550000002')
    expect(row.claim).to be_nil
  end

  it 'evaluates sent messages only when a provider ID is attached' do
    publish('message_sent', 'LeadSubmitted')
    LeadAcquisitionScopeEvent.create!(scope_key: 'client:cra', contact_id: contact.id, source: 'ctwa',
                                      source_key: 'synthetic-acquisition', signal: signal, occurred_at: Time.current,
                                      received_at: Time.current)
    message = Message.create!(inbox: inbox, conversation: conversation, message_type: 'outgoing', content: 'Synthetic outgoing')
    expect(WhatsappTrackingDelivery.count).to eq(0)
    message.update!(source_id: 'provider-confirmed')
    expect(WhatsappTrackingDelivery.sole.status).to eq('observed')
  end

  it 'captures a qualified stage transition once per contact and evaluates the previous stage' do
    user = User.create!(email: 'tracking-stage@example.com', name: 'Stage tester')
    pipeline = Pipeline.create!(name: 'Tracking pipeline', created_by: user)
    initial = pipeline.pipeline_stages.create!(name: 'Entrada', position: 1)
    qualified = pipeline.pipeline_stages.create!(name: 'Pré-Qualificado', position: 2)
    inbound = Message.create!(inbox: inbox, conversation: conversation, message_type: 'incoming', source_id: 'stage-acquisition',
                              content: 'Synthetic acquisition', content_attributes: { lead_acquisition: signal })
    LeadAcquisitionScopeEvent.create!(scope_key: 'client:cra', contact_id: contact.id, source: 'ctwa',
                                      source_key: 'synthetic-stage-acquisition', message_id: inbound.id, signal: signal,
                                      occurred_at: Time.current, received_at: Time.current)
    publish('stage_entered', 'QualifiedLead', filters: { stage_id: qualified.id, from_stage_id: initial.id })
    item = PipelineItem.create!(pipeline: pipeline, pipeline_stage: initial, conversation: conversation)
    expect(WhatsappTrackingDelivery.count).to eq(0)

    item.update!(pipeline_stage: qualified)
    item.update!(pipeline_stage: initial)
    item.update!(pipeline_stage: qualified)
    expect(WhatsappTrackingDelivery.sole.event).to include('event_name' => 'QualifiedLead')
  end

  it 'reconciles a provider message that arrives before the site click and stops processing revoked visitors' do
    visitor_id = 'a' * 48
    site_target = WhatsappTrackingDestination.create!(inbox: inbox, name: 'Website', dataset_id: WhatsappTracking::CraConversion::WEBSITE_DATASET,
                                                      credential_ref: 'WHATSAPP_TRACKING_META_TEST_TOKEN')
    publish('message_received', 'Lead', filters: { origin: 'website' }, target: site_target)
    attribution = signal.except('ctwa_clid', 'tracking_click_verified').merge('visitor_id' => visitor_id)
    message = { inbox: inbox, conversation: conversation, content: 'synthetic message', message_type: 'incoming',
                content_attributes: { lead_acquisition: attribution } }
    Message.create!(**message, source_id: 'before-site-click')
    candidate = CraTrackingCandidate.sole
    candidate.reconcile!
    expect(candidate.reload.status).to eq('pending')
    expect(WhatsappTrackingDelivery.count).to eq(0)

    intake = WhatsappTracking::CraSiteIntake.new(secret: 'synthetic-dedup-secret')
    intake.call({
                  'kind' => 'site_batch', 'visitor_id' => visitor_id,
                  'consent' => { 'at' => (Time.current.to_f * 1000).to_i, 'ads' => true, 'version' => 'synthetic' },
                  'first_touch' => {}, 'last_touch' => {},
                  'events' => [{ 'event_id' => SecureRandom.uuid, 'type' => 'whatsapp_click', 'path' => '/',
                                 'occurred_at' => Time.current.iso8601 }]
                }, rule: nil)
    candidate.reconcile!
    expect(candidate.reload.status).to eq('observed')
    expect(WhatsappTrackingDelivery.sole.event).to include('event_name' => 'Lead', 'action_source' => 'website')
    expect(WhatsappTrackingDelivery.sole.event).not_to have_key('user_data')

    intake.call({ 'kind' => 'revoke', 'visitor_id' => visitor_id, 'revoked_at' => Time.current.iso8601 }, rule: nil)
    Message.create!(**message, source_id: 'after-revocation')
    expect(CraTrackingCandidate.count).to eq(1)
  end

  it 'uses the legacy chat route for verified ad referrals after resolving the CRA ad account' do
    site_target = WhatsappTrackingDestination.create!(inbox: inbox, name: 'Chat dataset', dataset_id: WhatsappTracking::CraConversion::WEBSITE_DATASET,
                                                      credential_ref: 'WHATSAPP_TRACKING_META_TEST_TOKEN')
    publish('message_received', 'Lead', filters: { origin: 'chat' }, target: site_target)
    referral = signal.except('ctwa_clid', 'tracking_click_verified').merge('source_id' => '456', 'tracking_ad_referral' => true)
    Message.create!(inbox: inbox, conversation: conversation, message_type: 'incoming', source_id: 'ad-only',
                    content_attributes: { lead_acquisition: referral }, content: 'Synthetic ad referral')
    candidate = CraTrackingCandidate.sole
    expect(candidate).to have_attributes(visitor_key: nil, ad_id: '456')
    expect(WhatsappTrackingDelivery.count).to eq(0)
    CraTrackingAd.sole.update!(status: 'resolved')
    candidate.reconcile!

    expect(WhatsappTrackingDelivery.sole.event).to include('event_name' => 'Lead', 'action_source' => 'chat')
  end

  def publish(trigger, event_name, filters: {}, target: destination)
    rule = WhatsappTrackingRule.create!(inbox: inbox, name: trigger, draft: {
      trigger: trigger, event_name: event_name, mode: 'test', frequency: 'contact',
      destination_id: target.id, filters: { origin: 'ctwa' }.merge(filters)
    })
    rule.publish!
  end
end
