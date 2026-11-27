# frozen_string_literal: true

module WhatsappTracking
  class ProjectAdJob < ApplicationJob
    queue_as :scheduled_jobs
    self.log_arguments = false

    def perform(id)
      match = CraTrackingAdMatch.find_by(id: id)
      return unless match && DeliveryMode.production_inbox_ids.include?(match.scope_event.signal['inbox_id'])

      match.project!
    end
  end
end
