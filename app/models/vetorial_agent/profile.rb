class VetorialAgent::Profile < ApplicationRecord
  self.table_name = 'vetorial_agent_profiles'
  belongs_to :deployment, class_name: 'VetorialAgent::Deployment'
  validates :role, inclusion: { in: %w[atendimento analista] }, uniqueness: { scope: :deployment_id }
  validates :name, presence: true
end
