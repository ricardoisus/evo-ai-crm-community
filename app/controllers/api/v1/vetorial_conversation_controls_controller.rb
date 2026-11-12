class Api::V1::VetorialConversationControlsController < Api::V1::BaseController
  require_permissions({ show: 'conversations.read', pause: 'conversations.update', resume: 'conversations.update' })
  before_action :load_conversation
  rescue_from VetorialAgent::Configuration::Conflict do
    render json: { success: false, error: { code: 'conversation_conflict', message: 'A conversa mudou ou tem responsável. Atualize a página.' } }, status: :conflict
  end

  def show
    state = VetorialAgent::State.find_by(conversation: @conversation)
    eligible = @deployment.eligible?(@conversation)
    render json: { success: true, data: { version: state&.version || 0, paused: state&.paused || false,
      reason: state&.reason, eligible: eligible, revision: @deployment.payload['revision'] } }
  end

  def pause
    control('pause')
  end

  def resume
    control('resume')
  end

  private

  def load_conversation
    @conversation = Conversation.where(inbox_id: Current.user.assigned_inboxes.select(:id)).find(params[:conversation_id])
    @deployment = VetorialAgent::Deployment.for_conversation(@conversation)
    raise ActiveRecord::RecordNotFound unless @deployment
  end

  def control(action)
    # Removing a human requires the pre-existing assignment permission too.
    # Until that grant is wired/tested, this API never clears an assignee.
    return head :forbidden if params[:clear_assignee] == true
    data = VetorialAgent::ConversationControl.call(@conversation, action: action, version: params.require(:version), actor_id: Current.user.id)
    render json: { success: true, data: data }
  end
end
