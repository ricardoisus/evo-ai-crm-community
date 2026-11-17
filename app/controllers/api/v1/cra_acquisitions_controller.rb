class Api::V1::CraAcquisitionsController < Api::V1::BaseController
  require_permissions({ show: 'pipelines.read' })
  def show
    response.headers['Cache-Control'] = 'no-store'
    return head :forbidden unless Current.user&.administrator?
    pipeline = Pipeline.find(params[:pipeline_id])
    authorize pipeline, :view?
    rule = LeadAutomationRule.kept.find_by(pipeline_id: pipeline.id, acquisition_scope_key: 'client:cra')
    return head :not_found unless rule
    inbox = Inbox.find(rule.conditions.dig('ctwa', 'inbox_id'))
    authorize inbox, :show?
    deal = pipeline.pipeline_items.find(params[:id])
    event = LeadAcquisitionScopeEvent.find_by(id: deal.custom_fields.dig('cra_projection', 'scope_event_id'), scope_key: 'client:cra')
    return head :not_found unless event
    enrichment = LeadAcquisitionEnrichment.where(scope_event_id: event.id, acquisition_id: deal.custom_fields['cra_acquisition_id'], status: 'applied').order(revision: :desc).first
    payload = enrichment&.payload || event.signal
    success_response(data: { visitor_id: masked(payload['visitor_id'] || event.signal.dig('acquisition', 'visitor_id')),
                             ctwa_clid: masked(payload['ctwa_clid']) })
  end

  private

  def masked(value)
    value.present? ? "••••#{value.to_s.last(4)}" : nil
  end
end
