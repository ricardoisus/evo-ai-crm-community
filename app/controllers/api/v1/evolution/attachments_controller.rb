# frozen_string_literal: true

class Api::V1::Evolution::AttachmentsController < Api::V1::BaseController
  require_permissions({ create: 'inboxes.create', destroy: 'inboxes.update' })

  def create
    box = service.perform
    render json: { inbox_id: box.id, state: box.channel.provider_config['attachment_state'] }, status: :created
  rescue Evolution::AttachExistingInstance::Conflict, Evolution::ExistingInstanceClient::Error, ActiveRecord::RecordInvalid => e
    render json: { error: e.is_a?(ActiveRecord::RecordInvalid) ? 'Caixa inválida' : e.message }, status: :conflict
  end

  def destroy
    channel = Channel::Whatsapp.find(params[:id])
    box = service.detach(channel)
    render json: { inbox_id: box.id, state: 'detached' }
  rescue Evolution::AttachExistingInstance::Conflict, Evolution::ExistingInstanceClient::Error => e
    render json: { error: e.message }, status: :conflict
  end

  private

  def service
    Evolution::AttachExistingInstance.new(instance_name: params.require(:instance_name),
                                          phone_number: params.require(:phone_number), name: params.require(:name))
  end
end
