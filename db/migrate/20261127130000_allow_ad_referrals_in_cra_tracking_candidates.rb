# frozen_string_literal: true

class AllowAdReferralsInCraTrackingCandidates < ActiveRecord::Migration[7.1]
  def change
    change_column_null :cra_tracking_candidates, :visitor_key, true
    add_column :cra_tracking_candidates, :ad_id, :string, limit: 30
    add_check_constraint :cra_tracking_candidates, 'num_nonnulls(visitor_key, ad_id) = 1', name: 'cra_tracking_candidates_one_signal'
  end
end
