# frozen_string_literal: true

module Deals
  # Resumo leve (sem N+1) para o cartão do kanban decidir entre "Abrir conversa" e "Iniciar conversa".
  # Uma consulta para os números permitidos de todos os pipelines e uma para as conversas ativas.
  module ConversationSummary
    extend self

    ACTIVE_STATUSES = %w[open pending snoozed].freeze

    def primary_contact_id(item)
      item.primary_contact_id ||
        item.read_attribute(:contact_id) ||
        (item.deal_contacts.loaded? ? item.deal_contacts.min_by { |link| [link.created_at, link.id.to_s] }&.contact_id : nil) ||
        (item.conversation_id && item.association(:conversation).loaded? ? item.conversation&.contact_id : nil)
    end

    # @return [Hash{String => Hash}] item.id => resumo
    def batch(items)
      items = Array(items)
      return {} if items.empty?

      allowed = allowed_inbox_ids_by_pipeline(items.map(&:pipeline_id).uniq)
      contact_ids = items.filter_map { |item| primary_contact_id(item) }.uniq
      inbox_ids = allowed.values.flatten.uniq
      conversations = if contact_ids.any? && inbox_ids.any?
                        active_scope.where(contact_id: contact_ids, inbox_id: inbox_ids)
                                    .reorder(Arel.sql('conversations.last_activity_at DESC NULLS LAST'), created_at: :desc)
                                    .select(:id, :display_id, :contact_id, :inbox_id, :status, :last_activity_at)
                                    .group_by(&:contact_id)
                      else
                        {}
                      end

      items.index_by(&:id).transform_values do |item|
        contact_id = primary_contact_id(item)
        allowed_ids = allowed[item.pipeline_id] || []
        conversation = Array(conversations[contact_id]).find { |c| allowed_ids.include?(c.inbox_id) }
        build(conversation, contact_id, allowed_ids)
      end
    end

    def for_item(item)
      batch([item])[item.id]
    end

    def active_scope
      Conversation.where(status: ACTIVE_STATUSES.map { |s| Conversation.statuses[s] })
    end

    def allowed_inbox_ids_by_pipeline(pipeline_ids)
      PipelineWhatsappInbox.active.where(pipeline_id: pipeline_ids)
                           .pluck(:pipeline_id, :inbox_id).group_by(&:first).transform_values { |rows| rows.map(&:last) }
    end

    private

    def build(conversation, contact_id, allowed_ids)
      reason = if contact_id.blank? then 'no_contact'
               elsif allowed_ids.empty? then 'no_inbox_configured'
               end
      {
        has_active: conversation.present?,
        conversation_id: conversation&.id,
        display_id: conversation&.display_id,
        inbox_id: conversation&.inbox_id,
        status: conversation&.status,
        last_activity_at: conversation&.last_activity_at&.iso8601,
        can_start: reason.nil?,
        reason: conversation ? nil : reason,
        allowed_inbox_count: allowed_ids.size
      }
    end
  end
end
