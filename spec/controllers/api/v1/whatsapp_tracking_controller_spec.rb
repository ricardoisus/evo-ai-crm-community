# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::WhatsappTrackingController, type: :controller do
  let(:user) { User.create!(email: 'admin-tracking@example.com', name: 'Tracking administrator') }
  let(:inbox) { whatsapp_inbox('+15550000001') }
  let(:other_inbox) { whatsapp_inbox('+15550000002') }
  let(:destination) do
    WhatsappTrackingDestination.create!(inbox: inbox, name: 'Web', dataset_id: '123',
                                        credential_ref: 'WHATSAPP_TRACKING_META_TEST_TOKEN')
  end
  let(:draft) do
    { trigger: 'message_received', frequency: 'contact', event_name: 'Lead', destination_id: destination.id, mode: 'test',
      text: { operator: 'contains', value: 'Olá' } }
  end

  before do
    allow(user).to receive(:administrator?).and_return(true)
    allow(controller).to receive(:authenticate_request!) do
      Current.user = user
      Current.service_authenticated = true
    end
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config)
  end

  after { Current.reset }

  it 'creates, simulates, publishes and pauses a draft within the selected inbox' do
    post :create_rule, params: { inbox_id: inbox.id, name: 'CRA site', draft: draft }, as: :json
    expect(response).to have_http_status(:created)
    rule = WhatsappTrackingRule.sole

    post :simulate, params: { inbox_id: inbox.id, id: rule.id, event: { text: '  OLÁ equipe  ' } }, as: :json
    expect(response.parsed_body.dig('data', 'result')).to eq('matched')

    post :publish, params: { inbox_id: inbox.id, id: rule.id, lock_version: rule.lock_version }, as: :json
    expect(response).to have_http_status(:ok)
    expect(rule.reload.published).to eq(rule.draft)
    expect(rule).to be_active

    post :pause, params: { inbox_id: inbox.id, id: rule.id, lock_version: rule.lock_version }, as: :json
    expect(response).to have_http_status(:ok)
    expect(rule.reload).not_to be_active
  end

  it 'rejects a destination belonging to another WhatsApp inbox' do
    post :create_rule, params: { inbox_id: other_inbox.id, name: 'Isolated', draft: draft }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(WhatsappTrackingRule.count).to eq(0)
  end

  it 'rejects users without the administrator role' do
    allow(user).to receive(:administrator?).and_return(false)
    get :history, params: { inbox_id: inbox.id }, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  def whatsapp_inbox(phone)
    channel = Channel::Whatsapp.create!(provider: 'evolution', phone_number: phone, provider_config: { instance_name: 'Tracking' })
    Inbox.create!(name: phone, channel: channel)
  end
end
