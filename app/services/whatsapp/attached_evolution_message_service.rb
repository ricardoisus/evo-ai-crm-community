# frozen_string_literal: true

# Live observations use the existing inert persistence path. A1 can consume this
# stream explicitly; generic automations/bots/read receipts must not run here.
class Whatsapp::AttachedEvolutionMessageService < Whatsapp::IncomingMessageEvolutionService
  MAX_MEDIA_BYTES = 25.megabytes

  def perform
    return unless params[:instance] == inbox.channel.provider_config['instance_name']

    case params[:event]
    when 'messages.upsert'
      receive_message
    when 'messages.update'
      receive_status
    when 'connection.update'
      state = params.dig(:data, :state)
      inbox.channel.update_provider_connection!({ 'connection' => state }) if %w[open close connecting].include?(state)
    end
  end

  private

  def receive_message
    @raw_message = params[:data]
    normalize_lid_alternate!
    return unless processable_observation?

    @message = @contact = @contact_inbox = nil
    set_individual_contact
    @conversation = @contact_inbox.conversations.order(:created_at).last ||
                    @contact_inbox.conversations.create!(inbox: inbox, contact: @contact, source: :imported, status: :open)
    persist_observation
  end

  def normalize_lid_alternate!
    return unless @raw_message.is_a?(Hash) && @raw_message.dig(:key, :remoteJid).to_s.end_with?('@lid')

    alternate = @raw_message.dig(:key, :remoteJidAlt).to_s
    @raw_message[:key][:remoteJid] = alternate if alternate.match?(/\A\d{7,15}@s\.whatsapp\.net\z/)
  end

  def processable_observation?
    @raw_message.is_a?(Hash) && raw_message_id.present? && jid_type == 'user' &&
      [true, false].include?(@raw_message.dig(:key, :fromMe)) && !ignore_message? && !historical? &&
      !inbox.messages.exists?(source_id: raw_message_id)
  end

  def persist_observation
    build_message_attributes
    @message.source = :imported
    @message.status = :sent
    @message.content_attributes = @message.content_attributes.merge(
      'whatsapp_observed' => true, 'evolution_attached' => true,
      'evolution_origin' => incoming? ? 'contact' : 'human_device'
    )
    attach_observed_media if media_attachment?
    @message.save!
  end

  def historical?
    start = inbox.channel.provider_config['attachment_started_at'].to_i
    timestamp = @raw_message[:messageTimestamp].to_i
    timestamp /= 1000 if timestamp > 10**12
    timestamp < start
  end

  def set_individual_contact
    phone = Whatsapp::PhoneNumberNormalizer.to_e164("+#{phone_number_from_jid}")
    @contact_inbox = inbox.contact_inboxes.find_by(source_id: phone.delete_prefix('+'))
    @contact = @contact_inbox&.contact || Contact.find_by(phone_number: phone)
    unless @contact
      @contact = Contact.new(name: contact_name.presence || phone, phone_number: phone)
      @contact.passive_observation = true
      @contact.skip_default_pipeline_assignment = true
      @contact.save!
    end
    return if @contact_inbox

    @contact_inbox = ContactInbox.create!(inbox: inbox, contact: @contact, source_id: phone.delete_prefix('+'))
  end

  def attach_observed_media
    base64 = @raw_message.dig(:message, :base64).to_s.sub(/\Adata:[^;]+;base64,/, '')
    if base64.blank?
      @message.content_attributes['media_unavailable'] = true
      return
    end
    raise ArgumentError, 'Mídia excede o limite' if base64.bytesize > (MAX_MEDIA_BYTES * 4 / 3) + 4

    decoded = Base64.strict_decode64(base64)
    @message.attachments.build(file_type: file_content_type.to_s, file: {
                                 io: StringIO.new(decoded), filename: filename, content_type: message_mimetype || 'application/octet-stream'
                               })
  end

  def receive_status
    updates = params[:data].is_a?(Array) ? params[:data] : [params[:data]]
    updates.each do |update|
      next unless update.is_a?(Hash)

      update_observed_status(update)
    end
  end

  def update_observed_status(update)
    @raw_message = update
    @message = inbox.messages.find_by(source_id: raw_message_id)
    return unless @message && (jid_type == 'user' || jid_type == 'unknown')

    status = status_mapper
    Messages::StatusUpdateService.new(@message, status).perform if status.present?
  end
end
