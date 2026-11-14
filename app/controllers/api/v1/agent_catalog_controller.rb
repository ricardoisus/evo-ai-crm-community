class Api::V1::AgentCatalogController < Api::V1::BaseController
  MAX_MANAGED = 10

  require_permissions({ index: 'ai_agents.read' })

  def index
    ids = Current.user.assigned_inboxes.pluck(:id)
    profiles = VetorialAgent::Profile.includes(deployment: :active_revision).order(:role, :id).limit(MAX_MANAGED + 1).to_a
    raise "Managed profile limit exceeded (#{MAX_MANAGED})" if profiles.size > MAX_MANAGED

    managed = profiles.select do |profile|
      payload = profile.deployment.payload
      payload && payload['binding']['inbox_ids'].any? && (payload['binding']['inbox_ids'] - ids).empty?
    end
    managed = [] if params[:folder_id].present? || params[:source] == 'core'
    managed = managed.map { |profile| VetorialAgent::ProfileView.summary(profile) }
    managed.select! { |item| item[:name].downcase.include?(params[:search].downcase) } if params[:search].present?
    %w[mode health].each { |key| managed.select! { |item| item[key.to_sym] == params[key] } if params[key].present? }
    native = nil
    partial = false
    unless params[:source] == 'vetorial_runtime'
      result = EvoAiCoreService.catalog_agents(params.permit(:skip, :limit, :page, :pageSize, :page_size, :search, :search_query, :folder_id,
        filters: [:attribute_key, :filter_operator, :values, :query_operator, :operator, { conditions: [] }]).to_h, request.headers)
      return head result[:status] if [401, 403].include?(result[:status])
      native = result[:body] if result[:status] == 200
      partial = native.nil?
    end
    render json: { success: true, data: { managed: managed, native: native }, meta: { partial: partial, unavailable_sources: partial ? ['core'] : [] } }
  end
end
