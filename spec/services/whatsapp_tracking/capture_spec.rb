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
    LeadAcquisitionScopeEvent.create!(scope_key: 'client:cra', contact_id: contact.id, source: 'ctwa',
                                      source_key: 'synthetic-stage-acquisition', signal: signal, occurred_at: Time.current,
                                      received_at: Time.current)
    publish('stage_entered', 'QualifiedLead', filters: { stage_id: qualified.id, from_stage_id: initial.id })
    item = PipelineItem.create!(pipeline: pipeline, pipeline_stage: initial, conversation: conversation)
    expect(WhatsappTrackingDelivery.count).to eq(0)

    item.update!(pipeline_stage: qualified)
    item.update!(pipeline_stage: initial)
    item.update!(pipeline_stage: qualified)
    expect(WhatsappTrackingDelivery.sole.event).to include('event_name' => 'QualifiedLead')
  end

  def publish(trigger, event_name, filters: {})
    rule = WhatsappTrackingRule.create!(inbox: inbox, name: trigger, draft: {
      trigger: trigger, event_name: event_name, mode: 'test', frequency: 'contact',
      destination_id: destination.id, filters: filters.merge(origin: 'ctwa')
    })
    rule.publish!
  end
end
