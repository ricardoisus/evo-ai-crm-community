require 'rails_helper'
RSpec.describe 'CRA concurrent first touch' do
  self.use_transactional_tests = false
  it 'converges form and WhatsApp on two connections and processes exactly one scoped deal' do
    ActiveJob::Base.queue_adapter = :test
    stub_const('ENV', ENV.to_h.merge('CRA_ACQUISITION_ENABLED' => 'true'))
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config)
    user = User.create!(name: 'Synthetic CRA concurrency', email: "cra-lock-#{SecureRandom.hex(5)}@example.com")
    pipeline = Pipeline.create!(name: 'CRA concurrency', created_by: user)
    stage = pipeline.pipeline_stages.create!(name: 'New', position: 1)
    channel = Channel::Whatsapp.create!(provider: 'evolution', phone_number: '+15550000991', provider_config: { instance_name: 'CR Advogados', attached_instance_id: LeadAutomations::CraAcquisition::INSTANCE_ID })
    box = Inbox.create!(name: 'CRA concurrency', channel: channel)
    rule = LeadAutomationRule.create!(name: 'CRA concurrency', active: true, acquisition_scope_key: 'client:cra', pipeline_id: pipeline.id, pipeline_stage_id: stage.id, conditions: { version: 1, operator: 'any', ctwa: { enabled: true, inbox_id: box.id, instance_name: 'CR Advogados' }, domain: { enabled: true, host: 'carolineribeiroadvogados.com' } })
    contact = Contact.new(name: 'Human synthetic', phone_number: '+15550000992'); contact.passive_observation = true; contact.skip_default_pipeline_assignment = true; contact.save!
    stamp = Time.current
    calls = [
      -> { LeadAutomations::CaptureScopedEvent.call(contact: Contact.find(contact.id), source: 'ctwa', source_key: "evolution:#{box.id}:synthetic", occurred_at: stamp, received_at: stamp, signal: { 'inbox_id' => box.id, 'instance_name' => 'CR Advogados', 'ctwa_clid' => 'synthetic' }) },
      -> { LeadAutomations::ScopedIntake.call(rule, { 'event_id' => SecureRandom.uuid, 'page_url' => 'https://carolineribeiroadvogados.com/', 'contact' => { 'name' => 'Form synthetic', 'phone_number' => contact.phone_number }, 'contact_consent' => { 'accepted' => true, 'version' => 'v1', 'at' => stamp.iso8601 } }) }
    ]
    pids = concurrent(calls)
    expect(pids.uniq.size).to eq(2)
    event = LeadAcquisitionScopeEvent.where(contact_id: contact.id).sole
    concurrent(2.times.map { -> { LeadAutomations::ProcessScopedEvent.call(event.id) } })
    expect(rule.runs.sole.status).to eq('created')
    expect(pipeline.pipeline_items.count).to eq(1)
    expect(LeadAutomationEvent.where(contact_id: contact.id).count).to eq(0)
    expect(contact.reload.name).to eq('Human synthetic')
  ensure
    if pipeline
      ids = PipelineItem.where(pipeline_id: pipeline.id).pluck(:id)
      [DealHistoryEvent, DealContact, DealConversation, StageMovement].each { |model| model.where(pipeline_item_id: ids).delete_all }
      PipelineItem.where(id: ids).delete_all
      LeadAutomationRun.where(rule_id: rule&.id).delete_all
      LeadAcquisitionScopeEvent.where(contact_id: contact&.id).delete_all
      LeadAutomationRule.where(id: rule&.id).delete_all
      PipelineStage.where(pipeline_id: pipeline.id).delete_all
      Pipeline.where(id: pipeline.id).delete_all
    end
    Contact.where(id: contact&.id).delete_all
    Inbox.where(id: box&.id).delete_all
    Channel::Whatsapp.where(id: channel&.id).delete_all
    User.where(id: user&.id).delete_all
  end

  def concurrent(calls)
    ready = Queue.new; start = Queue.new; pids = Queue.new
    threads = calls.map do |call|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |db|
          pids << db.select_value('SELECT pg_backend_pid()')
          ready << true; start.pop; call.call
        end
      end
    end
    calls.size.times { ready.pop }; calls.size.times { start << true }
    threads.each(&:value)
    calls.size.times.map { pids.pop }
  ensure
    threads&.each { |thread| thread.join(5) }
  end
end
