# No auto-retry of provider POSTs: a timeout may mean WhatsApp accepted it.
class VetorialAgent::Transport
  def initialize(conversation)
    @c = conversation
    @channel = conversation.inbox.channel
    @config = @channel.provider_config
  end

  def send_text(text)
    response = post('message/sendText', { number: @c.contact.phone_number.delete_prefix('+'), text: text })
    raise 'provider_uncertain' unless response.code.between?(200, 299)

    id = JSON.parse(response.body).dig('key', 'id')
    raise 'provider_uncertain' if id.blank?

    id
  end

  def typing
    post('chat/sendPresence', { number: @c.contact.phone_number.delete_prefix('+'), presence: 'composing', delay: 1000 })
  end

  private

  def post(path, body)
    base = @config['api_url'].presence || GlobalConfigService.load('EVOLUTION_API_URL', '').to_s.strip
    token = @config['admin_token'].presence || GlobalConfigService.load('EVOLUTION_ADMIN_SECRET', '').to_s.strip
    HTTParty.post("#{base.sub(%r{/$}, '')}/#{path}/#{@config.fetch('instance_name')}",
                  headers: { 'apikey' => token, 'Content-Type' => 'application/json' }, body: body.to_json, timeout: 10)
  end
end
