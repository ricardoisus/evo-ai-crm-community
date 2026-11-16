module LeadAutomations
  class ReceiveEnrichment
    def self.call(rule, payload)
      result = LeadAcquisitionEnrichment.transaction do
        CraAcquisition.lock("acquisition:#{payload['acquisition_id']}")
        rows = LeadAcquisitionEnrichment.where(acquisition_id: payload['acquisition_id'])
        digest = Digest::SHA256.hexdigest(JSON.generate(CraAcquisition.canonical(payload)))
        old = rows.find_by(revision: payload['revision'])
        next old.digest == digest && old.rule_id == rule.id ? :duplicate : :conflict if old
        previous = rows.order(revision: :desc).first
        if previous
          identity = %w[phone_number instance_id source provider_message_id visitor_id ctwa_clid source_id]
          next :conflict if previous.rule_id != rule.id || identity.any? { |k| previous.payload[k].present? && previous.payload[k] != payload[k] }
          next :conflict if %w[ad_id adset_id campaign_id].any? { |k| previous.payload.dig('resolution', k).present? && previous.payload.dig('resolution', k) != payload.dig('resolution', k) }
        end
        LeadAcquisitionEnrichment.create!(rule_id: rule.id, acquisition_id: payload['acquisition_id'],
          revision: payload['revision'], payload: payload, digest: digest,
          status: previous && previous.revision > payload['revision'] ? 'superseded' : 'pending')
      end
      return result if result.is_a?(Symbol)
      # No contact/deal creation here. A worker reattaches after normal CRM ingress.
      LeadAutomations::ReconcileEnrichmentJob.perform_later(result.id)
      :accepted
    end
  end
end
