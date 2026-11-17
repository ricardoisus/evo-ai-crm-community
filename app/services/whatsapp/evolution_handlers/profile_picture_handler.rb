# frozen_string_literal: true

# Schedules a contact's WhatsApp profile picture fetch on the Evolution API
# inbound flow. Mirrors Whatsapp::EvolutionGoHandlers::ProfilePictureHandler so
# that any provider with proactive avatar fetching follows the same pattern.
module Whatsapp::EvolutionHandlers::ProfilePictureHandler
  include Whatsapp::EvolutionHandlers::Helpers

  private

  def update_contact_profile_picture(contact, phone_number)
    return if contact.blank?
    return if phone_number.blank?

    channel = inbox&.channel
    return unless channel

    Whatsapp::ContactIdentitySync.new(contact).schedule_avatar(channel, phone_number)
  rescue StandardError => e
    Rails.logger.error "Evolution API: Failed to schedule avatar fetch for contact #{contact.id}: #{e.message}"
  end
end
