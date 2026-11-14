class AgentBots::InactivityCheckSchedulerJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    Rails.logger.info '[InactivityScheduler] === Starting inactivity check ==='

    # Busca todos os agent_bots que têm inactivity_actions configuradas
    agent_bots_with_actions = AgentBot.where("bot_config -> 'inactivity_actions' IS NOT NULL")
                                       .where("jsonb_array_length(bot_config -> 'inactivity_actions') > 0")

    Rails.logger.info "[InactivityScheduler] Found #{agent_bots_with_actions.count} agent bots with inactivity actions"

    agent_bots_with_actions.find_each do |agent_bot|
      process_agent_bot_conversations(agent_bot)
    end

    Rails.logger.info '[InactivityScheduler] === Inactivity check completed ==='
  end

  private

  def process_agent_bot_conversations(agent_bot)
    return if VetorialAgent::Deployment.managed_bot?(agent_bot.id)
    Rails.logger.info "[InactivityScheduler] Processing agent bot: #{agent_bot.name} (ID: #{agent_bot.id})"

    # Pega as inboxes que usam este bot
    inbox_ids = agent_bot.agent_bot_inboxes.active.pluck(:inbox_id)

    if inbox_ids.empty?
      Rails.logger.debug "[InactivityScheduler] No active inboxes for bot #{agent_bot.id}"
      return
    end

    # Busca conversas abertas/pendentes nestas inboxes
    # Adiciona um threshold mínimo para evitar processar conversas muito recentes
    min_time_ago = 1.minute.ago # Só processa se pelo menos 1 minuto sem atividade

    conversations = Conversation.where(inbox_id: inbox_ids)
                                 .where(status: [:open, :pending])
                                 .where('last_activity_at < ?', min_time_ago)

    Rails.logger.info "[InactivityScheduler] Found #{conversations.count} conversations to check for bot #{agent_bot.id}"

    # Agenda job para processar cada conversa
    conversations.find_each(batch_size: 100) do |conversation|
      AgentBots::ProcessInactivityActionsJob.perform_later(conversation.id, agent_bot.id)
    end
  end
end
