class LeadAutomationRun < ApplicationRecord
  belongs_to :rule, class_name: 'LeadAutomationRule'
  belongs_to :event, class_name: 'LeadAutomationEvent'
  validates :contact_id, :rule_revision, :executed_at, presence: true
  validates :contact_id, uniqueness: { scope: :rule_id }
  validates :status, inclusion: { in: %w[created existing skipped error] }
  validates :source, inclusion: { in: %w[ctwa domain none] }
  validates :attempts, numericality: { only_integer: true, greater_than: 0 }
  validates :reason_code, format: { with: /\A[a-z0-9_]{1,80}\z/ }, allow_nil: true
end
