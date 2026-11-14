class VetorialAgent::Binding
  # Deliberately separate from schema/import. Operator must verify ALL CRM/Sidekiq
  # tasks run the new digest first. A flag alone cannot establish that invariant.
  def self.attach!(deployment, inventory:, digest:)
    deployment.with_lock do
      raise VetorialAgent::Configuration::Conflict unless deployment.guard_ready
      VetorialAgent::TaskInventory.verify!(inventory.call, digest)
      inbox = Inbox.find(deployment.payload.fetch('binding').fetch('inbox_ids').sole)
      inbox.with_lock do
        existing = inbox.agent_bot_inbox
        raise VetorialAgent::Configuration::Conflict if existing && existing.agent_bot_id != deployment.agent_bot_id
        existing || AgentBotInbox.create!(inbox: inbox, agent_bot: deployment.agent_bot, status: :active)
      end
    end
  end
end
