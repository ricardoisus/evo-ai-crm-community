# frozen_string_literal: true

module WhatsappTracking
  class SweepJob < ApplicationJob
    queue_as :scheduled_jobs

    def perform
      return unless ENV["WHATSAPP_TRACKING_DELIVERY_ENABLED"] == "true"

      WhatsappTrackingDelivery.abandoned.limit(100).each(&:expire_claim!)
      ids = WhatsappTrackingDelivery.ready.order(:available_at, :id).limit(100).ids
      ids.each { |id| DeliverJob.perform_later(id) }
    end
  end
end
