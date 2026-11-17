# == Schema Information
#
# Table name: pipeline_whatsapp_inboxes
#
#  id          :uuid             not null, primary key
#  is_active   :boolean          default(TRUE), not null
#  is_default  :boolean          default(FALSE), not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  inbox_id    :uuid             not null
#  pipeline_id :uuid             not null
#
# Números de WhatsApp (inboxes) autorizados a iniciar conversa nos negócios de um pipeline.
class PipelineWhatsappInbox < ApplicationRecord
  belongs_to :pipeline
  belongs_to :inbox

  validates :inbox_id, uniqueness: { scope: :pipeline_id }
  validate :inbox_must_be_whatsapp
  validate :default_must_be_active

  scope :active, -> { where(is_active: true) }

  private

  def inbox_must_be_whatsapp
    errors.add(:inbox, 'must be a WhatsApp inbox') unless inbox&.whatsapp?
  end

  def default_must_be_active
    errors.add(:is_default, 'requires an active inbox') if is_default? && !is_active?
  end
end
