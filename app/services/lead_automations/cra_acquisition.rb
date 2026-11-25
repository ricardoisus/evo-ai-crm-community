module LeadAutomations
  module CraAcquisition
    HOST = 'carolineribeiroadvogados.com'.freeze
    INSTANCE_ID = '23bd65f3-4d85-47d4-9ec1-09875fdc59ec'.freeze
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
    VISITOR = /\A[0-9a-f]{48}\z/
    TOUCH_KEYS = %w[utm_source utm_medium utm_campaign utm_content utm_term utm_posicionamento utm_placement page_url referrer captured_at fbclid fbp fbc].freeze
    RESOLUTION_KEYS = %w[status resolution_status resolved_at ad_id ad_name adset_id adset_name campaign_id campaign_name placement placement_source
                        campaign_objective adset_destination adset_goal ad_status creative_id creative_name creative_type creative_link platforms
                        device_os click_app click_delay_seconds media_type].freeze
    ENRICHMENT_KEYS = %w[version acquisition_id revision phone_number instance_id provider_message_id site_event_id page_url source occurred_at visitor_id ctwa_clid source_id source_url headline first_touch last_touch resolution consent].freeze
    module_function

    def enabled?
      ENV['CRA_ACQUISITION_ENABLED'] == 'true'
    end

    # Include inactive scoped rules: disabling CRA must never fall into legacy automation.
    def rule_for(inbox)
      LeadAutomationRule.kept.where(acquisition_scope_key: 'client:cra').order(:id).find do |rule|
        rule.conditions.dig('ctwa', 'inbox_id') == inbox.id &&
          rule.conditions.dig('ctwa', 'instance_name') == inbox.channel.provider_config['instance_name']
      end
    end

    def time?(value)
      value.is_a?(String) && Time.iso8601(value) <= Time.current + 60.seconds
    rescue ArgumentError
      false
    end

    def touch?(touch)
      touch.is_a?(Hash) && (touch.keys - TOUCH_KEYS).empty? && touch.all? { |k, v| v.nil? || (v.is_a?(String) && v.bytesize <= 2048 && !v.match?(/[\u0000-\u001f]/)) } &&
        (!touch['page_url'] || Matcher.domain_url?(touch['page_url'], HOST))
    end

    def consent?(c)
      c.is_a?(Hash) && (c.keys - %w[version at basis analytics ads]).empty? &&
        c['basis'] == 'explicit' && c['analytics'] == true && [true, false].include?(c['ads']) &&
        c['version'].is_a?(String) && c['version'].length.between?(1, 80) && time?(c['at'])
    end

    def acquisition?(a)
      return false unless a.is_a?(Hash) && (a.keys - %w[visitor_id first_touch last_touch consent_version consent_at consent_basis analytics ads]).empty?
      VISITOR.match?(a['visitor_id'].to_s) && touch?(a['first_touch']) && touch?(a['last_touch']) &&
        consent?({ 'version' => a['consent_version'], 'at' => a['consent_at'], 'basis' => a['consent_basis'], 'analytics' => a['analytics'], 'ads' => a['ads'] })
    end

    def intake?(p, key)
      return false unless p.is_a?(Hash) && (p.keys - %w[version event_id page_url contact contact_consent acquisition]).empty?
      c = p['contact']; consent = p['contact_consent']
      p['version'] == 2 && UUID.match?(p['event_id'].to_s) && p['event_id'] == key && Matcher.domain_url?(p['page_url'], HOST) &&
        c.is_a?(Hash) && c.keys.sort == %w[name phone_number] && c['name'].is_a?(String) && c['name'].strip.length.between?(1, 120) &&
        c['phone_number'].is_a?(String) && c['phone_number'].match?(/\A\+[1-9]\d{9,14}\z/) &&
        consent.is_a?(Hash) && consent.keys.sort == %w[accepted at version] && consent['accepted'] == true &&
        consent['version'].is_a?(String) && consent['version'].length.between?(1, 80) && time?(consent['at']) &&
        (!p.key?('acquisition') || acquisition?(p['acquisition']))
    end

    def enrichment?(p, key)
      return false unless p.is_a?(Hash) && (p.keys - ENRICHMENT_KEYS).empty?
      return false unless p['version'] == 1 && UUID.match?(p['acquisition_id'].to_s) && p['revision'].is_a?(Integer) && p['revision'].between?(1, 2**63 - 1)
      return false unless key == "#{p['acquisition_id']}:#{p['revision']}" && p['instance_id'] == INSTANCE_ID
      return false unless p['phone_number'].is_a?(String) && p['phone_number'].match?(/\A\+[1-9]\d{9,14}\z/) && %w[ctwa website chat].include?(p['source']) && time?(p['occurred_at'])
      return false if p['source'] == 'ctwa' && (!p['ctwa_clid'].is_a?(String) || p['ctwa_clid'].strip.empty?)
      limits = { 'ctwa_clid' => 2000, 'source_id' => 30, 'source_url' => 2048, 'headline' => 255, 'provider_message_id' => 200 }
      return false unless limits.all? { |k, max| !p.key?(k) || p[k].nil? || (p[k].is_a?(String) && p[k].bytesize <= max && !p[k].match?(/[\u0000-\u001f]/)) }
      return false if p['visitor_id'] && !VISITOR.match?(p['visitor_id'])
      return false if p['site_event_id'] && !UUID.match?(p['site_event_id'])
      return false if p['page_url'] && !Matcher.domain_url?(p['page_url'], HOST)
      return false unless %w[first_touch last_touch].all? { |k| !p.key?(k) || touch?(p[k]) }
      return false if p['consent'] && !consent?(p['consent'])
      r = p['resolution']
      !r || (r.is_a?(Hash) && (r.keys - RESOLUTION_KEYS).empty? && r.values.all? { |v| v.nil? || (v.is_a?(String) && v.bytesize <= 255) })
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |k| [k, canonical(value[k])] }
      when Array then value.map { |v| canonical(v) }
      else value
      end
    end

    def lock(key)
      digest = Digest::SHA256.hexdigest("cra:#{key}").first(15).to_i(16)
      ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{digest})")
    end
  end
end
