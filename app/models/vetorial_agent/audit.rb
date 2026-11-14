class VetorialAgent::Audit < ApplicationRecord
  self.table_name = 'vetorial_agent_audits'
  belongs_to :deployment, class_name: 'VetorialAgent::Deployment'
end
