module LeadAutomations
  class CaptureEvent
    def self.call(contact:, conversation: nil, message: nil, source:, source_key:, occurred_at:, received_at:, signal:)
      # Savepoint keeps acquisition failures from poisoning the ingress transaction.
      LeadAutomationEvent.transaction(requires_new: true) do
        contact.lock!
        LeadAutomationEvent.find_by(contact_id: contact.id) || LeadAutomationEvent.create!(
          contact_id: contact.id, conversation_id: conversation&.id, message_id: message&.id,
          source: source, source_key: source_key, occurred_at: occurred_at, received_at: received_at, signal: signal
        )
      end
    rescue StandardError
      Rails.logger.warn('[LEAD_AUTOMATION] capture_failed')
      nil
    end

    def self.persist_message(message, raw:, inbox:, params:)
      signal = begin
        SignalExtractor.call(raw, inbox: inbox, instance_name: params[:instance], envelope_type: params[:type])
      rescue StandardError
        Rails.logger.warn('[LEAD_AUTOMATION] extraction_failed')
        nil
      end
      Message.transaction do
        if signal
          message.content_attributes = message.content_attributes.merge('lead_acquisition' => {
            'source' => signal[:source], 'occurred_at' => signal[:occurred_at].iso8601(6), **signal[:signal]
          })
        end
        message.save!
        if signal
          received = Time.iso8601(params[:lead_automation_received_at].to_s) rescue Time.current
          call(contact: message.conversation.contact, conversation: message.conversation, message: message,
               received_at: received, **signal)
        end
      end
    end
  end
end
