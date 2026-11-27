# frozen_string_literal: true

class CreateWhatsappTrackingDeliveries < ActiveRecord::Migration[7.1]
  def change
    create_table :whatsapp_tracking_deliveries, id: :uuid do |t|
      t.references :inbox, type: :uuid, null: false, foreign_key: true, index: false
      t.string :event_id, null: false, limit: 64
      t.string :dataset_id, null: false, limit: 30
      t.string :credential_ref, null: false, limit: 120
      t.jsonb :event, null: false
      t.string :status, null: false, default: 'pending'
      t.integer :attempt_count, null: false, default: 0
      t.datetime :available_at, null: false
      t.datetime :claimed_at
      t.timestamps
    end

    add_index :whatsapp_tracking_deliveries, [:inbox_id, :event_id, :dataset_id], unique: true,
              name: 'idx_whatsapp_tracking_delivery_identity'
    add_index :whatsapp_tracking_deliveries, [:status, :available_at],
              name: 'idx_whatsapp_tracking_delivery_ready'
    add_index :whatsapp_tracking_deliveries, :claimed_at, where: "status = 'sending'",
              name: 'idx_whatsapp_tracking_delivery_claimed'

    create_table :whatsapp_tracking_receipts, id: :uuid do |t|
      t.references :delivery, type: :uuid, null: false, foreign_key: { to_table: :whatsapp_tracking_deliveries },
                 index: false
      t.integer :attempt_number, null: false
      t.string :status, null: false
      t.integer :http_status
      t.integer :error_code
      t.integer :error_subcode
      t.datetime :created_at, null: false
    end

    add_index :whatsapp_tracking_receipts, [:delivery_id, :attempt_number], unique: true,
              name: 'idx_whatsapp_tracking_receipt_attempt'
  end
end
