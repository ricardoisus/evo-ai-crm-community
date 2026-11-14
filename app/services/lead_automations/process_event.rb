module LeadAutomations
  class ProcessEvent
    def self.call(id)
      new.call(id)
    end

    def call(id)
      event = LeadAutomationEvent.find_by(id: id)
      return unless event && event.status != 'processed'
      contact = Contact.find_by(id: event.contact_id)
      return event.update!(status: 'failed', error_code: 'contact_missing') unless contact
      contact.with_lock do
        event.lock!
        return if event.status == 'processed'
        rules = LeadAutomationRule.where(deleted_at: nil)
        rules = rules.where(id: event.signal['rule_id']) if event.source == 'domain'
        errors = rules.order(:id).map { |rule| process_rule(rule, contact, event) }
        event.update!(status: errors.include?(true) ? 'failed' : 'processed', attempts: event.attempts + 1,
                      processed_at: Time.current, error_code: errors.include?(true) ? 'rule_failed' : nil)
      end
    end

    private

    def process_rule(rule, contact, event)
      rule.with_lock do
        run = LeadAutomationRun.find_or_initialize_by(rule_id: rule.id, contact_id: contact.id)
        return false if run.persisted? && run.status != 'error'
        attrs = { event_id: event.id, conversation_id: event.conversation_id, source: event.source,
                  rule_revision: rule.revision, executed_at: Time.current, attempts: run.persisted? ? run.attempts + 1 : 1 }
        begin
          # Roll back all deal writes on failure, but keep the safe execution log.
          PipelineItem.transaction(requires_new: true) do
            conversation = Conversation.find_by(id: event.conversation_id)
            e = event.signal.merge('source' => event.source, 'occurred_at' => event.occurred_at.iso8601(6),
                                   'contact_created_at' => contact.created_at.iso8601(6),
                                   'conversation_created_at' => conversation&.created_at&.iso8601(6),
                                   'page_url' => "https://#{event.signal['host']}/")
            decision = Matcher.call(rule, e)
            reason = decision[:reasons].first
            reason ||= 'old_event' if !rule.activated_at || event.received_at < rule.activated_at
            reason ||= 'conversation_missing' if event.conversation_id && !conversation
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

    def existing_deal(contact, rule)
      scope = PipelineItem.active.where(pipeline_id: rule.pipeline_id)
      scope.where(contact_id: contact.id).or(scope.where(primary_contact_id: contact.id))
           .or(scope.where(id: DealContact.where(contact_id: contact.id).select(:pipeline_item_id)))
           .or(scope.where(conversation_id: Conversation.where(contact_id: contact.id).select(:id)))
           .or(scope.where(id: DealConversation.where(conversation_id: Conversation.where(contact_id: contact.id).select(:id)).select(:pipeline_item_id))).first
    end
  end
end
