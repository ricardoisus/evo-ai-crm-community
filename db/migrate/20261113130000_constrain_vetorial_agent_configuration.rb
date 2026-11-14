class ConstrainVetorialAgentConfiguration < ActiveRecord::Migration[7.1]
  def change
    add_check_constraint :vetorial_agent_deployments, "policy_epoch > 0 AND lock_version >= 0 AND control_source IN ('crm', 'legacy_transition')", name: 'vetorial_deployment_contract'
    add_check_constraint :vetorial_agent_profiles, "role IN ('atendimento', 'analista')", name: 'vetorial_profile_role'
    add_check_constraint :vetorial_agent_revisions, "number > 0 AND status IN ('draft', 'published') AND sha256 ~ '^[0-9a-f]{64}$' AND jsonb_typeof(payload) = 'object'", name: 'vetorial_revision_contract'
    # A revision pointer must belong to the same deployment, even when written outside Rails.
    add_index :vetorial_agent_revisions, [:deployment_id, :id], unique: true, name: 'vetorial_revision_owner'
    add_foreign_key :vetorial_agent_deployments, :vetorial_agent_revisions,
                    column: [:id, :active_revision_id], primary_key: [:deployment_id, :id],
                    name: 'vetorial_active_revision_owner'
  end
end
