# frozen_string_literal: true

module WhatsappTracking
  # The input contains only receipt metadata exported from the CRA ledger.
  class CraMetaReceiptImport
    STATUS = { 'sent' => 'accepted', 'uncertain' => 'uncertain', 'leased' => 'uncertain' }.freeze
    EVENTS = { 'website' => %w[Lead QualifiedLead], 'chat' => %w[Lead QualifiedLead],
               'business_messaging' => %w[LeadSubmitted QualifiedLead] }.freeze

    def initialize(inbox:)
      unless inbox.whatsapp? && inbox.channel.provider_config['attached_instance_id'] == LeadAutomations::CraAcquisition::INSTANCE_ID
        raise ArgumentError, 'invalid CRA receipt migration inbox'
      end

      @inbox = inbox
    end

    def call(rows, commit: false)
      metrics = Hash.new(0)
      WhatsappTrackingDelivery.transaction do
        rows.each { |row| metrics[import(row)] += 1 }
        raise ActiveRecord::Rollback unless commit
      end
      metrics
    end

    private

    def import(row)
      event_id = row.fetch('event_id')
      name = row.fetch('event_name')
      source = row.fetch('action_source')
      status = STATUS.fetch(row.fetch('status'))
      raise ArgumentError, 'invalid CRA receipt identity' unless /\A[a-f0-9]{64}\z/.match?(event_id) && EVENTS.fetch(source).include?(name)

      time = Time.iso8601(row.fetch('occurred_at'))
      messaging = source == 'business_messaging'
      dataset = messaging ? CraConversion::MESSAGING_DATASET : CraConversion::WEBSITE_DATASET
      reference = messaging ? 'WHATSAPP_TRACKING_META_CRA_MESSAGING_TOKEN' : 'WHATSAPP_TRACKING_META_CRA_SITE_TOKEN'
      attempts = Integer(row.fetch('attempts'))
      raise ArgumentError, 'invalid CRA receipt attempt count' unless attempts.between?(0, 100)

      attributes = { event_name: name, event_id: event_id, event_time: time.to_i, action_source: source }
      identity = { inbox_id: @inbox.id, event_id: event_id, dataset_id: dataset, mode: 'production' }
      delivery = WhatsappTrackingDelivery.persist_identity!(**identity, event: attributes) do |record|
        record.assign_attributes(event: attributes, credential_ref: reference, status: status,
                                 available_at: time, expires_at: time + 7.days, created_at: time)
      end

      delivery.with_lock do
        next :existing if delivery.status == 'accepted' && delivery.receipts.exists?
        next :existing if delivery.status == 'uncertain' && status == 'uncertain' && delivery.receipts.exists?
        raise ArgumentError, 'live delivery already claimed' if delivery.status == 'sending'

        attempt = [attempts, delivery.attempt_count + 1].max
        delivery.update!(status: status, event: attributes, attempt_count: attempt, claimed_at: nil)
        delivery.receipts.create!(attempt_number: attempt, status: status,
                                 http_status: numeric(row, 'http_status'), error_code: numeric(row, 'error_code'),
                                 error_subcode: numeric(row, 'error_subcode'), created_at: receipt_time(row, time))
        status.to_sym
      end
    end

    def numeric(row, key)
      value = row[key]
      raise ArgumentError, "invalid #{key}" unless value.nil? || value.is_a?(Integer)

      value
    end

    def receipt_time(row, fallback)
      row['receipt_at'] ? Time.iso8601(row['receipt_at']) : fallback
    end
  end
end
