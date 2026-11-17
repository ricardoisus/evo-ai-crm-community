module LeadAutomations
  class CaptureScopedEvent
    def self.call(contact:, source:, source_key:, occurred_at:, received_at:, signal:, conversation: nil, message: nil)
      LeadAcquisitionScopeEvent.transaction(requires_new: true) do
        contact.lock!
        LeadAcquisitionScopeEvent.find_by(scope_key: 'client:cra', contact_id: contact.id) ||
          LeadAcquisitionScopeEvent.create!(scope_key: 'client:cra', contact_id: contact.id, source: source,
            source_key: source_key, occurred_at: occurred_at, received_at: received_at, signal: signal,
            conversation_id: conversation&.id, message_id: message&.id)
      end
    end
  end
end
