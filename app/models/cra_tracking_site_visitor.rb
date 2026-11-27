# frozen_string_literal: true

class CraTrackingSiteVisitor < ApplicationRecord
  has_many :events, class_name: 'CraTrackingSiteEvent', foreign_key: :visitor_id, inverse_of: :visitor,
                    dependent: :delete_all

  def tracking_allowed?
    analytics? && revoked_at.nil? && expires_at > Time.current
  end
end
