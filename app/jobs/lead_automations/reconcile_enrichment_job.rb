class LeadAutomations::ReconcileEnrichmentJob < ApplicationJob
  queue_as :low
  self.log_arguments = false
  def perform(id)
    LeadAutomations::ReconcileEnrichment.call(id)
  end
end
