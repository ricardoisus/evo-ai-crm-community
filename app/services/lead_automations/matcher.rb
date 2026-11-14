require 'uri'
module LeadAutomations
  class Matcher
    def self.domain_url?(url, host)
      return false unless url.is_a?(String) && url.bytesize <= 4096
      uri = URI.parse(url)
      uri.is_a?(URI::HTTPS) && uri.host&.downcase == host && uri.userinfo.nil? && uri.port == 443
    rescue URI::InvalidURIError
      false
    end

    def self.call(rule, event)
      e = event.stringify_keys
      reasons = []
      reasons << 'inactive' unless rule.active && rule.deleted_at.nil?
      reasons << 'destination_missing' unless rule.destinations_valid?
      cutoff = rule.activated_at
      %w[occurred_at contact_created_at].each do |key|
        time = parse_time(e[key])
        reasons << (key == 'contact_created_at' ? 'old_contact' : 'old_event') unless cutoff && time && time >= cutoff && time <= Time.current + 60.seconds
      end
      if e['conversation_created_at'].present?
        time = parse_time(e['conversation_created_at'])
        reasons << 'old_conversation' unless cutoff && time && time >= cutoff && time <= Time.current + 60.seconds
      end
      c = rule.conditions
      matched = case e['source']
                when 'ctwa'
                  s = c['ctwa'] || {}
                  s['enabled'] == true && s['inbox_id'] == e['inbox_id'] && s['instance_name'] == e['instance_name'] &&
                    e['ctwa_clid'].is_a?(String) && e['ctwa_clid'].strip.present? && e['ctwa_clid'].length <= 2000
                when 'domain'
                  s = c['domain'] || {}
                  s['enabled'] == true && domain_url?(e['page_url'], s['host'])
                else false
                end
      reasons << 'no_match' unless matched
      { matched: reasons.empty?, reasons: reasons.uniq, dry_run: true,
        action: { pipeline_id: rule.pipeline_id, pipeline_stage_id: rule.pipeline_stage_id, owner_id: rule.owner_id,
                  label_ids: rule.label_ids, title: rule.title_template.gsub('{{contact_name}}', 'Contato sintético') } }
    end

    def self.parse_time(value)
      Time.iso8601(value) if value.is_a?(String)
    rescue ArgumentError
      nil
    end
  end
end
