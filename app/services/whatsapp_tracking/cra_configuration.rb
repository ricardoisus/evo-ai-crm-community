# frozen_string_literal: true

module WhatsappTracking
  class CraConfiguration
    def initialize(inbox:)
      if !inbox.whatsapp? || inbox.channel.provider_config['attached_instance_id'] != LeadAutomations::CraAcquisition::INSTANCE_ID
        raise ArgumentError, 'invalid CRA configuration inbox'
      end

      @inbox = inbox
    end

    def install!(commit: false)
      WhatsappTrackingRule.transaction do
        scope = LeadAutomations::CraAcquisition.rule_for(@inbox)
        raise ArgumentError, 'missing CRA pipeline rule' unless scope&.active?

        stage = PipelineStage.where(pipeline_id: scope.pipeline_id).where('lower(name) = ?', 'pré-qualificado').sole
        web = destination!('Dataset CRA · Site', CraConversion::WEBSITE_DATASET, 'WHATSAPP_TRACKING_META_CRA_SITE_TOKEN')
        messages = destination!('Dataset CRA · Mensagens', CraConversion::MESSAGING_DATASET, 'WHATSAPP_TRACKING_META_CRA_MESSAGING_TOKEN')
        install_rules!(stage, web, messages)
        raise ActiveRecord::Rollback unless commit
      end
    end

    private

    def install_rules!(stage, web, messages)
      qualification = { 'pipeline_id' => stage.pipeline_id, 'stage_id' => stage.id }
      rule!('CRA · Lead site', 'message_received', 'Lead', web, 'website')
      rule!('CRA · Lead chat', 'message_received', 'Lead', web, 'chat')
      rule!('CRA · LeadSubmitted', 'message_received', 'LeadSubmitted', messages, 'ctwa')
      rule!('CRA · QualifiedLead site', 'stage_entered', 'QualifiedLead', web, 'website', qualification)
      rule!('CRA · QualifiedLead chat', 'stage_entered', 'QualifiedLead', web, 'chat', qualification)
      rule!('CRA · QualifiedLead CTWA', 'stage_entered', 'QualifiedLead', messages, 'ctwa', qualification)
    end

    def destination!(name, dataset_id, credential_ref)
      destination = WhatsappTrackingDestination.find_or_create_by!(inbox: @inbox, dataset_id: dataset_id) do |row|
        row.assign_attributes(name: name, credential_ref: credential_ref)
      end
      raise ArgumentError, 'CRA dataset credential reference conflicts with existing configuration' if destination.credential_ref != credential_ref

      destination
    end

    def rule!(name, trigger, event_name, destination, origin, filters = {})
      draft = { 'trigger' => trigger, 'event_name' => event_name, 'frequency' => 'contact', 'mode' => 'production',
                'destination_id' => destination.id, 'filters' => filters.merge('origin' => origin) }
      rule = WhatsappTrackingRule.find_or_initialize_by(inbox: @inbox, name: name)
      if rule.persisted?
        raise ArgumentError, 'existing CRA rule differs from canonical setup' unless rule.draft == draft && rule.published == draft

        return
      end
      rule.update!(draft: draft)
      rule.publish!
    end
  end
end
