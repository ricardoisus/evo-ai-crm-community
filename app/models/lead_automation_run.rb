class LeadAutomationRun < ApplicationRecord
  belongs_to :rule, class_name: 'LeadAutomationRule'
  belongs_to :event, class_name: 'LeadAutomationEvent', optional: true
  belongs_to :scope_event, class_name: 'LeadAcquisitionScopeEvent', optional: true
  validate { errors.add(:base, 'event_required') unless event_id.present? ^ scope_event_id.present? }
  validates :contact_id, :rule_revision, :executed_at, presence: true
  validates :contact_id, uniqueness: { scope: :rule_id }
  validates :status, inclusion: { in: %w[created existing skipped error] }
  validates :source, inclusion: { in: %w[ctwa domain none] }
  validates :attempts, numericality: { only_integer: true, greater_than: 0 }
  validates :reason_code, format: { with: /\A[a-z0-9_]{1,80}\z/ }, allow_nil: true
end
