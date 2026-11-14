class Api::V1::LeadAutomationRulesController < Api::V1::BaseController
  require_permissions({ index: 'automation_rules.read', show: 'automation_rules.read', create: 'automation_rules.create',
                      update: 'automation_rules.update', destroy: 'automation_rules.delete', activation: 'automation_rules.update',
                      test: 'automation_rules.read', runs: 'automation_rules.read', rotate_token: 'automation_rules.update' })
  before_action :require_admin
  before_action :load_rule, except: [:index, :create]
  rescue_from ActiveRecord::RecordInvalid do |error|
    error_response(ApiErrorCodes::VALIDATION_ERROR, 'Configuração inválida', details: error.record.errors.full_messages, status: :unprocessable_entity)
  end

  def index
    scope = LeadAutomationRule.kept.order(created_at: :desc)
    render_page(scope) { |rule| LeadAutomationRuleSerializer.serialize(rule) }
  end

  def show
    success_response(data: LeadAutomationRuleSerializer.serialize(@rule))
  end

  def create
    rule = LeadAutomationRule.new(rule_params.merge(created_by_id: Current.user.id))
    return head :forbidden unless pipeline_allowed?(rule.pipeline_id)
    rule.save!
    success_response(data: LeadAutomationRuleSerializer.serialize(rule), status: :created)
  end

  def update
    mutate { @rule.assign_attributes(rule_params); @rule.save! }
  end

  def activation
    return error_response(ApiErrorCodes::VALIDATION_ERROR, 'active deve ser booleano', status: :unprocessable_entity) unless [true, false].include?(params[:active])
    mutate { @rule.active = params[:active]; @rule.save! }
  end

  def destroy
    mutate { @rule.update_columns(active: false, deleted_at: Time.current, revision: @rule.revision + 1, updated_at: Time.current) }
  end

  def test
    input = params.require(:event).permit(:source, :inbox_id, :instance_name, :page_url, :ctwa_clid, :occurred_at, :contact_created_at, :conversation_created_at).to_h
    success_response(data: LeadAutomations::Matcher.call(@rule, input))
  end

  def runs
    scope = @rule.runs.order(executed_at: :desc)
    scope = scope.where(status: params[:status]) if params[:status].present?
    render_page(scope) { |run| run.attributes }
  end

  def rotate_token
    response.headers['Cache-Control'] = 'no-store'
    token = nil
    @rule.with_lock do
      return error_response('conflict', 'A regra mudou. Atualize a página.', status: :conflict) unless params[:revision].is_a?(Integer) && params[:revision] == @rule.revision
      unless @rule.conditions.dig('domain', 'enabled') == true
        return error_response(ApiErrorCodes::VALIDATION_ERROR, 'Origem domínio desabilitada', status: :unprocessable_entity)
      end
      token = SecureRandom.hex(32)
      @rule.update!(intake_token_digest: Digest::SHA256.hexdigest(token))
    end
    success_response(data: LeadAutomationRuleSerializer.serialize(@rule).merge(token: token))
  end

  private

  def require_admin
    head :forbidden unless Current.user&.administrator?
  end

  def load_rule
    @rule = LeadAutomationRule.kept.find(params[:id])
    head :forbidden unless pipeline_allowed?(@rule.pipeline_id)
  end

  def pipeline_allowed?(id)
    pipeline = Pipeline.find_by(id: id)
    pipeline.nil? || PipelinePolicy.new({ user: Current.user }, pipeline).show?
  end

  def mutate
    @rule.with_lock do
      return error_response('conflict', 'A regra mudou. Atualize a página.', status: :conflict) unless params[:revision].is_a?(Integer) && params[:revision] == @rule.revision
      return head :forbidden unless pipeline_allowed?(params[:pipeline_id] || @rule.pipeline_id)
      yield
    end
    success_response(data: LeadAutomationRuleSerializer.serialize(@rule))
  end

  def rule_params
    params.permit(:name, :active, :pipeline_id, :pipeline_stage_id, :owner_id, :title_template, label_ids: [],
                  conditions: [:version, :operator, { ctwa: [:enabled, :inbox_id, :instance_name], domain: [:enabled, :host] }]).to_h.tap do |input|
      # Keep unknown keys so model validation rejects unsupported condition versions/fields.
      if params.key?(:conditions)
        input['conditions'] = params[:conditions].is_a?(ActionController::Parameters) ? params[:conditions].to_unsafe_h : params[:conditions]
      end
      input['label_ids'] = params[:label_ids] if params.key?(:label_ids)
    end
  end

  def render_page(scope)
    page = [params[:page].to_i, 1].max
    size = [[params.fetch(:per_page, 25).to_i, 1].max, 100].min
    total = scope.count
    success_response(data: scope.limit(size).offset((page - 1) * size).map { |item| yield item },
                     meta: { pagination: { page: page, per_page: size, total_count: total, total_pages: (total.to_f / size).ceil } })
  end
end
