class VetorialAgent::TestSessions
  class Unavailable < StandardError; end
  class Limit < StandardError; end
  class Conflict < StandardError; end

  def initialize(profile, owner)
    @profile, @owner = profile, owner
  end

  def create(input, key)
    raise ArgumentError unless key.to_s.match?(/\A[a-zA-Z0-9_-]{1,100}\z/)
    raise ArgumentError unless (input.keys - %w[revision_id purpose criteria sample_count budget_usd max_turns]).empty?
    revision = @profile.deployment.revisions.find(input.fetch('revision_id'))
    %w[purpose criteria].each { |name| raise ArgumentError unless input[name].is_a?(String) && input[name].strip.length.between?(1, 1000) }
    sample = Integer(input.fetch('sample_count').to_s, 10)
    turns = Integer(input.fetch('max_turns', 5).to_s, 10)
    usd = input.fetch('budget_usd', '0.05').to_s
    raise ArgumentError unless usd.match?(/\A0(?:\.\d{1,6})?\z/)
    ceiling = (BigDecimal(usd) * 1_000_000).to_i
    raise ArgumentError unless sample.between?(3, 5) && turns.between?(1, 20) && ceiling.between?(1, 500_000)
    fingerprint = Digest::SHA256.hexdigest(input.sort.to_h.to_json)
    session = nil
    @profile.with_lock do
      session = VetorialAgent::TestSession.find_by(profile: @profile, owner: @owner, idempotency_key: key)
      if session
        raise Conflict unless session.input_sha256 == fingerprint
      else
        session = VetorialAgent::TestSession.create!(profile: @profile, owner: @owner, revision: revision,
          idempotency_key: key, input_sha256: fingerprint, sha256: revision.sha256, expires_at: 30.minutes.from_now,
          plan: { 'snapshot' => revision.payload.deep_dup, 'purpose' => input['purpose'], 'criteria' => input['criteria'],
                  'sample_count' => sample, 'ceiling' => ceiling, 'max_turns' => turns })
      end
    end
    session.with_lock do
      if session.state == 'pending'
        bridge('/test_sessions/manage', session.plan.merge('action' => 'create', 'session_id' => session.id,
          'actor_id' => session.owner_id, 'deployment_id' => @profile.deployment_id,
          'revision' => session.plan['snapshot']['revision'], 'role' => @profile.role))
        session.update!(state: 'open')
      end
    end
    show(session)
  end

  def show(session)
    budget = bridge('/test_sessions/manage', { action: 'show', session_id: session.id })
    { id: session.id, revision_id: session.revision_id, sha256: session.sha256, state: session.state,
      expires_at: session.expires_at, messages: session.messages, budget: budget,
      purpose: session.plan['purpose'], criteria: session.plan['criteria'], sample_count: session.plan['sample_count'] }
  end

  def close(session)
    session.with_lock do
      bridge('/test_sessions/manage', { action: 'close', session_id: session.id })
      session.update!(state: 'closed')
    end
    show(session)
  end

  def turn(session, text, key)
    raise ArgumentError unless text.is_a?(String) && text.bytesize.between?(1, 16_384)
    raise ArgumentError unless key.to_s.match?(/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/)
    session.with_lock do
      old = session.messages.find { |m| m['request_id'] == key }
      raise Conflict if old && old['text'] != text
      if old && old['status'] == 'completed'
        return show(session)
      end
      raise Limit unless old || (session.state == 'open' && session.expires_at > Time.current)
      unless old
        old = { 'request_id' => key, 'text' => text, 'status' => 'unknown' }
        session.update!(messages: session.messages + [old])
      end
    end
    # Commit the unknown intent before HTTP. Runtime deduplicates a lost ACK.
    result = bridge("/test_sessions/#{session.id}/turns", { request_id: key, text: text })
    session.with_lock do
      history = session.messages.deep_dup
      message = history.find { |m| m['request_id'] == key }
      message.merge!('status' => 'completed', 'response' => result)
      session.update!(messages: history)
    end
    show(session)
  end

  private

  def bridge(path, input)
    url = ENV['VETORIAL_AGENT_URL']
    raise Unavailable if url.blank? || VetorialAgent::Policy.secret.bytesize < 32
    body = input.to_json
    response = HTTParty.post("#{url.delete_suffix('/')}#{path}", body: body,
      headers: VetorialAgent::Signature.headers(body, path: path), timeout: 10)
    raise Limit if response.code == 429
    raise Unavailable unless response.code == 200
    JSON.parse(response.body).fetch('data')
  rescue JSON::ParserError, KeyError, IOError, SystemCallError, Timeout::Error
    raise Unavailable
  end
end
