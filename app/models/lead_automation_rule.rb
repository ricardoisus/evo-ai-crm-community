require 'digest'
class LeadAutomationRule < ApplicationRecord
  scope :kept, -> { where(deleted_at: nil) }
  has_many :runs, class_name: 'LeadAutomationRun', foreign_key: :rule_id
  validates :name, presence: true, length: { maximum: 120 }
  validates :active, inclusion: { in: [true, false] }
  validates :revision, numericality: { only_integer: true, greater_than: 0 }
  validates :title_template, presence: true, length: { maximum: 160 }
  validate :validate_configuration
  before_save :track_activation

  def token_valid?(token)
    token.is_a?(String) && intake_token_digest.present? &&
      ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(token), intake_token_digest)
  end

  def destinations_valid?
    Pipeline.exists?(id: pipeline_id) && PipelineStage.exists?(id: pipeline_stage_id, pipeline_id: pipeline_id) &&
      (owner_id.nil? || User.exists?(id: owner_id)) && label_ids.is_a?(Array) &&
      label_ids.all? { |id| id.is_a?(String) } && Label.where(id: label_ids).count == label_ids.uniq.length
  end

  private

  def track_activation
    self.activated_at = Time.current if active && (new_record? || will_save_change_to_active?)
    self.revision = revision_in_database + 1 unless new_record?
  end

  def validate_configuration
    errors.add(:base, 'destination_missing') unless destinations_valid?
    errors.add(:title_template, 'invalid_template') if title_template.to_s.gsub('{{contact_name}}', '').match?(/[{}]/)
    c = conditions
    unless c.is_a?(Hash) && (c.keys - %w[version operator ctwa domain]).empty? && c['version'] == 1 && c['operator'] == 'any'
      errors.add(:conditions, 'invalid_conditions')
      return
    end
    enabled = false
    %w[ctwa domain].each do |source|
      next unless c.key?(source)
      s = c[source]
      allowed = source == 'ctwa' ? %w[enabled inbox_id instance_name] : %w[enabled host]
      unless s.is_a?(Hash) && (s.keys - allowed).empty? && [true, false].include?(s['enabled'])
        errors.add(:conditions, 'invalid_source')
        next
      end
      next unless s['enabled']
      enabled = true
      if source == 'domain'
        host = s['host']
        errors.add(:conditions, 'invalid_domain') unless host.is_a?(String) && host.length <= 253 && host.match?(/\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/)
      else
        box = Inbox.find_by(id: s['inbox_id'])
        channel = box&.channel
        errors.add(:conditions, 'invalid_inbox') unless channel.is_a?(Channel::Whatsapp) && channel.provider == 'evolution' &&
          s['instance_name'].is_a?(String) && s['instance_name'].present? && channel.provider_config['instance_name'] == s['instance_name']
      end
    end
    errors.add(:conditions, 'empty_sources') unless enabled
  end
end
