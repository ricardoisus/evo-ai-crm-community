# frozen_string_literal: true

# Encaminha uma mensagem para outras conversas de WhatsApp (Evolution), como mensagens novas de saída
# marcadas com content_attributes.forwarded. O envio segue o caminho normal (SendReplyJob).
# A Evolution não oferece o selo "Encaminhada": o destinatário recebe uma mensagem comum.
# Quem chama já validou o acesso às conversas de destino.
class Messages::ForwardService
  FILE_TYPES = %w[image audio video file].freeze
  # A Evolution recusa telefone menor que isso no sendContact.
  MIN_PHONE_DIGITS = 10

  def initialize(message, targets:, sender:)
    @message = message
    @targets = targets
    @sender = sender
  end

  # Motivo da recusa da mensagem de origem, ou nil.
  def refusal
    return 'unsupported_message' if unforwardable?

    'unsupported_content' unless sendable_content?
  end

  # Uma transação: se uma criação falhar, nenhum destino recebe.
  def perform
    Message.transaction do
      @targets.flat_map { |target| copy_to(target) }
    end
  end

  private

  def unforwardable?
    attributes = @message.content_attributes.to_h
    @message.private? || @message.activity? ||
      attributes.values_at('deleted', 'revoked_by_contact', 'is_reaction', 'is_unsupported').any?
  end

  def sendable_content?
    return false if @message.content_attributes.to_h['media_unavailable']
    return contacts.all? if shared_contacts.present?
    return files? if @message.attachments.any?

    @message.content.present?
  end

  def files?
    @message.attachments.all? { |attachment| FILE_TYPES.include?(attachment.file_type) && attachment.file.attached? }
  end

  def shared_contacts
    Array(@message.content_attributes.to_h['shared_contacts'])
  end

  # O que segue no cartão: um telefone por contato. nil quando o contato não tem telefone utilizável.
  def contacts
    @contacts ||= shared_contacts.map do |contact|
      contact = contact.to_h.stringify_keys
      phone = Array(contact['phones']).find { |value| sendable_phone?(value) }
      next unless phone

      { 'name' => contact['name'].presence || phone, 'phones' => [phone], 'organization' => contact['organization'] }
    end
  end

  def sendable_phone?(value)
    value.to_s.exclude?('*') && value.to_s.count('0-9') >= MIN_PHONE_DIGITS
  end

  # O provedor envia um anexo por mensagem, então cada arquivo vira uma; o texto vai só no primeiro.
  def copy_to(target)
    return create_copy(target, content: @message.content) if shared_contacts.present? || @message.attachments.empty?

    @message.attachments.sort_by { |a| [a.created_at, a.id] }.map.with_index do |attachment, index|
      create_copy(target, content: index.zero? ? @message.content : '', attachment: attachment)
    end
  end

  def create_copy(target, content:, attachment: nil)
    copy = target.messages.build(inbox_id: target.inbox_id, message_type: :outgoing, sender: @sender,
                                 content: content, content_attributes: copy_attributes)
    attach(copy, attachment) if attachment
    copy.save!
    copy
  end

  # Nada do original além do cartão de contato: citação, reações e ids do WhatsApp ficam lá.
  def copy_attributes
    attributes = { 'forwarded' => true }
    attributes['shared_contacts'] = contacts if shared_contacts.present?
    attributes
  end

  # Mesmo blob: nada é baixado ou enviado de novo ao storage.
  def attach(copy, original)
    attachment = copy.attachments.build(file_type: original.file_type, extension: original.extension,
                                        fallback_title: original.fallback_title, meta: original.meta)
    attachment.file.attach(original.file.blob)
  end
end
