# frozen_string_literal: true

# Daily second chance for WhatsApp contact pictures: without it a contact is
# only looked up again when a new message arrives. Queues a fetch for every
# Evolution contact whose picture is due (see Whatsapp::ContactIdentitySync).
class Whatsapp::ContactAvatarSweepJob < ApplicationJob
  queue_as :scheduled_jobs

  PHONE_SOURCE_ID = /\A\d{7,15}\z/

  def perform(limit: 500)
    queued = 0
    Channel::Whatsapp.where(provider: 'evolution').find_each do |channel|
      next unless channel.inbox

      ContactInbox.where(inbox_id: channel.inbox.id).includes(:contact).find_each do |contact_inbox|
        return if queued >= limit

        queued += 1 if queue_fetch(channel, contact_inbox)
      end
    end
  end

  private

  def queue_fetch(channel, contact_inbox)
    contact = contact_inbox.contact
    return false unless contact && !contact.group?
    return false unless contact_inbox.source_id.to_s.match?(PHONE_SOURCE_ID)
    return false unless Whatsapp::ContactIdentitySync.avatar_due?(contact)

    Whatsapp::EvolutionHandlers::AvatarEnqueueGuard.enqueue_avatar_fetch(
      contact_id: contact.id, phone_number: contact_inbox.source_id, channel_id: channel.id, jitter: true
    ).present?
  end
end
