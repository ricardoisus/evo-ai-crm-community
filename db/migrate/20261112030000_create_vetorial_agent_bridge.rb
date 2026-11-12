class CreateVetorialAgentBridge < ActiveRecord::Migration[7.1]
  def change
    create_table :vetorial_agent_states, id: :uuid do |t|
      t.references :conversation, type: :uuid, null: false, index: { unique: true }, foreign_key: true
      t.bigint :version, null: false, default: 0
      t.boolean :paused, null: false, default: false
      t.string :reason
      t.jsonb :fields, null: false, default: {}
      t.jsonb :field_values, null: false, default: {}
      t.timestamps
    end
    create_table :vetorial_agent_events, id: :uuid do |t|
      t.references :conversation, type: :uuid, null: false, foreign_key: true
      t.jsonb :payload, null: false, default: {}
      t.datetime :delivered_at
      t.timestamps
    end
    add_index :vetorial_agent_events, :created_at, where: 'delivered_at IS NULL', name: 'vetorial_events_pending'
    create_table :vetorial_agent_commands, id: :uuid do |t|
      t.references :conversation, type: :uuid, null: false, foreign_key: true
      t.string :key, null: false
      t.string :kind, null: false
      t.string :status, null: false, default: 'pending'
      t.jsonb :payload, null: false, default: {}
      t.jsonb :result, null: false, default: {}
      t.timestamps
    end
    add_index :vetorial_agent_commands, :key, unique: true
  end
end
