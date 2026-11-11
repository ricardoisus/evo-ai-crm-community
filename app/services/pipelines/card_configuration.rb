# frozen_string_literal: true

module Pipelines
  module CardConfiguration
    NATIVE = {
      'title' => 'Título', 'value' => 'Valor', 'contact' => 'Contato',
      'company' => 'Empresa', 'owner' => 'Responsável', 'labels' => 'Etiquetas',
      'channel_origin' => 'Canal e origem', 'utm' => 'Campanha (UTM)',
      'stage_age' => 'Tempo na etapa', 'last_activity' => 'Última atividade',
      'last_message' => 'Última mensagem', 'next_task' => 'Próxima tarefa',
      'created_at' => 'Data de criação'
    }.freeze

    module_function

    def definitions(pipeline)
      native = NATIVE.map { |id, label| { id: id, label: label, type: 'text', source: 'native' } }
      custom = CustomAttributeDefinition.where(attribute_model: %i[contact_attribute pipeline_item_attribute]).map do |definition|
        source = definition.contact_attribute? ? 'contact_attribute' : 'deal_attribute'
        { id: "#{source}:#{definition.attribute_key}", label: definition.attribute_display_name,
          type: definition.attribute_display_type, source: source }
      end
      local = [pipeline, *pipeline.pipeline_stages].flat_map { |resource| local_definitions(resource) }
      native + (custom + local).uniq { |field| field[:id] }
    end

    def local_definitions(resource)
      fields = resource.custom_fields || {}
      Array(fields['attributes']).map do |key|
        definition = fields.dig('attribute_definitions', key) || {}
        { id: "deal_attribute:#{key}", label: definition['attribute_display_name'].presence || key,
          type: definition['attribute_display_type'] || 'text', source: 'deal_attribute' }
      end
    end

    def valid?(pipeline, config)
      return false unless valid_header?(config)

      fields = config['fields']
      return false unless fields.is_a?(Array) && fields.first == { 'id' => 'title', 'visible' => true }

      # Retain removed definitions already saved; never accept new unknown IDs.
      saved = saved_field_ids(pipeline)
      allowed = definitions(pipeline).pluck(:id) + saved
      fields.all? { |field| valid_field?(field, allowed) } && fields.pluck('id').uniq.length == fields.length
    end

    def saved_field_ids(pipeline)
      Array(pipeline.card_configuration_in_database&.dig('fields')).pluck('id')
    end

    def valid_header?(config)
      config.is_a?(Hash) && config.keys.sort == %w[density fields version] &&
        config['version'] == 1 && %w[comfortable compact].include?(config['density'])
    end

    def valid_field?(field, allowed)
      field.is_a?(Hash) && field.keys.sort == %w[id visible] && allowed.include?(field['id']) &&
        (field['visible'] == true || field['visible'] == false)
    end
  end
end
