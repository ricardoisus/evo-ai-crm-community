module LeadAutomations
  class SignalExtractor
    WRAPPERS = %w[ephemeralMessage viewOnceMessage viewOnceMessageV2 viewOnceMessageV2Extension documentWithCaptionMessage].freeze
    TYPES = %w[extendedTextMessage imageMessage videoMessage audioMessage documentMessage].freeze

    def self.call(raw, inbox:, instance_name:, envelope_type: nil)
      return unless raw.is_a?(Hash)
      r = raw.deep_stringify_keys
      return unless r.dig('key', 'fromMe') == false && r.dig('key', 'id').is_a?(String) && r.dig('key', 'id').present?
      return unless r.dig('key', 'remoteJid').to_s.match?(/\A\d{7,15}@s\.whatsapp\.net\z/)
      return if envelope_type == 'append' || r['type'] == 'append'
      return unless instance_name == inbox.channel.provider_config['instance_name']
      stamp = Float(r['messageTimestamp'], exception: false)
      return unless stamp && stamp.finite? && stamp.positive?
      stamp /= 1000 if stamp > 10**12
      occurred = Time.at(stamp).utc
      return if occurred > Time.current + 60.seconds
      message = r['message'] || {}
      5.times do
        wrapper = WRAPPERS.find { |key| message[key].is_a?(Hash) }
        break unless wrapper
        message = message.dig(wrapper, 'message') || {}
      end
      return if message.key?('reactionMessage') || message.key?('protocolMessage')
      return unless message.key?('conversation') || TYPES.any? { |key| message[key].is_a?(Hash) }
      context = r['contextInfo']
      context = TYPES.filter_map { |key| message.dig(key, 'contextInfo') }.first unless context.is_a?(Hash)
      context ||= {}
      ad = context['externalAdReply'].is_a?(Hash) ? context['externalAdReply'] : {}
      click = ad['ctwaClid'] || ad['ctwa_clid'] || context['ctwaClid'] || context['ctwa_clid']
      valid = click.is_a?(String) && click.strip.present? && click.length <= 2000
      signal = { 'inbox_id' => inbox.id, 'instance_name' => instance_name }
      signal['ctwa_clid'] = click if valid
      { source: valid ? 'ctwa' : 'none', occurred_at: occurred, signal: signal,
        source_key: "evolution:#{inbox.id}:#{r.dig('key', 'id')}" }
    rescue ArgumentError, RangeError
      nil
    end
  end
end
