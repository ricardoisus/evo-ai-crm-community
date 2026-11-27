# frozen_string_literal: true

class WhatsappTrackingReceipt < ApplicationRecord
  belongs_to :delivery, class_name: 'WhatsappTrackingDelivery', inverse_of: :receipts
end
