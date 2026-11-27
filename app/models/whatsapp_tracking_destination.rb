# frozen_string_literal: true

class WhatsappTrackingDestination < ApplicationRecord
  DATASET_FORMAT = /\A[0-9]{1,30}\z/
  CREDENTIAL_FORMAT = /\AWHATSAPP_TRACKING_META_[A-Z0-9_]{1,96}\z/

  belongs_to :inbox
  validates :name, presence: true, length: { maximum: 120 }
  validates :dataset_id, format: { with: DATASET_FORMAT }, uniqueness: { scope: :inbox_id }
  validates :credential_ref, format: { with: CREDENTIAL_FORMAT }
  validate :whatsapp_inbox

  private

  def whatsapp_inbox
    errors.add(:inbox, :invalid) unless inbox&.whatsapp?
  end
end
