# frozen_string_literal: true

module WhatsappTracking
  # Evaluate inside the source transaction. Persist only delivery identity and
  # minimized event data, so a restart cannot lose a committed conversion.
  class Capture
    def self.message(message)
      return unless message.inbox.whatsapp? && !message.private? && !message.imported? && !message.failed?
      return unless message.source_id.present?

      trigger = if message.incoming? && message.previously_new_record?
                  'message_received'
                elsif (message.outgoing? || message.template?) && message.saved_change_to_source_id?
                  'message_sent'
                end
      return unless trigger

      type = message.template? ? 'template' : message.attachments.first&.file_type || message.content_type
      new(message.inbox_id, message.conversation.contact).call(
        'trigger' => trigger, 'occurrence_id' => message.id,
        'occurred_at' => message.incoming? ? message.created_at : message.updated_at,
        'text' => message.content.to_s.gsub(JourneyMarker::BLOCK, ''), 'message_type' => type, 'confirmed' => message.source_id.present?,
        'signal' => message.content_attributes['lead_acquisition']
      )
    end

    def self.stage(item)
      return if item.lead_automation_context

      previous, current = item.saved_change_to_pipeline_stage_id
      inbox_id = item.conversation&.inbox_id || item.custom_fields&.dig('cra_inbox_id')
      return unless current && inbox_id

      new(inbox_id, item.contact).call(
        'trigger' => 'stage_entered', 'occurrence_id' => "#{item.id}:#{item.updated_at.iso8601(6)}:#{current}",
        'occurred_at' => item.updated_at, 'pipeline_id' => item.pipeline_id, 'stage_id' => current, 'from_stage_id' => previous
      )
    end

    def initialize(inbox_id, contact)
      @inbox_id = inbox_id
      @contact = contact
    end

    def call(event)
      return unless @contact && DeliveryMode.capture_inbox_ids.include?(@inbox_id)

      WhatsappTrackingDelivery.transaction(requires_new: true) do
        rule_scope.find_each { |rule| evaluate(rule, event) }
      end
    rescue ActiveRecord::ActiveRecordError, ArgumentError, KeyError
      Rails.logger.warn('[WHATSAPP_TRACKING] event_capture_failed')
    end

    private

    def rule_scope
      WhatsappTrackingRule.where(inbox_id: @inbox_id, active: true).where.not(published: nil)
    end

    def evaluate(rule, event)
      setup = rule.published
      return unless setup['trigger'] == event['trigger']

      acquisition = cra_acquisition(event)
      signal = event['signal'].presence || acquisition&.signal || {}
      facts = event.merge('account_id' => @inbox_id, 'inbox_id' => @inbox_id, 'origin' => origin(signal, acquisition))
      return unless RuleMatcher.new(setup.merge('account_id' => @inbox_id), facts).result == :matched

      target = WhatsappTrackingDestination.find_by(id: setup['destination_id'], inbox_id: @inbox_id)
      return unless target

      conversion = convert(setup, facts, signal, acquisition)
      return unless conversion && conversion[:dataset_id] == target.dataset_id

      WhatsappTrackingDelivery.observe!(inbox_id: @inbox_id, credential_ref: target.credential_ref, **conversion)
    end

    def cra_acquisition(event)
      return if event['signal'].present?

      candidate = LeadAcquisitionScopeEvent.find_by(scope_key: 'client:cra', contact_id: @contact.id)
      candidate if candidate&.signal&.dig('inbox_id') == @inbox_id
    end

    def origin(signal, acquisition)
      return 'ctwa' if signal['tracking_click_verified'] == true
      return 'website' if acquisition&.source == 'website' || acquisition&.source == 'domain'

      'organic'
    end

    def convert(setup, event, signal, acquisition)
      return unless signal['instance_id'] == LeadAutomations::CraAcquisition::INSTANCE_ID
      return unless event['origin'] == 'ctwa' && MetaEvent::CLICK_ID.match?(signal['ctwa_clid'])
      return unless %w[LeadSubmitted QualifiedLead].include?(setup['event_name']) && setup['frequency'] == 'contact'
      return if setup['event_name'] == 'QualifiedLead' && (event['trigger'] != 'stage_entered' || !acquisition)

      secret = ENV['WHATSAPP_TRACKING_CRA_DEDUP_SECRET']
      return if secret.blank?

      CraConversion.new(dedup_secret: secret).attributes(
        phone: @contact.phone_number, action_source: 'business_messaging', occurred_at: event.fetch('occurred_at'),
        qualified: setup['event_name'] == 'QualifiedLead', ctwa_clid: signal['ctwa_clid']
      )
    end
  end
end
