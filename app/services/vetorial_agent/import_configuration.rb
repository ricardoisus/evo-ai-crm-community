# Explicitly consumes an in-memory snapshot produced from the A14 export tool.
# No production reads, env changes or native bot/inbox creation.
class VetorialAgent::ImportConfiguration
  def self.call(payload, dry_run: true)
    VetorialAgent::Snapshot.validate!(payload)
    hash = VetorialAgent::Snapshot.digest(payload)
    return { 'sha256' => hash, 'dry_run' => true } if dry_run
    VetorialAgent::Deployment.transaction do
      deployment = VetorialAgent::Deployment.find_or_create_by!(slug: 'vetorial') do |d|
        d.id = payload.fetch('deployment_id')
        d.agent_bot_id = payload.fetch('binding').fetch('agent_bot_id')
      end
      deployment.with_lock do
        raise VetorialAgent::Configuration::Conflict unless deployment.id == payload['deployment_id'] &&
          deployment.agent_bot_id == payload['binding']['agent_bot_id']
        if deployment.active_revision
          raise VetorialAgent::Configuration::Conflict unless deployment.active_revision.sha256 == hash
          next deployment
        end
        raise VetorialAgent::Configuration::Conflict unless payload['revision'] == 1 && payload['policy_epoch'] == 1
        inbox = Inbox.find(payload['binding']['inbox_ids'].sole)
        raise ArgumentError unless inbox.channel.is_a?(Channel::Whatsapp) && inbox.channel.evolution_attached?
        revision = deployment.revisions.create!(number: 1, payload: payload, sha256: hash, status: 'published', published_at: Time.current)
        deployment.update!(active_revision: revision)
        { 'atendimento' => 'Ricardo IA', 'analista' => 'Analista do pipeline' }.each do |role, name|
          deployment.profiles.create!(role: role, name: name)
        end
        deployment
      end
    end
  end
end
