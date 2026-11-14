# All challenges are persisted and consumed under the deployment mutation lock.
class VetorialAgent::Activation
  def initialize(profile, actor_id:)
    @profile, @deployment, @actor_id = profile, profile.deployment, actor_id
  end

  def challenge
    @deployment.with_lock do
      raise VetorialAgent::Configuration::Conflict unless @deployment.control_source == 'crm'
      nonce = SecureRandom.hex(32)
      @deployment.audits.create!(action: 'activation_challenge', idempotency_key: Digest::SHA256.hexdigest(nonce),
        actor_id: @actor_id, request_sha256: @deployment.active_revision.sha256,
        response: { profile_id: @profile.id, used: false }, expires_at: 60.seconds.from_now)
      { nonce: nonce, expires_in: 60, phrase: 'ATIVAR PARA TODOS' }
    end
  end

  def apply(input)
    mode = input.fetch('mode')
    raise ArgumentError unless %w[off pilot all].include?(mode)
    raise VetorialAgent::Configuration::Conflict unless @deployment.control_source == 'crm' || mode == 'off'
    if @deployment.control_source != 'crm' && %w[allowlist internal_numbers].any? { |key| input.key?(key) }
      raise VetorialAgent::Configuration::Conflict
    end
    if mode == 'all'
      challenge = @deployment.audits.find_by(action: 'activation_challenge', idempotency_key: Digest::SHA256.hexdigest(input['nonce'].to_s))
      raise ArgumentError unless challenge && challenge.actor_id == @actor_id && challenge.expires_at > Time.current &&
        challenge.request_sha256 == @deployment.active_revision.sha256 && challenge.response['profile_id'] == @profile.id &&
        challenge.response['used'] == false && input['phrase'] == 'ATIVAR PARA TODOS' && input['confirm'] == true
      challenge.update!(response: challenge.response.merge('used' => true))
    end
    payload = @deployment.payload.deep_dup
    payload['activation'][@profile.role] = mode
    %w[allowlist internal_numbers].each { |key| payload['activation'][key] = input[key] if input.key?(key) }
    VetorialAgent::Configuration.new(@deployment, actor_id: @actor_id).replace(payload)
  end
end
