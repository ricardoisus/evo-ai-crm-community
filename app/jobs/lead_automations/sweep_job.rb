class LeadAutomations::SweepJob < ApplicationJob
  queue_as :scheduled_jobs
  self.log_arguments = false

  def perform
    if LeadAutomations::CraAcquisition.enabled?
      LeadAcquisitionScopeEvent.where(status: %w[pending waiting failed]).where('attempts < 5').order(:received_at).limit(500).pluck(:id).each do |id|
        LeadAutomations::ProcessScopedEventJob.perform_later(id)
      end
      LeadAcquisitionEnrichment.where(status: 'pending').order(:created_at).limit(500).pluck(:id).each do |id|
        LeadAutomations::ReconcileEnrichmentJob.perform_later(id)
      end
    end
    LeadAutomationEvent.where(status: %w[pending failed]).where('attempts < 5').order(:received_at).limit(500).pluck(:id).each do |id|
      LeadAutomations::ProcessEventJob.perform_later(id)
    end
  end
end
