# frozen_string_literal: true

module WhatsappTracking
  # Wire format already emitted by the CRA website: 48 ASCII hex bytes
  # represented as zero-width bits between two BOM characters.
  class JourneyMarker
    DELIMITER = "\uFEFF"
    BLOCK = /\uFEFF[\u200B\u200C]+\uFEFF/
    VISITOR_ID = /\A[a-f0-9]{48}\z/

    def self.decode(text)
      return { tracking: :absent } unless text.is_a?(String) && text.include?(DELIMITER)

      blocks = text.scan(BLOCK)
      return { tracking: :invalid } unless blocks.one? && blocks.first.length == 386

      bits = blocks.first[1...-1].tr("\u200B\u200C", '10')
      visitor_id = [bits].pack('B*')
      return { tracking: :invalid } unless VISITOR_ID.match?(visitor_id)

      { tracking: :journey, visitor_id: visitor_id }
    end
  end
end
