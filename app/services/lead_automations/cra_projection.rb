module LeadAutomations
  module CraProjection
    LABELS = {
      'source' => 'Origem', 'inbox_id' => 'Caixa', 'instance_id' => 'Instância', 'acquired_at' => 'Data da aquisição',
      'resolution_status' => 'Resolução do anúncio', 'resolution_at' => 'Data da resolução',
      'source_id' => 'ID do anúncio original', 'source_url' => 'Link do anúncio', 'headline' => 'Título do anúncio',
      'ad_id' => 'ID do anúncio', 'ad_name' => 'Anúncio', 'adset_id' => 'ID do conjunto', 'adset_name' => 'Conjunto',
      'campaign_id' => 'ID da campanha', 'campaign_name' => 'Campanha', 'placement' => 'Posicionamento', 'placement_source' => 'Fonte do posicionamento',
      'utm_source' => 'UTM origem', 'utm_medium' => 'UTM mídia', 'utm_campaign' => 'UTM campanha', 'utm_content' => 'UTM conjunto',
      'utm_term' => 'UTM anúncio', 'utm_posicionamento' => 'UTM posicionamento', 'page_url' => 'Página', 'referrer' => 'Referência'
    }.freeze
    TECHNICAL = %w[acquisition_id source inbox_id instance_id acquired_at source_id ad_id adset_id campaign_id].map { |k| "cra_#{k}" }.freeze
    STRUCTURED = %w[cra_first_touch cra_last_touch cra_consent cra_projection cra_manual_fields].freeze
    module_function

    # Provision on the dedicated pipeline only, by the administrative promotion step.
    def configure_pipeline!(rule)
      raise ArgumentError, 'cra_scope_required' unless rule.cra_scoped?
      pipeline = Pipeline.find(rule.pipeline_id)
      pipeline.with_lock do
        fields = pipeline.custom_fields.deep_dup
        keys = LABELS.keys.map { |k| "cra_#{k}" }
        fields['attributes'] = (Array(fields['attributes']) + keys).uniq
        fields['attribute_definitions'] ||= {}
        LABELS.each do |key, label|
          fields['attribute_definitions']["cra_#{key}"] = { 'attribute_display_name' => label, 'attribute_display_type' => 'text' }
        end
        visible = %w[title deal_attribute:cra_source deal_attribute:cra_campaign_name deal_attribute:cra_ad_name owner]
        config = { 'version' => 1, 'density' => 'comfortable', 'fields' => visible.map { |id| { 'id' => id, 'visible' => true } } }
        keys.each { |key| config['fields'] << { 'id' => "deal_attribute:#{key}", 'visible' => false } unless visible.include?("deal_attribute:#{key}") }
        pipeline.update!(custom_fields: fields, card_configuration: config)
      end
    end

    def call(deal, event:, payload:)
      return unless deal
      deal.with_lock do
        fields = deal.custom_fields.deep_dup
        owner = fields.dig('cra_projection', 'scope_event_id')
        next if owner && owner != event.id
        acquisition = payload['acquisition_id']
        previous = fields['cra_acquisition_id']
        next if previous && acquisition && previous != acquisition
        revision = payload['revision'].to_i
        next if acquisition && previous == acquisition && fields.dig('cra_projection', 'revision').to_i >= revision
        p = payload
        values = { 'source' => p['source'], 'inbox_id' => event.signal['inbox_id'], 'instance_id' => p['instance_id'],
                   'acquired_at' => event.occurred_at.iso8601(6), 'acquisition_id' => acquisition }
        %w[source_id source_url headline].each { |k| values[k] = p[k] }
        r = p['resolution'] || {}
        %w[ad_id ad_name adset_id adset_name campaign_id campaign_name placement placement_source].each { |k| values[k] = r[k] }
        values['resolution_status'] = r['resolution_status'] || r['status'] || (r['ad_id'].present? ? 'resolved' : 'pending')
        values['resolution_at'] = r['resolved_at']
        last = p['last_touch'] || {}
        %w[utm_source utm_medium utm_campaign utm_content utm_term utm_posicionamento page_url referrer].each { |k| values[k] = last[k] }
        values['page_url'] ||= p['page_url']
        values['placement'] ||= last['utm_posicionamento']
        values['placement_source'] ||= 'utm_posicionamento' if last['utm_posicionamento'].present?
        manual = Array(fields['cra_manual_fields'])
        values.each do |key, value|
          field = "cra_#{key}"
          next if value.nil? || manual.include?(field)
          # Technical identity never changes once projected.
          next if TECHNICAL.include?(field) && fields[field].present?
          fields[field] = value
        end
        %w[first_touch last_touch].each { |key| fields["cra_#{key}"] = safe_touch(p[key]) if p[key] }
        fields['cra_consent'] = p['consent'] if p['consent']
        fields['cra_projection'] = { 'scope_event_id' => event.id, 'revision' => revision }
        # No callbacks: enrichment has no commercial, messaging, Flow or agent effects.
        deal.update_columns(custom_fields: fields, updated_at: Time.current)
      end
    end

    def safe_touch(touch)
      touch.except('fbclid', 'fbp', 'fbc', 'visitor_id')
    end

    def egress(fields, pipeline: nil)
      fields ||= {}
      return fields unless fields.keys.any? { |key| key.start_with?('cra_') }
      return fields.reject { |key, _| key.start_with?('cra_') } unless pipeline && CraAccess.allowed?(pipeline)
      # Technical identifiers remain only in restricted audit rows, never card/socket/webhook.
      (fields || {}).except('cra_ctwa_clid', 'cra_visitor_id', 'cra_projection', 'cra_manual_fields')
    end
  end
end
