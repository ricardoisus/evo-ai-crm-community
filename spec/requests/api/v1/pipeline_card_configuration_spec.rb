# frozen_string_literal: true

# Controller instances are created by the request stack; stub only authentication and remote RBAC.
# rubocop:disable RSpec/AnyInstance
require 'rails_helper'

RSpec.describe 'Pipeline card configuration', type: :request do
  let(:user) { User.create!(name: 'Card Editor', email: "cards-#{SecureRandom.hex(4)}@example.com") }
  let(:pipeline) { Pipeline.create!(name: "Cards #{SecureRandom.hex(4)}", pipeline_type: 'sales', visibility: :public, created_by: user) }
  let(:configuration) { { version: 1, density: 'compact', fields: [{ id: 'title', visible: true }, { id: 'value', visible: true }] } }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission).and_return(true)
    allow_any_instance_of(User).to receive(:has_permission?).and_return(true)
  end

  after { Current.reset }

  def save_configuration(config = configuration, revision = 0)
    patch "/api/v1/pipelines/#{pipeline.id}", params: { pipeline: { card_configuration: config, card_configuration_revision: revision } }, as: :json
  end

  it 'defaults to an empty configuration and returns the field catalog' do
    get "/api/v1/pipelines/#{pipeline.id}", as: :json
    expect(response).to have_http_status(:ok)
    data = response.parsed_body['data']
    expect(data['card_configuration']).to eq({})
    expect(data['card_configuration_revision']).to eq(0)
    expect(data['card_field_definitions'].map { |f| f['id'] }).to include('title', 'next_task')
  end

  it 'persists independently per pipeline without changing custom fields' do
    other = Pipeline.create!(name: "Other #{SecureRandom.hex(4)}", created_by: user)
    fields = pipeline.custom_fields.deep_dup
    save_configuration
    expect(response).to have_http_status(:ok)
    expect(pipeline.reload.card_configuration['density']).to eq('compact')
    expect(pipeline.card_configuration_revision).to eq(1)
    expect(pipeline.custom_fields).to eq(fields)
    expect(other.reload.card_configuration).to eq({})
    get "/api/v1/pipelines/#{pipeline.id}", as: :json
    expect(response.parsed_body.dig('data', 'card_configuration', 'density')).to eq('compact')
  end

  it 'shares the saved configuration with another authorized user' do
    save_configuration
    colleague = User.create!(name: 'Equipe', email: "team-#{SecureRandom.hex(4)}@example.com")
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = colleague
      Current.evo_permission_cache ||= {}
    end
    get "/api/v1/pipelines/#{pipeline.id}", as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('data', 'card_configuration', 'density')).to eq('compact')
  end

  it 'authorizes local custom field IDs and rejects fields from another pipeline' do
    pipeline.update!(custom_fields: { 'attributes' => ['especialidade'], 'attribute_definitions' => {
                       'especialidade' => { 'attribute_display_name' => 'Especialidade', 'attribute_display_type' => 'text' }
                     } })
    custom = configuration.merge(fields: configuration[:fields] + [{ id: 'deal_attribute:especialidade', visible: true }])
    save_configuration(custom)
    expect(response).to have_http_status(:ok)
    save_configuration(configuration.merge(fields: configuration[:fields] + [{ id: 'deal_attribute:outro_pipeline', visible: true }]), 1)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(pipeline.reload.card_configuration_revision).to eq(1)
  end

  it 'rejects stale revisions without overwriting the first writer' do
    save_configuration
    save_configuration(configuration.merge(density: 'comfortable'))
    expect(response).to have_http_status(:conflict)
    expect(pipeline.reload.card_configuration_revision).to eq(1)
    expect(pipeline.card_configuration['density']).to eq('compact')
  end

  it 'rejects invalid version, density, unknown IDs, duplicates, hidden title and malformed fields' do
    [nil, false, {}, configuration.merge(version: 2), configuration.merge(density: 'tiny'),
     configuration.merge(fields: [{ id: 'secret', visible: true }]),
     configuration.merge(fields: [{ id: 'title', visible: true }, { id: 'title', visible: true }]),
     configuration.merge(fields: [{ id: 'title', visible: false }]),
     configuration.merge(fields: 'invalid')].each do |invalid|
      save_configuration(invalid)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(pipeline.reload.card_configuration_revision).to eq(0)
    end
  end

  it 'projects the next pending task in a bounded number of queries for a board' do
    stage = pipeline.pipeline_stages.create!(name: 'Entrada', position: 1)
    6.times do |index|
      item = pipeline.pipeline_items.create!(pipeline_stage: stage, title: "Negócio #{index}")
      item.tasks.create!(title: "Retornar #{index}", due_date: 1.day.from_now, created_by: user)
      item.tasks.create!(title: 'Já concluída', status: :completed, due_date: 1.day.ago, created_by: user)
    end
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, event|
      queries << event[:sql] if event[:sql].match?(/SELECT.*FROM "pipeline_tasks"/i)
    end
    begin
      get "/api/v1/pipelines/#{pipeline.id}", as: :json
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
    expect(response).to have_http_status(:ok)
    items = response.parsed_body.dig('data', 'stages', 0, 'items')
    expect(items.size).to eq(6)
    expect(items.pluck('next_task').pluck('title')).to all(start_with('Retornar'))
    # One preload plus the three existing aggregate queries, independent of card count.
    expect(queries.size).to be <= 4
  end

  it 'denies a reader changing shared configuration' do
    allow_any_instance_of(PipelinePolicy).to receive(:update?).and_return(false)
    save_configuration
    expect(response).to have_http_status(:unauthorized)
    expect(pipeline.reload.card_configuration).to eq({})
  end

  it 'does not expose private pipelines of another user' do
    pipeline.update!(visibility: :private, created_by: User.create!(name: 'Other', email: "other-#{SecureRandom.hex(4)}@example.com"))
    get "/api/v1/pipelines/#{pipeline.id}", as: :json
    expect(response).to have_http_status(:not_found)
    save_configuration
    expect(response).to have_http_status(:not_found)
  end
end

# rubocop:enable RSpec/AnyInstance
