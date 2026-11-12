# The hash covers payload only. Lease and transport metadata never enter the digest.
# Shared wire format: UTF-8 JSON, recursively sorted keys, integers only, no whitespace.
module VetorialAgent::Snapshot
  class Invalid < StandardError; end
  MODELS = %w[gpt-6-luna gpt-6.1-sol].freeze
  ROOT_KEYS = %w[schema_version deployment_id revision policy_epoch binding activation roles behavior limits integrations provider runtime].freeze

  def self.canonical(value)
    case value
    when Hash
      raise Invalid unless value.keys.all? { |key| key.is_a?(String) }
      value.keys.sort.to_h { |key| [key, canonical(value[key])] }
    when Array then value.map { |entry| canonical(entry) }
    when String, Integer, TrueClass, FalseClass, NilClass then value
    else raise Invalid, 'A configuração aceita apenas números inteiros.'
    end
  end

  def self.digest(payload)
    Digest::SHA256.hexdigest(JSON.generate(canonical(payload)))
  end

  def self.validate!(payload)
    canonical(payload)
    raise Invalid unless payload.keys.sort == ROOT_KEYS.sort && payload['schema_version'] == 1
    raise Invalid unless payload.values_at('revision', 'policy_epoch').all? { |v| v.is_a?(Integer) && v.positive? }
    raise Invalid unless payload['roles'].keys.sort == %w[analista atendimento]
    payload['roles'].each_value do |role|
      raise Invalid unless role.keys.sort == %w[model prompt prompt_version output_schema actions].sort
      raise Invalid unless MODELS.include?(role['model']) && role['prompt'].is_a?(String) && role['prompt'].bytesize.between?(1, 131072)
    end
    activation = payload.fetch('activation')
    raise Invalid unless activation.keys.sort == %w[atendimento analista allowlist internal_numbers].sort
    raise Invalid unless activation.values_at('atendimento', 'analista').all? { |mode| %w[off pilot all].include?(mode) }
    %w[allowlist internal_numbers].each do |key|
      raise Invalid unless activation[key].is_a?(Array) && activation[key].all? { |phone| phone.match?(/\A\+[1-9]\d{6,14}\z/) }
    end
    raise Invalid if activation.value?('pilot') && activation['allowlist'].empty?
    validate_behavior!(payload.fetch('behavior'))
    # No free-form URLs, authentication fields, or secrets in editable configuration.
    integration = payload.fetch('integrations')
    raise Invalid unless integration.keys.sort == %w[availability_provider event_type calendar_id booking_minutes google_gateway_ref].sort
    raise Invalid unless integration['availability_provider'] == 'calendly' && integration['booking_minutes'] == 45 &&
                         integration['google_gateway_ref'] == 'vetorial-calendar-v1' &&
                         integration['event_type'].match?(%r{\Ahttps://api\.calendly\.com/event_types/[0-9a-f-]{36}\z})
    raise Invalid unless payload.fetch('binding').keys.sort == %w[agent_bot_id inbox_ids pipeline_id].sort
    raise Invalid unless payload['binding']['inbox_ids'].is_a?(Array) && payload['binding']['inbox_ids'].size == 1
    true
  rescue KeyError, NoMethodError, TypeError
    raise Invalid, 'Configuração inválida.'
  end

  def self.validate_behavior!(behavior)
    bounds = { 'text_debounce_ms' => 1000..120000, 'audio_debounce_ms' => 1000..180000,
               'analysis_silence_ms' => 60000..3600000, 'typing_cpm' => 300..3000,
               'first_typing_cap_ms' => 0..30000, 'next_typing_cap_ms' => 0..30000, 'recheck_ms' => 100..1000 }
    raise Invalid unless behavior.keys.sort == (bounds.keys + %w[timezone office_hours]).sort
    bounds.each { |key, range| raise Invalid unless behavior[key].is_a?(Integer) && range.cover?(behavior[key]) }
    raise Invalid unless behavior['timezone'] == 'America/Sao_Paulo'
    # Scheduling windows require a separate validated implementation before enabling.
    raise Invalid unless behavior['office_hours'] == { 'enabled' => false, 'windows' => [] }
  end
end
