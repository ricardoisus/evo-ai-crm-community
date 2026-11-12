# Deliberately separate from service-token/global CRUD APIs. HMAC + fixed inbox.
class Internal::VetorialAgentController < ActionController::API
  before_action :authenticate_bridge

  def show
    snapshot = @conversation.with_lock do
      state = VetorialAgent::State.find_or_create_by!(conversation: @conversation)
      page = history_page
      state_snapshot(state).merge(messages: page.reverse.map { |message| history_message(message) }, next_before: cursor(page))
    end
    render json: snapshot
  rescue ArgumentError
    head :unprocessable_entity
  end

  def create
    result = VetorialAgent::Bridge.new(@conversation).call(params.require(:command).permit!.to_h)
    render json: result
  rescue VetorialAgent::Bridge::Rejected
    render json: { sucesso: false, erro: 'estado_ou_politica' }, status: :conflict
  rescue ArgumentError, ActiveRecord::RecordInvalid
    render json: { sucesso: false, erro: 'comando_invalido' }, status: :unprocessable_entity
  end

  private

  def state_snapshot(state)
    item = @conversation.pipeline_items.active.find_by(pipeline_id: ENV.fetch('VETORIAL_AGENT_PIPELINE_ID', nil))
    {
      version: state.version, paused: state.paused, allowed: VetorialAgent::Policy.allowed?(@conversation),
      eligible: VetorialAgent::Policy.eligible?(@conversation), nome_contato: @conversation.contact.name,
      campos_negocio: state.fields.merge(item&.custom_fields || {}).merge(
        'etapa_atual' => item&.pipeline_stage&.name, 'etapa_definida_por_humano' => human_stage?(item)
      )
    }
  end

  def human_stage?(item)
    item.present? && item.stage_movements.where.not(moved_by_id: nil).exists?
  end

  def history_page
    messages = @conversation.messages.where(private: false, message_type: [:incoming, :outgoing])
    messages = messages.where("sender_type IS DISTINCT FROM 'AgentBot' OR (source_id IS NOT NULL AND source_id <> '')")
    if params[:before].present?
      at, id = params[:before].split('|', 2)
      raise ArgumentError unless id.to_s.match?(/\A[0-9a-f-]{36}\z/)

      messages = messages.where('(created_at, id) < (?, ?)', Time.iso8601(at), id)
    end
    messages.order(created_at: :desc, id: :desc).limit(50).to_a
  end

  def cursor(page)
    "#{page.last.created_at.iso8601(6)}|#{page.last.id}" if page.size == 50
  end

  def authenticate_bridge
    valid = VetorialAgent::Signature.valid?(request.raw_post, request.headers, method: request.request_method, path: request.path)
    return head :unauthorized unless valid

    @conversation = Conversation.find_by(id: params[:conversation_id])
    head :not_found unless @conversation && VetorialAgent::Policy.scoped?(@conversation)
  end

  def history_message(message)
    attachments = message.attachments.select { |attachment| attachment.file.attached? }.map { |attachment| media_metadata(attachment) }
    {
      id: message.id, role: message.incoming? ? 'user' : 'assistant', content: message.content.to_s,
      created_at: message.created_at.iso8601(6), media_unavailable: message.content_attributes['media_unavailable'], attachments: attachments
    }
  end

  def media_metadata(attachment)
    { id: attachment.id, mime: attachment.file.blob.content_type, bytes: attachment.file.blob.byte_size }
  end
end
