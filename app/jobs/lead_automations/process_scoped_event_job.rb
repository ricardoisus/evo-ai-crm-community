class LeadAutomations::ProcessScopedEventJob < ApplicationJob
  queue_as :low
  self.log_arguments = false
  def perform(id)
    LeadAutomations::ProcessScopedEvent.call(id)
  end
end
