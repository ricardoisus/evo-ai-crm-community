# frozen_string_literal: true

require 'digest'
require 'openssl'

module WhatsappTracking
  # Produces the same Meta identity and routing as the existing CRA outbox.
  class CraConversion
    WEBSITE_HOST = 'carolineribeiroadvogados.com'
    WEBSITE_DATASET = '1810107146920833'
    MESSAGING_DATASET = '1163151943355821'
    WABA_ID = '1410643097384818'
    FAMILIES = { 'website' => 'site_chat', 'chat' => 'site_chat', 'business_messaging' => 'ctwa' }.freeze
    VISITOR_ID = /\A[a-f0-9]{48}\z/
    BROWSER_ID = /\Afb\.[0-2]\.([0-9]{13})\.[A-Za-z0-9_-]{1,255}\z/

    def initialize(dedup_secret:)
      raise ArgumentError, 'missing CRA dedup credential' if dedup_secret.to_s.empty?

      @dedup_secret = dedup_secret
    end

    def attributes(phone:, action_source:, occurred_at:, qualified: false, **source_data)
      family = FAMILIES.fetch(action_source)
      digits = phone.to_s.delete_prefix('+')
      raise ArgumentError, 'invalid CRA phone' unless /\A[1-9][0-9]{9,14}\z/.match?(digits)

      contact_key = OpenSSL::HMAC.hexdigest('SHA256', @dedup_secret, digits)
      event_id = Digest::SHA256.hexdigest("cra:v1:#{qualified ? 'qualified' : family}:#{contact_key}")
      destination = family == 'ctwa' ? MESSAGING_DATASET : WEBSITE_DATASET
      name = qualified ? 'QualifiedLead' : (family == 'ctwa' ? 'LeadSubmitted' : 'Lead')
      attribution = { phone: digits, action_source: action_source }
      attribution.merge!(source_attribution(source_data, occurred_at: occurred_at, family: family))

      { dataset_id: destination, event_id: event_id, event_name: name, occurred_at: occurred_at, attribution: attribution }
    end

    private

    def source_attribution(input, occurred_at:, family:)
      return { ctwa_clid: input[:ctwa_clid], whatsapp_business_account_id: WABA_ID } if family == 'ctwa'

      result = input.slice(:ads_consent, :page_url).merge(website_host: WEBSITE_HOST)
      visitor_id = input[:visitor_id]
      return result unless VISITOR_ID.match?(visitor_id)

      result[:external_id] = Digest::SHA256.hexdigest("cra:#{visitor_id}")
      result[:fbp] = input[:fbp] if BROWSER_ID.match?(input[:fbp])
      click = BROWSER_ID.match(input[:fbc])
      event_ms = occurred_at.to_i * 1000
      result[:fbc] = input[:fbc] if click && click[1].to_i.between?(event_ms - 90 * 86_400_000, event_ms + 60_000)
      result
    end
  end
end
