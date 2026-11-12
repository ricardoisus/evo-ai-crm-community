module VetorialAgent::ProfileView
  def self.summary(profile)
    deployment = profile.deployment
    payload = deployment.payload
    role = payload.fetch('roles').fetch(profile.role)
    statuses = VetorialAgent::RuntimeStatus.where(deployment: deployment).order(heartbeat_at: :desc)
    runtime = statuses.first
    health = if runtime.nil?
               'unavailable'
             elsif runtime.heartbeat_at < 90.seconds.ago
               'unavailable'
             elsif runtime.sha256 != deployment.active_revision.sha256
               'awaiting_configuration'
             elsif runtime.heartbeat_at < 45.seconds.ago
               'delayed'
             else
               'healthy'
             end
    { id: profile.id, catalog_id: "vetorial_runtime:#{profile.id}", source: 'vetorial_runtime', type: 'external',
      provider: 'vetorial_runtime', name: profile.name, description: profile.description, role: profile.role,
      model: role['model'], prompt_version: role['prompt_version'], mode: payload['activation'][profile.role], health: health,
      applied_revision: runtime&.applied_revision_id, updated_at: deployment.updated_at,
      capabilities: { read: true, delete: false, clone: false, share: false, sync_evolution: false } }
  end
end
