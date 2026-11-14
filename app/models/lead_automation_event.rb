class LeadAutomationEvent < ApplicationRecord
  validates :contact_id, :source_key, :occurred_at, :received_at, presence: true
  validates :source_key, uniqueness: true, length: { maximum: 200 }
  validates :contact_id, uniqueness: true
  validates :source, inclusion: { in: %w[ctwa domain none] }
  validates :status, inclusion: { in: %w[pending processed failed] }
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate do
    allowed = %w[inbox_id instance_name ctwa_clid source_id source_url source_type host rule_id]
    errors.add(:signal, 'invalid_signal') unless signal.is_a?(Hash) && (signal.keys - allowed).empty? && signal.values.all? { |v| v.is_a?(String) && v.length <= 2000 }
  end
end
