class AddVetorialPricingVersion < ActiveRecord::Migration[7.1]
  def change
    add_column :vetorial_agent_usages, :pricing_version, :string
  end
end
