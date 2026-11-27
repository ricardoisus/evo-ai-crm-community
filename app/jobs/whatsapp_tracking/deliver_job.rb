# frozen_string_literal: true

module WhatsappTracking
  class DeliverJob < ApplicationJob
    queue_as :scheduled_jobs
    self.log_arguments = false

    def perform(delivery_id)
      delivery = WhatsappTrackingDelivery.find_by(id: delivery_id)
      return unless delivery

      return unless DeliveryMode.enabled_inbox_ids.include?(delivery.inbox_id)

      mode = DeliveryMode.new(delivery.mode)

      attempt = delivery.claim
      return unless attempt

      delivery.finish!(attempt, deliver(delivery, mode))
    end

    private

    def deliver(delivery, mode)
      token = ENV[delivery.credential_ref]
      return { status: :configuration_error } if token.blank? || !mode.ready?

      MetaClient.new(dataset_id: delivery.dataset_id, token: token).deliver(delivery.event, test_code: mode.test_code)
    end
  end
end
