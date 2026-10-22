# frozen_string_literal: true

class AddInstagramGraphExecution < ActiveRecord::Migration[7.0]
  def change
    add_column :instagram_amh_deliveries, :execution_trace, :jsonb, null: false, default: []
    add_column :instagram_amh_deliveries, :graph_cursor, :string
  end
end
