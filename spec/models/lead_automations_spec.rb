require 'rails_helper'
RSpec.describe LeadAutomationRule, type: :model do
  let(:user) { User.create!(name: 'Synthetic', email: "model-#{SecureRandom.hex(6)}@example.com") }
  let(:pipeline) { Pipeline.create!(name: 'Synthetic', created_by: user) }
  let(:stage) { pipeline.pipeline_stages.first || pipeline.pipeline_stages.create!(name: 'New', position: 1) }
  let(:rule) { described_class.new(name: 'Rule', pipeline_id: pipeline.id, pipeline_stage_id: stage.id, conditions: { version: 1, operator: 'any', domain: { enabled: true, host: 'co.example.com' } }) }

  it 'validates destinations, optional labels and owner, and templates' do
    expect(rule).to be_valid
    [:pipeline_id, :pipeline_stage_id, :owner_id].each do |field|
      original = rule[field]; rule[field] = SecureRandom.uuid
      expect(rule).not_to be_valid
      rule[field] = original
    end
    rule.label_ids = [SecureRandom.uuid]
    expect(rule).not_to be_valid
    rule.label_ids = []
    rule.title_template = '{{phone}}'
    expect(rule).not_to be_valid
  end

  it 'rejects unsupported sources, operators, domains and nonexistent CTWA boxes' do
    [{ version: 2 }, { operator: 'all' }, { domain: { enabled: false } },
     { domain: { enabled: true, host: 'https://co.example.com' } },
     { ctwa: { enabled: true, inbox_id: SecureRandom.uuid, instance_name: 'synthetic' } }, { unknown: true }].each do |change|
      original = rule.conditions.deep_dup
      rule.conditions = original.merge(change.deep_stringify_keys)
      expect(rule).not_to be_valid
      rule.conditions = original
    end
  end

  it 'matches only exact HTTPS hosts without credentials or alternative ports' do
    %w[https://co.example.com https://co.example.com/path https://CO.example.com:443/path].each { |url| expect(LeadAutomations::Matcher.domain_url?(url, 'co.example.com')).to be(true) }
    %w[http://co.example.com https://co.example.com.evil.test https://user@co.example.com https://co.example.com:444 invalid].each { |url| expect(LeadAutomations::Matcher.domain_url?(url, 'co.example.com')).to be(false) }
  end

  it 'rejects old contacts/events and inactive rules without mutation' do
    rule.save!; rule.update!(active: true)
    event = { source: 'domain', page_url: 'https://co.example.com', occurred_at: 1.day.ago.iso8601, contact_created_at: 1.day.ago.iso8601 }
    expect(LeadAutomations::Matcher.call(rule, event)[:reasons]).to include('old_contact', 'old_event')
    rule.update!(active: false)
    expect(LeadAutomations::Matcher.call(rule, event)[:reasons]).to include('inactive')
  end

  it 'enforces first touch and decision uniqueness in PostgreSQL' do
    rule.save!
    event = LeadAutomationEvent.create!(contact_id: SecureRandom.uuid, source_key: 'synthetic:1', source: 'none', occurred_at: Time.current, received_at: Time.current)
    expect { event.dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'matches CTWA only with selected box, instance and click id' do
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config)
    channel = Channel::Whatsapp.create!(provider: 'evolution', phone_number: '+15550000111', provider_config: { instance_name: 'synthetic' })
    box = Inbox.create!(name: 'Synthetic box', channel: channel)
    rule.conditions = { version: 1, operator: 'any', ctwa: { enabled: true, inbox_id: box.id, instance_name: 'synthetic' } }
    expect(rule).to be_valid
    rule.save!; rule.update!(active: true)
    event = { source: 'ctwa', inbox_id: box.id, instance_name: 'synthetic', ctwa_clid: 'synthetic-click', occurred_at: Time.current.iso8601(6), contact_created_at: Time.current.iso8601(6) }
    expect(LeadAutomations::Matcher.call(rule, event)[:matched]).to be(true)
    [:ctwa_clid, :inbox_id, :instance_name].each do |key|
      expect(LeadAutomations::Matcher.call(rule, event.merge(key => ''))[:matched]).to be(false)
    end
    rule.conditions['ctwa']['instance_name'] = 'other'
    expect(rule).not_to be_valid
  end

  it 'enforces decision uniqueness and preserves audit on soft deletion' do
    rule.save!
    event = LeadAutomationEvent.create!(contact_id: SecureRandom.uuid, source_key: 'synthetic:run', source: 'none', occurred_at: Time.current, received_at: Time.current)
    run = LeadAutomationRun.create!(rule: rule, event: event, contact_id: event.contact_id, rule_revision: rule.revision, status: 'skipped', reason_code: 'no_match', source: 'none', executed_at: Time.current)
    expect { LeadAutomationRun.transaction(requires_new: true) { run.dup.save!(validate: false) } }.to raise_error(ActiveRecord::RecordNotUnique)
    rule.update_columns(deleted_at: Time.current)
    expect(run.reload.rule_id).to eq(rule.id)
  end

  it 'validates event allowlist and execution status' do
    event = LeadAutomationEvent.new(contact_id: SecureRandom.uuid, source_key: 'synthetic', source: 'none', occurred_at: Time.current, received_at: Time.current)
    expect(event).to be_valid
    event.signal = { token: 'forbidden' }
    expect(event).not_to be_valid
    run = LeadAutomationRun.new(status: 'sending', source: 'none')
    expect(run).not_to be_valid
  end
end
