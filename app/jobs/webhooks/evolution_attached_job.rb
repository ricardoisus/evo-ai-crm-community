# frozen_string_literal: true

class Webhooks::EvolutionAttachedJob < ApplicationJob
  queue_as :low
  self.log_arguments = false

  def perform(channel_id, payload)
    channel = Channel::Whatsapp.find(channel_id)
    return unless channel.evolution_attached? && channel.provider_config['attachment_state'].in?(%w[pending active])

    # A row lock covers both directions, lookup, contact/conversation and commit.
    channel.with_lock do
      Whatsapp::AttachedEvolutionMessageService.new(inbox: channel.inbox, params: payload.with_indifferent_access).perform
    end
    Rails.logger.info('[EVOLUTION_ATTACHED] event processed')
  end
end
