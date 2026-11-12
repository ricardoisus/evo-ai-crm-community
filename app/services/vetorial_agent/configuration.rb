# Serialize mutations on deployment, with durable request/response idempotency.
class VetorialAgent::Configuration
  class Conflict < StandardError; end

  def initialize(deployment, actor_id: nil)
    @deployment, @actor_id = deployment, actor_id
  end

  def mutate(action:, key:, expected_version:, input:)
    raise ArgumentError unless key.to_s.match?(/\A[a-zA-Z0-9:_-]{1,160}\z/)
    request_hash = VetorialAgent::Snapshot.digest('actor_id' => @actor_id, 'input' => input)
    @deployment.with_lock do
      existing = @deployment.audits.find_by(action: action, idempotency_key: key)
      if existing
        raise Conflict unless existing.request_sha256 == request_hash && existing.expires_at > Time.current
        next existing.response
      end
      raise Conflict unless expected_version.to_s == @deployment.lock_version.to_s
      response = yield
      @deployment.touch # increments optimistic lock even for draft-only operations
      @deployment.audits.create!(action: action, idempotency_key: key, actor_id: @actor_id,
                                request_sha256: request_hash, response: response, expires_at: 24.hours.from_now)
      response
    end
  end

  def draft(payload, restored_from_id: nil)
    raise Conflict unless @deployment.control_source == 'crm'
    payload = payload.deep_dup
    current = @deployment.payload
    # Publishing prompts must never expand activation or replace native binding.
    %w[activation binding limits integrations provider runtime].each do |key|
      raise ArgumentError unless payload[key] == current.fetch(key)
    end
    payload.fetch('roles').each do |role, config|
      %w[actions output_schema].each { |key| raise ArgumentError unless config[key] == current.fetch('roles').fetch(role).fetch(key) }
    end
    number = (@deployment.revisions.maximum(:number) || 0) + 1
    payload.merge!('deployment_id' => @deployment.id, 'revision' => number, 'policy_epoch' => @deployment.policy_epoch + 1)
    @deployment.revisions.create!(number: number, payload: payload, sha256: VetorialAgent::Snapshot.digest(payload),
                                  created_by_id: @actor_id, restored_from_id: restored_from_id)
  end

  def publish(revision)
    raise Conflict unless @deployment.control_source == 'crm' && revision.status == 'draft'
    raise Conflict unless revision.deployment_id == @deployment.id && revision.payload['policy_epoch'] == @deployment.policy_epoch + 1
    raise Conflict unless revision.payload['activation'] == @deployment.payload['activation'] && revision.payload['binding'] == @deployment.payload['binding']
    revision.update!(status: 'published', published_at: Time.current)
    @deployment.update!(active_revision: revision, policy_epoch: revision.payload['policy_epoch'])
    revision
  end
end
