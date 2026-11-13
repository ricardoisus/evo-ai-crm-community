class Internal::VetorialAgentTelemetryController < ActionController::API
  before_action :authenticate_bridge

  rescue_from VetorialAgent::Telemetry::Invalid, JSON::ParserError do
    render json: { error: 'invalid_telemetry' }, status: :unprocessable_entity
  end
  rescue_from VetorialAgent::Telemetry::Conflict, ActiveRecord::RecordNotUnique do
    render json: { error: 'telemetry_conflict' }, status: :conflict
  end

  def create
    body = JSON.parse(request.raw_post)
    raise VetorialAgent::Telemetry::Invalid unless body.is_a?(Hash) && body.keys == ['events']

    result = VetorialAgent::Telemetry.new(body['events'], idempotency_key: request.headers['Idempotency-Key']).call
    render json: result
  end

  private

  def authenticate_bridge
    valid = VetorialAgent::Signature.valid?(request.raw_post, request.headers,
                                            method: request.request_method, path: request.path)
    head :unauthorized unless valid
  end
end
