# frozen_string_literal: true

module Pipelines
  # Lê e grava a lista de números de WhatsApp autorizados a iniciar conversa num pipeline.
  # Decisão: pipeline sem linhas ativas = NENHUM número autorizado (seguro por padrão).
  class WhatsappInboxSettings
    class Invalid < StandardError; end

    def initialize(pipeline)
      @pipeline = pipeline
    end

    def self.eligible_inboxes
      Inbox.where(channel_type: 'Channel::Whatsapp').preload(:channel).order(Arel.sql('lower(inboxes.name)'))
    end

    # Estado de conexão do canal: desconhecido (sem snapshot) conta como conectado, para não
    # bloquear canais cujo provedor não reporta estado (Cloud API).
    DISCONNECTED_STATES = %w[close closed disconnected logout].freeze

    def self.channel_connected?(inbox)
      channel = inbox.channel
      return false if channel.nil?
      return false if channel.respond_to?(:reauthorization_required?) && channel.reauthorization_required?

      connection = channel.provider_connection.is_a?(Hash) ? channel.provider_connection['connection'] : nil
      # Só o estado explicitamente desligado bloqueia. "connecting" costuma ficar preso no snapshot de
      # canais anexados/observados que seguem recebendo mensagens (caixa Vetorial em produção).
      !DISCONNECTED_STATES.include?(connection.to_s.downcase)
    end

    def self.inbox_data(inbox)
      channel = inbox.channel
      {
        id: inbox.id,
        name: inbox.name,
        phone_number: channel&.phone_number,
        provider: channel&.provider,
        connected: channel_connected?(inbox),
        connection: channel&.provider_connection.is_a?(Hash) ? channel.provider_connection['connection'] : nil
      }
    end

    def as_json_payload
      links = @pipeline.pipeline_whatsapp_inboxes.preload(inbox: :channel).to_a
      active = links.select(&:is_active)
      default = active.find(&:is_default)
      {
        pipeline_id: @pipeline.id,
        configured: active.any?,
        default_inbox_id: default&.inbox_id,
        allowed: active.sort_by { |link| link.inbox.name.to_s.downcase }.map do |link|
          self.class.inbox_data(link.inbox).merge(is_default: link.is_default)
        end,
        eligible: self.class.eligible_inboxes.map do |inbox|
          self.class.inbox_data(inbox).merge(allowed: active.any? { |link| link.inbox_id == inbox.id })
        end
      }
    end

    # Substitui a lista inteira. `inbox_ids` = quem fica autorizado; `default_inbox_id` opcional
    # (precisa estar na lista; se omitido e só há um número, ele vira o padrão).
    def replace!(inbox_ids:, default_inbox_id: nil)
      ids = Array(inbox_ids).map(&:to_s).reject(&:blank?).uniq
      eligible = self.class.eligible_inboxes.where(id: ids).pluck(:id).map(&:to_s)
      invalid = ids - eligible
      raise Invalid, "Inbox(es) not eligible (WhatsApp only): #{invalid.join(', ')}" if invalid.any?

      default_id = default_inbox_id.presence&.to_s
      raise Invalid, 'default_inbox_id must be one of inbox_ids' if default_id && ids.exclude?(default_id)

      default_id ||= ids.first if ids.size == 1

      Pipeline.transaction do
        @pipeline.lock!
        @pipeline.pipeline_whatsapp_inboxes.where.not(inbox_id: ids).destroy_all
        # Libera o padrão antes de regravar (índice parcial único de um padrão por pipeline).
        @pipeline.pipeline_whatsapp_inboxes.where(is_default: true).update_all(is_default: false) # rubocop:disable Rails/SkipsModelValidations
        ids.each do |inbox_id|
          link = @pipeline.pipeline_whatsapp_inboxes.find_or_initialize_by(inbox_id: inbox_id)
          link.is_active = true
          link.is_default = (inbox_id == default_id)
          link.save!
        end
      end
      as_json_payload
    rescue ActiveRecord::RecordInvalid => e
      raise Invalid, e.record.errors.full_messages.join(', ')
    end

    def set_default!(inbox_id)
      link = @pipeline.pipeline_whatsapp_inboxes.active.find_by(inbox_id: inbox_id)
      raise Invalid, 'Inbox is not allowed in this pipeline' unless link

      Pipeline.transaction do
        @pipeline.lock!
        @pipeline.pipeline_whatsapp_inboxes.where(is_default: true).update_all(is_default: false) # rubocop:disable Rails/SkipsModelValidations
        link.update!(is_default: true)
      end
      as_json_payload
    end
  end
end
