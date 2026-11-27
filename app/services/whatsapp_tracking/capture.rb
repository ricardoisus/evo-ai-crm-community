# frozen_string_literal: true

module WhatsappTracking
  # Evaluate inside the source transaction. Persist only delivery identity and
  # minimized event data, so a restart cannot lose a committed conversion.
  class Capture
    def self.message(message, reconciling: false)
      return unless message.inbox.whatsapp? && !message.private? && !message.imported? && !message.failed?
      return unless message.source_id.present?

      trigger = if message.incoming? && (message.previously_new_record? || reconciling)
                  'message_received'
                elsif (message.outgoing? || message.template?) &&
                      (message.saved_change_to_source_id? || message.saved_change_to_status&.first == 'failed')
                  'message_sent'
                end
      return unless trigger

      signal = message.content_attributes['lead_acquisition'] || {}
      if trigger == 'message_received' && !reconciling && signal['tracking_click_verified'] != true &&
         (JourneyMarker::VISITOR_ID.match?(signal['visitor_id']) || signal['tracking_ad_referral'] == true)
        return CraTrackingCandidate.capture!(message, signal)
      end

      type = message.template? ? 'template' : message.attachments.first&.file_type || message.content_type
      new(message.inbox_id, message.conversation.contact).call(
        'trigger' => trigger, 'occurrence_id' => message.id,
        'occurred_at' => message.incoming? ? inbound_time(signal, message.created_at) : message.updated_at,
        'text' => message.content.to_s.gsub(JourneyMarker::BLOCK, ''), 'message_type' => type, 'confirmed' => message.source_id.present?,
        'signal' => signal
      )
    end

    def self.inbound_time(signal, fallback)
      Time.iso8601(signal['occurred_at'].to_s)
    rescue ArgumentError
      fallback
    end

    def self.stage(item)
      return if item.lead_automation_context

      previous, current = item.saved_change_to_pipeline_stage_id
      inbox_id = item.conversation&.inbox_id || item.custom_fields&.dig('cra_inbox_id')
      if inbox_id.nil?
        scoped = LeadAutomationRule.kept.find_by(pipeline_id: item.pipeline_id, acquisition_scope_key: 'client:cra', active: true)
        inbox_id = scoped&.conditions&.dig('ctwa', 'inbox_id')
      end
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
        acquisition = cra_acquisition(event)
        source_proof = acquisition_proof(acquisition)
        signal = event['signal'].presence || source_proof || acquisition&.signal || {}
        secret = ENV['WHATSAPP_TRACKING_CRA_DEDUP_SECRET']
        next false if secret.blank?

        attribution = attribution_for(event, signal, acquisition, secret)
        next false unless attribution
        next false if event['trigger'] == 'stage_entered' && !source_proof && acquisition&.message_id.nil?

        facts = event.merge('account_id' => @inbox_id, 'inbox_id' => @inbox_id,
                            'origin' => attribution[:action_source] == 'business_messaging' ? 'ctwa' : attribution[:action_source])
        rule_scope.find_each { |rule| evaluate(rule, facts, attribution, acquisition, secret) }
        project_site(event, attribution)
        true
      end
    rescue ActiveRecord::ActiveRecordError, ArgumentError, KeyError
      Rails.logger.warn('[WHATSAPP_TRACKING] event_capture_failed')
    end

    private

    def rule_scope
      WhatsappTrackingRule.where(inbox_id: @inbox_id, active: true).where.not(published: nil)
    end

    def project_site(event, attribution)
      return unless event['trigger'] == 'message_received' && attribution[:site_event_id]
      return unless DeliveryMode.production_inbox_ids.include?(@inbox_id)

      CraSiteProjection.call(message_id: event.fetch('occurrence_id'), inbox_id: @inbox_id,
                             contact: @contact, attribution: attribution)
    end

    def evaluate(rule, facts, attribution, acquisition, secret)
      setup = rule.published
      return unless setup['trigger'] == facts['trigger']

      return unless RuleMatcher.new(setup.merge('account_id' => @inbox_id), facts).result == :matched

      target = WhatsappTrackingDestination.find_by(id: setup['destination_id'], inbox_id: @inbox_id)
      return unless target

      conversion = convert(rule, setup, facts, attribution, acquisition, secret)
      return unless conversion && conversion[:dataset_id] == target.dataset_id

      delivery = { inbox_id: @inbox_id, credential_ref: target.credential_ref, **conversion }
      if setup['mode'] == 'production' && DeliveryMode.production_inbox_ids.include?(@inbox_id)
        WhatsappTrackingDelivery.enqueue!(**delivery, consent_visitor_id: attribution[:consent_visitor_id])
      else
        WhatsappTrackingDelivery.observe!(**delivery)
      end
    end

    def cra_acquisition(event)
      return if event['signal'].present?

      candidate = LeadAcquisitionScopeEvent.find_by(scope_key: 'client:cra', contact_id: @contact.id)
      return unless candidate
      return candidate if candidate.signal['inbox_id'] == @inbox_id

      scoped = LeadAutomationRule.kept.find_by(id: candidate.signal['rule_id'], acquisition_scope_key: 'client:cra', active: true)
      candidate if scoped&.conditions&.dig('ctwa', 'inbox_id') == @inbox_id
    end

    def acquisition_proof(acquisition)
      return unless acquisition&.source == 'domain'

      enrichment = LeadAcquisitionEnrichment.where(scope_event_id: acquisition.id, status: 'applied').order(revision: :desc).first
      payload = enrichment&.payload
      payload if payload&.dig('source') == 'website' && payload['provider_message_id'].present? && payload['site_event_id'].present?
    end

    def attribution_for(event, signal, acquisition, secret)
      if signal['instance_id'] == LeadAutomations::CraAcquisition::INSTANCE_ID &&
         signal['tracking_click_verified'] == true && MetaEvent::CLICK_ID.match?(signal['ctwa_clid'])
        return { action_source: 'business_messaging', ctwa_clid: signal['ctwa_clid'] }
      end

      visitor_id = signal['visitor_id'] || signal.dig('acquisition', 'visitor_id')
      if visitor_id.nil? && signal['tracking_ad_referral'] == true && CraTrackingAd.exists?(ad_id: signal['source_id'], status: 'resolved')
        return { action_source: 'chat', ad_referral_verified: true }
      end

      fallback_time = acquisition&.occurred_at || event.fetch('occurred_at')
      CraSiteAttribution.new(visitor_id: visitor_id, occurred_at: self.class.inbound_time(signal, fallback_time), secret: secret).call
    end

    def convert(rule, setup, event, attribution, acquisition, secret)
      event_name = setup['event_name']
      messaging = attribution[:action_source] == 'business_messaging'
      return if (event_name == 'Lead' && messaging) || (event_name == 'LeadSubmitted' && !messaging)

      qualified = event_name == 'QualifiedLead'
      return if qualified && (event['trigger'] != 'stage_entered' || !acquisition)

      conversion = CraConversion.new(dedup_secret: secret).attributes(
        phone: @contact.phone_number, occurred_at: event.fetch('occurred_at'), qualified: qualified, **attribution
      )
      return conversion if qualified || (setup['frequency'] == 'contact' && conversion[:event_name] == event_name)

      scope = frequency_scope(setup['frequency'], event, acquisition)
      return if scope.blank?

      event_id = Digest::SHA256.hexdigest("native-wa-tracking:v1:#{rule.id}:#{scope}")
      conversion.merge(event_id: event_id, event_name: event_name)
    end

    def frequency_scope(frequency, event, acquisition)
      case frequency
      when 'occurrence' then event.fetch('occurrence_id')
      when 'contact' then @contact.id
      when 'acquisition' then acquisition&.id || (event['trigger'] == 'message_received' && event.fetch('occurrence_id'))
      end
    end
  end
end
