# frozen_string_literal: true

require 'time'
require 'uri'

module WhatsappTracking
  # Wire contract used by the CRA edge worker. Keep this aligned with
  # integracoes/cra/normalize.mjs in the CRA operations repository.
  class CraSiteContract
    class Invalid < StandardError; end

    VERSION = 'cra-tracking-2026-11-16-v1'
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
    PHONE = /\A\+[1-9][0-9]{9,14}\z/
    PATH = %r{\A/(?!/)[^?#\\\x00-\x1f]*\z}
    RATE_KEY = /\A[a-f0-9]{64}\z/
    BROWSER_KEYS = %w[fbclid fbp fbc].freeze
    UTM_KEYS = %w[utm_source utm_medium utm_campaign utm_content utm_term utm_posicionamento utm_placement].freeze
    ONE_DAY = 86_400

    def initialize(now: Time.current)
      @now = now
    end

    def normalize(payload, rate_key:)
      ensure!(payload.is_a?(Hash) && payload['version'] == 1 && payload['client'] == 'cra', 'client')
      kind = payload['kind']
      return revoke(payload) if kind == 'revoke'

      ensure!(RATE_KEY.match?(rate_key), 'rate_key')
      case kind
      when 'site_batch' then site_batch(payload)
      when 'crm_intake' then crm_intake(payload)
      else raise Invalid, 'kind'
      end
    rescue TypeError
      raise Invalid, 'invalid type'
    end

    private

    def revoke(payload)
      allowed!(payload, %w[version client kind visitor_id revoked_at analytics ads])
      ensure!(JourneyMarker::VISITOR_ID.match?(payload['visitor_id']) && boolean?(payload['analytics']) && boolean?(payload['ads']), 'revoke')
      payload.merge('revoked_at' => timestamp(payload['revoked_at'], days: 180))
    end

    def site_batch(payload)
      allowed!(payload, %w[version client kind visitor_id consent events first_touch last_touch])
      events = payload['events']
      ensure!(JourneyMarker::VISITOR_ID.match?(payload['visitor_id']) && events.is_a?(Array) && events.length.between?(1, 20), 'batch')
      permission = consent(payload['consent'])
      entries = events.map { |event| site_event(event) }
      ensure!(entries.pluck('event_id').uniq.length == entries.length, 'duplicate')
      payload.merge('consent' => permission, 'events' => entries,
                    'first_touch' => touch(payload['first_touch'], permission['ads']),
                    'last_touch' => touch(payload['last_touch'], permission['ads']))
    end

    def site_event(event)
      allowed!(event, %w[event_id type occurred_at path page_url target])
      path = event['path']
      page_url = page(event['page_url'])
      ensure!(UUID.match?(event['event_id']) && %w[page_view whatsapp_click].include?(event['type']) &&
              PATH.match?(path) && path.length <= 500 && URI.parse(page_url).path == path, 'event')
      ensure!(!event.key?('target') || %w[hero office direct form bio floating].include?(event['target']), 'target')
      event.merge('occurred_at' => timestamp(event['occurred_at']), 'page_url' => page_url)
    end

    def crm_intake(payload)
      allowed!(payload, %w[version client kind event_id page_url contact contact_consent visitor_id consent])
      person = payload['contact']
      permission = payload['contact_consent']
      allowed!(person, %w[name phone])
      allowed!(permission, %w[accepted at version])
      ensure!(UUID.match?(payload['event_id']) && PHONE.match?(person['phone']) &&
              permission['accepted'] == true && permission['version'] == 'cra-contact-v1', 'intake')
      ensure!(person['name'].is_a?(String), 'name')
      normalized = payload.except('visitor_id', 'consent').merge(
        'page_url' => page(payload['page_url']), 'contact' => person.merge('name' => string(person['name'].strip, 100)),
        'contact_consent' => permission.merge('at' => timestamp(permission['at']))
      )
      return normalized unless payload.key?('visitor_id')

      ensure!(JourneyMarker::VISITOR_ID.match?(payload['visitor_id']), 'visitor')
      normalized.merge('visitor_id' => payload['visitor_id'], 'consent' => consent(payload['consent']))
    end

    def consent(value)
      allowed!(value, %w[analytics ads version basis at])
      instant = value['at']
      ensure!(value['analytics'] == true && boolean?(value['ads']) && value['basis'] == 'explicit' &&
              value['version'] == VERSION && instant.is_a?(Numeric) &&
              (instant / 1000.0).between?(@now.to_f - 180 * ONE_DAY, @now.to_f + 60), 'consent')
      value
    end

    def touch(value, ads)
      allowed!(value, UTM_KEYS + BROWSER_KEYS + %w[page_url referrer captured_at])
      input = ads ? value : value.except(*BROWSER_KEYS)
      output = input.each_with_object({}) do |(key, entry), result|
        normalized = case key
                     when 'page_url' then page(entry)
                     when 'referrer' then safe_url(entry, site: false) if entry.present?
                     when 'captured_at' then timestamp(entry, days: 90)
                     else string(entry, { 'fbclid' => 500, 'fbc' => 600, 'fbp' => 200 }.fetch(key, 100))
                     end
        result[key] = normalized if normalized
      end
      output.delete('fbp') unless /\Afb\.1\.[0-9]{13}\.[0-9]+\z/.match?(output['fbp'])
      click = /\Afb\.1\.([0-9]{13})\.[A-Za-z0-9_-]+\z/.match(output['fbc'])
      output.delete('fbc') unless click && (click[1].to_i / 1000.0).between?(@now.to_f - 90 * ONE_DAY, @now.to_f + 60)
      placement = output['utm_posicionamento'] || output['utm_placement']
      output.merge!('utm_posicionamento' => placement, 'utm_placement' => placement) if placement
      output
    end

    def page(value)
      safe_url(value, site: true)
    end

    def safe_url(value, site:)
      url = URI.parse(string(value, 2048))
      ensure!(%w[http https].include?(url.scheme) && url.host.present? && !url.userinfo, 'url')
      ensure!(url.scheme == 'https' && url.host.casecmp?(CraConversion::WEBSITE_HOST) && url.port == 443, 'origin') if site
      url.host = url.host.downcase
      url.query = url.fragment = nil
      url.path = '/' if url.path.empty?
      url.to_s
    rescue URI::InvalidURIError
      raise Invalid, 'url'
    end

    def timestamp(value, days: 7)
      parsed = Time.iso8601(string(value, 100))
      ensure!(parsed.to_f.between?(@now.to_f - days * ONE_DAY, @now.to_f + 60), 'time')
      parsed.utc.iso8601(3)
    rescue ArgumentError
      raise Invalid, 'time'
    end

    def string(value, limit)
      ensure!(value.is_a?(String) && value.length.between?(1, limit) && !/[\x00-\x1f\x7f]/.match?(value), 'string')
      value
    end

    def boolean?(value)
      value == true || value == false
    end

    def allowed!(value, keys)
      ensure!(value.is_a?(Hash) && (value.keys - keys).empty?, 'schema')
    end

    def ensure!(valid, reason)
      raise Invalid, reason unless valid
    end
  end
end
