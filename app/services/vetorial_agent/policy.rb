# Closed by default. Only one attached inbox is eligible; no global bot routing.
module VetorialAgent::Policy
  def self.secret
    path = ENV.fetch('VETORIAL_AGENT_SECRET_FILE', nil)
    return File.read(path).strip if path.present?

    Rails.env.production? ? '' : ENV.fetch('VETORIAL_AGENT_SECRET', '')
  end

  def self.scoped?(conversation)
    ENV['VETORIAL_AGENT_INBOX_ID'].present? && conversation.inbox_id.to_s == ENV['VETORIAL_AGENT_INBOX_ID'] &&
      conversation.inbox.channel.is_a?(Channel::Whatsapp) && conversation.inbox.channel.evolution_attached?
  end

  def self.eligible?(conversation)
    phone = conversation.contact.phone_number.to_s
    allowed = ENV.fetch('VETORIAL_AGENT_ALLOWLIST', '').split(',').map(&:strip).reject(&:blank?)
    internal = ENV.fetch('VETORIAL_AGENT_INTERNAL_NUMBERS', '').split(',').map(&:strip)
    scoped?(conversation) && eligible_phone?(phone, allowed, internal) && !conversation.contact.blocked?
  end

  # The analyst has private-only capabilities; it never expands public sending permission.
  def self.analysis_eligible?(conversation)
    return eligible?(conversation) unless ENV['VETORIAL_AGENT_ANALYSIS_ALL'] == 'true'

    phone = conversation.contact.phone_number.to_s
    internal = ENV.fetch('VETORIAL_AGENT_INTERNAL_NUMBERS', '').split(',').map(&:strip)
    scoped?(conversation) && phone.match?(/\A\+[1-9]\d{6,14}\z/) && internal.exclude?(phone) && !conversation.contact.blocked?
  end

  def self.eligible_phone?(phone, allowed, internal)
    enabled = ENV['VETORIAL_AGENT_ALL_CONTACTS'] == 'true' || allowed.include?(phone)
    phone.match?(/\A\+[1-9]\d{6,14}\z/) && enabled && internal.exclude?(phone)
  end

  def self.allowed?(conversation)
    eligible?(conversation) && conversation.assignee_id.nil?
  end
end
