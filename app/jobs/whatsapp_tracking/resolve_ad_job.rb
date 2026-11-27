# frozen_string_literal: true

module WhatsappTracking
  class ResolveAdJob < ApplicationJob
    queue_as :scheduled_jobs
    self.log_arguments = false

    def perform(id)
      token = ENV['WHATSAPP_TRACKING_CRA_AD_READ_TOKEN']
      return if token.blank? || DeliveryMode.capture_inbox_ids.empty? || CraTrackingAd.cooling_down?

      ad = CraTrackingAd.find_by(id: id)
      attempt = ad&.claim
      return unless attempt

      ad.finish!(attempt, CraAdClient.new(token: token).fetch(ad.ad_id))
    end
  end
end
