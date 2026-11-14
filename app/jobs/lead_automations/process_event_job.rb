class LeadAutomations::ProcessEventJob < ApplicationJob
  queue_as :low
  self.log_arguments = false

  def perform(event_id)
    LeadAutomations::ProcessEvent.call(event_id)
  end
end
