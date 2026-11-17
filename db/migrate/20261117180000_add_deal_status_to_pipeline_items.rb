# frozen_string_literal: true

# Status do negócio: open (aberto), won (ganho), lost (perdido).
# Aditiva e reversível. Reaproveita `completed_at` como data do fechamento (ganho/perdido):
# o índice único "um negócio ativo por conversa/contato" já usa `completed_at IS NULL`.
# Todos os negócios existentes nascem `open`; os poucos já fechados (completed_at preenchido,
# o que nenhum caminho da aplicação gravava antes) viram `won`/`lost` conforme o tipo da etapa.
class AddDealStatusToPipelineItems < ActiveRecord::Migration[7.1]
  def up
    add_column :pipeline_items, :deal_status, :string, null: false, default: 'open'
    add_column :pipeline_items, :lost_reason, :text
    add_column :pipeline_items, :closed_by_id, :uuid

    execute <<~SQL.squish
      UPDATE pipeline_items SET deal_status = CASE
        WHEN (SELECT stage_type FROM pipeline_stages s WHERE s.id = pipeline_items.pipeline_stage_id) = 2 THEN 'lost'
        ELSE 'won' END
      WHERE completed_at IS NOT NULL
    SQL

    add_check_constraint :pipeline_items, "deal_status IN ('open', 'won', 'lost')", name: 'chk_pipeline_items_deal_status'
    add_index :pipeline_items, %i[pipeline_id deal_status], name: 'idx_pipeline_items_pipeline_deal_status'
    add_foreign_key :pipeline_items, :users, column: :closed_by_id, on_delete: :nullify
  end

  def down
    remove_foreign_key :pipeline_items, column: :closed_by_id
    remove_index :pipeline_items, name: 'idx_pipeline_items_pipeline_deal_status'
    remove_check_constraint :pipeline_items, name: 'chk_pipeline_items_deal_status'
    remove_column :pipeline_items, :closed_by_id
    remove_column :pipeline_items, :lost_reason
    remove_column :pipeline_items, :deal_status
  end
end
