class VetorialAgent::Usage < ApplicationRecord
  self.table_name = 'vetorial_agent_usages'
  belongs_to :deployment, class_name: 'VetorialAgent::Deployment'
end
