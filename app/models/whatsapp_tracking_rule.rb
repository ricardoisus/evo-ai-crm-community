# frozen_string_literal: true

class WhatsappTrackingRule < ApplicationRecord
  TRIGGERS = %w[message_received message_sent stage_entered].freeze
  FREQUENCIES = %w[occurrence contact acquisition].freeze
  OPERATORS = %w[exact contains starts_with].freeze
  MODES = %w[test production].freeze
  FIELDS = %w[trigger frequency filters text event_name destination_id mode].freeze

  belongs_to :inbox
  validates :name, presence: true, length: { maximum: 120 }
  validate :valid_draft

  def publish!
    missing = %w[trigger frequency event_name destination_id mode].reject { |field| draft[field].present? }
    if missing.any?
      errors.add(:draft, :blank, message: "Preencha #{missing.join(', ')}")
      raise ActiveRecord::RecordInvalid, self
    end

    update!(published: draft.deep_dup, active: true)
  end

  def simulate(event)
    return :missing_trigger unless draft['trigger']

    input = event.merge('account_id' => inbox_id, 'inbox_id' => inbox_id)
    WhatsappTracking::RuleMatcher.new(draft.merge('account_id' => inbox_id), input).result
  end

  private

  def valid_draft
    errors.add(:inbox, :invalid) unless inbox&.whatsapp?
    unless draft.is_a?(Hash) && (draft.keys - FIELDS).empty?
      errors.add(:draft, :invalid)
      return
    end

    validate_choice('trigger', TRIGGERS)
    validate_choice('frequency', FREQUENCIES)
    validate_choice('mode', MODES)
    errors.add(:draft, 'Evento Meta inválido') if draft.key?('event_name') && !WhatsappTracking::MetaEvent::EVENT_NAME.match?(draft['event_name'].to_s)
    validate_filters if draft.key?('filters')
    validate_text if draft.key?('text')
    validate_destination if draft.key?('destination_id')
  end

  def validate_choice(key, choices)
    errors.add(:draft, "#{key} inválido") if draft.key?(key) && !choices.include?(draft[key])
  end

  def validate_destination
    return if WhatsappTrackingDestination.exists?(id: draft['destination_id'], inbox_id: inbox_id)

    errors.add(:draft, 'Destino Meta inválido para a caixa')
  end

  def validate_filters
    filters = draft['filters']
    return if filters.is_a?(Hash) && (filters.keys - WhatsappTracking::RuleMatcher::FILTERS.keys).empty? &&
              filters.values.all? { |value| value.is_a?(String) && value.length.between?(1, 120) } &&
              (!filters.key?('inbox_id') || filters['inbox_id'] == inbox_id)

    errors.add(:draft, 'Filtros inválidos')
  end

  def validate_text
    text = draft['text']
    return if draft['trigger'] != 'stage_entered' && text.is_a?(Hash) && text.keys.sort == %w[operator value] &&
              OPERATORS.include?(text['operator']) && text['value'].is_a?(String) && text['value'].strip.length.between?(1, 500)

    errors.add(:draft, 'Condição de texto inválida')
  end
end
