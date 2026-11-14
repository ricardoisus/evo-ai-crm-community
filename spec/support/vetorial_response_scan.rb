# Sweep every HTTP response in the suite, including failures. Provider canaries cover
# arbitrary opaque secrets and full phones; integration DTOs additionally forbid any phone.
# Private operational snapshots legitimately carry allowlist entries.
module VetorialResponseScan
  FORBIDDEN = ['sk-j8-secret-canary', 'token-j8-canary', '5511987654321', 'https://private.invalid/auth'].freeze
  TOKEN = /\b(?:sk-(?:proj-)?[A-Za-z0-9_-]{16,}|gsk_[A-Za-z0-9]{16,}|Bearer\s+[A-Za-z0-9._-]{16,})/
  PHONE = /\+\d{11,15}(?!\d)/

  def self.check!(rendered, phones: false)
    leaked = FORBIDDEN.any? { |value| rendered.include?(value) } || rendered.match?(TOKEN)
    leaked ||= phones && rendered.match?(PHONE)
    raise 'Sensitive value in Vetorial HTTP response' if leaked
  end

  def process_action(...)
    super
  ensure
    VetorialResponseScan.check!(response.body.to_s + response.headers.to_json, phones: request.path.include?('/integrations'))
  end
end
ActionController::API.prepend(VetorialResponseScan)
ActionController::Base.prepend(VetorialResponseScan)
