# frozen_string_literal: true

require 'openssl'

module WhatsappTracking
  class CraSiteIntake
    class Conflict < StandardError; end

    ATTRIBUTION_KEYS = %w[utm_source utm_medium utm_campaign utm_content utm_term utm_posicionamento utm_placement fbclid fbc].freeze

    def initialize(secret:)
      raise ArgumentError, 'CRA tracking secret is required' if secret.blank?

      @secret = secret
    end

    def call(payload, rule:)
      CraTrackingSiteVisitor.transaction do
        visitor = lock_visitor(payload['visitor_id'])
        case payload.fetch('kind')
        when 'revoke' then revoke(visitor, payload)
        when 'site_batch' then record_site(visitor, payload)
        when 'crm_intake' then record_intake(visitor, payload, rule)
        else raise ArgumentError, 'unsupported CRA intake kind'
        end
      end
    end

    def visitor_key(visitor_id)
      hmac(visitor_id)
    end

    private

    def lock_visitor(visitor_id)
      return if visitor_id.blank?

      key = visitor_key(visitor_id)
      LeadAutomations::CraAcquisition.lock("native:visitor:#{key}")
      CraTrackingSiteVisitor.find_by(visitor_key: key) || CraTrackingSiteVisitor.new(visitor_key: key)
    end

    def revoke(visitor, payload)
      incoming = Time.iso8601(payload.fetch('revoked_at'))
      visitor.assign_attributes(analytics: false, ads: false, first_touch: {}, last_touch: {},
                                revoked_at: [visitor.revoked_at, incoming].compact.max,
                                expires_at: [visitor.expires_at, 180.days.from_now].compact.max)
      visitor.save!
      WhatsappTrackingDelivery.cancel_visitor!(visitor.id)
      visitor.events.delete_all
      CraTrackingCandidate.where(visitor_key: visitor.visitor_key, status: 'pending').update_all(status: 'revoked', updated_at: Time.current)
      { accepted: true, http: 202 }
    end

    def record_site(visitor, payload)
      raise Conflict, 'revoked visitor' if visitor.revoked_at && visitor.expires_at > Time.current

      permission = payload.fetch('consent')
      consented_at = Time.at(permission.fetch('at') / 1000.0).utc
      newest = visitor.consented_at.nil? || consented_at >= visitor.consented_at
      fresh = visitor.new_record? || visitor.expires_at <= Time.current
      visitor.first_touch = payload.fetch('first_touch') if fresh
      if newest
        last_touch = payload.fetch('last_touch')
        visitor.last_touch = last_touch if (last_touch.keys & ATTRIBUTION_KEYS).any? || fresh
        visitor.assign_attributes(analytics: true, ads: permission.fetch('ads'), consent_version: permission.fetch('version'),
                                  consented_at: consented_at, expires_at: consented_at + 180.days, revoked_at: nil)
      end
      unless visitor.ads?
        scrub_browser_ids(visitor)
        visitor.events.where(ads: true).update_all(ads: false, last_touch: {})
      end
      visitor.save!
      WhatsappTrackingDelivery.cancel_visitor!(visitor.id) unless visitor.ads?

      ids = payload.fetch('events').map do |event|
        fingerprint = digest(event)
        row = CraTrackingSiteEvent.create_or_find_by!(event_id: event.fetch('event_id')) do |created|
          created.assign_attributes(visitor: visitor, kind: event.fetch('type'), fingerprint: fingerprint,
                                    path: event.fetch('path'), ads: visitor.ads?, last_touch: visitor.last_touch, occurred_at: Time.iso8601(event.fetch('occurred_at')))
        end
        raise Conflict, 'site event conflict' unless row.visitor_id == visitor.id && row.fingerprint == fingerprint

        row.event_id
      end
      CraTrackingCandidate.where(visitor_key: visitor.visitor_key, status: 'pending').update_all(next_check_at: Time.current)
      { accepted: true, http: 202, ids: ids }
    end

    def scrub_browser_ids(visitor)
      visitor.first_touch = visitor.first_touch.except(*CraSiteContract::BROWSER_KEYS)
      visitor.last_touch = visitor.last_touch.except(*CraSiteContract::BROWSER_KEYS)
    end

    def record_intake(visitor, payload, rule)
      LeadAutomations::CraAcquisition.lock("native:intake:#{payload.fetch('event_id')}")
      fingerprint = digest(payload)
      row = CraTrackingIntakeReceipt.find_by(event_id: payload.fetch('event_id'))
      raise Conflict, 'intake conflict' if row && row.fingerprint != fingerprint

      unless row
        CraTrackingIntakeReceipt.create!(event_id: payload.fetch('event_id'), fingerprint: fingerprint)
        LeadAutomations::ScopedIntake.call(rule, crm_payload(visitor, payload))
      end
      { accepted: true, http: 202, event_id: payload.fetch('event_id') }
    end

    def crm_payload(visitor, payload)
      data = payload.slice('event_id', 'page_url', 'contact_consent').merge(
        'version' => 2, 'contact' => {
          'name' => payload.dig('contact', 'name'), 'phone_number' => payload.dig('contact', 'phone')
        }
      )
      return data unless visitor&.tracking_allowed?

      data.merge('acquisition' => {
                   'visitor_id' => payload.fetch('visitor_id'), 'first_touch' => visitor.first_touch,
                   'last_touch' => visitor.last_touch, 'analytics' => true, 'ads' => visitor.ads?,
                   'consent_basis' => 'explicit', 'consent_version' => visitor.consent_version,
                   'consent_at' => visitor.consented_at.iso8601(6)
                 })
    end

    def digest(payload)
      connection = CraTrackingSiteVisitor.connection
      value = connection.quote(JSON.generate(payload))
      connection.select_value("SELECT encode(digest(#{value}::jsonb::text, 'sha256'), 'hex')")
    end

    def hmac(value)
      OpenSSL::HMAC.hexdigest('SHA256', @secret, value)
    end
  end
end
