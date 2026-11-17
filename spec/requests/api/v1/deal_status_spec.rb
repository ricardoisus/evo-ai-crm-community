# frozen_string_literal: true

require 'rails_helper'

# R1 (repaginada 2): status do negócio open/won/lost. Padrão do quadro e da lista: só abertos.
RSpec.describe 'Deal status (aberto/ganho/perdido)', type: :request do
  let(:user) { User.create!(name: 'Closer', email: "closer-#{SecureRandom.hex(4)}@example.com") }
  let(:pipeline) { Pipeline.create!(name: "Sales #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: user) }
  let!(:stage) { PipelineStage.create!(pipeline: pipeline, name: 'New', position: 1) }
  let!(:stage2) { PipelineStage.create!(pipeline: pipeline, name: 'Proposta', position: 2) }
  let(:base) { "/api/v1/pipelines/#{pipeline.id}/pipeline_items" }
  let!(:open_deal) { PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, title: 'Aberto', value: 100) }
  let!(:won_deal) { PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, title: 'Ganho', value: 300) }
  let!(:lost_deal) { PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage2, title: 'Perdido', value: 50) }

  before do
    current_user = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = current_user
      Current.service_authenticated = true
      Current.authentication_method = 'service_token'
    end
    won_deal.mark_won!(actor: user)
    lost_deal.mark_lost!(reason: 'Sem orçamento', actor: user)
  end

  after { Current.reset }

  def patch_status(deal, params)
    patch "#{base}/#{deal.id}/status", params: params, as: :json
  end

  describe 'model' do
    it 'defaults to open and keeps completed_at coherent' do
      expect(open_deal.reload.deal_status).to eq('open')
      expect(open_deal.completed_at).to be_nil
      expect(won_deal.reload).to have_attributes(deal_status: 'won', closed_by_id: user.id)
      expect(won_deal.completed_at).to be_present
      expect(lost_deal.reload).to have_attributes(deal_status: 'lost', lost_reason: 'Sem orçamento')
    end

    it 'rejects any value outside the three statuses' do
      open_deal.deal_status = 'arquivado'
      expect(open_deal).not_to be_valid
      expect { open_deal.update_column(:deal_status, 'x') }.to raise_error(ActiveRecord::StatementInvalid) # rubocop:disable Rails/SkipsModelValidations
    end

    it 'sets completed_at when status is written directly' do
      open_deal.update!(deal_status: 'won')
      expect(open_deal.reload.completed_at).to be_present
    end

    it 'records history for each transition' do
      open_deal.reopen!(actor: user)
      won_deal.reopen!(actor: user)
      actions = won_deal.deal_history_events.pluck(:action)
      expect(actions).to include('deal_won', 'deal_reopened')
      expect(lost_deal.deal_history_events.find_by(action: 'deal_lost').change_set.dig('lost_reason', 'current')).to eq('Sem orçamento')
    end

    it 'does not let a closed deal change stage' do
      expect(won_deal.move_to_stage(stage2)).to be(false)
      expect(won_deal.reload.pipeline_stage_id).to eq(stage.id)
    end

    it 'fires the completed webhook event once, on close' do
      deal = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, title: 'Evento')
      expect(Rails.configuration.dispatcher).to receive(:dispatch).with('pipeline_item.completed', anything, hash_including(:pipeline_item)).once
      allow(Rails.configuration.dispatcher).to receive(:dispatch).with(satisfy { |name| name != 'pipeline_item.completed' }, any_args)
      deal.update!(deal_status: 'won')
    end
  end

  describe 'GET pipeline_items' do
    def titles(params = {})
      get base, params: params
      response.parsed_body['data'].map { |i| i['title'] }
    end

    it 'defaults to open deals only' do
      expect(titles).to contain_exactly('Aberto')
    end

    it 'filters by status (en and pt-BR) and all' do
      expect(titles(deal_status: 'won')).to contain_exactly('Ganho')
      expect(titles(deal_status: 'perdido')).to contain_exactly('Perdido')
      expect(titles(deal_status: 'all')).to contain_exactly('Aberto', 'Ganho', 'Perdido')
      expect(titles(status: 'completed')).to contain_exactly('Ganho', 'Perdido') # compatibilidade com a API anterior
      expect(titles(status: 'active')).to contain_exactly('Aberto')
    end

    it 'exposes deal_status, lost_reason and closed_by_id' do
      get base, params: { deal_status: 'lost' }
      item = response.parsed_body['data'].first
      expect(item).to include('deal_status' => 'lost', 'lost_reason' => 'Sem orçamento', 'closed_by_id' => user.id)
    end
  end

  describe 'GET pipeline (board)' do
    def board(params = {})
      get "/api/v1/pipelines/#{pipeline.id}", params: params
      response.parsed_body['data']
    end

    it 'shows only open deals with matching per-stage counters and totals' do
      data = board
      by_name = data['stages'].index_by { |s| s['name'] }
      expect(by_name['New']['items'].map { |i| i['title'] }).to eq(['Aberto'])
      expect(by_name['New']).to include('item_count' => 1, 'total_value' => 100.0)
      expect(by_name['Proposta']).to include('item_count' => 0, 'total_value' => 0.0)
      expect(data['deal_status_counts']).to eq('open' => 1, 'won' => 1, 'lost' => 1)
      expect(data['item_count']).to eq(1)
    end

    it 'counters follow the active status filter' do
      data = board(deal_status: 'lost')
      by_name = data['stages'].index_by { |s| s['name'] }
      expect(by_name['Proposta']).to include('item_count' => 1, 'total_value' => 50.0)
      expect(by_name['New']['item_count']).to eq(0)
      all = board(deal_status: 'all')['stages'].sum { |s| s['item_count'] }
      expect(all).to eq(3)
    end
  end

  describe 'PATCH status' do
    it 'marks as won, records who/when and sets completed_at' do
      patch_status(open_deal, status: 'won')
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['data']).to include('deal_status' => 'won', 'closed_by_id' => user.id)
      expect(open_deal.reload.completed_at).to be_present
    end

    it 'marks as lost with optional reason and accepts pt-BR' do
      patch_status(open_deal, status: 'perdido', lost_reason: '  Escolheu concorrente ')
      expect(response).to have_http_status(:ok)
      expect(open_deal.reload).to have_attributes(deal_status: 'lost', lost_reason: 'Escolheu concorrente')
      other = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, title: 'Sem motivo')
      patch_status(other, status: 'lost')
      expect(response).to have_http_status(:ok)
      expect(other.reload.lost_reason).to be_nil
    end

    it 'reopens and clears closing data' do
      patch_status(lost_deal, status: 'open')
      expect(response).to have_http_status(:ok)
      expect(lost_deal.reload).to have_attributes(deal_status: 'open', completed_at: nil, closed_by_id: nil, lost_reason: nil)
    end

    it 'is idempotent' do
      patch_status(won_deal, status: 'won')
      expect(response).to have_http_status(:ok)
      expect(won_deal.deal_history_events.where(action: 'deal_won').count).to eq(1)
    end

    it 'rejects invalid status' do
      patch_status(open_deal, status: 'arquivado')
      expect(response).to have_http_status(:unprocessable_entity)
      expect(open_deal.reload.deal_status).to eq('open')
    end

    it 'reopens even when another open deal exists for the same conversation (várias negociações por contato são permitidas)' do
      inbox = Inbox.create!(name: 'W', channel: Channel::WebWidget.create!(website_url: "https://#{SecureRandom.hex(3)}.example.com"))
      contact = Contact.create!(name: 'C', phone_number: "+5521#{rand(900_000_00..999_999_99)}")
      contact_inbox = ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(6))
      conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      closed = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, title: 'A', conversation: conversation)
      closed.mark_won!(actor: user)
      PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, title: 'B', conversation: conversation)
      patch_status(closed, status: 'open')
      expect(response).to have_http_status(:ok)
      expect(closed.reload.deal_status).to eq('open')
    end

    it 'does not let a closed deal be moved through the API' do
      patch "#{base}/#{won_deal.id}/move_to_stage", params: { new_stage_id: stage2.id }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(won_deal.reload.pipeline_stage_id).to eq(stage.id)
      patch "#{base}/#{won_deal.id}", params: { pipeline_stage_id: stage2.id }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'deals endpoints (usados pelo modal)' do
    it 'PATCH /deals/:id/status marks won/lost/open and the deal payload carries the status' do
      patch "/api/v1/deals/#{open_deal.id}/status", params: { status: 'lost', lost_reason: 'Preço' }, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['data']).to include('deal_status' => 'lost', 'lost_reason' => 'Preço')
      patch "/api/v1/deals/#{open_deal.id}/status", params: { status: 'open' }, as: :json
      expect(response.parsed_body['data']).to include('deal_status' => 'open', 'lost_reason' => nil)
      patch "/api/v1/deals/#{open_deal.id}/status", params: { status: 'x' }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'lists only open deals by default and filters by deal_status' do
      get "/api/v1/pipelines/#{pipeline.id}/deals"
      expect(response.parsed_body['data'].map { |d| d['title'] }).to contain_exactly('Aberto')
      get "/api/v1/pipelines/#{pipeline.id}/deals", params: { deal_status: 'all' }
      expect(response.parsed_body['data'].size).to eq(3)
    end

    it 'does not move a closed deal through PATCH /deals/:id' do
      patch "/api/v1/deals/#{won_deal.id}", params: { deal: { pipeline_stage_id: stage2.id } }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(won_deal.reload.pipeline_stage_id).to eq(stage.id)
    end

    it 'cannot set the status through the generic update (só pelo endpoint de status)' do
      patch "/api/v1/deals/#{open_deal.id}", params: { deal: { title: 'Novo', deal_status: 'won' } }, as: :json
      expect(open_deal.reload).to have_attributes(title: 'Novo', deal_status: 'open')
    end
  end

  describe 'RBAC' do
    it 'requires the same write level as editing a deal' do
      allow_any_instance_of(PipelinePolicy).to receive(:view?).and_return(true)
      allow_any_instance_of(PipelinePolicy).to receive(:update?).and_return(false)
      allow_any_instance_of(Api::BaseController).to receive(:service_authenticated?).and_return(false)
      patch_status(open_deal, status: 'won')
      expect(response).to have_http_status(:unauthorized)
      expect(open_deal.reload.deal_status).to eq('open')
    end
  end

  describe 'migration backfill' do
    it 'is reversible' do
      require Rails.root.join('db/migrate/20261117180000_add_deal_status_to_pipeline_items.rb')
      ActiveRecord::Migration.suppress_messages { AddDealStatusToPipelineItems.new.down }
      PipelineItem.reset_column_information
      expect(PipelineItem.column_names).not_to include('deal_status')
      ActiveRecord::Migration.suppress_messages { AddDealStatusToPipelineItems.new.up }
      PipelineItem.reset_column_information
      expect(PipelineItem.column_names).to include('deal_status', 'lost_reason', 'closed_by_id')
    ensure
      PipelineItem.reset_column_information
    end
  end
end
