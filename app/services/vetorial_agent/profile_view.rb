module VetorialAgent::ProfileView
  def self.health(deployment)
    payload = deployment.payload
    statuses = VetorialAgent::RuntimeStatus.where(deployment: deployment).order(heartbeat_at: :desc)
    runtime = statuses.first
    if runtime.nil? || runtime.heartbeat_at < 90.seconds.ago || runtime.heartbeat_at > Time.current
      'unavailable'
    elsif runtime.sha256 != deployment.active_revision.sha256 || runtime.revision != payload['revision'] || runtime.policy_epoch != deployment.policy_epoch
      'awaiting_configuration'
    elsif runtime.heartbeat_at < 45.seconds.ago
      'delayed'
    else
      'healthy'
    end
  end

  def self.summary(profile)
    deployment = profile.deployment
    payload = deployment.payload
    role = payload.fetch('roles').fetch(profile.role)
    runtime = VetorialAgent::RuntimeStatus.where(deployment: deployment).order(heartbeat_at: :desc).first
    health = health(deployment)
    { id: profile.id, catalog_id: "vetorial_runtime:#{profile.id}", source: 'vetorial_runtime', type: 'external',
      provider: 'vetorial_runtime', name: profile.name, description: profile.description, role: profile.role,
      model: role['model'], prompt_version: role['prompt_version'], mode: payload['activation'][profile.role], health: health,
      applied_revision: runtime&.applied_revision_id, applied_version: runtime&.revision,
      desired_version: payload['revision'], updated_at: deployment.updated_at,
      capabilities: { read: true, delete: false, clone: false, share: false, sync_evolution: false } }
  end
end
