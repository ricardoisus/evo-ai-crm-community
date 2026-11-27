# frozen_string_literal: true

module WhatsappTracking
  class CraSiteStateImport
    KEY = /\A[a-f0-9]{64}\z/

    def call(snapshot, commit: false)
      metrics = Hash.new(0)
      CraTrackingSiteVisitor.transaction do
        snapshot.fetch('visitors').each { |row| metrics[visitor(row)] += 1 }
        snapshot.fetch('events').each { |row| metrics[event(row)] += 1 }
        snapshot.fetch('intake_receipts').each { |row| metrics[receipt(row)] += 1 }
        raise ActiveRecord::Rollback unless commit
      end
      metrics
    end

    private

    def visitor(row)
      key = valid_key(row.fetch('visitor_key'))
      LeadAutomations::CraAcquisition.lock("native:visitor:#{key}")
      record = CraTrackingSiteVisitor.find_or_initialize_by(visitor_key: key)
      revoked = instant(row['revoked_at'])
      consented = instant(row['consented_at'])
      if record.persisted?
        current = [record.revoked_at, record.consented_at].compact.max
        incoming = [revoked, consented].compact.max
        return :visitor_existing if current && (!incoming || current > incoming || (current == incoming && (!revoked || record.revoked_at)))
      end

      record.assign_attributes(
        analytics: !revoked && row['analytics'] == true, ads: !revoked && row['analytics'] == true && row['ads'] == true,
        consent_version: row['consent_version'], consented_at: consented, revoked_at: revoked,
        expires_at: instant(row.fetch('expires_at')), first_touch: allowed_touch(row.fetch('first_touch', {})),
        last_touch: allowed_touch(row.fetch('last_touch', {}))
      )
      if revoked
        record.assign_attributes(first_touch: {}, last_touch: {})
      elsif !record.ads?
        record.first_touch = record.first_touch.except(*CraSiteContract::BROWSER_KEYS)
        record.last_touch = record.last_touch.except(*CraSiteContract::BROWSER_KEYS)
      end
      record.save!
      if revoked || !record.ads?
        WhatsappTrackingDelivery.cancel_visitor!(record.id)
        if revoked
          record.events.delete_all
          CraTrackingCandidate.where(visitor_key: key, status: 'pending').update_all(status: 'revoked', updated_at: Time.current)
        else
          record.events.where(ads: true).update_all(ads: false, last_touch: {})
        end
      end
      :visitor_imported
    end

    def event(row)
      record = CraTrackingSiteVisitor.find_by(visitor_key: valid_key(row.fetch('visitor_key')))
      return :event_inactive unless record&.tracking_allowed?

      id = row.fetch('event_id')
      type = row.fetch('kind')
      fingerprint = valid_key(row.fetch('fingerprint'))
      path = row.fetch('path')
      raise ArgumentError, 'invalid legacy site event' unless CraSiteContract::UUID.match?(id) &&
                                                               %w[page_view whatsapp_click].include?(type) &&
                                                               CraSiteContract::PATH.match?(path) && path.length <= 500

      delivery = CraTrackingSiteEvent.find_or_initialize_by(event_id: id)
      if delivery.persisted?
        raise ArgumentError, 'legacy site event conflict' unless delivery.visitor_id == record.id && delivery.fingerprint == fingerprint

        return :event_existing
      end

      ads = row['ads'] == true && record.ads?
      delivery.update!(visitor: record, kind: type, fingerprint: fingerprint, path: path, ads: ads,
                       occurred_at: instant(row.fetch('occurred_at')), last_touch: ads ? allowed_touch(row.fetch('last_touch')) : {})
      :event_imported
    end

    def receipt(row)
      id = row.fetch('event_id')
      raise ArgumentError, 'invalid legacy intake receipt' unless CraSiteContract::UUID.match?(id)

      fingerprint = valid_key(row.fetch('fingerprint'))
      record = CraTrackingIntakeReceipt.find_or_initialize_by(event_id: id)
      if record.persisted?
        raise ArgumentError, 'legacy site intake conflict' unless record.fingerprint == fingerprint

        return :intake_existing
      end

      record.update!(fingerprint: fingerprint, created_at: instant(row.fetch('created_at')))
      :intake_imported
    end

    def allowed_touch(value)
      raise ArgumentError, 'invalid touch metadata' unless value.is_a?(Hash)

      value.slice(*(CraSiteContract::UTM_KEYS + CraSiteContract::BROWSER_KEYS + %w[page_url referrer captured_at]))
    end

    def valid_key(value)
      raise ArgumentError, 'invalid legacy tracking key' unless KEY.match?(value)

      value
    end

    def instant(value)
      Time.iso8601(value) if value
    end
  end
end
