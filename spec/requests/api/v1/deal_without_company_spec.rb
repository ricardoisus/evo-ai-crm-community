# frozen_string_literal: true

require 'rails_helper'

# R2 (repaginada 2): o CRM não tem "empresa"; negócios se vinculam apenas a contatos.
# A coluna pipeline_items.company_id permanece no banco (sem apagar dados), mas some da API.
RSpec.describe 'Negócio sem empresa', type: :request do
  let(:user) { User.create!(name: 'Closer', email: "closer-#{SecureRandom.hex(4)}@example.com") }
  let(:pipeline) { Pipeline.create!(name: "Sales #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: user) }
  let!(:stage) { PipelineStage.create!(pipeline: pipeline, name: 'New', position: 1) }
  let(:person) { Contact.create!(name: 'Maria', type: 'person') }
  let(:legacy_company) { Contact.create!(name: 'Acme', type: 'company') }
  let!(:deal) { PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, title: 'Negócio', value: 10) }

  before do
    current_user = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = current_user
      Current.service_authenticated = true
      Current.authentication_method = 'service_token'
    end
    deal.update_column(:company_id, legacy_company.id) # rubocop:disable Rails/SkipsModelValidations
  end

  after { Current.reset }

  def keys_deep(node)
    case node
    when Hash then node.keys.map(&:to_s) + node.values.flat_map { |value| keys_deep(value) }
    when Array then node.flat_map { |value| keys_deep(value) }
    else []
    end
  end

  it 'does not expose company on the deal' do
    get "/api/v1/deals/#{deal.id}", as: :json
    expect(response).to have_http_status(:ok)
    expect(keys_deep(response.parsed_body)).not_to include('company', 'company_id')
  end

  it 'does not expose company on pipeline items or the board' do
    get "/api/v1/pipelines/#{pipeline.id}/pipeline_items", as: :json
    expect(response).to have_http_status(:ok)
    expect(keys_deep(response.parsed_body)).not_to include('company', 'company_id')
    get "/api/v1/pipelines/#{pipeline.id}", as: :json
    expect(keys_deep(response.parsed_body)).not_to include('company', 'company_id')
  end

  it 'ignores company_id on update and keeps the stored value untouched' do
    patch "/api/v1/deals/#{deal.id}", params: { deal: { title: 'Novo', company_id: nil } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(deal.reload.title).to eq('Novo')
    expect(deal.company_id).to eq(legacy_company.id)
  end

  it 'does not offer company in the card field catalog' do
    get "/api/v1/pipelines/#{pipeline.id}", as: :json
    ids = response.parsed_body.dig('data', 'card_field_definitions').pluck('id')
    expect(ids).to include('contact')
    expect(ids).not_to include('company')
  end

  it 'links a company-type contact as a regular deal contact' do
    deal.attach_contact!(person)
    deal.attach_contact!(legacy_company)
    expect(deal.reload.contacts).to include(person, legacy_company)
    expect(deal.company_id).to eq(legacy_company.id) # coluna legada intacta
    expect(deal.deal_history_events.pluck(:action)).not_to include('company_associated')
  end

  it 'does not emit company_id in webhook and push payloads' do
    expect(deal.webhook_data.keys.map(&:to_s)).not_to include('company_id')
    expect(deal.push_event_data.keys.map(&:to_s)).not_to include('company_id')
  end
end
