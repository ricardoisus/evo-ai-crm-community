# frozen_string_literal: true

class CreateCraTrackingSiteState < ActiveRecord::Migration[7.1]
  def change
    create_table :cra_tracking_site_visitors, id: :uuid do |t|
      t.string :visitor_key, null: false, limit: 64
      t.boolean :analytics, null: false, default: false
      t.boolean :ads, null: false, default: false
      t.string :consent_version, limit: 100
      t.datetime :consented_at
      t.datetime :revoked_at
      t.datetime :expires_at, null: false
      t.jsonb :first_touch, null: false, default: {}
      t.jsonb :last_touch, null: false, default: {}
      t.timestamps
    end
    add_index :cra_tracking_site_visitors, :visitor_key, unique: true

    create_table :cra_tracking_site_events, id: :uuid do |t|
      t.references :visitor, type: :uuid, null: false, index: false,
                   foreign_key: { to_table: :cra_tracking_site_visitors, on_delete: :cascade }
      t.uuid :event_id, null: false
      t.string :kind, null: false
      t.string :fingerprint, null: false, limit: 64
      t.string :path, limit: 500
      t.boolean :ads, null: false, default: false
      t.jsonb :last_touch, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    add_index :cra_tracking_site_events, :event_id, unique: true
    add_index :cra_tracking_site_events, [:visitor_id, :kind, :occurred_at], name: 'idx_cra_tracking_site_event_attribution'

    create_table :cra_tracking_candidates, id: :uuid do |t|
      t.references :message, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :visitor_key, null: false, limit: 64
      t.datetime :occurred_at, null: false
      t.datetime :next_check_at, null: false
      t.string :status, default: 'pending', null: false
      t.timestamps
    end
    add_index :cra_tracking_candidates, :next_check_at, where: "status = 'pending'", name: 'idx_cra_tracking_candidates_ready'
    add_index :cra_tracking_candidates, :visitor_key, where: "status = 'pending'", name: 'idx_cra_tracking_candidates_visitor'

    create_table :cra_tracking_intake_receipts, id: :uuid do |t|
      t.uuid :event_id, null: false
      t.string :fingerprint, null: false, limit: 64
      t.datetime :created_at, null: false
    end
    add_index :cra_tracking_intake_receipts, :event_id, unique: true
  end
end
