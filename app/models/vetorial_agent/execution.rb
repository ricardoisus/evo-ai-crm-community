class VetorialAgent::Execution < ApplicationRecord
  self.table_name = 'vetorial_agent_executions'
  belongs_to :deployment, class_name: 'VetorialAgent::Deployment'
end
