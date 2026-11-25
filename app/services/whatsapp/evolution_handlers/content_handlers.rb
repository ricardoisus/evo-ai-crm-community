module Whatsapp::EvolutionHandlers::ContentHandlers
  def handle_location
    location_msg = @raw_message.dig(:message, :locationMessage)
    return unless location_msg

    @message.content_attributes[:location] = {
      latitude: location_msg[:degreesLatitude],
      longitude: location_msg[:degreesLongitude],
      name: location_msg[:name],
      address: location_msg[:address]
    }
  end

  # O vCard bruto não é gravado: só nome, telefones e empresa.
  def handle_contacts
    contacts = shared_contacts
    @message.content_attributes[:shared_contacts] = contacts if contacts.any?
  end

  def shared_contacts
    message = @raw_message[:message] || {}
    contacts = message[:contactMessage] ? [message[:contactMessage]] : message.dig(:contactsArrayMessage, :contacts)
    Whatsapp::SharedContactsParser.parse(contacts)
  end

  def message_content_attributes
    content_attributes = {
      external_created_at: evolution_extract_message_timestamp(@raw_message[:messageTimestamp])
    }

    if message_type == 'unsupported'
      content_attributes[:is_unsupported] = true
    elsif quoted_stanza_id.present?
      content_attributes[:in_reply_to_external_id] = quoted_stanza_id
    end

    content_attributes[:sender_name] = participant_push_name if jid_type == 'group' && participant_push_name.present?
    content_attributes[:media_type] = message_type if media_attachment?

    content_attributes
  end

  # A Evolution entrega o contextInfo na raiz de data ou dentro do tipo da mensagem.
  def quoted_stanza_id
    message = @raw_message[:message] || {}
    nodes = [@raw_message, *message.values, message.dig(:documentWithCaptionMessage, :message, :documentMessage)]
    nodes.filter_map { |node| node.dig(:contextInfo, :stanzaId).presence if node.is_a?(Hash) }.first
  end
end
