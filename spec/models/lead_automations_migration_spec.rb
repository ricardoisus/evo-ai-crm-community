require 'rails_helper'
require Rails.root.join('db/migrate/20261114040000_create_lead_automations')

RSpec.describe CreateLeadAutomations do
  it 'rolls down only the three additive tables and recreates their unique indexes in the synthetic database' do
    connection = ActiveRecord::Base.connection
    expect(Rails.env).to eq('test')
    expect(connection.pool.db_config.database).to match(/test/)
    migration = described_class.new
    migration.migrate(:down)
    %w[lead_automation_rules lead_automation_events lead_automation_runs].each { |table| expect(connection.table_exists?(table)).to be(false) }
    %w[contacts conversations pipeline_items pipelines].each { |table| expect(connection.table_exists?(table)).to be(true) }
    migration.migrate(:up)
    expect(connection.indexes(:lead_automation_events).any? { |i| i.unique && i.columns == ['contact_id'] }).to be(true)
    expect(connection.indexes(:lead_automation_runs).any? { |i| i.unique && i.columns == %w[rule_id contact_id] }).to be(true)
  ensure
    connection&.schema_cache&.clear!
  end
end
