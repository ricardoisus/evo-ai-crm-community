# frozen_string_literal: true

require 'digest'
require 'uri'

module WhatsappTracking
  class MetaEvent
    EVENT_NAME = /\A[A-Za-z][A-Za-z0-9_]{0,49}\z/
    CLICK_ID = /\A[A-Za-z0-9._~+\/=-]{1,2000}\z/
    BROWSER_ID = /\Afb\.[0-2]\.[0-9]{13}\.[A-Za-z0-9_-]{1,500}\z/

    def initialize(event_name:, event_id:, occurred_at:, attribution:)
      @event_name = event_name
      @event_id = event_id
      @occurred_at = occurred_at
      @attribution = attribution
    end

    def to_h
      validate!
      result = {
        event_name: @event_name, event_id: @event_id, event_time: @occurred_at.to_i,
        action_source: source, user_data: user_data
      }
      result[:messaging_channel] = 'whatsapp' if source == 'business_messaging'
      result[:event_source_url] = website_url if source == 'website'
      result
    end

    private

    def source
      @attribution.fetch(:action_source)
    end

    def validate!
      raise ArgumentError, 'invalid Meta event' unless EVENT_NAME.match?(@event_name) && /\A[a-f0-9]{64}\z/.match?(@event_id)
      raise ArgumentError, 'unsupported action source' unless %w[website chat business_messaging].include?(source)
      raise ArgumentError, 'missing advertising consent' if source != 'business_messaging' && @attribution[:ads_consent] != true
      raise ArgumentError, 'Lead requires website or chat' if source == 'business_messaging' && @event_name == 'Lead'
      raise ArgumentError, 'LeadSubmitted requires business messaging' if source != 'business_messaging' && @event_name == 'LeadSubmitted'
    end

    def user_data
      phone = @attribution[:phone].to_s.delete_prefix('+')
      raise ArgumentError, 'invalid phone' unless /\A[1-9][0-9]{9,14}\z/.match?(phone)

      data = { ph: [Digest::SHA256.hexdigest(phone)] }
      if source == 'business_messaging'
        click_id = @attribution[:ctwa_clid]
        waba_id = @attribution[:whatsapp_business_account_id]
        raise ArgumentError, 'missing business messaging attribution' unless CLICK_ID.match?(click_id) && /\A[0-9]{1,30}\z/.match?(waba_id)

        data.merge(ctwa_clid: click_id, whatsapp_business_account_id: waba_id)
      else
        %i[fbp fbc].each do |key|
          data[key] = @attribution[key] if BROWSER_ID.match?(@attribution[key])
        end
        data
      end
    end

    def website_url
      uri = URI.parse(@attribution[:page_url].to_s)
      configured_host = @attribution[:website_host]
      unless uri.is_a?(URI::HTTPS) && configured_host && uri.host == configured_host && uri.userinfo.nil? && uri.port == 443
        raise ArgumentError, 'invalid conversion URL'
      end

      uri.query = nil
      uri.fragment = nil
      uri.to_s
    rescue URI::InvalidURIError
      raise ArgumentError, 'invalid conversion URL'
    end
  end
end
