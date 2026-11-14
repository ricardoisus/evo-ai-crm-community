class LeadAutomations::SweepJob < ApplicationJob
  queue_as :scheduled_jobs
  self.log_arguments = false

  def perform
    LeadAutomationEvent.where(status: %w[pending failed]).where('attempts < 5').order(:received_at).limit(500).pluck(:id).each do |id|
      LeadAutomations::ProcessEventJob.perform_later(id)
    end
  end
end
