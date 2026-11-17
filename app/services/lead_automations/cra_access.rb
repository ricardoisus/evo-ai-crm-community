module LeadAutomations
  module CraAccess
    module_function
    def allowed?(pipeline, user = Current.user)
      rule = LeadAutomationRule.kept.find_by(pipeline_id: pipeline.id, acquisition_scope_key: 'client:cra')
      return true unless rule
      return false unless user
      inbox = Inbox.find_by(id: rule.conditions.dig('ctwa', 'inbox_id'))
      (user.administrator? || pipeline.created_by_id == user.id) && inbox &&
        InboxPolicy.new({ user: user }, inbox).show?
    end
  end
end
