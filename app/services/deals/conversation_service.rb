# frozen_string_literal: true

module Deals
  # Abre (ou inicia) a conversa de WhatsApp do contato primário de um negócio.
  # NUNCA envia mensagem: só garante ContactInbox + Conversation aberta e vincula ao negócio.
  # A conversa nasce aberta e atribuída a quem a iniciou, então o agente de IA (que exige conversa
  # sem responsável e contato na allowlist piloto) não é acionado por este fluxo.
  class ConversationService
    class Error < StandardError
      attr_reader :code, :status, :details

      def initialize(code, message, status: :unprocessable_entity, details: nil)
        super(message)
        @code = code
        @status = status
        @details = details
      end
    end

    PHONE_FORMAT = /\A\+[1-9]\d{7,14}\z/

    def initialize(deal, actor: Current.user)
      @deal = deal
      @pipeline = deal.pipeline
      @actor = actor
    end

    def status
      allowed = allowed_links
      contact = primary_contact
      conversation = contact && latest_active_conversation(contact, allowed.map(&:inbox_id))
      {
        deal_id: @deal.id,
        pipeline_id: @pipeline.id,
        has_active: conversation.present?,
        conversation: conversation && conversation_data(conversation),
        can_start: contact.present? && allowed.any?,
        reason: conversation ? nil : unavailable_reason(contact, allowed),
        contact: contact && { id: contact.id, name: contact.name, phone_number: contact.phone_number },
        allowed_inboxes: allowed.map { |link| inbox_option(link) },
        default_inbox_id: allowed.find(&:is_default)&.inbox_id
      }
    end

    # @return [Array(Conversation, Boolean)] conversa e se foi criada agora
    def open_or_start!(inbox_id: nil)
      allowed = allowed_links
      raise Error.new('NO_INBOX_CONFIGURED', 'Nenhum número de WhatsApp autorizado neste pipeline. Configure em Pipeline > Números de WhatsApp.') if allowed.empty?

      contact = primary_contact
      raise Error.new('NO_CONTACT', 'O negócio não tem contato principal.') unless contact

      allowed_ids = allowed.map(&:inbox_id)
      # Reuso rápido (sem lock) e conferência de novo dentro do lock.
      existing = latest_active_conversation(contact, allowed_ids)
      return [link!(existing), false] if existing

      inbox = choose_inbox!(allowed, inbox_id)
      validate_start!(contact, inbox)

      conversation = nil
      created = false
      ApplicationRecord.transaction do
        lock!(contact, inbox)
        existing = latest_active_conversation(contact, allowed_ids)
        if existing
          conversation = existing
        else
          conversation, created = find_or_create_conversation!(contact, inbox)
        end
      end
      [link!(conversation), created]
    end

    private

    def allowed_links
      @allowed_links ||= @pipeline.pipeline_whatsapp_inboxes.active.preload(inbox: :channel).to_a
                                  .sort_by { |link| [link.is_default ? 0 : 1, link.inbox.name.to_s.downcase] }
    end

    def primary_contact
      @primary_contact ||= @deal.primary_contact || @deal.contacts.order(:created_at, :id).first || @deal.contact
    end

    def latest_active_conversation(contact, inbox_ids)
      return nil if inbox_ids.blank?

      ConversationSummary.active_scope.where(contact_id: contact.id, inbox_id: inbox_ids)
                         .reorder(Arel.sql('conversations.last_activity_at DESC NULLS LAST'), created_at: :desc).first
    end

    def choose_inbox!(allowed, inbox_id)
      if inbox_id.present?
        link = allowed.find { |l| l.inbox_id.to_s == inbox_id.to_s }
        raise Error.new('INBOX_NOT_ALLOWED', 'Este número de WhatsApp não está autorizado a iniciar conversa neste pipeline.', status: :forbidden) unless link

        return link.inbox
      end
      link = allowed.find(&:is_default) || (allowed.one? ? allowed.first : nil)
      raise Error.new('INBOX_REQUIRED', 'Escolha o número de WhatsApp que iniciará a conversa.', details: { allowed_inboxes: allowed.map { |l| inbox_option(l) } }) unless link

      link.inbox
    end

    def validate_start!(contact, inbox)
      raise Error.new('CONTACT_BLOCKED', 'Contato bloqueado.') if contact.respond_to?(:blocked?) && contact.blocked?
      unless contact.phone_number.to_s.match?(PHONE_FORMAT)
        raise Error.new('CONTACT_WITHOUT_PHONE', 'O contato não tem um telefone válido (formato internacional) para WhatsApp.')
      end
      return if Pipelines::WhatsappInboxSettings.channel_connected?(inbox)

      raise Error.new('CHANNEL_DISCONNECTED', 'O canal de WhatsApp está desconectado. Reconecte-o antes de iniciar a conversa.', status: :conflict)
    end

    # Trava de transação por contato+inbox: duas requisições concorrentes (inclusive de negócios
    # diferentes do mesmo contato) não criam duas conversas.
    def lock!(contact, inbox)
      key = "deal-conversation:#{contact.id}:#{inbox.id}"
      ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(hashtextextended(#{ApplicationRecord.connection.quote(key)}, 0))")
    end

    def find_or_create_conversation!(contact, inbox)
      contact_inbox = ContactInboxBuilder.new(contact: contact, inbox: inbox).perform
      raise Error.new('CONTACT_WITHOUT_PHONE', 'Não foi possível identificar o contato neste canal.') unless contact_inbox

      if inbox.lock_to_single_conversation? && (last = contact_inbox.conversations.order(:created_at).last)
        last.update!(status: :open) unless last.open? || last.pending? || last.snoozed?
        return [last, false]
      end

      conversation = Conversation.new(
        inbox_id: inbox.id, contact_id: contact.id, contact_inbox_id: contact_inbox.id,
        assignee_id: (@actor.id if @actor.respond_to?(:id) && !Current.service_authenticated),
        additional_attributes: { 'started_from_deal_id' => @deal.id }
      )
      conversation.status = :open
      conversation.status_explicitly_set!
      conversation.skip_pipeline_auto_assignment = true
      conversation.save!
      [conversation, true]
    end

    def link!(conversation)
      begin
        @deal.attach_conversation!(conversation, actor: @actor)
      rescue ActiveRecord::RecordNotUnique
        @deal.deal_conversations.find_or_create_by!(conversation: conversation)
      end
      conversation
    end

    def unavailable_reason(contact, allowed)
      return 'no_contact' unless contact
      return 'no_inbox_configured' if allowed.empty?
      return 'contact_without_phone' unless contact.phone_number.to_s.match?(PHONE_FORMAT)
      return 'contact_blocked' if contact.respond_to?(:blocked?) && contact.blocked?

      nil
    end

    def inbox_option(link)
      Pipelines::WhatsappInboxSettings.inbox_data(link.inbox).merge(is_default: link.is_default)
    end

    def conversation_data(conversation)
      message = conversation.messages.where(private: false).where.not(message_type: :activity).order(created_at: :desc).first
      {
        id: conversation.id,
        display_id: conversation.display_id,
        status: conversation.status,
        inbox: Pipelines::WhatsappInboxSettings.inbox_data(conversation.inbox),
        last_activity_at: conversation.last_activity_at&.iso8601,
        last_message: message && {
          id: message.id,
          content: ActionController::Base.helpers.strip_tags(message.content.to_s).squish.first(280),
          message_type: message.message_type,
          created_at: message.created_at.iso8601
        },
        path: "/conversations/#{conversation.id}"
      }
    end
  end
end
