# frozen_string_literal: true

module WhatsappTracking
  class CraSiteProjection
    def self.call(message_id:, inbox_id:, contact:, attribution:)
      event = LeadAcquisitionScopeEvent.find_by(scope_key: 'client:cra', contact_id: contact.id)
      return unless event

      observed = Message.find_by(id: message_id, inbox_id: inbox_id)
      tracking = observed&.content_attributes&.dig('lead_acquisition')
      return unless tracking&.dig('visitor_id') == attribution[:visitor_id]
      return unless bound_journey?(event, message_id, attribution[:visitor_id])

      inbox = Inbox.find_by(id: inbox_id)
      rule = LeadAutomations::CraAcquisition.rule_for(inbox) if inbox&.whatsapp?
      return unless rule&.active? && CraSiteContract::PHONE.match?(contact.phone_number)
      return if LeadAcquisitionEnrichment.where(scope_event_id: event.id, rule_id: rule.id, status: 'applied').exists?

      payload = attribution.slice(:site_event_id, :page_url, :visitor_id, :first_touch, :last_touch, :consent).stringify_keys
      payload.merge!('version' => 1, 'acquisition_id' => event.id, 'revision' => 1, 'source' => 'website',
                     'phone_number' => contact.phone_number, 'instance_id' => LeadAutomations::CraAcquisition::INSTANCE_ID,
                     'provider_message_id' => observed.source_id, 'occurred_at' => WhatsappTracking::Capture.inbound_time(tracking, observed.created_at).iso8601(6))
      LeadAutomations::ReceiveEnrichment.call(rule, payload)
    end

    def self.bound_journey?(event, message_id, visitor_id)
      case event.source
      when 'none' then event.message_id == message_id && event.signal['visitor_id'] == visitor_id
      when 'domain' then event.signal.dig('acquisition', 'visitor_id') == visitor_id
      else false
      end
    end
    private_class_method :bound_journey?
  end
end
