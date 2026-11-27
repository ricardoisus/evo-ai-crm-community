# frozen_string_literal: true

class CreateWhatsappTrackingConfiguration < ActiveRecord::Migration[7.1]
  def change
    create_table :whatsapp_tracking_destinations, id: :uuid do |t|
      t.references :inbox, type: :uuid, null: false, foreign_key: true
      t.string :name, null: false, limit: 120
      t.string :dataset_id, null: false, limit: 30
      t.string :credential_ref, null: false, limit: 120
      t.timestamps
    end

    add_index :whatsapp_tracking_destinations, [:inbox_id, :dataset_id], unique: true,
              name: 'idx_whatsapp_tracking_destination_dataset'

    create_table :whatsapp_tracking_rules, id: :uuid do |t|
      t.references :inbox, type: :uuid, null: false, foreign_key: true
      t.string :name, null: false, limit: 120
      t.jsonb :draft, default: {}, null: false
      t.jsonb :published
      t.boolean :active, default: false, null: false
      t.integer :lock_version, default: 0, null: false
      t.timestamps
    end
    add_index :whatsapp_tracking_rules, :inbox_id, where: 'active', name: 'idx_whatsapp_tracking_active_rules'
  end
end
