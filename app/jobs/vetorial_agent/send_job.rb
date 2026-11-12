class VetorialAgent::SendJob < ApplicationJob
  queue_as :high

  def perform(id)
    command = VetorialAgent::Command.find(id)
    ready = with_locks(command) do
      next false unless command.reload.status == 'pending'

      unless sendable?(command)
        command.update!(status: 'discarded')
        next false
      end
      # Commit intent before provider POST; crash in the uncertainty window is quarantined.
      command.update!(status: 'sending')
      true
    end
    deliver(command) if ready
  end

  private

  def with_locks(command, &)
    # Same lock order as U8 ingress. Its echo cannot overtake source_id reconciliation.
    command.conversation.inbox.channel.with_lock { command.conversation.with_lock(&) }
  end

  def sendable?(command)
    state = VetorialAgent::State.find_by!(conversation: command.conversation)
    ENV['VETORIAL_AGENT_SEND_ENABLED'] == 'true' && VetorialAgent::Policy.allowed?(command.conversation) &&
      !state.paused && state.version == command.payload['version']
  end

  def deliver(command)
    with_locks(command) do
      unless sendable?(command)
        command.update!(status: 'discarded')
        next
      end
      message = Message.find(command.result.fetch('message_id'))
      source_id = VetorialAgent::Transport.new(command.conversation).send_text(message.content)
      message.update!(source_id: source_id, status: :sent)
      command.update!(status: 'sent')
    end
  rescue StandardError
    quarantine(command) # Never log provider exceptions (can contain headers/PII).
  end

  def quarantine(command)
    command.conversation.with_lock do
      command.update!(status: 'uncertain')
      state = VetorialAgent::State.find_by!(conversation: command.conversation)
      state.update!(version: state.version + 1, paused: true, reason: 'envio_incerto')
      VetorialAgent::Capture.persist(command.conversation, state, 'human')
    end
  end
end
