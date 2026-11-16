class Public::LeadAcquisitionsController < ActionController::API
  def create
    response.headers['Cache-Control'] = 'no-store'
    return head :forbidden unless Rails.env.test? || request.ssl?
    return head :forbidden if request.headers['Origin'].present?
    return limited unless LeadAutomations::IntakeRateLimit.allowed?("cra_ip:#{request.remote_ip}", 20)
    rule = LeadAutomationRule.kept.find_by(id: params[:id], acquisition_scope_key: 'client:cra')
    token = request.headers['Authorization'].to_s.match(/\ABearer ([^\s]+)\z/)&.[](1)
    return head :forbidden unless rule&.active && rule.enrichment_token_valid?(token)
    return head :service_unavailable unless LeadAutomations::CraAcquisition.enabled?
    return limited unless LeadAutomations::IntakeRateLimit.allowed?("cra_enrichment:#{rule.id}", 60)
    return head :unsupported_media_type unless request.media_type == 'application/json'
    return head :payload_too_large if request.content_length.to_i > 16_384
    body = request.body.read(16_385)
    return head :payload_too_large if body.bytesize > 16_384
    p = JSON.parse(body)
    return head :bad_request unless LeadAutomations::CraAcquisition.enrichment?(p, request.headers['Idempotency-Key'])
    result = LeadAutomations::ReceiveEnrichment.call(rule, p)
    return head :conflict if result == :conflict
    render json: { accepted: true }, status: :accepted
  rescue JSON::ParserError, ArgumentError
    head :bad_request
  rescue StandardError
    Rails.logger.warn('[CRA_ACQUISITION] ingress_unavailable')
    head :service_unavailable
  end

  private

  def limited
    response.set_header('Retry-After', '60')
    head :too_many_requests
  end
end
