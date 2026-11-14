class Api::V1::VetorialAgentsController < Api::V1::BaseController
  READ_ACTIONS = %w[show revisions revision metrics integrations test_session].freeze
  require_permissions({ test_session: 'ai_agents.read', create_test_session: 'ai_agents.update', test_message: 'ai_agents.update', close_test_session: 'ai_agents.update', show: 'ai_agents.read', revisions: 'ai_agents.read', revision: 'ai_agents.read', metrics: 'ai_agents.read', integrations: 'ai_agents.read',
                        activation_challenges: 'ai_agents.update', activation: 'ai_agents.update', binding: 'ai_agents.update', create_revision: 'ai_agents.update', publish: 'ai_agents.update', restore: 'ai_agents.update' })
  before_action :load_profile
  before_action :require_admin, except: READ_ACTIONS + %w[create_test_session test_message close_test_session]
  rescue_from VetorialAgent::Configuration::Conflict, ActiveRecord::StaleObjectError do
    render json: { success: false, error: { code: 'conflict', message: 'A configuração mudou. Atualize a página.' } }, status: :conflict
  end
  rescue_from VetorialAgent::Snapshot::Invalid, ArgumentError do
    render json: { success: false, error: { code: 'invalid_configuration', message: 'Revise a configuração informada.' } }, status: :unprocessable_entity
  end

  rescue_from VetorialAgent::TestSessions::Limit do
    render json: { success: false, error: { code: 'test_limit', message: 'Limite do teste atingido' } }, status: :too_many_requests
  end
  rescue_from VetorialAgent::TestSessions::Unavailable do
    render json: { success: false, error: { code: 'test_unavailable', message: 'Teste indisponível. Consulte a sessão antes de tentar novamente.' } }, status: :service_unavailable
  end
  rescue_from VetorialAgent::TestSessions::Conflict do
    render json: { success: false, error: { code: 'conflict', message: 'Requisição de teste conflitante.' } }, status: :conflict
  end

  def create_test_session
    input = params.permit(:revision_id, :purpose, :criteria, :sample_count, :budget_usd, :max_turns).to_h
    render json: { success: true, data: test_service.create(input, request.headers['Idempotency-Key']) }
  end

  def test_session
    render json: { success: true, data: test_service.show(scoped_test_session) }
  end

  def test_message
    render json: { success: true, data: test_service.turn(scoped_test_session, params[:text], request.headers['Idempotency-Key']) }
  end

  def close_test_session
    render json: { success: true, data: test_service.close(scoped_test_session) }
  end

  def activation_challenges
    render json: { success: true, data: VetorialAgent::Activation.new(@profile, actor_id: Current.user.id).challenge }
  end

  def activation
    input = params.permit(:mode, :nonce, :phrase, :confirm, allowlist: [], internal_numbers: []).to_h
    mutate('activation', input) do |_service|
      revision_view(VetorialAgent::Activation.new(@profile, actor_id: Current.user.id).apply(input))
    end
  end

  def binding
    return head :forbidden unless has_user_permission?(Current.user.id, 'pipelines.read')
    input = params.require(:binding).permit(:agent_bot_id, :pipeline_id, inbox_ids: []).to_h
    mutate('binding', input) do |service|
      raise VetorialAgent::Configuration::Conflict unless @deployment.control_source == 'crm'
      raise ArgumentError unless input.keys.sort == %w[agent_bot_id inbox_ids pipeline_id].sort && input['agent_bot_id'] == @deployment.agent_bot_id
      raise ArgumentError unless input['inbox_ids'].is_a?(Array) && input['inbox_ids'].size == 1
      inbox = Current.user.assigned_inboxes.find(input['inbox_ids'].sole)
      inbox.with_lock do
        # HTTP only reuses an attached native binding; creation stays boot/inventory gated.
        raise VetorialAgent::Configuration::Conflict unless inbox.agent_bot_inbox&.agent_bot_id == @deployment.agent_bot_id
        raise ArgumentError unless inbox.channel.is_a?(Channel::Whatsapp) && inbox.channel.evolution_attached?
        Pipeline.find(input['pipeline_id']) if input['pipeline_id'].present?
        payload = @deployment.payload.deep_dup
        payload['binding'] = input
        revision_view(service.replace(payload))
      end
    end
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

  def test_service
    VetorialAgent::TestSessions.new(@profile, Current.user)
  end

  def scoped_test_session
    scope = VetorialAgent::TestSession.where(profile: @profile)
    scope = scope.where(owner: Current.user) unless Current.user.administrator?
    scope.find(params[:session_id])
  end

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
