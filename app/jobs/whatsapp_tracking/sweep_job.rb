# frozen_string_literal: true

module WhatsappTracking
  class SweepJob < ApplicationJob
    queue_as :scheduled_jobs

    def perform
      inboxes = DeliveryMode.enabled_inbox_ids
      return if inboxes.empty?

      WhatsappTrackingDelivery.abandoned.limit(100).each(&:expire_claim!)
      WhatsappTrackingDelivery.expired.update_all(status: 'expired', updated_at: Time.current)
      ids = WhatsappTrackingDelivery.ready.where(inbox_id: inboxes).order(:available_at, :id).limit(100).ids
      ids.each { |id| DeliverJob.perform_later(id) }
    end
  end
end
