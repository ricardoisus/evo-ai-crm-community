class CreateVetorialAgentTestSessions < ActiveRecord::Migration[7.1]
  def change
    create_table :vetorial_agent_test_sessions, id: :uuid do |t|
      t.references :profile, type: :uuid, null: false, foreign_key: { to_table: :vetorial_agent_profiles }
      t.references :owner, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.references :revision, type: :uuid, null: false, foreign_key: { to_table: :vetorial_agent_revisions }
      t.string :idempotency_key, null: false
      t.string :input_sha256, null: false
      t.string :sha256, null: false
      t.jsonb :plan, null: false, default: {}
      t.jsonb :messages, null: false, default: []
      t.string :state, null: false, default: 'pending'
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :vetorial_agent_test_sessions, [:profile_id, :owner_id, :idempotency_key], unique: true, name: 'vetorial_test_creation_key'
  end
end
