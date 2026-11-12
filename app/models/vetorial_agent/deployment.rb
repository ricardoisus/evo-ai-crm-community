class VetorialAgent::Deployment < ApplicationRecord
  self.table_name = 'vetorial_agent_deployments'
  belongs_to :agent_bot
  belongs_to :active_revision, class_name: 'VetorialAgent::Revision', optional: true
  has_many :profiles, class_name: 'VetorialAgent::Profile', dependent: :restrict_with_exception
  has_many :revisions, class_name: 'VetorialAgent::Revision', dependent: :restrict_with_exception
  has_many :audits, class_name: 'VetorialAgent::Audit', dependent: :restrict_with_exception
  validates :slug, uniqueness: true, presence: true
  validates :control_source, inclusion: { in: %w[legacy_transition crm] }

  def self.for_conversation(conversation)
    joins(:active_revision).find_by("vetorial_agent_revisions.payload -> 'binding' -> 'inbox_ids' @> ?", [conversation.inbox_id.to_s].to_json)
  end

  def self.managed_bot?(id)
    id.present? && exists?(agent_bot_id: id)
  end

  def payload
    active_revision&.payload
  end

  def eligible?(conversation, role = 'atendimento')
    config = payload
    return false unless config && config['binding']['inbox_ids'].include?(conversation.inbox_id.to_s)
    return false unless conversation.inbox.channel.is_a?(Channel::Whatsapp) && conversation.inbox.channel.evolution_attached?
    phone = conversation.contact.phone_number.to_s
    activation = config['activation']
    mode = activation.fetch(role)
    phone.match?(/\A\+[1-9]\d{6,14}\z/) && !conversation.contact.blocked? &&
      activation['internal_numbers'].exclude?(phone) && mode != 'off' && (mode == 'all' || activation['allowlist'].include?(phone))
  end

  def command_current?(data)
    return true if control_source == 'legacy_transition' && data['revision'].nil?
    data['revision'] == payload['revision'] && data['policy_epoch'] == policy_epoch && data['sha256'] == active_revision.sha256
  end
end
