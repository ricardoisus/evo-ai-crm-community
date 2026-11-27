# frozen_string_literal: true

module WhatsappTracking
  class DeliveryMode
    attr_reader :name

    def initialize(name)
      @name = name
    end

    def self.enabled_inbox_ids
      return [] unless ENV['WHATSAPP_TRACKING_DELIVERY_ENABLED'] == 'true'

      ENV.fetch('WHATSAPP_TRACKING_DELIVERY_INBOX_IDS', '').split(',').map(&:strip)
    end

    def self.capture_inbox_ids
      observation = ENV.fetch('WHATSAPP_TRACKING_OBSERVE_INBOX_IDS', '').split(',').map(&:strip)
      (observation + production_inbox_ids).uniq
    end

    def self.production_inbox_ids
      owner = ENV['WHATSAPP_TRACKING_CRA_PRODUCTION_OWNER_INBOX_ID']
      enabled_inbox_ids & [owner].compact
    end

    def test_code
      ENV['WHATSAPP_TRACKING_META_TEST_CODE'].presence if name == 'test'
    end

    def ready?
      name == 'production' || (name == 'test' && test_code.present?)
    end
  end
end
