class LeadAcquisitionEnrichment < ApplicationRecord
  validates :rule_id, :acquisition_id, :digest, presence: true
  validates :revision, numericality: { only_integer: true, greater_than: 0 }
  validates :revision, uniqueness: { scope: [:rule_id, :acquisition_id] }
  validates :status, inclusion: { in: %w[pending applied superseded review] }
end
