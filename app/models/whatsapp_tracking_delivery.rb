# frozen_string_literal: true

class WhatsappTrackingDelivery < ApplicationRecord
  MANUAL_RETRY_STATUSES = %w[configuration_error exhausted].freeze

  belongs_to :inbox
  has_many :receipts, class_name: 'WhatsappTrackingReceipt', foreign_key: :delivery_id, inverse_of: :delivery,
                     dependent: :restrict_with_exception

  scope :ready, -> { where(status: %w[pending retryable]).where(available_at: ..Time.current) }
  scope :expired, -> { where(status: %w[pending retryable]).where(expires_at: ..Time.current) }
  scope :abandoned, -> { where(status: 'sending').where(claimed_at: ..10.minutes.ago) }

  def self.enqueue!(inbox_id:, dataset_id:, credential_ref:, event_name:, event_id:, occurred_at:, attribution:, mode: 'production')
    raise ArgumentError, 'invalid destination dataset' unless /\A[0-9]{1,30}\z/.match?(dataset_id)
    raise ArgumentError, 'invalid credential reference' unless /\AWHATSAPP_TRACKING_META_[A-Z0-9_]{1,96}\z/.match?(credential_ref)

    raise ArgumentError, 'invalid delivery mode' unless %w[test production].include?(mode)

    event = WhatsappTracking::MetaEvent.new(event_name: event_name, event_id: event_id, occurred_at: occurred_at,
                                            attribution: attribution).to_h

    create_or_find_by!(inbox_id: inbox_id, dataset_id: dataset_id, event_id: event_id, mode: mode) do |delivery|
      delivery.assign_attributes(credential_ref: credential_ref, event: event, available_at: Time.current, expires_at: occurred_at + 7.days)
    end
  end

  def self.observe!(inbox_id:, dataset_id:, credential_ref:, event_name:, event_id:, occurred_at:, attribution:)
    metadata = WhatsappTracking::MetaEvent.new(event_name: event_name, event_id: event_id, occurred_at: occurred_at,
                                               attribution: attribution).to_h.except(:user_data, :event_source_url)
    create_or_find_by!(inbox_id: inbox_id, dataset_id: dataset_id, event_id: event_id, mode: 'observation') do |delivery|
      delivery.assign_attributes(credential_ref: credential_ref, event: metadata, status: 'observed',
                                 available_at: Time.current, expires_at: occurred_at + 7.days)
    end
  end

  def claim
    with_lock do
      return unless %w[pending retryable].include?(status) && available_at <= Time.current

      if expires_at <= Time.current
        update!(status: 'expired')
        next
      end

      update!(status: 'sending', claimed_at: Time.current, attempt_count: attempt_count + 1)
      attempt_count
    end
  end

  def finish!(attempt, receipt)
    with_lock do
      return unless attempt == attempt_count && status == 'sending'

      record_receipt!(receipt)
    end
  end

  def retry_manually
    with_lock do
      next false unless MANUAL_RETRY_STATUSES.include?(status) && expires_at > Time.current

      update!(status: 'pending', available_at: Time.current)
    end
  end

  def expire_claim!
    with_lock do
      return unless status == 'sending' && claimed_at <= 10.minutes.ago

      record_receipt!(status: :uncertain)
    end
  end

  private

  def record_receipt!(receipt)
    disposition = receipt.fetch(:status)
    receipts.create!(attempt_number: attempt_count, status: disposition,
                     **receipt.slice(:http_status, :error_code, :error_subcode))

    next_status = disposition == :retryable && attempt_count >= 5 ? :exhausted : disposition
    update!(status: next_status, claimed_at: nil, available_at: Time.current + (2**[attempt_count, 5].min).minutes)
  end
end
