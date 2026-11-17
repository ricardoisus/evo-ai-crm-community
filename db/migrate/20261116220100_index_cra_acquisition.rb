class IndexCraAcquisition < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!
  def change
    add_index :lead_automation_rules, :acquisition_scope_key, unique: true,
              where: "acquisition_scope_key IS NOT NULL AND deleted_at IS NULL", algorithm: :concurrently,
              name: 'idx_cra_rule_scope'
    add_index :lead_automation_runs, :scope_event_id, algorithm: :concurrently
    add_index :lead_acquisition_enrichments, [:acquisition_id, :revision], unique: true, algorithm: :concurrently,
              name: 'idx_cra_acquisition_revision'
  end
end
