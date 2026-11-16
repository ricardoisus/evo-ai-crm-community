module LeadAutomations
  class ReconcileEnrichment
    def self.call(id)
      return unless CraAcquisition.enabled?
      row = LeadAcquisitionEnrichment.find_by(id: id)
      return unless row && row.status == 'pending'
      rule = LeadAutomationRule.kept.find_by(id: row.rule_id, acquisition_scope_key: 'client:cra', active: true)
      return unless rule
      contact = Contact.find_by(phone_number: row.payload['phone_number'])
      return expire(row) unless contact
      contact.with_lock do
        row.lock!
        next unless row.status == 'pending'
        event = LeadAcquisitionScopeEvent.find_by(scope_key: rule.acquisition_scope_key, contact_id: contact.id)
        next expire(row) unless event
        p = row.payload
        prior_proof = LeadAcquisitionEnrichment.exists?(scope_event_id: event.id, acquisition_id: row.acquisition_id, status: 'applied')
        if p['instance_id'] != CraAcquisition::INSTANCE_ID ||
           (event.signal['inbox_id'].present? && event.signal['inbox_id'] != rule.conditions.dig('ctwa', 'inbox_id')) ||
           (event.message_id.present? && p['provider_message_id'] != event.signal['provider_message_id']) ||
           (event.source == 'ctwa' && (p['source'] != 'ctwa' || p['ctwa_clid'] != event.signal['ctwa_clid'])) ||
           (event.source == 'none' && ((!%w[pending waiting].include?(event.status) && !prior_proof) || !CraAcquisition::VISITOR.match?(event.signal['visitor_id'].to_s) || p['source'] != 'website' ||
             p['visitor_id'] != event.signal['visitor_id'] || !p['site_event_id'] || !CraAcquisition.consent?(p['consent']) ||
             !Matcher.domain_url?(p['page_url'], CraAcquisition::HOST) || (row.created_at > event.received_at + 24.hours && !prior_proof)))
          next row.update!(status: 'review', error_code: 'identity_conflict', scope_event_id: event.id)
        end
        if event.source == 'domain' && p['source'] == 'website' &&
           (p['visitor_id'].blank? || p['visitor_id'] != event.signal.dig('acquisition', 'visitor_id'))
          next row.update!(status: 'review', error_code: 'journey_unbound', scope_event_id: event.id)
        end
        latest = LeadAcquisitionEnrichment.where(rule_id: rule.id, acquisition_id: row.acquisition_id, status: 'applied').maximum(:revision)
        next row.update!(status: 'superseded') if latest && latest >= row.revision
        row.update!(scope_event_id: event.id, status: 'applied')
        run = LeadAutomationRun.find_by(rule_id: rule.id, scope_event_id: event.id, status: %w[created existing])
        if run&.deal_id
          deal = PipelineItem.find_by(id: run.deal_id, pipeline_id: rule.pipeline_id)
          CraProjection.call(deal, event: event, payload: p) if deal && !(event.source == 'domain' && p['source'] == 'ctwa')
        elsif event.status != 'processed'
          ProcessScopedEventJob.perform_later(event.id)
        end
      end
    end

    def self.expire(row)
      row.update!(status: 'review', error_code: 'ingress_missing') if row.created_at < 24.hours.ago
    end
  end
end
