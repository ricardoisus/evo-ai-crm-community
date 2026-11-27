# frozen_string_literal: true

class CreateCraTrackingAds < ActiveRecord::Migration[7.1]
  def change
    create_table :cra_tracking_ads, id: :uuid do |t|
      t.string :ad_id, limit: 30, null: false
      t.string :status, null: false, default: 'pending'
      t.jsonb :resolution, null: false, default: {}
      t.integer :attempt_count, null: false, default: 0
      t.datetime :next_attempt_at, null: false
      t.datetime :resolved_at
      t.datetime :cooldown_until
      t.timestamps
    end

    add_index :cra_tracking_ads, :ad_id, unique: true
    add_index :cra_tracking_ads, [:status, :next_attempt_at], name: 'idx_cra_tracking_ads_due'

    add_index :cra_tracking_ads, :cooldown_until, where: 'cooldown_until IS NOT NULL'

    create_table :cra_tracking_ad_matches, id: :uuid do |t|
      t.references :ad, type: :uuid, null: false, foreign_key: { to_table: :cra_tracking_ads }
      t.references :scope_event, type: :uuid, null: false, index: { unique: true },
                   foreign_key: { to_table: :lead_acquisition_scope_events, on_delete: :cascade }
      t.datetime :projected_at
      t.timestamps
    end
  end
end
