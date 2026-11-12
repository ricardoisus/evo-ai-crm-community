# Hooks run inside the source transaction, including U8's inert observations.
module VetorialAgent::Capture
  def self.message(message)
    conversation = message.conversation
    return unless VetorialAgent::Policy.scoped?(conversation) && public_message?(message)

    conversation.with_lock do
      state = VetorialAgent::State.find_or_create_by!(conversation: conversation)
      state.version += 1
      pause_for_policy(state, conversation)
      if message.outgoing?
        state.paused = true
        state.reason = 'humano'
      end
      state.save!
      persist(conversation, state, message.incoming? ? 'incoming' : 'human', message)
    end
  end

  def self.public_message?(message)
    !message.private? && !message.activity? && message.sender_type != 'AgentBot' && !message.content_attributes['vetorial_agent'] &&
      (message.incoming? || message.outgoing?)
  end

  def self.pause_for_policy(state, conversation)
    return if VetorialAgent::Policy.eligible?(conversation)

    state.paused = true
    state.reason = 'fora_da_lista'
  end

  def self.resume?(conversation)
    before, after = conversation.saved_change_to_label_list || [[], []]
    (Array(after) - Array(before)).include?('ia-ativa') && VetorialAgent::Policy.allowed?(conversation)
  end

  def self.assignment(conversation)
    return unless VetorialAgent::Policy.scoped?(conversation)

    human = conversation.saved_change_to_assignee_id? && conversation.assignee_id.present?
    return unless human || resume?(conversation)

    conversation.with_lock do
      state = VetorialAgent::State.find_or_create_by!(conversation: conversation)
      state.update!(version: state.version + 1, paused: human, reason: human ? 'atribuicao_humana' : nil)
      persist(conversation, state, human ? 'human' : 'resume')
    end
  end

  def self.persist(conversation, state, kind, message = nil)
    state_view = { 'version' => state.version, 'paused' => state.paused, 'reason' => state.reason }
    state_labels(conversation, state)
    # Derived status only; update_columns avoids recursively triggering assignment/automation callbacks.
    conversation.update_columns(custom_attributes: conversation.custom_attributes.merge('vetorial_ia' => state_view)) # rubocop:disable Rails/SkipsModelValidations
    VetorialAgent::Event.create!(conversation: conversation, payload: event_payload(conversation, state, kind, message))
  end

  def self.event_payload(conversation, state, kind, message)
    {
      inbox_id: conversation.inbox_id, conversation_id: conversation.id, message_id: message&.id || "#{conversation.id}:state-#{state.version}",
      version: state.version, paused: state.paused, kind: kind, phone: conversation.contact.phone_number,
      audio: message&.attachments&.any?(&:audio?) || false, occurred_at: Time.current.to_f
    }
  end

  def self.state_labels(conversation, state)
    conversation.remove_labels(state.paused ? %w[ia-ativa ia-em-atendimento] : ['ia-pausada'])
    label = state.paused ? 'ia-pausada' : 'ia-em-atendimento'
    conversation.add_labels([label]) unless conversation.label_list.include?(label)
    pipeline_id = ENV.fetch('VETORIAL_AGENT_PIPELINE_ID', nil)
    return if pipeline_id.blank?

    conversation.pipeline_items.active.where(pipeline_id: pipeline_id).find_each do |item|
      item.remove_labels(state.paused ? ['ia-em-atendimento'] : ['ia-pausada'])
      item.add_labels([label])
    end
  end
end
