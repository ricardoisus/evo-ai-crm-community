# frozen_string_literal: true

# Deliberately exposes no instance create/delete/connect or integration setters.
class Evolution::ExistingInstanceClient
  class Error < StandardError; end

  def initialize(api_url:, token:)
    @base = api_url.to_s.chomp('/')
    @token = token
    uri = URI.parse(@base)
    raise Error, 'Evolution não configurada' unless uri.is_a?(URI::HTTP) && uri.host.present? && token.present?
  end

  def instances(name)
    request(:get, "/instance/fetchInstances?instanceName=#{segment(name)}")
  end

  def webhook(name)
    request(:get, "/webhook/find/#{segment(name)}")
  end

  def set_webhook(name, config)
    request(:post, "/webhook/set/#{segment(name)}", { webhook: config })
  end

  private

  def segment(name)
    raise Error, 'Nome de instância inválido' unless self.class.valid_name?(name)
    name.bytes.map { |b| b.chr.match?(/[A-Za-z0-9_.~-]/) ? b.chr : format('%%%02X', b) }.join
  end

  def self.valid_name?(name)
    name.is_a?(String) && name.valid_encoding? && name.length.between?(1, 100) && name == name.strip &&
      !%w[. ..].include?(name) && !name.match?(/[\x00-\x1f\x7f\/\\?#%]/)
  end

  def request(method, path, body = nil)
    uri = URI.parse(@base + path)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = 10
    http.read_timeout = 20
    req = method == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
    req['apikey'] = @token
    req['Content-Type'] = 'application/json'
    req.body = body.to_json if body
    response = http.request(req)
    raise Error, "Evolution HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError, IOError, SystemCallError, Timeout::Error
    raise Error, 'Falha de comunicação com Evolution; reconcilie por GET antes de tentar novamente'
  end
end
