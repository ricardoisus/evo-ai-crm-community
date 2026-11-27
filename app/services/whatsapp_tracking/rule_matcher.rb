# frozen_string_literal: true

module WhatsappTracking
  # Shared decision logic for live evaluation and dry runs. Event facts are
  # supplied by the server-side adapter and contain no Meta credentials.
  class RuleMatcher
    FILTERS = {
      'inbox_id' => 'inbox_id',
      'pipeline_id' => 'pipeline_id',
      'stage_id' => 'stage_id',
      'from_stage_id' => 'from_stage_id',
      'origin' => 'origin',
      'message_type' => 'message_type'
    }.freeze

    def initialize(rule, event)
      @rule = rule
      @event = event
    end

    def result
      return :different_account unless event.fetch('account_id') == rule.fetch('account_id')
      return :different_trigger unless event.fetch('trigger') == rule.fetch('trigger')
      return :ineligible_message if ineligible_message?
      return :filter_mismatch unless filters_match?
      return :text_mismatch unless text_matches?

      :matched
    end

    private

    attr_reader :rule, :event

    def ineligible_message?
      return false if event['trigger'] == 'stage_entered'
      return true if event['private'] || event['imported']

      event['trigger'] == 'message_sent' && event['confirmed'] != true
    end

    def filters_match?
      FILTERS.all? do |filter, fact|
        expected = rule.fetch('filters', {})[filter]
        expected.nil? || expected == event[fact]
      end
    end

    def text_matches?
      condition = rule['text']
      return true unless condition

      actual = normalize(event['text'])
      expected = normalize(condition['value'])
      return false if actual.empty? || expected.empty?

      case condition['operator']
      when 'exact' then actual == expected
      when 'contains' then actual.include?(expected)
      when 'starts_with' then actual.start_with?(expected)
      else false
      end
    end

    def normalize(value)
      value.to_s.unicode_normalize(:nfc).downcase.gsub(/[[:space:]]+/, ' ').strip
    end
  end
end
