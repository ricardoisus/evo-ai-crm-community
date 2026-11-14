class CreateLeadAutomations < ActiveRecord::Migration[7.1]
  def change
    create_table :lead_automation_rules, id: :uuid do |t|
      t.string :name, limit: 120, null: false
      t.boolean :active, default: false, null: false
      t.datetime :activated_at
      t.integer :revision, default: 1, null: false
      t.jsonb :conditions, null: false, default: {}
      t.uuid :pipeline_id, null: false
      t.uuid :pipeline_stage_id, null: false
      t.uuid :owner_id
      t.jsonb :label_ids, null: false, default: []
      t.string :title_template, limit: 160, null: false, default: 'Novo lead · {{contact_name}}'
      t.string :intake_token_digest, limit: 64
      t.uuid :created_by_id
      t.datetime :deleted_at
      t.timestamps
    end
    add_index :lead_automation_rules, [:active, :deleted_at]
    add_index :lead_automation_rules, :pipeline_id
    create_table :lead_automation_events, id: :uuid do |t|
      t.uuid :contact_id, null: false
      t.uuid :conversation_id
      t.uuid :message_id
      t.string :source_key, limit: 200, null: false
      t.string :source, limit: 20, null: false
      t.datetime :occurred_at, null: false
      t.datetime :received_at, null: false
      t.jsonb :signal, null: false, default: {}
      t.string :status, limit: 20, null: false, default: 'pending'
      t.integer :attempts, null: false, default: 0
      t.datetime :processed_at
      t.string :error_code, limit: 80
      t.timestamps
    end
    add_index :lead_automation_events, :source_key, unique: true
    add_index :lead_automation_events, :contact_id, unique: true
    add_index :lead_automation_events, [:status, :received_at]
    create_table :lead_automation_runs, id: :uuid do |t|
      [:rule_id, :event_id, :contact_id].each { |key| t.uuid key, null: false }
      t.uuid :conversation_id
      t.uuid :deal_id
      t.integer :rule_revision, null: false
      t.string :status, limit: 20, null: false
      t.string :reason_code, limit: 80
      t.string :source, limit: 20, null: false
      t.integer :attempts, null: false, default: 1
      t.datetime :executed_at, null: false
      t.timestamps
    end
    add_index :lead_automation_runs, [:rule_id, :contact_id], unique: true
    add_index :lead_automation_runs, [:rule_id, :executed_at]
  end
end
