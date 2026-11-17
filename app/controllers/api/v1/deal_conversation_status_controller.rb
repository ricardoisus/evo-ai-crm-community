# frozen_string_literal: true

# GET  /deals/:deal_id/conversation_status  -> há conversa ativa? posso iniciar?
# POST /deals/:deal_id/conversation         -> retorna a ativa ou cria (sem enviar mensagem)
class Api::V1::DealConversationStatusController < Api::V1::BaseController
  require_permissions({ show: 'pipelines.read', create: 'pipelines.update' })

  before_action :set_deal
  before_action :authorize_deal

  def show
    success_response(data: Deals::ConversationService.new(@deal).status)
  end

  def create
    conversation, created = Deals::ConversationService.new(@deal).open_or_start!(inbox_id: params[:inbox_id])
    data = Deals::ConversationService.new(@deal.reload).status.merge(created: created, conversation_id: conversation.id)
    success_response(data: data, message: created ? 'Conversation started' : 'Active conversation found',
                     status: created ? :created : :ok)
  rescue Deals::ConversationService::Error => e
    error_response(e.code, e.message, details: e.details, status: e.status)
  end

  private

  def set_deal
    @deal = PipelineItem.find(params[:deal_id])
  end

  def authorize_deal
    authorize @deal.pipeline, action_name == 'show' ? :view? : :update? unless service_authenticated?
  end
end
