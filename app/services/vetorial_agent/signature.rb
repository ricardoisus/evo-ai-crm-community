require 'openssl'
module VetorialAgent::Signature
  def self.headers(body, method: 'POST', path: '/events')
    time = Time.now.to_i.to_s
    { 'Content-Type' => 'application/json', 'X-Vetorial-Time' => time,
      'X-Vetorial-Signature' => OpenSSL::HMAC.hexdigest('SHA256', VetorialAgent::Policy.secret, "#{time}.#{method.upcase}.#{path}.#{body}") }
  end

  def self.valid?(body, headers, method:, path:)
    time = headers['X-Vetorial-Time'].to_s
    return false if VetorialAgent::Policy.secret.bytesize < 32 || !time.match?(/\A\d+\z/) || (Time.now.to_i - time.to_i).abs > 60

    expected = OpenSSL::HMAC.hexdigest('SHA256', VetorialAgent::Policy.secret, "#{time}.#{method.upcase}.#{path}.#{body}")
    ActiveSupport::SecurityUtils.secure_compare(expected, headers['X-Vetorial-Signature'].to_s)
  end
end
