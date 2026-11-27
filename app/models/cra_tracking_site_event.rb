# frozen_string_literal: true

class CraTrackingSiteEvent < ApplicationRecord
  belongs_to :visitor, class_name: 'CraTrackingSiteVisitor', inverse_of: :events
end
