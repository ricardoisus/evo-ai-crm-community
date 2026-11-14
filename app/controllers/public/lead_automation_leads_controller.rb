class Public::LeadAutomationLeadsController < ActionController::API
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

  def create
    return head :forbidden unless Rails.env.test? || request.ssl?
    return limited unless LeadAutomations::IntakeRateLimit.allowed?("ip:#{request.remote_ip}", 20)
    rule = LeadAutomationRule.kept.find_by(id: params[:id])
    return head :forbidden unless rule && origin_allowed?(rule)
    return preflight if request.options?
    token = request.headers['Authorization'].to_s.match(/\ABearer ([^\s]+)\z/)&.[](1)
    return head :forbidden unless rule.active && rule.conditions.dig('domain', 'enabled') && rule.token_valid?(token)
    return limited unless LeadAutomations::IntakeRateLimit.allowed?("rule:#{rule.id}", 60)
    return head :unprocessable_entity unless request.media_type == 'application/json' && request.content_length.to_i <= 16_384
    body = request.body.read(16_385)
    return head :unprocessable_entity if body.bytesize > 16_384
    payload = JSON.parse(body)
    return head :unprocessable_entity unless valid_payload?(payload, rule)
    event_id = payload['event_id']
    key = "intake:#{rule.id}:#{event_id}"
    phone = Whatsapp::PhoneNumberNormalizer.to_e164(payload.dig('contact', 'phone_number'))
    received = Time.current
    captured = false
    LeadAutomationEvent.transaction do
      # Stable phone and replay locks work across processes and do not expose PII.
      ["event:#{key}", "phone:#{phone}"].sort.each do |lock|
        digest = Digest::SHA256.hexdigest(lock).first(15).to_i(16)
        ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{digest})")
      end
      unless LeadAutomationEvent.exists?(source_key: key)
        contact = Contact.find_by(phone_number: phone)
        unless contact
          contact = Contact.new(payload['contact'].slice('name', 'email').merge('phone_number' => phone))
          contact.passive_observation = true
          contact.skip_default_pipeline_assignment = true
          contact.save!
        end
        event = LeadAutomations::CaptureEvent.call(contact: contact, source: 'domain', source_key: key,
                                                   occurred_at: received, received_at: received,
                                                   signal: { 'host' => rule.conditions.dig('domain', 'host'), 'rule_id' => rule.id })
        raise ActiveRecord::Rollback unless event
      end
      captured = true
    end
    return head :service_unavailable unless captured
    cors
    render json: { accepted: true, event_id: event_id }, status: :accepted
  rescue JSON::ParserError, ActiveRecord::RecordInvalid, ArgumentError
    head :unprocessable_entity
  rescue StandardError
    Rails.logger.warn('[LEAD_AUTOMATION] intake_unavailable')
    head :service_unavailable
  end

  private

  def origin_allowed?(rule)
    rule.conditions.dig('domain', 'enabled') == true && request.headers['Origin'] == "https://#{rule.conditions.dig('domain', 'host')}"
  end

  def cors
    response.set_header('Access-Control-Allow-Origin', request.headers['Origin'])
    response.set_header('Vary', 'Origin')
    response.set_header('Cache-Control', 'no-store')
  end

  def preflight
    requested = request.headers['Access-Control-Request-Headers'].to_s.downcase.split(',').map(&:strip)
    return head :forbidden unless request.headers['Access-Control-Request-Method'] == 'POST' && (requested - %w[authorization content-type idempotency-key]).empty?
    cors
    response.set_header('Access-Control-Allow-Methods', 'POST')
    response.set_header('Access-Control-Allow-Headers', 'Authorization, Content-Type, Idempotency-Key')
    head :no_content
  end

  def limited
    response.set_header('Retry-After', '60')
    head :too_many_requests
  end

  def valid_payload?(p, rule)
    return false unless p.is_a?(Hash) && (p.keys - %w[event_id page_url contact]).empty?
    return false unless p['event_id'].is_a?(String) && UUID.match?(p['event_id']) && p['event_id'] == request.headers['Idempotency-Key']
    return false unless LeadAutomations::Matcher.domain_url?(p['page_url'], rule.conditions.dig('domain', 'host'))
    c = p['contact']
    c.is_a?(Hash) && (c.keys - %w[name phone_number email]).empty? &&
      c['name'].is_a?(String) && c['name'].strip.present? && c['name'].length <= 120 &&
      c['phone_number'].is_a?(String) && c['phone_number'].match?(/\A\+[1-9]\d{6,14}\z/) &&
      (!c.key?('email') || (c['email'].is_a?(String) && c['email'].length <= 254 && c['email'].match?(URI::MailTo::EMAIL_REGEXP)))
  end
end
