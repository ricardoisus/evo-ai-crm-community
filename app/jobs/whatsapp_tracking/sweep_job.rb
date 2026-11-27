# frozen_string_literal: true

module WhatsappTracking
  class SweepJob < ApplicationJob
    queue_as :scheduled_jobs

    def perform
      capture_inboxes = DeliveryMode.capture_inbox_ids
      if capture_inboxes.any?
        candidates = CraTrackingCandidate.ready.joins(:message).where(messages: { inbox_id: capture_inboxes }).limit(100)
        candidates.ids.each { |id| ReconcileSiteCandidateJob.perform_later(id) }
        CraTrackingAd.due.order(:next_attempt_at).limit(3).ids.each { |id| ResolveAdJob.perform_later(id) }
      end

      production_inboxes = DeliveryMode.production_inbox_ids
      if production_inboxes.any?
        matches = CraTrackingAdMatch.joins(:ad, :scope_event).where(projected_at: nil, cra_tracking_ads: { status: 'resolved' })
        matches.where("lead_acquisition_scope_events.signal->>'inbox_id' IN (?)", production_inboxes)
               .order(:created_at).limit(50).ids.each { |id| ProjectAdJob.perform_later(id) }
      end

      inboxes = DeliveryMode.enabled_inbox_ids
      return if inboxes.empty?

      WhatsappTrackingDelivery.abandoned.limit(100).each(&:expire_claim!)
      WhatsappTrackingDelivery.expired.update_all(status: 'expired', updated_at: Time.current)
      ready = WhatsappTrackingDelivery.ready
      test = ready.where(inbox_id: inboxes, mode: 'test')
      production = ready.where(inbox_id: production_inboxes, mode: 'production')
      ids = test.or(production).order(:available_at, :id).limit(100).ids
      ids.each { |id| DeliverJob.perform_later(id) }
    end
  end
end
