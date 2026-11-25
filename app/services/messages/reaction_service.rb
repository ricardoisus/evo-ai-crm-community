# frozen_string_literal: true

# Grava a reação na mensagem alvo, no máximo uma por autor ('contact' ou 'me').
# Usa update_columns de propósito: reação não é mensagem nova nem edição, então
# não pode acionar agente, automação, webhooks, não lidas ou a ordem da conversa.
# A tela é avisada só pelo ActionCable (message.updated).
class Messages::ReactionService
  # Folga entre o relógio do CRM e o do WhatsApp na marca de um envio pelo CRM.
  CLOCK_SKEW_SECONDS = 5

  # occurred_at: horário do WhatsApp (webhook). Sem ele, é o envio feito pelo CRM.
  def initialize(message, emoji:, from:, user_id: nil, occurred_at: nil)
    @message = message
    @emoji = emoji.to_s
    @from = from
    @user_id = user_id
    @occurred_at = occurred_at.to_i.positive? ? occurred_at.to_i : nil
  end

  def perform
    changed = false
    @message.with_lock do
      next if stale?

      attributes = (@message.content_attributes || {}).to_h.stringify_keys
      changed = apply(attributes)
      mark(attributes)
      persist(attributes)
    end
    broadcast if changed
    changed
  end

  private

  def persist(attributes)
    @message.update_columns(content_attributes: attributes, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
  end

  # Webhook mais antigo que o último aplicado do mesmo autor (reentrega fora de
  # ordem) não pode desfazer uma troca ou remoção.
  def stale?
    @occurred_at && @occurred_at < @message.content_attributes.to_h.dig('reaction_marks', @from).to_i
  end

  def apply(attributes)
    reactions = Array(attributes['reactions']).map { |reaction| reaction.to_h.stringify_keys }
    current = reactions.find { |reaction| reaction['from'] == @from }
    # Mesmo emoji (reentrega ou eco do envio do CRM) preserva autor e horário.
    return claim(attributes, reactions, current) if current&.dig('emoji').to_s == @emoji

    others = reactions - [current]
    others << { 'emoji' => @emoji, 'from' => @from, 'user_id' => @user_id, 'at' => @occurred_at || Time.current.to_i } if @emoji.present?
    attributes['reactions'] = others
    true
  end

  # Só falta o autor quando o eco chegou antes de o envio do CRM ser gravado.
  def claim(attributes, reactions, current)
    return false unless current && @user_id && current['user_id'].blank?

    current['user_id'] = @user_id
    attributes['reactions'] = reactions
    true
  end

  # Sem horário do WhatsApp (envio pelo CRM), marca o agora menos a folga de relógio: um webhook
  # antigo do aparelho, atrasado na fila, não sobrescreve a reação.
  def mark(attributes)
    marks = attributes['reaction_marks'].to_h
    at = @occurred_at || (Time.current.to_i - CLOCK_SKEW_SECONDS)
    attributes['reaction_marks'] = marks.merge(@from => [at, marks[@from].to_i].max)
  end

  def broadcast
    event = Struct.new(:data).new({ message: @message, previous_changes: {} })
    ActionCableListener.instance.message_updated(event)
  end
end
