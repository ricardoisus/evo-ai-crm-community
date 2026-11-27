# frozen_string_literal: true

class CraTrackingAd < ApplicationRecord
  scope :due, -> { where(status: %w[pending retry resolving]).where(next_attempt_at: ..Time.current) }

  def self.cooling_down?
    where('cooldown_until > ?', Time.current).exists?
  end

  def claim
    with_lock do
      next unless %w[pending retry resolving].include?(status) && next_attempt_at <= Time.current

      update!(status: 'resolving', attempt_count: attempt_count + 1, next_attempt_at: 2.minutes.from_now)
      attempt_count
    end
  end

  def finish!(attempt, result)
    with_lock do
      next unless status == 'resolving' && attempt == attempt_count

      delay = (2**[attempt, 6].min).minutes
      update!(status: result.fetch(:status), resolution: result.fetch(:resolution, {}),
              resolved_at: result[:status] == 'resolved' ? Time.current : nil,
              cooldown_until: result[:cooldown] ? 15.minutes.from_now : nil, next_attempt_at: Time.current + delay)
    end
  end
end
