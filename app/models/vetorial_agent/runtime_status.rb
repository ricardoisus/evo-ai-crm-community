class VetorialAgent::RuntimeStatus < ApplicationRecord
  self.table_name = 'vetorial_agent_runtime_statuses'
  belongs_to :deployment, class_name: 'VetorialAgent::Deployment'
end
