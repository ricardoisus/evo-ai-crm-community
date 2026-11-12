class VetorialAgent::Revision < ApplicationRecord
  self.table_name = 'vetorial_agent_revisions'
  belongs_to :deployment, class_name: 'VetorialAgent::Deployment'
  validates :number, uniqueness: { scope: :deployment_id }
  validates :status, inclusion: { in: %w[draft published] }
  validate :valid_snapshot
  before_update { throw(:abort) if status_in_database == 'published' }
  before_destroy { throw(:abort) if status == 'published' }

  private

  def valid_snapshot
    VetorialAgent::Snapshot.validate!(payload)
    errors.add(:sha256, 'não corresponde à configuração') unless sha256 == VetorialAgent::Snapshot.digest(payload)
  rescue VetorialAgent::Snapshot::Invalid
    errors.add(:payload, 'Configuração inválida.')
  end
end
