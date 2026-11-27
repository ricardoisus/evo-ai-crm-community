# frozen_string_literal: true

class GuardCraTrackingDeliveries < ActiveRecord::Migration[7.1]
  def change
    add_reference :whatsapp_tracking_deliveries, :consent_visitor, type: :uuid,
                  foreign_key: { to_table: :cra_tracking_site_visitors }
    add_index :whatsapp_tracking_deliveries, [:inbox_id, :event_id, :mode], unique: true,
              where: "event->>'event_name' = 'QualifiedLead'", name: 'idx_whatsapp_tracking_qualified_contact'
  end
end
