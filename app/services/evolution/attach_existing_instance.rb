# frozen_string_literal: true

class Evolution::AttachExistingInstance
  class Conflict < StandardError; end
  EVENTS = %w[MESSAGES_UPSERT MESSAGES_UPDATE CONNECTION_UPDATE].freeze
  WEBHOOK_KEYS = %w[enabled url headers webhookByEvents webhookBase64 events].freeze

  def initialize(instance_name:, phone_number:, name:, client: nil)
    @instance = instance_name.to_s
    @phone = "+#{phone_number.to_s.gsub(/\D/, '')}"
    @name = name.to_s
    @client = client || Evolution::ExistingInstanceClient.new(
      api_url: GlobalConfigService.load('EVOLUTION_API_URL', ''),
      token: GlobalConfigService.load('EVOLUTION_ADMIN_SECRET', '')
    )
  end

  def perform
    validate_input!
    remote = find_remote_instance!
    current = @client.webhook(@instance)
    prepare_local_channel(remote, current)
    expected = webhook_config
    current = @client.webhook(@instance) # Recheck ownership immediately before the sole remote write.
    raise Conflict, 'Webhook ocupado ou alterado; reconciliação necessária' if current.present? && !same_webhook?(current, expected)

    # Persist local identity before enabling the callback. Ambiguous HTTP failures
    # keep this box for GET reconciliation; never delete the box or the instance.
    @client.set_webhook(@instance, expected) if current.blank?
    raise Conflict, 'Webhook não confirmado; reconciliação necessária' unless same_webhook?(@client.webhook(@instance), expected)

    @channel.update!(provider_config: @channel.provider_config.merge('attachment_state' => 'active'))
    @channel.inbox
  end

  def detach(channel)
    @channel = channel
    raise Conflict, 'Caixa não pertence a esta anexação' unless channel.evolution_attached? && channel.provider_config['instance_name'] == @instance

    current = @client.webhook(@instance)
    disabled = webhook_config.merge('enabled' => false, 'events' => [], 'headers' => {})
    unless same_webhook?(current, disabled)
      raise Conflict, 'Webhook alterado; remoção recusada' unless same_webhook?(current, webhook_config)

      @client.set_webhook(@instance, disabled)
    end
    raise Conflict, 'Desativação não confirmada' unless same_webhook?(@client.webhook(@instance), disabled)

    channel.update!(provider_config: channel.provider_config.merge('attachment_state' => 'detached'))
    channel.inbox
  end

  private

  def validate_input!
    valid = @instance.match?(/\A[a-zA-Z0-9_-]+\z/) && @phone.match?(/\A\+\d{10,15}\z/) && @name.present?
    raise Conflict, 'Instância, número ou nome inválido' unless valid
  end

  def find_remote_instance!
    instances = @client.instances(@instance)
    matches = Array(instances).select { |i| i['name'] == @instance }
    raise Conflict, 'Instância existente não encontrada ou ambígua' unless matches.one?

    remote = matches.first
    owner = remote['ownerJid'].to_s.split('@').first.split(':').first
    raise Conflict, 'Número ou conexão da instância não confere' unless owner == @phone.delete_prefix('+') && remote['connectionStatus'] == 'open'

    remote
  end

  def prepare_local_channel(remote, current)
    Channel::Whatsapp.transaction do
      Channel::Whatsapp.connection.execute('SELECT pg_advisory_xact_lock(80731108)')
      @channel = Channel::Whatsapp.where(provider: 'evolution').find_by("provider_config ->> 'instance_name' = ?", @instance)
      if @channel
        raise Conflict, 'Nome ou número já vinculado' unless owned_local_channel?(remote)
      else
        raise Conflict, 'Webhook ocupado; nenhuma configuração foi alterada' if current.present?
        raise Conflict, 'Nome ou número já vinculado' if collision?

        create_local_channel(remote)
      end
    end
  end

  def collision?
    Channel::Whatsapp.exists?(["regexp_replace(phone_number, '[^0-9]', '', 'g') = ?", @phone.delete_prefix('+')]) ||
      Inbox.exists?(name: Inbox.new.sanitize_instance_name(@name)) || Inbox.exists?(['lower(display_name) = ?', @name.downcase])
  end

  def owned_local_channel?(remote)
    @channel.evolution_attached? && @channel.phone_number == @phone &&
      @channel.provider_config['attached_instance_id'] == remote['id'] &&
      @channel.inbox&.display_name == @name && @channel.provider_config['attachment_state'] != 'detached'
  end

  def create_local_channel(remote)
    base = ENV.fetch('BACKEND_URL').to_s.chomp('/')
    raise Conflict, 'BACKEND_URL ausente' if base.blank?

    @channel = Channel::Whatsapp.create!(
      provider: 'evolution', phone_number: @phone, provider_connection: { 'connection' => 'open' },
      provider_config: {
        'instance_name' => @instance, 'attached_instance_id' => remote.fetch('id'),
        'existing_instance_attached' => true, 'attachment_state' => 'pending',
        'attachment_token' => SecureRandom.hex(32), 'attachment_callback' => "#{base}/webhooks/evolution_attached",
        'mark_as_read' => false, 'attachment_started_at' => Time.current.to_i
      }
    )
    Inbox.create!(channel: @channel, name: @name, display_name: @name, timezone: 'America/Sao_Paulo',
                  enable_auto_assignment: false, greeting_enabled: false, csat_survey_enabled: false,
                  working_hours_enabled: false, enable_email_collect: false)
  end

  def webhook_config
    {
      'enabled' => true, 'url' => @channel.provider_config.fetch('attachment_callback'),
      'headers' => { 'X-Evo-Attach-Token' => @channel.provider_config.fetch('attachment_token') },
      'byEvents' => false, 'base64' => true, 'events' => EVENTS
    }
  end

  def same_webhook?(actual, expected)
    return false unless actual.is_a?(Hash)

    normalized = actual.slice(*WEBHOOK_KEYS).merge(
      'byEvents' => actual['webhookByEvents'], 'base64' => actual['webhookBase64']
    ).except('webhookByEvents', 'webhookBase64')
    normalized['events'] = Array(normalized['events']).sort
    normalized == expected.merge('events' => expected['events'].sort)
  end
end
