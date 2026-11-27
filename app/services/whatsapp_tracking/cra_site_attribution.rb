# frozen_string_literal: true

module WhatsappTracking
  class CraSiteAttribution
    def initialize(visitor_id:, occurred_at:, secret:)
      @visitor_id = visitor_id
      @occurred_at = occurred_at
      @secret = secret
    end

    def call
      return unless JourneyMarker::VISITOR_ID.match?(@visitor_id) && @secret.present?

      key = CraSiteIntake.new(secret: @secret).visitor_key(@visitor_id)
      LeadAutomations::CraAcquisition.lock("native:visitor:#{key}")
      visitor = CraTrackingSiteVisitor.find_by(visitor_key: key)
      return unless visitor&.tracking_allowed? && visitor.ads?

      event = visitor.events.where(ads: true, occurred_at: (@occurred_at - 7.days)..(@occurred_at + 1.minute))
                     .order(Arel.sql("CASE WHEN kind = 'whatsapp_click' THEN 0 ELSE 1 END"), occurred_at: :desc, event_id: :desc).first
      return if event.nil? && @occurred_at > 5.minutes.ago

      last_touch = event ? event.last_touch : visitor.last_touch
      {
        action_source: event ? 'website' : 'chat',
        visitor_id: @visitor_id, consent_visitor_id: visitor.id,
        page_url: event ? "https://#{CraConversion::WEBSITE_HOST}#{event.path}" : nil,
        ads_consent: true, fbp: last_touch['fbp'], fbc: last_touch['fbc'],
        site_event_id: event&.event_id, first_touch: visitor.first_touch, last_touch: last_touch,
        consent: { 'version' => visitor.consent_version, 'at' => visitor.consented_at.iso8601(6),
                   'basis' => 'explicit', 'analytics' => true, 'ads' => true }
      }
    end
  end
end
