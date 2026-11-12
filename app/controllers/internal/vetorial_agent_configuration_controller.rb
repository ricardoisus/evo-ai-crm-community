class Internal::VetorialAgentConfigurationController < ActionController::API
  before_action :authenticate_bridge

  def show
    deployment = VetorialAgent::Deployment.find(params[:deployment_id])
    revision = deployment.active_revision
    return head :service_unavailable unless revision
    # No 304: each response is self-contained, authenticated by the private transport.
    render json: { payload: revision.payload, sha256: revision.sha256, lease_ms: 120000 }
  end

  private

  def authenticate_bridge
    valid = VetorialAgent::Signature.valid?(request.raw_post, request.headers, method: request.request_method, path: request.path)
    head :unauthorized unless valid
  end
end
