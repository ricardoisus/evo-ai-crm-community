# frozen_string_literal: true

class WhatsappTrackingDelivery < ApplicationRecord
  MANUAL_RETRY_STATUSES = %w[configuration_error exhausted].freeze

  belongs_to :inbox
  belongs_to :consent_visitor, class_name: 'CraTrackingSiteVisitor', optional: true
  has_many :receipts, class_name: 'WhatsappTrackingReceipt', foreign_key: :delivery_id, inverse_of: :delivery,
                     dependent: :restrict_with_exception

  scope :ready, -> { where(status: %w[pending retryable]).where(available_at: ..Time.current) }
  scope :expired, -> { where(status: %w[pending retryable]).where(expires_at: ..Time.current) }
  scope :abandoned, -> { where(status: 'sending').where(claimed_at: ..10.minutes.ago) }

  def self.enqueue!(inbox_id:, dataset_id:, credential_ref:, event_name:, event_id:, occurred_at:, attribution:, mode: 'production', consent_visitor_id: nil)
    raise ArgumentError, 'invalid destination dataset' unless /\A[0-9]{1,30}\z/.match?(dataset_id)
    raise ArgumentError, 'invalid credential reference' unless /\AWHATSAPP_TRACKING_META_[A-Z0-9_]{1,96}\z/.match?(credential_ref)

    raise ArgumentError, 'invalid delivery mode' unless %w[test production].include?(mode)

    event = WhatsappTracking::MetaEvent.new(event_name: event_name, event_id: event_id, occurred_at: occurred_at,
                                            attribution: attribution).to_h

    persist_identity!(inbox_id: inbox_id, dataset_id: dataset_id, event_id: event_id, mode: mode, event: event) do |delivery|
      delivery.assign_attributes(credential_ref: credential_ref, consent_visitor_id: consent_visitor_id,
                                 available_at: Time.current, expires_at: occurred_at + 7.days)
    end
  end

  def self.observe!(inbox_id:, dataset_id:, credential_ref:, event_name:, event_id:, occurred_at:, attribution:)
    metadata = WhatsappTracking::MetaEvent.new(event_name: event_name, event_id: event_id, occurred_at: occurred_at,
                                               attribution: attribution).to_h.except(:user_data, :event_source_url)
    persist_identity!(inbox_id: inbox_id, dataset_id: dataset_id, event_id: event_id, mode: 'observation', event: metadata) do |delivery|
      delivery.assign_attributes(credential_ref: credential_ref, status: 'observed',
                                 available_at: Time.current, expires_at: occurred_at + 7.days)
    end
  end

  def self.persist_identity!(inbox_id:, dataset_id:, event_id:, mode:, event:)
    identity = { inbox_id: inbox_id, event_id: event_id, mode: mode }
    qualified = (event[:event_name] || event['event_name']) == 'QualifiedLead'
    identity[:dataset_id] = dataset_id unless qualified

    create_or_find_by!(identity) do |delivery|
      delivery.assign_attributes(dataset_id: dataset_id, event: event)
      yield delivery
    end
  end

  def self.cancel_visitor!(visitor_id)
    where(consent_visitor_id: visitor_id, status: %w[pending retryable configuration_error exhausted]).find_each do |record|
      record.with_lock do
        if %w[pending retryable configuration_error exhausted].include?(record.status)
          record.update!(status: 'cancelled', event: record.event.except('user_data', 'event_source_url'))
        end
      end
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
    payload = %i[accepted cancelled rejected].include?(next_status) ? event.except('user_data', 'event_source_url') : event
    update!(status: next_status, claimed_at: nil, event: payload, available_at: Time.current + (2**[attempt_count, 5].min).minutes)
  end
end
