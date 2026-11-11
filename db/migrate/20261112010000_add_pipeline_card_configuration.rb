class AddPipelineCardConfiguration < ActiveRecord::Migration[7.1]
  def change
    add_column :pipelines, :card_configuration, :jsonb, null: false, default: {}
    add_column :pipelines, :card_configuration_revision, :integer, null: false, default: 0
  end
end
