require 'rails_helper'

RSpec.describe 'Lead automation PostgreSQL concurrency' do
  self.use_transactional_tests = false

  it 'serializes two jobs and two rules on distinct database connections and commits one deal' do
    ActiveJob::Base.queue_adapter = :test
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config)
    channel = Channel::Whatsapp.create!(provider: 'evolution', phone_number: '+15550000078', provider_config: { instance_name: 'synthetic-locks' })
    box = Inbox.create!(name: 'Synthetic locks', channel: channel)
    user = User.create!(name: 'Synthetic concurrency', email: "locks-#{SecureRandom.hex(6)}@example.com")
    pipeline = Pipeline.create!(name: 'Synthetic concurrency', created_by: user)
    stage = pipeline.pipeline_stages.first || pipeline.pipeline_stages.create!(name: 'New', position: 1)
    rules = 2.times.map do
      LeadAutomationRule.create!(name: 'Synthetic concurrent', active: true, pipeline_id: pipeline.id, pipeline_stage_id: stage.id,
                                 conditions: { version: 1, operator: 'any', ctwa: { enabled: true, inbox_id: box.id, instance_name: 'synthetic-locks' } })
    end
    contact = Contact.new(name: 'Synthetic concurrency', phone_number: '+15550000077')
    contact.passive_observation = true
    contact.save!
    # CTWA-style dispatch evaluates all rules; domain events target just their rule.
    event = LeadAutomationEvent.create!(contact_id: contact.id, source_key: "synthetic:#{SecureRandom.uuid}", source: 'ctwa',
                                        occurred_at: Time.current, received_at: Time.current, signal: { inbox_id: box.id, instance_name: 'synthetic-locks', ctwa_clid: 'synthetic-locks' })
    ready = Queue.new
    start = Queue.new
    pids = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |db|
          pids << db.select_value('SELECT pg_backend_pid()')
          ready << true
          start.pop
          LeadAutomations::ProcessEvent.call(event.id)
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each(&:value)
    expect(2.times.map { pids.pop }.uniq.size).to eq(2)
    expect(pipeline.pipeline_items.count).to eq(1)
    expect(LeadAutomationRun.where(rule_id: rules.map(&:id)).pluck(:status).sort).to eq(%w[created existing])
    expect(event.reload.status).to eq('processed')
    # Re-entry after commit remains idempotent.
    LeadAutomations::ProcessEvent.call(event.id)
    expect(pipeline.pipeline_items.count).to eq(1)
  ensure
    threads&.each { |t| t.join(5) }
    if pipeline
      deals = PipelineItem.where(pipeline_id: pipeline.id).pluck(:id)
      DealHistoryEvent.where(pipeline_item_id: deals).delete_all
      DealContact.where(pipeline_item_id: deals).delete_all
      DealConversation.where(pipeline_item_id: deals).delete_all
      StageMovement.where(pipeline_item_id: deals).delete_all
      PipelineItem.where(id: deals).delete_all
      LeadAutomationRun.where(rule_id: Array(rules).map(&:id)).delete_all
      LeadAutomationEvent.where(id: event&.id).delete_all
      LeadAutomationRule.where(id: Array(rules).map(&:id)).delete_all
      PipelineStage.where(pipeline_id: pipeline.id).delete_all
      PipelineMembership.where(pipeline_id: pipeline.id).delete_all if defined?(PipelineMembership)
      Pipeline.where(id: pipeline.id).delete_all
    end
    Contact.where(id: contact&.id).delete_all
    User.where(id: user&.id).delete_all
    Inbox.where(id: box&.id).delete_all
    Channel::Whatsapp.where(id: channel&.id).delete_all
  end
end
