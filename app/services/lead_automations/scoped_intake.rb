module LeadAutomations
  class ScopedIntake
    def self.call(rule, payload)
      received = Time.current
      phone = payload.dig('contact', 'phone_number')
      LeadAcquisitionScopeEvent.transaction do
        CraAcquisition.lock("phone:#{phone}")
        key = "intake:#{rule.id}:#{payload['event_id']}"
        next if LeadAcquisitionScopeEvent.exists?(scope_key: 'client:cra', source_key: key)
        contact = Contact.find_by(phone_number: phone)
        unless contact
          contact = Contact.new(name: payload.dig('contact', 'name'), phone_number: phone)
          contact.passive_observation = true
          contact.skip_default_pipeline_assignment = true
          contact.save!
        end
        signal = { 'host' => CraAcquisition::HOST, 'rule_id' => rule.id, 'page_url' => payload['page_url'],
                   'contact_consent' => payload['contact_consent'] }
        signal['acquisition'] = payload['acquisition'] if payload['acquisition']
        CaptureScopedEvent.call(contact: contact, source: 'domain', source_key: key,
                                occurred_at: received, received_at: received, signal: signal)
      end
    end
  end
end
