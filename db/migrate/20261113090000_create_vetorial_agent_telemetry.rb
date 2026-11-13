class CreateVetorialAgentTelemetry < ActiveRecord::Migration[7.1]
  def change
    create_table :vetorial_agent_telemetry_events, id: :uuid do |t|
      t.references :deployment, type: :uuid, null: false, foreign_key: { to_table: :vetorial_agent_deployments }
      t.uuid :event_id, null: false
      t.string :kind, null: false
      t.string :payload_sha256, null: false
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    add_index :vetorial_agent_telemetry_events, :event_id, unique: true

    create_table :vetorial_agent_executions, id: :uuid do |t|
      t.references :deployment, type: :uuid, null: false, foreign_key: { to_table: :vetorial_agent_deployments }
      t.uuid :execution_id, null: false
      t.uuid :conversation_id, null: false
      t.string :role, null: false
      t.string :source, null: false
      t.integer :revision, null: false
      t.integer :policy_epoch, null: false
      t.string :status, null: false
      t.bigint :latency_ms, null: false
      t.string :outcome, null: false
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    add_index :vetorial_agent_executions, [:deployment_id, :execution_id], unique: true, name: 'vetorial_execution_identity'
    add_index :vetorial_agent_executions, [:deployment_id, :source, :occurred_at], name: 'vetorial_execution_metrics'

    create_table :vetorial_agent_usages, id: :uuid do |t|
      t.references :deployment, type: :uuid, null: false, foreign_key: { to_table: :vetorial_agent_deployments }
      t.uuid :call_id, null: false
      t.uuid :execution_id, null: false
      t.string :source, null: false
      t.string :provider, null: false
      t.string :model, null: false
      t.bigint :input_tokens, null: false
      t.bigint :cached_tokens, null: false
      t.bigint :output_tokens, null: false
      t.bigint :reasoning_tokens, null: false
      t.bigint :cost_micro_usd
      t.string :usage_state, null: false
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    add_index :vetorial_agent_usages, [:deployment_id, :call_id], unique: true, name: 'vetorial_usage_identity'
    add_index :vetorial_agent_usages, [:deployment_id, :source, :occurred_at], name: 'vetorial_usage_metrics'

    add_column :vetorial_agent_runtime_statuses, :revision, :integer
    add_column :vetorial_agent_runtime_statuses, :policy_epoch, :integer
  end
end
