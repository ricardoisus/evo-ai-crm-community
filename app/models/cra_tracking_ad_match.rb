# frozen_string_literal: true

class CraTrackingAdMatch < ApplicationRecord
  belongs_to :ad, class_name: 'CraTrackingAd'
  belongs_to :scope_event, class_name: 'LeadAcquisitionScopeEvent'

  def self.capture(event)
    signal = event.signal
    return unless WhatsappTracking::DeliveryMode.capture_inbox_ids.include?(signal['inbox_id'])
    return unless signal['tracking_click_verified'] == true && WhatsappTracking::CraAdClient::ID.match?(signal['source_id'])

    transaction(requires_new: true) do
      ad = CraTrackingAd.create_or_find_by!(ad_id: signal['source_id']) { |row| row.next_attempt_at = Time.current }
      create_or_find_by!(scope_event_id: event.id) { |row| row.ad = ad }
    end
  rescue ActiveRecord::ActiveRecordError
    Rails.logger.warn('[WHATSAPP_TRACKING] ad_capture_failed')
  end

  def project!
    with_lock do
      next if projected_at || ad.status != 'resolved'

      event = scope_event
      inbox = Inbox.find_by(id: event.signal['inbox_id'])
      rule = LeadAutomations::CraAcquisition.rule_for(inbox) if inbox&.whatsapp?
      phone = Contact.find_by(id: event.contact_id)&.phone_number
      next unless rule&.active? && WhatsappTracking::CraSiteContract::PHONE.match?(phone)

      previous = LeadAcquisitionEnrichment.where(scope_event_id: event.id, rule_id: rule.id, status: 'applied').order(revision: :desc).first
      next unless project_enrichment(event, rule, phone, previous)

      update!(projected_at: Time.current)
    end
  end

  private

  def project_enrichment(event, rule, phone, previous)
    signal = event.signal
    base = signal.slice('provider_message_id', 'ctwa_clid', 'source_id', 'source_url', 'headline')
    return false if previous && previous.payload['provider_message_id'] != base['provider_message_id']

    payload = base.merge('version' => 1, 'revision' => previous ? previous.revision + 1 : 1,
                         'acquisition_id' => previous&.acquisition_id || event.id, 'source' => 'ctwa',
                         'instance_id' => LeadAutomations::CraAcquisition::INSTANCE_ID, 'phone_number' => phone,
                         'occurred_at' => event.occurred_at.iso8601(6),
                         'resolution' => ad.resolution.merge('status' => 'resolved', 'resolved_at' => ad.resolved_at.iso8601(6)))
    result = LeadAutomations::ReceiveEnrichment.call(rule, payload)
    %i[accepted duplicate].include?(result)
  end
end
