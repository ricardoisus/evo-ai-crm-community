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
      base[:signal]['instance_id'] = CraAcquisition::INSTANCE_ID
      base[:signal]['provider_message_id'] = raw.dig('key', 'id')
      text = message['conversation'] || message.dig('extendedTextMessage', 'text') || message.dig('imageMessage', 'caption')
      # Same 384-bit UTF-16 codec as site/normalize.mjs. The original text is never retained.
      encoded = text.to_s.match(/\uFEFF([\u200B\u200C]{384})\uFEFF/)&.[](1)
      if encoded
        bits = encoded.chars.map { |c| c == "\u200B" ? '1' : '0' }.join
        visitor = bits.scan(/.{8}/).map { |b| b.to_i(2).chr }.join
        base[:signal]['visitor_id'] = visitor if CraAcquisition::VISITOR.match?(visitor)
      end
      base
    end
  end
end
