class Api::V1::VetorialAgentsController < Api::V1::BaseController
  READ_ACTIONS = %w[show revisions revision metrics integrations].freeze
  require_permissions({ show: 'ai_agents.read', revisions: 'ai_agents.read', revision: 'ai_agents.read', metrics: 'ai_agents.read', integrations: 'ai_agents.read',
                        create_revision: 'ai_agents.update', publish: 'ai_agents.update', restore: 'ai_agents.update' })
  before_action :load_profile
  before_action :require_admin, except: READ_ACTIONS
  rescue_from VetorialAgent::Configuration::Conflict, ActiveRecord::StaleObjectError do
    render json: { success: false, error: { code: 'conflict', message: 'A configuração mudou. Atualize a página.' } }, status: :conflict
  end
  rescue_from VetorialAgent::Snapshot::Invalid, ArgumentError do
    render json: { success: false, error: { code: 'invalid_configuration', message: 'Revise a configuração informada.' } }, status: :unprocessable_entity
  end

  def show
    render json: { success: true, data: VetorialAgent::ProfileView.summary(@profile).merge(
      lock_version: @deployment.lock_version, control_source: @deployment.control_source,
      published_revision: revision_view(@deployment.active_revision)) }
  end

  def revisions
    render json: { success: true, data: @deployment.revisions.order(number: :desc).limit(100).map { |r| revision_view(r, text: false) } }
  end

  def integrations
    render json: { success: true, data: VetorialAgent::Integrations.new(@deployment).call }
  end

  def metrics
    data = VetorialAgent::Metrics.new(@deployment, source: params[:source], from: params[:from], to: params[:to]).call
    render json: { success: true, data: data }
  end

  def revision
    render json: { success: true, data: revision_view(scoped_revision) }
  end

  def create_revision
    input = params.require(:payload).to_unsafe_h
    mutate('draft', input) { |service| revision_view(service.draft(input)) }
  end

  def publish
    mutate('publish', { 'revision_id' => params[:revision_id] }) { |service| revision_view(service.publish(scoped_revision)) }
  end

  def restore
    mutate('restore', { 'revision_id' => params[:revision_id] }) do |service|
      original = scoped_revision
      revision_view(service.draft(original.payload, restored_from_id: original.id))
    end
  end

  private

  def load_profile
    @profile = VetorialAgent::Profile.find(params[:id])
    @deployment = @profile.deployment
    boxes = @deployment.payload&.dig('binding', 'inbox_ids') || []
    raise ActiveRecord::RecordNotFound unless boxes.any? && (boxes - Current.user.assigned_inboxes.pluck(:id)).empty?
  end

  def require_admin
    head :forbidden unless Current.user.administrator?
  end

  def scoped_revision
    @deployment.revisions.find(params[:revision_id])
  end

  def revision_view(revision, text: true)
    view = { id: revision.id, revision: revision.number, sha256: revision.sha256, status: revision.status,
             created_at: revision.created_at, published_at: revision.published_at }
    view[:payload] = revision.payload if text
    view
  end

  def mutate(action, input)
    service = VetorialAgent::Configuration.new(@deployment, actor_id: Current.user.id)
    result = service.mutate(action: action, key: request.headers['Idempotency-Key'],
                            expected_version: request.headers['If-Match'], input: input) { yield service }
    render json: { success: true, data: result, meta: { lock_version: @deployment.reload.lock_version } }
  end
end
