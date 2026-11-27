# frozen_string_literal: true

class Public::CraTrackingSiteController < ActionController::API
  MAX_BYTES = 65_536

  def create
    response.headers['Cache-Control'] = 'no-store'
    mode = ENV['WHATSAPP_TRACKING_CRA_SITE_MODE']
    return head :service_unavailable unless ENV['WHATSAPP_TRACKING_CRA_SITE_ENABLED'] == 'true' && %w[observe native].include?(mode)
    return head :forbidden unless authorized?
    return head :unprocessable_entity unless request.media_type == 'application/json' && request.content_length.to_i <= MAX_BYTES

    raw = request.body.read(MAX_BYTES + 1)
    return head :unprocessable_entity if raw.bytesize > MAX_BYTES

    rate_key = request.headers['X-CRA-Rate-Key']
    payload = WhatsappTracking::CraSiteContract.new.normalize(JSON.parse(raw), rate_key: rate_key)
    return render_result(accepted: false, http: 429) unless within_limit?(payload, rate_key)

    if payload['kind'] == 'crm_intake' && mode == 'observe'
      return render_result(accepted: true, http: 202, event_id: payload.fetch('event_id'))
    end

    rule = scoped_rule if payload['kind'] == 'crm_intake'
    return head :service_unavailable if payload['kind'] == 'crm_intake' && !rule

    result = WhatsappTracking::CraSiteIntake.new(secret: ENV['WHATSAPP_TRACKING_CRA_DEDUP_SECRET']).call(payload, rule: rule)
    render_result(result)
  rescue JSON::ParserError, WhatsappTracking::CraSiteContract::Invalid
    render_result(accepted: false, http: 422)
  rescue WhatsappTracking::CraSiteIntake::Conflict
    render_result(accepted: false, http: 409)
  rescue ActiveRecord::ActiveRecordError, ArgumentError, Redis::BaseError
    Rails.logger.warn('[WHATSAPP_TRACKING] site_intake_unavailable')
    head :service_unavailable
  end

  private

  def authorized?
    expected = ENV['WHATSAPP_TRACKING_CRA_SITE_TOKEN'].to_s
    supplied = request.headers['X-CRA-Tracking-Token'].to_s
    (request.ssl? || Rails.env.test?) && expected.present? && supplied.present? &&
      ActiveSupport::SecurityUtils.secure_compare(expected, supplied)
  end

  def scoped_rule
    return unless LeadAutomations::CraAcquisition.enabled?

    LeadAutomationRule.kept.find_by(id: ENV['WHATSAPP_TRACKING_CRA_SITE_RULE_ID'], active: true,
                                    acquisition_scope_key: 'client:cra')&.then do |rule|
      rule if rule.conditions.dig('domain', 'enabled') == true
    end
  end

  def within_limit?(payload, rate_key)
    return true if payload['kind'] == 'revoke'

    limit = payload['kind'] == 'crm_intake' ? 5 : 20
    LeadAutomations::IntakeRateLimit.allowed?("cra:native:#{payload['kind']}:#{rate_key}", limit)
  end

  def render_result(result)
    render json: result, status: result.fetch(:http)
  end
end
