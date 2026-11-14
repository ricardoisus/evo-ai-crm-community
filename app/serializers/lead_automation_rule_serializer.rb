module LeadAutomationRuleSerializer
  def self.serialize(rule)
    rule.attributes.slice('id', 'name', 'active', 'activated_at', 'revision', 'conditions', 'pipeline_id',
                          'pipeline_stage_id', 'owner_id', 'label_ids', 'title_template', 'created_by_id', 'created_at', 'updated_at')
        .merge('has_intake_token' => rule.intake_token_digest.present?)
  end
end
