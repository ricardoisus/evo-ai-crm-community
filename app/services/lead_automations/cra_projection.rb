module LeadAutomations
  module CraProjection
    LABELS = {
      'source' => 'Origem', 'inbox_id' => 'Caixa', 'instance_id' => 'Instância', 'acquired_at' => 'Data da aquisição',
      'resolution_status' => 'Resolução do anúncio', 'resolution_at' => 'Data da resolução',
      'source_id' => 'ID do anúncio original', 'source_url' => 'Link do anúncio', 'headline' => 'Título do anúncio',
      'ad_id' => 'ID do anúncio', 'ad_name' => 'Anúncio', 'adset_id' => 'ID do conjunto', 'adset_name' => 'Conjunto',
      'campaign_id' => 'ID da campanha', 'campaign_name' => 'Campanha', 'placement' => 'Posicionamento', 'placement_source' => 'Fonte do posicionamento',
      'utm_source' => 'UTM origem', 'utm_medium' => 'UTM mídia', 'utm_campaign' => 'UTM campanha', 'utm_content' => 'UTM conjunto',
      'utm_term' => 'UTM anúncio', 'utm_posicionamento' => 'UTM posicionamento', 'page_url' => 'Página', 'referrer' => 'Referência',
      'origin_label' => 'Origem (texto)', 'media_label' => 'Mídia (texto)',
      'campaign_objective' => 'Objetivo da campanha', 'adset_destination' => 'Destino do conjunto', 'adset_goal' => 'Otimização do conjunto',
      'ad_status' => 'Status do anúncio', 'creative_id' => 'ID do criativo', 'creative_name' => 'Criativo', 'creative_type' => 'Tipo do criativo',
      'creative_link' => 'Link do criativo', 'platforms' => 'Plataformas do anúncio', 'device_os' => 'Dispositivo', 'click_app' => 'App do clique',
      'click_delay_seconds' => 'Segundos do clique à mensagem', 'media_type' => 'Formato do anúncio', 'ddd' => 'DDD', 'uf' => 'Estado (pelo DDD)'
    }.freeze
    # DDD brasileiro -> UF (localização aproximada, derivada do telefone; sem IP nem geolocalização).
    DDD_UF = {
      '11' => 'SP', '12' => 'SP', '13' => 'SP', '14' => 'SP', '15' => 'SP', '16' => 'SP', '17' => 'SP', '18' => 'SP', '19' => 'SP',
      '21' => 'RJ', '22' => 'RJ', '24' => 'RJ', '27' => 'ES', '28' => 'ES', '31' => 'MG', '32' => 'MG', '33' => 'MG', '34' => 'MG',
      '35' => 'MG', '37' => 'MG', '38' => 'MG', '41' => 'PR', '42' => 'PR', '43' => 'PR', '44' => 'PR', '45' => 'PR', '46' => 'PR',
      '47' => 'SC', '48' => 'SC', '49' => 'SC', '51' => 'RS', '53' => 'RS', '54' => 'RS', '55' => 'RS', '61' => 'DF', '62' => 'GO',
      '63' => 'TO', '64' => 'GO', '65' => 'MT', '66' => 'MT', '67' => 'MS', '68' => 'AC', '69' => 'RO', '71' => 'BA', '73' => 'BA',
      '74' => 'BA', '75' => 'BA', '77' => 'BA', '79' => 'SE', '81' => 'PE', '82' => 'AL', '83' => 'PB', '84' => 'RN', '85' => 'CE',
      '86' => 'PI', '87' => 'PE', '88' => 'CE', '89' => 'PI', '91' => 'PA', '92' => 'AM', '93' => 'PA', '94' => 'PA', '95' => 'RR',
      '96' => 'AP', '97' => 'AM', '98' => 'MA', '99' => 'MA'
    }.freeze
    TECHNICAL = %w[acquisition_id source inbox_id instance_id acquired_at source_id ad_id adset_id campaign_id].map { |k| "cra_#{k}" }.freeze
    # Campos de parâmetro padrão do negócio, preenchidos com os dados do anúncio/UTM (sem prefixo cra_).
    PARAMETER_FIELDS = %w[utm_source utm_medium utm_campaign utm_content utm_term].freeze
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
        %w[ad_id ad_name adset_id adset_name campaign_id campaign_name placement placement_source campaign_objective adset_destination adset_goal ad_status
           creative_id creative_name creative_type creative_link platforms device_os click_app click_delay_seconds media_type].each { |k| values[k] = r[k] }
        if p['source'] == 'ctwa'
          values['origin_label'] = 'Meta Ads'
          values['media_label'] = 'Click to WhatsApp'
        end
        digits = p['phone_number'].to_s.delete('^0-9')
        if digits.start_with?('55') && digits.length >= 12
          values['ddd'] = digits[2, 2]
          values['uf'] = DDD_UF[values['ddd']]
        end
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
        auto = mirror_parameters!(fields, values, manual)
        fields['cra_projection'] = { 'scope_event_id' => event.id, 'revision' => revision, 'utm_auto' => auto }
        # No callbacks: enrichment has no commercial, messaging, Flow or agent effects.
        deal.update_columns(custom_fields: fields, updated_at: Time.current)
      end
    end

    # UTM do site tem prioridade; no CTWA segue a convenção do site (IDs): MetaAds/cpc, campanha, conjunto e anúncio por ID.
    # Posicionamento só vem preenchido quando houver dado real (o clique CTWA não o informa). Valor humano nunca é sobrescrito.
    def parameter_values(values)
      ctwa = values['source'] == 'ctwa'
      {
        'utm_source' => values['utm_source'].presence || (ctwa ? 'MetaAds' : nil),
        'utm_medium' => values['utm_medium'].presence || (ctwa ? 'cpc' : nil),
        'utm_campaign' => values['utm_campaign'].presence || values['campaign_id'],
        'utm_content' => values['utm_content'].presence || values['adset_id'],
        'utm_term' => values['utm_term'].presence || values['ad_id']
      }
    end

    def mirror_parameters!(fields, values, manual)
      auto = Array(fields.dig('cra_projection', 'utm_auto'))
      parameter_values(values).each do |field, value|
        next if value.blank? || manual.include?(field)
        next if fields[field].present? && !auto.include?(field)
        fields[field] = value
        auto |= [field]
      end
      auto
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
