# frozen_string_literal: true

# Async fetch of a contact's WhatsApp profile picture via Evolution API.
# Resolves the picture URL through the provider service and downloads it right
# away (this job already runs in the :low queue, so neither message ingestion
# nor the avatar attach path blocks on a flaky external call).
#
# The outcome (success / no picture) is recorded on the contact so later
# messages do not re-query WhatsApp on every event: see
# Whatsapp::ContactIdentitySync for the backoff and refresh policy.
class Evolution::FetchContactAvatarJob < ApplicationJob
  queue_as :low

  retry_on Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, wait: :polynomially_longer, attempts: 5
  retry_on HTTParty::ResponseError, HTTParty::Error, wait: :polynomially_longer, attempts: 3

  def perform(contact_id, phone_number, channel_id)
    contact = Contact.find_by(id: contact_id)
    return unless contact
    return unless Whatsapp::ContactIdentitySync.avatar_due?(contact)

    channel = Channel::Whatsapp.find_by(id: channel_id)
    return unless channel

    Rails.logger.info "Evolution API: Fetching profile picture URL for contact #{contact.id}"

    profile_picture_url = Whatsapp::Providers::EvolutionService
                          .new(whatsapp_channel: channel)
                          .fetch_profile_picture_url(phone_number)

    if profile_picture_url.blank?
      Rails.logger.debug { "Evolution API: No profile picture available for contact #{contact.id}" }
      Whatsapp::ContactIdentitySync.record_avatar_result(contact, success: false)
      return
    end

    Avatar::AvatarFromUrlJob.perform_now(contact, profile_picture_url)
    Whatsapp::ContactIdentitySync.record_avatar_result(contact, success: contact.reload.avatar.attached?)
  end
end
