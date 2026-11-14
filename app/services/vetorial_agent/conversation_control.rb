class VetorialAgent::ConversationControl
  def self.call(conversation, action:, version:, actor_id:, clear_assignee: false)
    raise ArgumentError unless %w[pause resume].include?(action)
    conversation.with_lock do
      deployment = VetorialAgent::Deployment.for_conversation(conversation)
      raise ActiveRecord::RecordNotFound unless deployment
      state = VetorialAgent::State.find_or_create_by!(conversation: conversation)
      raise VetorialAgent::Configuration::Conflict unless state.version == version
      if action == 'resume'
        raise VetorialAgent::Configuration::Conflict unless deployment.eligible?(conversation)
        raise VetorialAgent::Configuration::Conflict if conversation.assignee_id.present? && !clear_assignee
        # Deliberately bypass only assignment callbacks; no status/read change.
        conversation.update_columns(assignee_id: nil) if clear_assignee && conversation.assignee_id.present? # rubocop:disable Rails/SkipsModelValidations
      end
      state.update!(version: state.version + 1, paused: action == 'pause', reason: action == 'pause' ? 'pausa_manual' : nil)
      VetorialAgent::Capture.persist(conversation, state, action == 'pause' ? 'human' : 'resume')
      { version: state.version, paused: state.paused, reason: state.reason, actor_id: actor_id }
    end
  end
end
