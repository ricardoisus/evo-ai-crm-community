class VetorialAgent::DispatchJob < ApplicationJob
  queue_as :high

  def perform
    recover_commands
    url = ENV.fetch('VETORIAL_AGENT_URL', nil)
    return if url.blank? || VetorialAgent::Policy.secret.bytesize < 32

    VetorialAgent::Event.where(delivered_at: nil).order(:created_at).limit(100).each do |event|
      dispatch(event, url.delete_suffix('/'))
    end
  end

  private

  def recover_commands
    VetorialAgent::Command.where(kind: 'send', status: 'pending').where('created_at < ?', 30.seconds.ago).limit(100).pluck(:id).each do |id|
      VetorialAgent::SendJob.perform_later(id)
    end
    # A crash after send intent cannot be retried automatically. Pause for reconciliation.
    VetorialAgent::Command.where(kind: 'send', status: 'sending').where('updated_at < ?', 2.minutes.ago).find_each do |command|
      quarantine(command)
    end
  end

  def quarantine(command)
    command.conversation.with_lock do
      next unless command.reload.status == 'sending'

      command.update!(status: 'uncertain')
      state = VetorialAgent::State.find_by!(conversation: command.conversation)
      state.update!(version: state.version + 1, paused: true, reason: 'envio_incerto')
      VetorialAgent::Capture.persist(command.conversation, state, 'human')
    end
  end

  def dispatch(event, url)
    event.with_lock do
      next if event.delivered_at

      body = event.payload.merge(event_id: event.id).to_json
      response = HTTParty.post("#{url}/events", body: body, headers: VetorialAgent::Signature.headers(body), timeout: 5)
      raise 'Vetorial agent delivery failed' unless response.code == 202

      event.update!(delivered_at: Time.current)
    end
  end
end
