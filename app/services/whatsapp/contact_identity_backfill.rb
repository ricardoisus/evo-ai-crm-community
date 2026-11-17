# frozen_string_literal: true

# Backfill idempotente de nome e foto para contatos WhatsApp (Evolution API).
# Roda em dry-run por padrão: nada é gravado nem baixado. Limite de taxa entre
# contatos (sleep) e relatório ao final. Nunca envia mensagem: só lê o perfil
# na Evolution (findContacts) e aplica Whatsapp::ContactIdentitySync.
#
#   rake whatsapp:backfill_contact_identity            # dry-run
#   rake whatsapp:backfill_contact_identity APPLY=1 LIMIT=50 RATE=1.5
class Whatsapp::ContactIdentityBackfill
  Report = Struct.new(:scanned, :name_updates, :avatar_updates, :no_profile, :errors, :dry_run, keyword_init: true) do
    def to_h_report
      to_h.merge(mode: dry_run ? 'dry-run' : 'apply')
    end
  end

  def initialize(inbox_ids: nil, apply: false, limit: nil, rate: 1.0, sleeper: Kernel, logger: Rails.logger) # rubocop:disable Metrics/ParameterLists
    @inbox_ids = inbox_ids
    @apply = apply
    @limit = limit
    @rate = rate.to_f
    @sleeper = sleeper
    @logger = logger
  end

  def run
    report = Report.new(scanned: 0, name_updates: 0, avatar_updates: 0, no_profile: 0, errors: 0, dry_run: !@apply)
    services = {}

    scope.find_each do |contact_inbox|
      break if @limit && report.scanned >= @limit

      process(contact_inbox, services, report)
      @sleeper.sleep(@rate) if @rate.positive? && @apply
    end
    report
  end

  private

  def scope
    inboxes = Inbox.where(channel_type: 'Channel::Whatsapp')
    inboxes = inboxes.where(id: @inbox_ids) if @inbox_ids.present?
    ContactInbox.where(inbox_id: inboxes.select(:id)).includes(:contact, :inbox)
  end

  def process(contact_inbox, services, report)
    channel = contact_inbox.inbox.channel
    return unless channel.provider == 'evolution'

    contact = contact_inbox.contact
    return unless contact && !contact.group?

    report.scanned += 1
    service = (services[channel.id] ||= Whatsapp::Providers::EvolutionService.new(whatsapp_channel: channel))
    profile = service.fetch_contact_profile(contact_inbox.source_id)
    return report.no_profile += 1 if profile.nil?

    apply_name(contact, profile[:push_name], report)
    apply_avatar(contact, profile[:profile_picture_url], report)
  rescue StandardError => e
    report.errors += 1
    @logger.error "[whatsapp:backfill_contact_identity] #{e.class}"
  end

  def apply_name(contact, push_name, report)
    return if push_name.blank?

    sync = Whatsapp::ContactIdentitySync.new(contact)
    return unless name_would_change?(contact, push_name)

    report.name_updates += 1
    sync.sync_name(push_name) if @apply
  end

  def name_would_change?(contact, push_name)
    return false if Whatsapp::ContactIdentitySync.placeholder_name?(push_name)
    return true if Whatsapp::ContactIdentitySync.placeholder_name?(contact.name)

    stored = (contact.additional_attributes || {})[Whatsapp::ContactIdentitySync::PUSH_NAME_KEY]
    contact.name == stored && contact.name != push_name
  end

  def apply_avatar(contact, url, report)
    return if url.blank?
    return unless Whatsapp::ContactIdentitySync.avatar_due?(contact)

    report.avatar_updates += 1
    return unless @apply

    Avatar::AvatarFromUrlJob.perform_now(contact, url)
    Whatsapp::ContactIdentitySync.record_avatar_result(contact, success: contact.reload.avatar.attached?)
  end
end
