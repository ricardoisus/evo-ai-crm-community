# Status-only payloads never create empty messages. Redis retention is bounded.
class Whatsapp::ObservedStatusService
  TTL = 24.hours
  RANK = { 'sent' => 1, 'delivered' => 2, 'read' => 3, 'failed' => 4 }.freeze

  def initialize(inbox)
    @inbox = inbox
  end

  def receive(status)
    return unless status[:id].present? && RANK.key?(status[:status])

    message = @inbox.messages.find_by(source_id: status[:id])
    return apply(message, status) if message

    key = cache_key(status[:id])
    old = Rails.cache.read(key)
    return if old && RANK.fetch(old['status'], 0) >= RANK.fetch(status[:status])

    Rails.cache.write(key, status.slice(:id, :status).stringify_keys, expires_in: TTL)
  end

  def reconcile(id)
    status = Rails.cache.read(cache_key(id))
    return unless status

    message = @inbox.messages.find_by(source_id: id)
    return unless message

    apply(message, status.with_indifferent_access)
    # Keep until TTL: a surrounding transaction can still roll back.
  end

  private

  def apply(message, status)
    if message.whatsapp_observed?
      return if %w[read failed].include?(message.status)
      return if RANK.fetch(message.status, 0) >= RANK.fetch(status[:status])

      message.update!(status: status[:status])
    else
      Messages::StatusUpdateService.new(message, status[:status]).perform
    end
  end

  def cache_key(id)
    "whatsapp:pending-status:#{@inbox.id}:#{Digest::SHA256.hexdigest(id.to_s)}"
  end
end
