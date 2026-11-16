module LeadAutomations
  class ProcessScopedEvent < ProcessEvent
    def call(id)
      return unless CraAcquisition.enabled?
      event = LeadAcquisitionScopeEvent.find_by(id: id)
      return unless event && event.status != 'processed'
      contact = Contact.find_by(id: event.contact_id)
      return event.update!(status: 'failed', error_code: 'contact_missing') unless contact
      contact.with_lock do
        event.lock!
        next if event.status == 'processed'
        rules = LeadAutomationRule.kept.where(acquisition_scope_key: event.scope_key).order(:id)
        rules = rules.where(id: event.signal['rule_id']) if event.source == 'domain'
        rules = rules.select { |rule| event.source == 'domain' || rule.conditions.dig('ctwa', 'inbox_id') == event.signal['inbox_id'] }
        # Late proof is allowed only for the original encoded message, for 24 hours.
        if event.source == 'none' && event.signal['visitor_id'].present? && event.received_at > 24.hours.ago && !proof(event)
          event.update!(status: 'waiting')
          next
        end
        errors = rules.map { |rule| process_scoped_rule(rule, contact, event) }
        event.update!(status: errors.include?(true) ? 'failed' : 'processed', attempts: event.attempts + 1,
                      error_code: errors.include?(true) ? 'rule_failed' : nil)
      end
    end

    private

    def proof(event)
      LeadAcquisitionEnrichment.where(scope_event_id: event.id, status: 'applied').order(revision: :desc).find do |row|
        p = row.payload
        CraAcquisition::VISITOR.match?(event.signal['visitor_id'].to_s) && p['source'] == 'website' && p['provider_message_id'] == event.signal['provider_message_id'] &&
          p['visitor_id'] == event.signal['visitor_id'] && p['site_event_id'].present? &&
          Matcher.domain_url?(p['page_url'], CraAcquisition::HOST) && CraAcquisition.consent?(p['consent']) &&
          Time.iso8601(p['occurred_at']) >= event.occurred_at - 7.days &&
          (Time.iso8601(p['occurred_at']) - event.occurred_at).abs <= 60 && row.created_at <= event.received_at + 24.hours
      end
    end

    def process_scoped_rule(rule, contact, event)
      rule.with_lock do
        run = LeadAutomationRun.find_or_initialize_by(rule_id: rule.id, contact_id: contact.id)
        next false if run.persisted? && run.status != 'error'
        attrs = { scope_event_id: event.id, conversation_id: event.conversation_id, source: event.source == 'website' ? 'domain' : event.source,
                  rule_revision: rule.revision, executed_at: Time.current, attempts: run.persisted? ? run.attempts + 1 : 1 }
        begin
          PipelineItem.transaction(requires_new: true) do
            conversation = Conversation.find_by(id: event.conversation_id)
            derived = event.source == 'none' && event.status != 'processed' ? proof(event) : nil
            source = derived ? 'domain' : event.source
            signal = event.signal.merge('source' => source, 'occurred_at' => event.occurred_at.iso8601(6),
              # Scoped eligibility is the first CRA ingress, not global contact age.
              'contact_created_at' => event.received_at.iso8601(6), 'conversation_created_at' => conversation&.created_at&.iso8601(6))
            signal['page_url'] = derived.payload['page_url'] if derived
            reason = Matcher.call(rule, signal)[:reasons].first
            reason ||= 'old_event' unless rule.activated_at && event.received_at >= rule.activated_at
            reason ||= 'conversation_missing' if event.conversation_id && !conversation
            box_id = rule.conditions.dig('ctwa', 'inbox_id')
            reason ||= 'old_conversation' if rule.activated_at && Conversation.where(contact_id: contact.id, inbox_id: box_id).where('created_at < ?', rule.activated_at).exists?
            if reason
              attrs.merge!(status: reason == 'destination_missing' ? 'error' : 'skipped', reason_code: reason)
            else
              deal = existing_deal(contact, rule)
              if deal
                attrs.merge!(status: 'existing', deal_id: deal.id, reason_code: 'open_deal_exists')
              else
                deal = PipelineItem.new(pipeline_id: rule.pipeline_id, pipeline_stage_id: rule.pipeline_stage_id,
                  contact: contact, primary_contact: contact, owner_id: rule.owner_id,
                  title: rule.title_template.gsub('{{contact_name}}', contact.name.to_s).first(160), value: 0, currency: 'BRL')
                deal.lead_automation_context = true
                deal.label_list = Label.where(id: rule.label_ids).pluck(:title)
                deal.save!
                deal.deal_conversations.create!(conversation: conversation) if conversation
                attrs.merge!(status: 'created', deal_id: deal.id, reason_code: nil)
              end
              CraProjection.call(deal, event: event, payload: derived&.payload || initial_payload(event))
            end
          end
        rescue StandardError
          attrs.merge!(status: 'error', reason_code: 'execution_failed', deal_id: nil)
        end
        run.assign_attributes(attrs)
        run.save!
        run.status == 'error'
      end
    end

    def initial_payload(event)
      a = event.signal['acquisition'] || {}
      event.signal.merge(a.slice('visitor_id', 'first_touch', 'last_touch')).merge(
        'source' => event.source == 'domain' ? 'website' : event.source,
        'occurred_at' => event.occurred_at.iso8601(6),
        'consent' => a.present? ? { 'basis' => a['consent_basis'], 'version' => a['consent_version'], 'at' => a['consent_at'], 'analytics' => a['analytics'], 'ads' => a['ads'] } : nil)
    end
  end
end
