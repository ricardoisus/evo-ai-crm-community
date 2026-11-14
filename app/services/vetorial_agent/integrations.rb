# Only closed states leave this service; never serialize provider data or exceptions.
class VetorialAgent::Integrations
  NAMES = %w[openai groq calendly google_gateway evolution].freeze
  STATES = %w[configured absent error].freeze

  def initialize(deployment)
    @deployment = deployment
  end

  def call
    runtime = VetorialAgent::RuntimeStatus.where(deployment: @deployment).order(heartbeat_at: :desc).first
    fresh = runtime && runtime.heartbeat_at.between?(90.seconds.ago, Time.current)
    NAMES.index_with do |name|
      value = fresh ? runtime.integrations[name] : nil
      STATES.include?(value) ? value : 'error'
    end
  end

  def evolution
    ids = @deployment.payload&.dig('binding', 'inbox_ids') || []
    channels = Inbox.where(id: ids).map(&:channel)
    return 'absent' if channels.empty? || channels.any? { |c| !c.is_a?(Channel::Whatsapp) || !c.evolution_attached? }

    url = GlobalConfigService.load('EVOLUTION_API_URL', '')
    token = GlobalConfigService.load('EVOLUTION_ADMIN_SECRET', '')
    return 'absent' if url.blank? || token.blank?

    client = Evolution::ExistingInstanceClient.new(api_url: url, token: token)
    channels.all? do |channel|
      instance = channel.provider_config['instance_name']
      next false if instance.blank?

      rows = client.instances(instance)
      rows.is_a?(Array) && rows.any? { |row| row.is_a?(Hash) && row['name'] == instance && row['connectionStatus'] == 'open' }
    end ? 'configured' : 'error'
  rescue StandardError
    'error'
  end
end
