# frozen_string_literal: true

class AddModeAndExpiryToWhatsappTrackingDeliveries < ActiveRecord::Migration[7.1]
  def change
    change_table :whatsapp_tracking_deliveries, bulk: true do |t|
      t.string :mode, null: false, default: 'production'
      t.datetime :expires_at
    end

    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          UPDATE whatsapp_tracking_deliveries
          SET expires_at = timezone('UTC', to_timestamp((event->>'event_time')::double precision)) + interval '7 days'
        SQL
      end
    end

    change_column_null :whatsapp_tracking_deliveries, :expires_at, false
    remove_index :whatsapp_tracking_deliveries, [:inbox_id, :event_id, :dataset_id], unique: true,
                 name: 'idx_whatsapp_tracking_delivery_identity'
    add_index :whatsapp_tracking_deliveries, [:inbox_id, :event_id, :dataset_id, :mode], unique: true,
              name: 'idx_whatsapp_tracking_delivery_identity'
  end
end
