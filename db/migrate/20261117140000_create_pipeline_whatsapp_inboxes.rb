# frozen_string_literal: true

# Números (inboxes) de WhatsApp autorizados a iniciar conversa por pipeline.
# Aditiva e reversível: nenhuma tabela existente é alterada. Pipeline sem linhas
# ativas = nenhum número autorizado (a UI orienta a configurar; nada é iniciado).
class CreatePipelineWhatsappInboxes < ActiveRecord::Migration[7.1]
  def change
    create_table :pipeline_whatsapp_inboxes, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.references :pipeline, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :inbox, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: true
      t.boolean :is_default, null: false, default: false
      t.boolean :is_active, null: false, default: true
      t.timestamps
    end

    add_index :pipeline_whatsapp_inboxes, %i[pipeline_id inbox_id], unique: true,
                                                                    name: 'idx_pipeline_whatsapp_inboxes_unique'
    add_index :pipeline_whatsapp_inboxes, :pipeline_id, unique: true, where: 'is_default AND is_active',
                                                        name: 'idx_pipeline_whatsapp_inboxes_one_default'
  end
end
