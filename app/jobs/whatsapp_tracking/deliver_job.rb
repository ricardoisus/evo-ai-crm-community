# frozen_string_literal: true

module WhatsappTracking
  class DeliverJob < ApplicationJob
    queue_as :scheduled_jobs
    self.log_arguments = false

    def perform(delivery_id)
      return unless ENV["WHATSAPP_TRACKING_DELIVERY_ENABLED"] == "true"

      delivery = WhatsappTrackingDelivery.find_by(id: delivery_id)
      attempt = delivery&.claim
      return unless attempt

      delivery.finish!(attempt, deliver(delivery))
    end

    private

    def deliver(delivery)
      token = ENV[delivery.credential_ref]
      return { status: :configuration_error } if token.blank?

      MetaClient.new(dataset_id: delivery.dataset_id, token: token).deliver(delivery.event)
    end
  end
end
