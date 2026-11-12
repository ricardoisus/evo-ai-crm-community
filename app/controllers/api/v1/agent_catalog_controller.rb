class Api::V1::AgentCatalogController < Api::V1::BaseController
  require_permissions({ index: 'ai_agents.read' })

  def index
    ids = Current.user.assigned_inboxes.pluck(:id)
    managed = VetorialAgent::Profile.includes(deployment: :active_revision).select do |profile|
      payload = profile.deployment.payload
      payload && (payload['binding']['inbox_ids'] - ids).empty?
    end
    managed = [] if params[:folder_id].present? || params[:source] == 'core'
    managed = managed.map { |profile| VetorialAgent::ProfileView.summary(profile) }
    managed.select! { |item| item[:name].downcase.include?(params[:search].downcase) } if params[:search].present?
    %w[mode health].each { |key| managed.select! { |item| item[key.to_sym] == params[key] } if params[key].present? }
    native = nil
    partial = false
    unless params[:source] == 'vetorial_runtime'
      result = EvoAiCoreService.catalog_agents(params.except(:controller, :action, :source, :mode, :health).to_unsafe_h, request.headers)
      return head result[:status] if [401, 403].include?(result[:status])
      native = result[:body] if result[:status] == 200
      partial = native.nil?
    end
    render json: { success: true, data: { managed: managed, native: native }, meta: { partial: partial, unavailable_sources: partial ? ['core'] : [] } }
  end
end
