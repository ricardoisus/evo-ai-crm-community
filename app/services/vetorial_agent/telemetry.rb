class VetorialAgent::Telemetry
  class Invalid < StandardError; end
  class Conflict < StandardError; end

  COMMON = %w[event_id deployment_id kind occurred_ms].freeze
  FIELDS = {
    'execution' => %w[execution_id conversation_id role source revision policy_epoch status latency_ms outcome],
    'usage' => %w[call_id execution_id source provider model input_tokens cached_tokens output_tokens reasoning_tokens cost_micro_usd usage_state],
    'heartbeat' => %w[instance_id revision policy_epoch sha256 integrations]
  }.freeze
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
  INTEGRATIONS = %w[openai groq calendly google_gateway].freeze

  def initialize(events, idempotency_key:)
    @events = events
    @key = idempotency_key.to_s
  end

  def call
    raise Invalid unless @events.is_a?(Array) && @events.size.between?(1, 100) && @key.present? && @key.bytesize <= 255

    sanitized = @events.map { |event| validate(event) }
    deployment = deployment_for(sanitized)
    request_sha = Digest::SHA256.hexdigest(JSON.generate(sanitized))
    result = nil
    deployment.with_lock { result = replay_or_ingest(deployment, sanitized, request_sha) }
    result
  end

  private

  def deployment_for(events)
    deployment_id = events.first['deployment_id']
    raise Invalid unless events.all? { |event| event['deployment_id'] == deployment_id }

    VetorialAgent::Deployment.find(deployment_id)
  end

  def replay_or_ingest(deployment, events, request_sha)
    previous = deployment.audits.find_by(action: 'telemetry', idempotency_key: @key)
    if previous && previous.expires_at > Time.current
      raise Conflict unless previous.request_sha256 == request_sha

      return previous.response
    end
    previous&.destroy!
    response = { 'acknowledged' => events.map { |event| ingest(deployment, event) } }
    deployment.audits.create!(action: 'telemetry', idempotency_key: @key, request_sha256: request_sha,
                              response: response, expires_at: 24.hours.from_now)
    response
  end

  def validate(value)
    raise Invalid unless value.is_a?(Hash)

    event = value.deep_stringify_keys
    kind = event['kind']
    raise Invalid unless FIELDS.key?(kind) && event.keys.sort == (COMMON + FIELDS.fetch(kind)).sort

    %w[event_id deployment_id].each { |key| uuid!(event[key]) }
    integer!(event['occurred_ms'])
    send("validate_#{kind}", event)
    event
  end

  def validate_execution(event)
    %w[execution_id conversation_id].each { |key| uuid!(event[key]) }
    %w[revision policy_epoch latency_ms].each { |key| integer!(event[key]) }
    enum!(event['role'], %w[atendimento analista])
    enum!(event['source'], %w[live test])
    enum!(event['status'], %w[succeeded failed discarded uncertain])
    enum!(event['outcome'], %w[none send_confirmed booking_confirmed paused resumed])
  end

  def validate_usage(event)
    %w[call_id execution_id].each { |key| uuid!(event[key]) }
    %w[input_tokens cached_tokens output_tokens reasoning_tokens].each { |key| integer!(event[key]) }
    enum!(event['source'], %w[live test])
    enum!(event['provider'], %w[openai groq])
    enum!(event['model'], %w[gpt-6-luna gpt-6.1-sol whisper-large-v3-turbo])
    enum!(event['usage_state'], %w[known unknown])
    raise Invalid if event['cached_tokens'] > event['input_tokens'] || event['reasoning_tokens'] > event['output_tokens']

    event['usage_state'] == 'known' ? integer!(event['cost_micro_usd']) : (raise Invalid unless event['cost_micro_usd'].nil?)
  end

  def validate_heartbeat(event)
    uuid!(event['instance_id'])
    integer!(event['revision'])
    integer!(event['policy_epoch'])
    raise Invalid unless event['sha256'].is_a?(String) && event['sha256'].match?(/\A[0-9a-f]{64}\z/)
    raise Invalid unless event['integrations'].is_a?(Hash) && event['integrations'].keys.sort == INTEGRATIONS.sort

    event['integrations'].each_value { |value| enum!(value, %w[configured absent error unverified]) }
  end

  def ingest(deployment, event)
    # event_id is globally unique; serialize cross-deployment collisions before lookup.
    lock_id = Digest::SHA256.digest(event['event_id']).unpack1('q>')
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{lock_id})")
    sha = Digest::SHA256.hexdigest(JSON.generate(event))
    receipt = VetorialAgent::TelemetryEvent.find_by(event_id: event['event_id'])
    if receipt
      raise Conflict unless receipt.deployment_id == deployment.id && receipt.payload_sha256 == sha

      return event['event_id']
    end

    occurred_at = Time.at(event['occurred_ms'] / 1000.0).utc
    persist_event(deployment, event, occurred_at)
    deployment.telemetry_events.create!(event_id: event['event_id'], kind: event['kind'], payload_sha256: sha, occurred_at: occurred_at)
    event['event_id']
  end

  def persist_event(deployment, event, occurred_at)
    case event['kind']
    when 'execution'
      deployment.executions.create!(event.slice(*FIELDS['execution']).merge(occurred_at: occurred_at))
    when 'usage'
      deployment.usages.create!(event.slice(*FIELDS['usage']).merge(occurred_at: occurred_at))
    when 'heartbeat'
      status = VetorialAgent::RuntimeStatus.find_or_initialize_by(deployment: deployment, instance_id: event['instance_id'])
      status.update!(revision: event['revision'], policy_epoch: event['policy_epoch'], sha256: event['sha256'],
                     integrations: event['integrations'], heartbeat_at: occurred_at)
    end
  end

  def uuid!(value)
    raise Invalid unless value.is_a?(String) && value.match?(UUID)
  end

  def integer!(value)
    raise Invalid unless value.is_a?(Integer) && value >= 0 && value <= ((2**63) - 1)
  end

  def enum!(value, allowed)
    raise Invalid unless allowed.include?(value)
  end
end
