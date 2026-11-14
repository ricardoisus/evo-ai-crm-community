class CreateVetorialAgentConfiguration < ActiveRecord::Migration[7.1]
  def change
    create_table :vetorial_agent_deployments, id: :uuid do |t|
      t.references :agent_bot, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.string :slug, null: false
      t.uuid :active_revision_id
      t.integer :policy_epoch, null: false, default: 1
      t.integer :lock_version, null: false, default: 0
      t.string :control_source, null: false, default: 'legacy_transition'
      t.boolean :guard_ready, null: false, default: false
      t.timestamps
    end
    add_index :vetorial_agent_deployments, :slug, unique: true
    create_table :vetorial_agent_profiles, id: :uuid do |t|
      t.references :deployment, type: :uuid, null: false, foreign_key: { to_table: :vetorial_agent_deployments }
      t.string :role, null: false
      t.string :name, null: false
      t.string :description
      t.timestamps
    end
    add_index :vetorial_agent_profiles, [:deployment_id, :role], unique: true
    create_table :vetorial_agent_revisions, id: :uuid do |t|
      t.references :deployment, type: :uuid, null: false, foreign_key: { to_table: :vetorial_agent_deployments }
      t.integer :number, null: false
      t.jsonb :payload, null: false
      t.string :sha256, null: false
      t.string :status, null: false, default: 'draft'
      t.uuid :created_by_id
      t.uuid :restored_from_id
      t.datetime :published_at
      t.timestamps
    end
    add_index :vetorial_agent_revisions, [:deployment_id, :number], unique: true
    add_foreign_key :vetorial_agent_deployments, :vetorial_agent_revisions, column: :active_revision_id
    create_table :vetorial_agent_audits, id: :uuid do |t|
      t.references :deployment, type: :uuid, null: false, foreign_key: { to_table: :vetorial_agent_deployments }
      t.string :action, null: false
      t.string :idempotency_key, null: false
      t.uuid :actor_id
      t.string :request_sha256, null: false
      t.jsonb :response, null: false, default: {}
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :vetorial_agent_audits, [:deployment_id, :action, :idempotency_key], unique: true, name: 'vetorial_audit_idempotency'
    create_table :vetorial_agent_runtime_statuses, id: :uuid do |t|
      t.references :deployment, type: :uuid, null: false, foreign_key: { to_table: :vetorial_agent_deployments }
      t.string :instance_id, null: false
      t.uuid :applied_revision_id
      t.string :sha256
      t.datetime :heartbeat_at
      t.jsonb :integrations, null: false, default: {}
      t.timestamps
    end
    add_index :vetorial_agent_runtime_statuses, [:deployment_id, :instance_id], unique: true, name: 'vetorial_runtime_instance'
  end
end
