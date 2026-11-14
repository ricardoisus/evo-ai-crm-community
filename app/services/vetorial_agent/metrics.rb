class VetorialAgent::Metrics
  ZONE = 'America/Sao_Paulo'.freeze

  def initialize(deployment, source:, from: nil, to: nil, now: Time.current)
    @deployment = deployment
    @source = source.presence || 'live'
    raise ArgumentError unless %w[live test].include?(@source)

    zone = ActiveSupport::TimeZone[ZONE]
    local_now = now.in_time_zone(zone)
    @from = parse_time(from) || local_now.beginning_of_month.utc
    @to = parse_time(to) || local_now.end_of_month.utc
    raise ArgumentError unless @from < @to

    @month_from = local_now.beginning_of_month.utc
    @month_to = local_now.end_of_month.utc
  end

  def call
    executions = @deployment.executions.where(source: @source, occurred_at: @from..@to)
    usages = @deployment.usages.where(source: @source, occurred_at: @from..@to)
    month_usage = @deployment.usages.where(source: @source, occurred_at: @month_from..@month_to)
    send_confirmed = executions.where(outcome: 'send_confirmed')
    known = usages.where(usage_state: 'known')
    month_known = month_usage.where(usage_state: 'known')

    latencies = send_confirmed.order(:latency_ms).pluck(:latency_ms)
    recent = executions.order(occurred_at: :desc).limit(20).map do |execution|
      usage = usages.where(execution_id: execution.execution_id)
      cost = usage.exists? && !usage.where(usage_state: 'unknown').exists? ? usage.sum(:cost_micro_usd) : nil
      { role: execution.role, status: execution.status, revision: execution.revision,
        occurred_at: execution.occurred_at, latency_ms: execution.latency_ms, cost_micro_usd: cost }
    end
    {
      measurement_started_at: @deployment.executions.minimum(:occurred_at),
      latency: { n: latencies.length, p50_ms: percentile(latencies, 0.50), p95_ms: percentile(latencies, 0.95) },
      recent_executions: recent,
      timezone: ZONE, source: @source, from: @from.iso8601, to: @to.iso8601,
      conversations: send_confirmed.distinct.count(:conversation_id),
      responses: send_confirmed.count,
      pauses: executions.where(outcome: 'paused').count,
      returns: executions.where(outcome: 'resumed').count,
      appointments: executions.where(outcome: 'booking_confirmed').count,
      errors: executions.where(status: %w[failed uncertain]).count,
      cost_micro_usd: known.sum(:cost_micro_usd),
      month_cost_micro_usd: month_known.sum(:cost_micro_usd),
      month_usage_known: month_known.count, month_usage_unknown: month_usage.where(usage_state: 'unknown').count,
      usage_known: known.count, usage_unknown: usages.where(usage_state: 'unknown').count,
      input_tokens: known.sum(:input_tokens), cached_tokens: known.sum(:cached_tokens),
      output_tokens: known.sum(:output_tokens), reasoning_tokens: known.sum(:reasoning_tokens)
    }
  end

  private

  def percentile(values, fraction)
    return nil if values.empty?
    values[[(values.length * fraction).ceil - 1, 0].max]
  end

  def parse_time(value)
    return if value.blank?

    Time.iso8601(value).utc
  rescue ArgumentError
    raise ArgumentError
  end
end
