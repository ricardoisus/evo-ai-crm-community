require 'base64'
module LeadAutomations
  class CraSignalExtractor
    def self.call(raw, inbox:, params:)
      raw = raw.deep_stringify_keys
      # LID has a separately delivered phone JID. Never treat the LID as a phone.
      if raw.dig('key', 'remoteJid').to_s.end_with?('@lid') && raw.dig('key', 'remoteJidAlt').to_s.match?(/\A\d{7,15}@s\.whatsapp\.net\z/)
        raw = raw.deep_dup
        raw['key']['remoteJid'] = raw['key']['remoteJidAlt']
      end
      base = SignalExtractor.call(raw, inbox: inbox, instance_name: params[:instance], envelope_type: params[:type])
      return unless base
      message = raw['message'] || {}
      5.times do
        wrapper = SignalExtractor::WRAPPERS.find { |k| message[k].is_a?(Hash) }
        break unless wrapper
        message = message.dig(wrapper, 'message') || {}
      end
      context = raw['contextInfo']
      context = SignalExtractor::TYPES.filter_map { |k| message.dig(k, 'contextInfo') }.first unless context.is_a?(Hash)
      context ||= {}
      ad = context['externalAdReply'].is_a?(Hash) ? context['externalAdReply'] : {}
      if base[:source] == 'ctwa' && WhatsappTracking::MetaEvent::CLICK_ID.match?(base[:signal]['ctwa_clid'])
        base[:signal]['tracking_click_verified'] = true
      end
      [ad['ctwaPayload'], context['ctwaPayload'], context['conversionData']].each do |encoded|
        next unless encoded.is_a?(String) && encoded.bytesize <= 8000
        begin
          decoded = Base64.urlsafe_decode64(encoded)
          if decoded.match?(/\AAf[A-Za-z0-9_-]{10,1998}\z/)
            base[:signal]['ctwa_clid'] ||= decoded
            base[:source] = 'ctwa'
          end
        rescue ArgumentError, JSON::ParserError
          # Malformed optional metadata does not invalidate an organic message.
        end
      end
      { 'source_id' => ['sourceId', 30], 'source_url' => ['sourceUrl', 2048], 'headline' => ['title', 255] }.each do |key, (input, limit)|
        value = ad[input] || (key == 'headline' && ad['headline'])
        base[:signal][key] = value if value.is_a?(String) && value.bytesize <= limit && !value.match?(/[\u0000-\u001f]/)
      end
      source_type = ad['sourceType'] || ad['source_type']
      base[:signal]['tracking_ad_referral'] = true if source_type == 'ad' && /\A[0-9]{1,30}\z/.match?(base[:signal]['source_id'])
      base[:signal]['instance_id'] = CraAcquisition::INSTANCE_ID
      base[:signal]['provider_message_id'] = raw.dig('key', 'id')
      text = message['conversation'] || message.dig('extendedTextMessage', 'text') || message.dig('imageMessage', 'caption')
      tracking = WhatsappTracking::JourneyMarker.decode(text)
      base[:signal]['visitor_id'] = tracking[:visitor_id] if tracking[:tracking] == :journey
      base
    end
  end
end
