class LeadAcquisitionScopeEvent < ApplicationRecord
  after_create_commit { LeadAutomations::ProcessScopedEventJob.perform_later(id) }
  validates :scope_key, inclusion: { in: ['client:cra'] }
  validates :contact_id, :source_key, :occurred_at, :received_at, presence: true
  validates :contact_id, uniqueness: { scope: :scope_key }
  validates :source_key, uniqueness: { scope: :scope_key }, length: { maximum: 200 }
  validates :source, inclusion: { in: %w[none ctwa domain website] }
  validates :status, inclusion: { in: %w[pending waiting processed failed] }
end
