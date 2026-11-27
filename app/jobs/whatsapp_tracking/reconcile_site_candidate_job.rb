# frozen_string_literal: true

module WhatsappTracking
  class ReconcileSiteCandidateJob < ApplicationJob
    queue_as :scheduled_jobs
    self.log_arguments = false

    def perform(candidate_id)
      candidate = CraTrackingCandidate.find_by(id: candidate_id)
      return unless candidate && DeliveryMode.capture_inbox_ids.include?(candidate.message.inbox_id)

      candidate.reconcile!
    end
  end
end
