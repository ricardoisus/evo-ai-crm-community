# frozen_string_literal: true

# Nome (pushName/verifiedName) e foto de perfil de contatos WhatsApp.
#
# Regras de nome: só substitui o nome atual quando ele é "provisório" (vazio,
# número, e-mail, nome aleatório do Haikunator) ou quando foi o próprio WhatsApp
# quem o gravou antes (additional_attributes['whatsapp_push_name'] == nome atual).
# Nome editado por uma pessoa nunca é sobrescrito.
#
# Regras de foto: busca ativa pela Evolution com backoff por tentativas sem
# sucesso e renovação periódica (a foto pode mudar). O estado fica em
# additional_attributes['whatsapp_avatar'] = { checked_at, synced_at, misses }.
class Whatsapp::ContactIdentitySync
  PHONE_NAME = /\A\+?[\d\s().-]{7,}\z/
  EMAIL_NAME = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
  HAIKUNATOR_NAME = /\A[a-z]+-[a-z]+-\d+\z/
  PUSH_NAME_KEY = 'whatsapp_push_name'
  AVATAR_KEY = 'whatsapp_avatar'
  # Espera (segundos) após N tentativas seguidas sem foto: 0, 1h, 6h, 1d, 3d, 7d
  AVATAR_BACKOFF = [0, 3_600, 21_600, 86_400, 259_200, 604_800].freeze
  AVATAR_REFRESH_AFTER = 14.days

  class << self
    def placeholder_name?(name)
      value = name.to_s.strip
      value.blank? || value.match?(PHONE_NAME) || value.match?(EMAIL_NAME) || value.match?(HAIKUNATOR_NAME)
    end

    def avatar_state(contact)
      state = (contact.additional_attributes || {})[AVATAR_KEY]
      state.is_a?(Hash) ? state : {}
    end

    # true quando vale a pena (re)consultar a foto agora.
    def avatar_due?(contact, now: Time.current)
      state = avatar_state(contact)
      if contact.avatar.attached?
        synced = parse_time(state['synced_at']) || contact.avatar.attachment&.created_at
        return synced.nil? || synced <= now - AVATAR_REFRESH_AFTER
      end

      checked = parse_time(state['checked_at'])
      return true unless checked

      wait = AVATAR_BACKOFF[[state['misses'].to_i, AVATAR_BACKOFF.size - 1].min]
      checked + wait <= now
    end

    def record_avatar_result(contact, success:, now: Time.current)
      state = avatar_state(contact)
      misses = success ? 0 : state['misses'].to_i + 1
      new_state = { 'checked_at' => now.iso8601, 'misses' => misses,
                    'synced_at' => success ? now.iso8601 : state['synced_at'] }.compact
      merge_attributes(contact, AVATAR_KEY => new_state)
    end

    def merge_attributes(contact, attrs)
      merged = (contact.additional_attributes || {}).merge(attrs)
      # Estado interno de sincronização: sem callbacks/webhooks de contato.
      contact.update_columns(additional_attributes: merged, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end

    def parse_time(value)
      value.present? ? Time.zone.parse(value.to_s) : nil
    rescue ArgumentError
      nil
    end
  end

  def initialize(contact)
    @contact = contact
  end

  # Aplica o nome vindo do WhatsApp. Retorna true se o nome do contato mudou.
  def sync_name(candidate)
    candidate = candidate.to_s.strip
    return false if self.class.placeholder_name?(candidate)

    current = @contact.name.to_s.strip
    stored = (@contact.additional_attributes || {})[PUSH_NAME_KEY]
    if current == candidate
      remember(candidate)
      return false
    end

    return false unless self.class.placeholder_name?(current) || current == stored.to_s

    @contact.update!(name: candidate,
                     additional_attributes: (@contact.additional_attributes || {}).merge(PUSH_NAME_KEY => candidate))
    true
  end

  # Enfileira a busca da foto se estiver "devida". Sem efeito colateral fora disso.
  def schedule_avatar(channel, phone_number)
    return false unless channel && phone_number.present?
    return false unless self.class.avatar_due?(@contact)

    Whatsapp::EvolutionHandlers::AvatarEnqueueGuard.enqueue_avatar_fetch(
      contact_id: @contact.id, phone_number: phone_number.to_s, channel_id: channel.id
    )
    true
  end

  private

  def remember(candidate)
    return if (@contact.additional_attributes || {})[PUSH_NAME_KEY] == candidate

    self.class.merge_attributes(@contact, PUSH_NAME_KEY => candidate)
  end
end
