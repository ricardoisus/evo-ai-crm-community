# frozen_string_literal: true

class CraTrackingCandidate < ApplicationRecord
  belongs_to :message

  scope :ready, -> { where(status: 'pending').where(next_check_at: ..Time.current) }

  def self.capture!(message, signal)
    return unless signal['instance_id'] == LeadAutomations::CraAcquisition::INSTANCE_ID

    secret = ENV['WHATSAPP_TRACKING_CRA_DEDUP_SECRET']
    return if secret.blank?

    visitor_id = signal['visitor_id']
    key = WhatsappTracking::CraSiteIntake.new(secret: secret).visitor_key(visitor_id) if WhatsappTracking::JourneyMarker::VISITOR_ID.match?(visitor_id)
    ad_id = signal['source_id'] if key.nil? && signal['tracking_ad_referral'] == true && WhatsappTracking::CraAdClient::ID.match?(signal['source_id'])
    return unless key || ad_id

    transaction(requires_new: true) do
      if key
        LeadAutomations::CraAcquisition.lock("native:visitor:#{key}")
        visitor = CraTrackingSiteVisitor.find_by(visitor_key: key)
        next if visitor&.revoked_at && visitor.expires_at > Time.current
      else
        CraTrackingAd.create_or_find_by!(ad_id: ad_id) { |ad| ad.next_attempt_at = Time.current }
      end

      create_or_find_by!(message_id: message.id) do |candidate|
        candidate.assign_attributes(visitor_key: key, ad_id: ad_id, next_check_at: Time.current,
                                    occurred_at: WhatsappTracking::Capture.inbound_time(signal, message.created_at))
      end
    end
  rescue ActiveRecord::ActiveRecordError, ArgumentError
    Rails.logger.warn('[WHATSAPP_TRACKING] site_candidate_capture_failed')
    nil
  end

  def reconcile!
    self.class.transaction do
      LeadAutomations::CraAcquisition.lock("native:visitor:#{visitor_key}") if visitor_key
      lock!
      next unless status == 'pending' && next_check_at <= Time.current

      if occurred_at <= 7.days.ago
        update!(status: 'expired')
      elsif WhatsappTracking::Capture.message(message, reconciling: true)
        update!(status: 'observed')
      else
        update!(next_check_at: Time.current + (occurred_at > 10.minutes.ago ? 1.minute : 15.minutes))
      end
    end
  end
end
