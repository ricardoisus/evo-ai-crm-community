# frozen_string_literal: true

class Webhooks::EvolutionAttachedController < ActionController::API
  def create
    channel = Channel::Whatsapp.where(provider: 'evolution').find_by("provider_config ->> 'instance_name' = ?", params[:instance].to_s)
    return head :unauthorized unless authenticated?(channel)
    return head :conflict unless channel.provider_config['attachment_state'].in?(%w[pending active])

    Webhooks::EvolutionAttachedJob.perform_later(channel.id, params.permit!.to_h.slice('instance', 'event', 'data', 'type').merge('lead_automation_received_at' => Time.current.iso8601(6)))
    head :ok
  end

  private

  def authenticated?(channel)
    token = request.headers['X-Evo-Attach-Token'].to_s
    expected = channel&.provider_config&.dig('attachment_token').to_s
    channel&.evolution_attached? && expected.present? && ActiveSupport::SecurityUtils.secure_compare(expected, token)
  end
end
