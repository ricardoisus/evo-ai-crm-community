# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Deals API', type: :request do
  let(:user) { User.create!(name: 'Deal Owner', email: "deal-owner-#{SecureRandom.hex(4)}@example.com") }
  let(:pipeline) { Pipeline.create!(name: "Sales #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: user) }
  let!(:stage) { PipelineStage.create!(pipeline: pipeline, name: 'New', position: 1) }

  before do
    current_user = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = current_user
      Current.service_authenticated = true
      Current.authentication_method = 'service_token'
    end
  end

  after { Current.reset }

  it 'creates an autonomous deal and exposes compatibility aliases' do
    post "/api/v1/pipelines/#{pipeline.id}/deals", params: {
      deal: { title: 'Annual contract', value: 15_000, currency: 'BRL', pipeline_stage_id: stage.id }
    }, as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('data', 'title')).to eq('Annual contract')
    expect(response.parsed_body.dig('data', 'deal_id')).to eq(response.parsed_body.dig('data', 'id'))
    expect(PipelineItem.last.contacts).to be_empty

    get "/api/v1/pipelines/#{pipeline.id}", as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('data', 'deal_count')).to eq(1)
    expect(response.parsed_body.dig('data', 'stages', 0, 'deals', 0, 'title')).to eq('Annual contract')
  end

  it 'attaches a conversation and automatically links its contact' do
    contact = Contact.create!(name: 'Customer', email: "customer-#{SecureRandom.hex(3)}@example.com")
    channel = Channel::WebWidget.create!(website_url: "https://#{SecureRandom.hex(3)}.example.com")
    inbox = Inbox.create!(name: 'Inbox', channel: channel)
    contact_inbox = ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(4))
    conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    deal = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage)

    post "/api/v1/deals/#{deal.id}/conversations", params: { conversation_id: conversation.id }, as: :json

    expect(response).to have_http_status(:created)
    expect(deal.reload.conversations).to contain_exactly(conversation)
    expect(deal.contacts).to contain_exactly(contact)
    expect(deal.primary_contact).to eq(contact)
  end

  it 'records commercial changes in the append-only timeline' do
    deal = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, title: 'Before')

    patch "/api/v1/deals/#{deal.id}", params: { deal: { title: 'After', notes: 'Qualified' } }, as: :json

    expect(response).to have_http_status(:ok)
    event = deal.reload.deal_history_events.order(:created_at).last
    expect(event.action).to eq('deal_updated')
    expect(event.changes.dig('title', 'previous')).to eq('Before')
    expect(event.changes.dig('title', 'current')).to eq('After')
    expect { event.update!(source: 'tampered') }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { event.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it 'uploads and removes a safe deal file while auditing both actions' do
    deal = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, title: 'Documents')
    upload = Rack::Test::UploadedFile.new(StringIO.new('proposal'), 'text/plain', original_filename: 'proposal.txt')

    post "/api/v1/deals/#{deal.id}/files", params: { files: [upload] }

    expect(response).to have_http_status(:created)
    attachment_id = response.parsed_body.dig('data', 0, 'id')
    expect(attachment_id).to be_present
    expect(deal.reload.deal_history_events.pluck(:action)).to include('files_attached')

    delete "/api/v1/deals/#{deal.id}/files/#{attachment_id}"

    expect(response).to have_http_status(:ok)
    expect(deal.reload.attachments).to be_empty
    expect(deal.deal_history_events.pluck(:action)).to include('file_removed')
  end
end
