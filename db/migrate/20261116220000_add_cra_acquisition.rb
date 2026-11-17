class AddCraAcquisition < ActiveRecord::Migration[7.1]
  def change
    add_column :lead_automation_rules, :acquisition_scope_key, :string, limit: 60
    add_column :lead_automation_rules, :enrichment_token_digest, :string, limit: 64
    add_column :lead_automation_runs, :scope_event_id, :uuid
    change_column_null :lead_automation_runs, :event_id, true
    create_table :lead_acquisition_scope_events, id: :uuid do |t|
      t.string :scope_key, limit: 60, null: false
      t.uuid :contact_id, null: false
      t.uuid :conversation_id
      t.uuid :message_id
      t.string :source_key, limit: 200, null: false
      t.string :source, limit: 20, null: false
      t.jsonb :signal, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.datetime :received_at, null: false
      t.string :status, limit: 20, null: false, default: 'pending'
      t.integer :attempts, null: false, default: 0
      t.string :error_code, limit: 80
      t.timestamps
    end
    add_index :lead_acquisition_scope_events, [:scope_key, :contact_id], unique: true, name: 'idx_cra_scope_contact'
    add_index :lead_acquisition_scope_events, [:scope_key, :source_key], unique: true, name: 'idx_cra_scope_source'
    add_index :lead_acquisition_scope_events, [:status, :received_at], name: 'idx_cra_scope_pending'
    add_index :lead_acquisition_scope_events, :contact_id
    create_table :lead_acquisition_enrichments, id: :uuid do |t|
      t.uuid :scope_event_id
      t.uuid :rule_id, null: false
      t.uuid :acquisition_id, null: false
      t.bigint :revision, null: false
      t.string :digest, limit: 64, null: false
      t.jsonb :payload, null: false, default: {}
      t.string :status, limit: 20, null: false, default: 'pending'
      t.string :error_code, limit: 80
      t.timestamps
    end
    add_index :lead_acquisition_enrichments, [:rule_id, :acquisition_id, :revision], unique: true, name: 'idx_cra_enrichment_revision'
    add_index :lead_acquisition_enrichments, [:status, :created_at], name: 'idx_cra_enrichment_pending'
    add_index :lead_acquisition_enrichments, :scope_event_id
  end
end
