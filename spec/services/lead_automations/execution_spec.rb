require 'rails_helper'
require 'webmock/rspec'
WebMock.disable_net_connect!(allow_localhost: true)

RSpec.describe 'Lead acquisition execution' do
  include ActiveJob::TestHelper
  let(:user) { User.create!(name: 'Synthetic', email: "execution-#{SecureRandom.hex(5)}@example.com") }
  let(:pipeline) { Pipeline.create!(name: 'Synthetic', created_by: user) }
  let(:stage) { pipeline.pipeline_stages.first || pipeline.pipeline_stages.create!(name: "New", position: 1) }
  let(:channel) { Channel::Whatsapp.create!(provider: 'evolution', phone_number: '+15550000001', provider_config: { instance_name: 'synthetic', existing_instance_attached: true, attachment_state: 'active', attachment_started_at: 1 }) }
  let(:box) { Inbox.create!(name: 'Synthetic', channel: channel, enable_auto_assignment: false) }
  let(:rule) { LeadAutomationRule.create!(name: 'Rule', active: true, pipeline_id: pipeline.id, pipeline_stage_id: stage.id, conditions: { version: 1, operator: 'any', ctwa: { enabled: true, inbox_id: box.id, instance_name: 'synthetic' }, domain: { enabled: true, host: 'co.example.com' } }) }

  def payload(click: 'synthetic-click', id: SecureRandom.hex(5))
    { instance: 'synthetic', event: 'messages.upsert', lead_automation_received_at: Time.current.iso8601(6), data: {
      key: { id: id, fromMe: false, remoteJid: '15550000002@s.whatsapp.net' },
      messageTimestamp: Time.current.to_f, message: { conversation: 'Synthetic' },
      contextInfo: { externalAdReply: { ctwaClid: click, sourceType: 'ad', sourceUrl: 'https://fb.me/synthetic' } }
    } }.with_indifferent_access
  end

  def ingest(p = payload)
    Whatsapp::AttachedEvolutionMessageService.new(inbox: box, params: p).perform
    LeadAutomationEvent.last
  end

  def process(event)
    LeadAutomations::ProcessEvent.call(event.id)
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config)
    rule
  end

  it 'creates from real-format CTWA and keeps history and associations without dispatching any action' do
    expect(Whatsapp::SendOnWhatsappService).not_to receive(:new)
    expect_any_instance_of(PipelineItem).not_to receive(:publish)
    event = ingest
    clear_enqueued_jobs
    expect(Rails.configuration.dispatcher).not_to receive(:dispatch)
    expect(event.source).to eq('ctwa')
    expect(box.messages.sole.content_attributes.dig('lead_acquisition', 'ctwa_clid')).to eq('synthetic-click')
    process(event)
    deal = PipelineItem.where(pipeline: pipeline).sole
    expect(deal.contact_id).to eq(event.contact_id)
    expect(deal.primary_contact_id).to eq(event.contact_id)
    expect(deal.deal_contacts.count).to eq(1)
    expect(deal.deal_conversations.count).to eq(1)
    expect(deal.stage_movements.count).to eq(1)
    expect(deal.deal_history_events.where(action: 'deal_created').count).to eq(1)
    expect(rule.runs.sole.status).to eq('created')
    expect(enqueued_jobs.map { |j| j[:job].name }.grep(/SendReply|BotRuntime|Read|Agent/)).to be_empty
    expect(event.reload.status).to eq('processed')
  end

  it 'does not pass a fabricated page URL for CTWA matching' do
    event = ingest
    expect(LeadAutomations::Matcher).to receive(:call).with(rule, hash_excluding('page_url')).and_call_original
    process(event)
    expect(rule.runs.sole.status).to eq('created')
  end

  it 'rejects unused signal metadata' do
    event = ingest
    %w[source_id source_url source_type].each do |key|
      event.signal = event.signal.merge(key => 'unused')
      expect(event).not_to be_valid
      expect(event.errors[:signal]).to include('invalid_signal')
      event.reload
    end
  end

  it 'captures nested image CTWA on the real attached ingress without retaining thumbnails or full payload' do
    p = payload
    ad = p[:data].delete(:contextInfo)
    ad[:externalAdReply][:thumbnail] = 'synthetic-private-thumbnail'
    p[:data][:message] = { imageMessage: { caption: 'Synthetic image', mimetype: 'image/png', contextInfo: ad } }
    event = ingest(p)
    process(event)
    expect(rule.runs.sole.status).to eq('created')
    expect(event.signal.keys.sort).to eq(%w[ctwa_clid inbox_id instance_name])
    expect(box.messages.sole.content_attributes['lead_acquisition'].to_json).not_to include('thumbnail')
  end

  it 'preserves first touch without CTWA even when a later message has an ad' do
    first = ingest(payload(click: nil))
    process(first)
    second = ingest(payload)
    expect(second.id).to eq(first.id)
    expect(first.reload.source).to eq('none')
    process(second)
    expect(pipeline.pipeline_items.count).to eq(0)
    expect(rule.runs.sole.reason_code).to eq('no_match')
  end

  it 'does not duplicate on replay, retry or a later entry after closing the deal' do
    p = payload
    event = ingest(p)
    2.times { process(event) }
    ingest(p)
    expect(pipeline.pipeline_items.count).to eq(1)
    pipeline.pipeline_items.sole.update_column(:completed_at, Time.current)
    event.update!(status: 'failed')
    process(event)
    expect(pipeline.pipeline_items.count).to eq(1)
    expect(rule.runs.count).to eq(1)
  end

  it 'reuses open deals linked through DealContact and does not move them' do
    event = ingest
    deal = PipelineItem.new(pipeline: pipeline, pipeline_stage: stage, title: 'Existing', value: 0)
    deal.lead_automation_context = true
    deal.save!
    deal.deal_contacts.create!(contact_id: event.contact_id)
    process(event)
    expect(pipeline.pipeline_items.count).to eq(1)
    expect(rule.runs.sole.status).to eq('existing')
    expect(deal.reload.title).to eq('Existing')
  end

  %w[primary_contact legacy_conversation deal_conversation].each do |link|
    it "reuses an open deal linked by #{link}" do
      event = ingest
      deal = PipelineItem.new(pipeline: pipeline, pipeline_stage: stage, title: 'Linked synthetic', value: 0)
      deal.primary_contact_id = event.contact_id if link == 'primary_contact'
      deal.conversation_id = event.conversation_id if link == 'legacy_conversation'
      deal.lead_automation_context = true
      deal.save!
      deal.deal_conversations.create!(conversation_id: event.conversation_id) if link == 'deal_conversation'
      process(event)
      expect(pipeline.pipeline_items.count).to eq(1)
      expect(rule.runs.sole.status).to eq('existing')
    end
  end

  it 'applies optional owner and labels only to the new deal' do
    label = Label.create!(title: "synthetic-#{SecureRandom.hex(5)}", color: '#123456')
    rule.update!(owner_id: user.id, label_ids: [label.id])
    event = ingest
    process(event)
    deal = pipeline.pipeline_items.sole
    expect(deal.owner_id).to eq(user.id)
    expect(deal.label_list.to_a).to eq([label.title])
    expect(Contact.find(event.contact_id).label_list.to_a).to be_empty
    expect(Conversation.find(event.conversation_id).label_list.to_a).to be_empty
  end

  it 'does not backfill a queued event after reactivation' do
    event = ingest
    rule.update!(active: false)
    rule.update!(active: true)
    process(event)
    expect(rule.runs.sole.status).to eq('skipped')
    expect(pipeline.pipeline_items.count).to eq(0)
  end

  it 'does not act when disabled while queued' do
    event = ingest
    rule.update!(active: false)
    process(event)
    expect(rule.runs.sole.reason_code).to eq('inactive')
    expect(pipeline.pipeline_items.count).to eq(0)
  end

  it 'revalidates the edited rule rather than its queued snapshot' do
    event = ingest
    rule.update!(conditions: { version: 1, operator: 'any', domain: { enabled: true, host: 'elsewhere.example.com' } })
    process(event)
    expect(rule.runs.sole.rule_revision).to eq(rule.revision)
    expect(rule.runs.sole.reason_code).to eq('no_match')
  end

  %w[pipeline stage owner label].each do |destination|
    it "logs removed #{destination} without raising or creating a deal" do
      event = ingest
      field = { 'pipeline' => :pipeline_id, 'stage' => :pipeline_stage_id, 'owner' => :owner_id, 'label' => :label_ids }.fetch(destination)
      rule.update_column(field, destination == 'label' ? [SecureRandom.uuid] : SecureRandom.uuid)
      expect { process(event) }.not_to raise_error
      expect(rule.runs.sole.status).to eq('error')
      expect(rule.runs.sole.reason_code).to eq('destination_missing')
      expect(pipeline.pipeline_items.count).to eq(0)
    end
  end

  %w[contact conversation event received].each do |old|
    it "rejects old #{old}" do
      event = ingest
      case old
      when 'contact' then Contact.find(event.contact_id).update_column(:created_at, 1.day.ago)
      when 'conversation' then Conversation.find(event.conversation_id).update_column(:created_at, 1.day.ago)
      when 'event' then event.update!(occurred_at: 1.day.ago)
      when 'received' then event.update!(received_at: 1.day.ago)
      end
      process(event)
      expect(rule.runs.sole.status).to eq('skipped')
      expect(pipeline.pipeline_items.count).to eq(0)
    end
  end

  it 'rolls back failed deal creation and retries the same execution log' do
    event = ingest
    allow_any_instance_of(PipelineItem).to receive(:record_creation_history).and_raise(StandardError, 'private text')
    process(event)
    expect(rule.runs.sole.reason_code).to eq('execution_failed')
    expect(pipeline.pipeline_items.count).to eq(0)
    allow_any_instance_of(PipelineItem).to receive(:record_creation_history).and_call_original
    process(event)
    expect(rule.runs.sole.status).to eq('created')
    expect(rule.runs.sole.attempts).to eq(2)
    expect(pipeline.pipeline_items.count).to eq(1)
  end

  it 'keeps ingress durable if enqueue fails and the sweeper recovers' do
    allow(LeadAutomations::ProcessEventJob).to receive(:perform_later).and_raise(Redis::CannotConnectError)
    event = ingest
    expect(box.messages.count).to eq(1)
    expect(event.status).to eq('pending')
    expect { event.enqueue_processing }.not_to raise_error
    allow(LeadAutomations::ProcessEventJob).to receive(:perform_later).and_call_original
    expect { LeadAutomations::SweepJob.new.perform }.to have_enqueued_job(LeadAutomations::ProcessEventJob).with(event.id)
    process(event)
    expect(rule.runs.sole.status).to eq('created')
  end

  it 'does not poison message persistence if capture fails' do
    allow(LeadAutomationEvent).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)
    expect { ingest }.not_to raise_error
    expect(box.messages.count).to eq(1)
  end

  it 'extracts the signal on the normal Evolution persistence path too' do
    event_payload = payload
    contact = Contact.new(name: 'Synthetic', phone_number: '+15550000002'); contact.passive_observation = true; contact.save!
    ci = ContactInbox.create!(contact: contact, inbox: box, source_id: '15550000002')
    conversation = Conversation.create!(contact: contact, inbox: box, contact_inbox: ci, source: :imported)
    message = conversation.messages.new(content: 'Synthetic', inbox: box, sender: contact, message_type: :incoming, source: :imported)
    service = Whatsapp::IncomingMessageEvolutionService.new(inbox: box, params: event_payload)
    service.instance_variable_set(:@message, message)
    service.instance_variable_set(:@conversation, conversation)
    service.instance_variable_set(:@raw_message, event_payload[:data])
    allow(channel).to receive(:received_messages)
    service.send(:save_message_and_notify)
    expect(LeadAutomationEvent.sole.source).to eq('ctwa')
  end
end
