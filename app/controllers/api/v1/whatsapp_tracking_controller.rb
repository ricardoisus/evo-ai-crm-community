# frozen_string_literal: true

class Api::V1::WhatsappTrackingController < Api::V1::BaseController
  require_permissions({
    rules: 'automation_rules.read', create_rule: 'automation_rules.create', update_rule: 'automation_rules.update',
    publish: 'automation_rules.update', pause: 'automation_rules.update', simulate: 'automation_rules.read',
    destinations: 'automation_rules.read', create_destination: 'automation_rules.create',
    update_destination: 'automation_rules.update', history: 'automation_rules.read', retry_delivery: 'automation_rules.update'
  })

  before_action :require_admin
  before_action :load_inbox
  before_action :load_rule, only: %i[update_rule publish pause simulate]

  rescue_from ActiveRecord::RecordInvalid do |error|
    error_response(ApiErrorCodes::VALIDATION_ERROR, 'Configuração inválida', details: error.record.errors.full_messages,
                   status: :unprocessable_entity)
  end

  rescue_from ActiveRecord::StaleObjectError do
    error_response('conflict', 'A regra mudou. Atualize a página.', status: :conflict)
  end

  def rules
    success_response(data: inbox_rules.order(created_at: :desc, id: :desc).map { |rule| rule_data(rule) })
  end

  def create_rule
    rule = inbox_rules.create!(rule_params)
    success_response(data: rule_data(rule), status: :created)
  end

  def update_rule
    mutate_rule { @rule.update!(rule_params) }
  end

  def publish
    mutate_rule { @rule.publish! }
  end

  def pause
    mutate_rule { @rule.update!(active: false) }
  end

  def simulate
    event = params.require(:event).permit(:trigger, :pipeline_id, :stage_id, :from_stage_id, :origin,
                                         :message_type, :private, :imported, :confirmed, :text).to_h
    event['trigger'] ||= @rule.draft['trigger']
    success_response(data: { result: @rule.simulate(event) })
  end

  def destinations
    success_response(data: inbox_destinations.order(:name, :id).map { |destination| destination_data(destination) })
  end

  def create_destination
    destination = inbox_destinations.create!(destination_params)
    success_response(data: destination_data(destination), status: :created)
  end

  def update_destination
    destination = inbox_destinations.find(params[:id])
    destination.update!(destination_params.except(:dataset_id))
    success_response(data: destination_data(destination))
  end

  def history
    response.headers['Cache-Control'] = 'no-store'
    scope = WhatsappTrackingDelivery.where(inbox_id: @inbox.id).includes(:receipts).order(created_at: :desc, id: :desc)
    %i[status mode dataset_id].each { |key| scope = scope.where(key => params[key]) if params[key].is_a?(String) }
    page = [params[:page].to_i, 1].max
    per_page = 25
    records = scope.offset((page - 1) * per_page).limit(per_page)
    success_response(data: records.map { |delivery| delivery_data(delivery) },
                     meta: { page: page, per_page: per_page, total_count: scope.count })
  end

  def retry_delivery
    delivery = WhatsappTrackingDelivery.find_by!(inbox_id: @inbox.id, id: params[:id])
    unless delivery.retry_manually
      return error_response('conflict', 'Entrega indisponível para nova tentativa', status: :conflict)
    end

    success_response(data: delivery_data(delivery))
  end

  private

  def require_admin
    head :forbidden unless Current.user&.administrator?
  end

  def load_inbox
    @inbox = Inbox.find(params[:inbox_id])
    head :not_found unless @inbox.whatsapp?
  end

  def load_rule
    @rule = inbox_rules.find(params[:id])
  end

  def inbox_rules
    WhatsappTrackingRule.where(inbox_id: @inbox.id)
  end

  def inbox_destinations
    WhatsappTrackingDestination.where(inbox_id: @inbox.id)
  end

  def mutate_rule
    @rule.with_lock do
      raise ActiveRecord::StaleObjectError.new(@rule, 'update') unless params[:lock_version] == @rule.lock_version

      yield
    end
    success_response(data: rule_data(@rule))
  end

  def rule_params
    params.permit(:name, draft: [:trigger, :frequency, :event_name, :destination_id, :mode,
                                { filters: WhatsappTracking::RuleMatcher::FILTERS.keys, text: %i[operator value] }]).to_h
  end

  def destination_params
    params.permit(:name, :dataset_id, :credential_ref).to_h
  end

  def rule_data(rule)
    rule.attributes.slice('id', 'name', 'inbox_id', 'draft', 'published', 'active', 'lock_version', 'updated_at')
  end

  def destination_data(destination)
    destination.attributes.slice('id', 'name', 'inbox_id', 'dataset_id').merge(
      'credential_configured' => ENV[destination.credential_ref].present?
    )
  end

  def delivery_data(delivery)
    delivery.attributes.slice('id', 'event_id', 'dataset_id', 'mode', 'status', 'attempt_count', 'available_at', 'created_at').merge(
      'event_name' => delivery.event['event_name'],
      'receipts' => delivery.receipts.sort_by(&:attempt_number).map do |receipt|
        receipt.attributes.slice('attempt_number', 'status', 'http_status', 'error_code', 'error_subcode', 'created_at')
      end
    )
  end
end
