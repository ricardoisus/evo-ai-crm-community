# frozen_string_literal: true

# Números de WhatsApp autorizados a iniciar conversa nos negócios de um pipeline.
class Api::V1::PipelineWhatsappInboxesController < Api::V1::BaseController
  require_permissions({ index: 'pipelines.read', update: 'pipelines.update', default: 'pipelines.update' })

  before_action :set_pipeline
  before_action :authorize_pipeline

  def index
    success_response(data: settings.as_json_payload, message: 'WhatsApp inboxes retrieved successfully')
  end

  # PUT /pipelines/:pipeline_id/whatsapp_inboxes  { inbox_ids: [...], default_inbox_id: "..." }
  def update
    payload = settings.replace!(inbox_ids: params[:inbox_ids], default_inbox_id: params[:default_inbox_id])
    success_response(data: payload, message: 'WhatsApp inboxes updated successfully')
  rescue Pipelines::WhatsappInboxSettings::Invalid => e
    error_response(ApiErrorCodes::VALIDATION_ERROR, e.message, status: :unprocessable_entity)
  end

  # PATCH /pipelines/:pipeline_id/whatsapp_inboxes/default  { inbox_id: "..." }
  def default
    success_response(data: settings.set_default!(params[:inbox_id]), message: 'Default inbox updated successfully')
  rescue Pipelines::WhatsappInboxSettings::Invalid => e
    error_response(ApiErrorCodes::VALIDATION_ERROR, e.message, status: :unprocessable_entity)
  end

  private

  def set_pipeline
    @pipeline = Pipeline.find(params[:pipeline_id])
  end

  def settings
    Pipelines::WhatsappInboxSettings.new(@pipeline)
  end

  def authorize_pipeline
    authorize @pipeline, action_name == 'index' ? :view? : :update? unless service_authenticated?
  end
end
