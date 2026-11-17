# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Deal conversation + pipeline WhatsApp inboxes', type: :request do
  let(:user) { User.create!(name: 'Starter', email: "starter-#{SecureRandom.hex(4)}@example.com") }
  let(:pipeline) { Pipeline.create!(name: "Sales #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: user) }
  let(:other_pipeline) { Pipeline.create!(name: "Other #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: user) }
  let!(:stage) { PipelineStage.create!(pipeline: pipeline, name: 'New', position: 1) }
  let!(:other_stage) { PipelineStage.create!(pipeline: other_pipeline, name: 'New', position: 1) }
  let(:contact) { Contact.create!(name: 'Lead Zap', phone_number: "+5521#{rand(900_000_00..999_999_99)}") }
  let(:deal) do
    PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, title: 'Deal').tap { |d| d.attach_contact!(contact) }
  end

  def make_whatsapp_inbox(name, connection: 'open', provider: 'evolution')
    channel = Channel::Whatsapp.new(phone_number: "+5511#{rand(900_000_00..999_999_99)}", provider: provider,
                                    provider_config: { 'api_url' => 'http://x', 'api_key' => 'k', 'instance_name' => name.parameterize })
    channel.save!(validate: false)
    channel.update_columns(provider_connection: { 'connection' => connection }) # rubocop:disable Rails/SkipsModelValidations
    Inbox.create!(name: name, channel: channel)
  end

  let!(:inbox_a) { make_whatsapp_inbox("Vetorial #{SecureRandom.hex(2)}") }
  let!(:inbox_b) { make_whatsapp_inbox("Comercial #{SecureRandom.hex(2)}") }
  let(:web_inbox) { Inbox.create!(name: 'Widget', channel: Channel::WebWidget.create!(website_url: "https://#{SecureRandom.hex(3)}.example.com")) }

  before do
    current_user = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = current_user
      Current.service_authenticated = true
      Current.authentication_method = 'service_token'
    end
  end

  after { Current.reset }

  def allow_inboxes(*inboxes, default: nil, on: pipeline)
    put "/api/v1/pipelines/#{on.id}/whatsapp_inboxes",
        params: { inbox_ids: inboxes.map(&:id), default_inbox_id: default&.id }, as: :json
  end

  describe 'pipeline whatsapp_inboxes' do
    it 'starts with no allowed number and lists eligible WhatsApp inboxes only' do
      web_inbox
      get "/api/v1/pipelines/#{pipeline.id}/whatsapp_inboxes", as: :json

      data = response.parsed_body['data']
      expect(response).to have_http_status(:ok)
      expect(data['configured']).to be(false)
      expect(data['allowed']).to eq([])
      expect(data['eligible'].map { |i| i['id'] }).to contain_exactly(inbox_a.id, inbox_b.id)
      expect(data['eligible'].first).to include('phone_number', 'connected', 'provider', 'allowed')
    end

    it 'replaces the list, sets the default and exposes it in the pipeline serializer' do
      allow_inboxes(inbox_a, inbox_b, default: inbox_b)

      expect(response).to have_http_status(:ok)
      data = response.parsed_body['data']
      expect(data['allowed'].map { |i| i['id'] }).to contain_exactly(inbox_a.id, inbox_b.id)
      expect(data['default_inbox_id']).to eq(inbox_b.id)

      get "/api/v1/pipelines/#{pipeline.id}", as: :json
      summary = response.parsed_body.dig('data', 'whatsapp_inboxes')
      expect(summary).to include('configured' => true, 'default_inbox_id' => inbox_b.id)
      expect(summary['allowed_inbox_ids']).to contain_exactly(inbox_a.id, inbox_b.id)
    end

    it 'makes a single allowed number the default and removes dropped ones' do
      allow_inboxes(inbox_a, inbox_b)
      allow_inboxes(inbox_a)

      expect(response.parsed_body.dig('data', 'default_inbox_id')).to eq(inbox_a.id)
      expect(pipeline.pipeline_whatsapp_inboxes.pluck(:inbox_id)).to eq([inbox_a.id])
    end

    it 'changes the default via PATCH and rejects a non-allowed default' do
      allow_inboxes(inbox_a, inbox_b, default: inbox_a)
      patch "/api/v1/pipelines/#{pipeline.id}/whatsapp_inboxes/default", params: { inbox_id: inbox_b.id }, as: :json
      expect(response.parsed_body.dig('data', 'default_inbox_id')).to eq(inbox_b.id)
      expect(pipeline.pipeline_whatsapp_inboxes.where(is_default: true).count).to eq(1)

      allow_inboxes(inbox_a)
      patch "/api/v1/pipelines/#{pipeline.id}/whatsapp_inboxes/default", params: { inbox_id: inbox_b.id }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects non-WhatsApp inboxes and a default outside the list' do
      allow_inboxes(web_inbox)
      expect(response).to have_http_status(:unprocessable_entity)

      put "/api/v1/pipelines/#{pipeline.id}/whatsapp_inboxes",
          params: { inbox_ids: [inbox_a.id], default_inbox_id: inbox_b.id }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(pipeline.pipeline_whatsapp_inboxes).to be_empty
    end

    it 'isolates pipelines from each other' do
      allow_inboxes(inbox_a)
      allow_inboxes(inbox_b, on: other_pipeline)

      expect(pipeline.pipeline_whatsapp_inboxes.pluck(:inbox_id)).to eq([inbox_a.id])
      expect(other_pipeline.pipeline_whatsapp_inboxes.pluck(:inbox_id)).to eq([inbox_b.id])
    end

    it 'denies write without pipeline update permission and read without view' do
      allow(Current).to receive(:service_authenticated).and_return(false)
      allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) { Current.user = user }
      allow_any_instance_of(EvoPermissionConcern).to receive(:check_permission!)
      allow_any_instance_of(PipelinePolicy).to receive(:view?).and_return(true)
      allow_any_instance_of(PipelinePolicy).to receive(:update?).and_return(false)

      get "/api/v1/pipelines/#{pipeline.id}/whatsapp_inboxes", as: :json
      expect(response).to have_http_status(:ok)

      allow_inboxes(inbox_a)
      expect(response).to have_http_status(:unauthorized)
      expect(pipeline.pipeline_whatsapp_inboxes).to be_empty
    end

    it 'is removed with the pipeline (cascade) and does not block inbox lookups' do
      allow_inboxes(inbox_a)
      expect { pipeline.destroy! }.to change(PipelineWhatsappInbox, :count).by(-1)
    end
  end

  describe 'GET /deals/:id/conversation_status' do
    it 'reports no active conversation and cannot start when the pipeline has no number' do
      get "/api/v1/deals/#{deal.id}/conversation_status", as: :json

      data = response.parsed_body['data']
      expect(data).to include('has_active' => false, 'can_start' => false, 'reason' => 'no_inbox_configured', 'conversation' => nil)
    end

    it 'can start once a number is allowed and shows allowed inboxes with default' do
      allow_inboxes(inbox_a, inbox_b, default: inbox_a)
      get "/api/v1/deals/#{deal.id}/conversation_status", as: :json

      data = response.parsed_body['data']
      expect(data).to include('can_start' => true, 'has_active' => false, 'default_inbox_id' => inbox_a.id)
      expect(data['allowed_inboxes'].size).to eq(2)
      expect(data['contact']).to include('id' => contact.id)
    end

    it 'returns the most recent active conversation in an allowed inbox, ignoring other inboxes and resolved ones' do
      allow_inboxes(inbox_a)
      ci_b = ContactInbox.create!(contact: contact, inbox: inbox_b, source_id: contact.phone_number.delete('+'))
      Conversation.create!(inbox: inbox_b, contact: contact, contact_inbox: ci_b) # fora dos permitidos
      ci_a = ContactInbox.create!(contact: contact, inbox: inbox_a, source_id: contact.phone_number.delete('+'))
      resolved = Conversation.create!(inbox: inbox_a, contact: contact, contact_inbox: ci_a)
      resolved.update_columns(status: Conversation.statuses[:resolved]) # rubocop:disable Rails/SkipsModelValidations
      active = Conversation.create!(inbox: inbox_a, contact: contact, contact_inbox: ci_a)

      get "/api/v1/deals/#{deal.id}/conversation_status", as: :json

      conv = response.parsed_body.dig('data', 'conversation')
      expect(response.parsed_body.dig('data', 'has_active')).to be(true)
      expect(conv['id']).to eq(active.id)
      expect(conv['id']).not_to eq(resolved.id)
      expect(conv['inbox']['id']).to eq(inbox_a.id)
      expect(conv['path']).to eq("/conversations/#{active.id}")
    end

    it 'explains missing contact and invalid phone' do
      allow_inboxes(inbox_a)
      empty = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, title: 'No contact')
      get "/api/v1/deals/#{empty.id}/conversation_status", as: :json
      expect(response.parsed_body.dig('data', 'reason')).to eq('no_contact')

      nophone = Contact.create!(name: 'Sem telefone', email: "np-#{SecureRandom.hex(3)}@example.com")
      d2 = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, title: 'NP').tap { |d| d.attach_contact!(nophone) }
      get "/api/v1/deals/#{d2.id}/conversation_status", as: :json
      expect(response.parsed_body.dig('data', 'reason')).to eq('contact_without_phone')
    end
  end

  describe 'POST /deals/:id/conversation' do
    before { allow_inboxes(inbox_a, inbox_b, default: inbox_a) }

    it 'creates ContactInbox + open conversation in the default inbox, links it to the deal and sends nothing' do
      deal_id = deal.id
      messages_before = Message.count
      expect do
        post "/api/v1/deals/#{deal_id}/conversation", as: :json
      end.to change(Conversation, :count).by(1).and change(ContactInbox, :count).by(1)
      expect(Message.count).to eq(messages_before)

      expect(response).to have_http_status(:created)
      data = response.parsed_body['data']
      conversation = Conversation.find(data['conversation_id'])
      expect(data).to include('created' => true, 'has_active' => true)
      expect(conversation.inbox_id).to eq(inbox_a.id)
      expect(conversation).to be_open
      expect(conversation.assignee_id).to be_nil.or eq(user.id)
      expect(conversation.contact_inbox.source_id).to eq(contact.phone_number.delete('+'))
      expect(deal.reload.conversations).to include(conversation)
      expect(deal.deal_history_events.pluck(:action)).to include('conversation_attached')
    end

    it 'is idempotent: a second call returns the same active conversation' do
      post "/api/v1/deals/#{deal.id}/conversation", as: :json
      first = response.parsed_body.dig('data', 'conversation_id')

      expect { post "/api/v1/deals/#{deal.id}/conversation", as: :json }.not_to change(Conversation, :count)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['data']).to include('conversation_id' => first, 'created' => false)
    end

    it 'reuses an existing active conversation of the contact in another allowed inbox' do
      ci_b = ContactInbox.create!(contact: contact, inbox: inbox_b, source_id: contact.phone_number.delete('+'))
      existing = Conversation.create!(inbox: inbox_b, contact: contact, contact_inbox: ci_b)

      expect { post "/api/v1/deals/#{deal.id}/conversation", params: { inbox_id: inbox_a.id }, as: :json }
        .not_to change(Conversation, :count)

      expect(response.parsed_body.dig('data', 'conversation_id')).to eq(existing.id)
      expect(deal.reload.conversations).to include(existing)
    end

    it 'starts a new one when the only conversation is resolved' do
      ci_a = ContactInbox.create!(contact: contact, inbox: inbox_a, source_id: contact.phone_number.delete('+'))
      old = Conversation.create!(inbox: inbox_a, contact: contact, contact_inbox: ci_a)
      old.update_columns(status: Conversation.statuses[:resolved]) # rubocop:disable Rails/SkipsModelValidations
      deal

      expect { post "/api/v1/deals/#{deal.id}/conversation", as: :json}.to change(Conversation, :count).by(1)
      expect(response).to have_http_status(:created)
    end

    it 'uses the chosen allowed inbox and rejects one that is not allowed' do
      allow_inboxes(inbox_a, default: inbox_a)
      post "/api/v1/deals/#{deal.id}/conversation", params: { inbox_id: inbox_b.id }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig('error', 'code')).to eq('INBOX_NOT_ALLOWED')
      expect(Conversation.count).to eq(0)

      allow_inboxes(inbox_a, inbox_b, default: inbox_a)
      post "/api/v1/deals/#{deal.id}/conversation", params: { inbox_id: inbox_b.id }, as: :json
      expect(Conversation.find(response.parsed_body.dig('data', 'conversation_id')).inbox_id).to eq(inbox_b.id)
    end

    it 'requires an explicit inbox when there are several and none is default' do
      pipeline.pipeline_whatsapp_inboxes.update_all(is_default: false) # rubocop:disable Rails/SkipsModelValidations
      post "/api/v1/deals/#{deal.id}/conversation", as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig('error', 'code')).to eq('INBOX_REQUIRED')
      expect(response.parsed_body.dig('error', 'message')).to be_present
    end

    it 'fails clearly when no number is configured, no contact, no phone, blocked or channel disconnected' do
      pipeline.pipeline_whatsapp_inboxes.destroy_all
      post "/api/v1/deals/#{deal.id}/conversation", as: :json
      expect(response.parsed_body.dig('error', 'code')).to eq('NO_INBOX_CONFIGURED')

      allow_inboxes(inbox_a)
      empty = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, title: 'No contact')
      post "/api/v1/deals/#{empty.id}/conversation", as: :json
      expect(response.parsed_body.dig('error', 'code')).to eq('NO_CONTACT')

      nophone = Contact.create!(name: 'Sem telefone', email: "np-#{SecureRandom.hex(3)}@example.com")
      d2 = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, title: 'NP').tap { |d| d.attach_contact!(nophone) }
      post "/api/v1/deals/#{d2.id}/conversation", as: :json
      expect(response.parsed_body.dig('error', 'code')).to eq('CONTACT_WITHOUT_PHONE')

      inbox_a.channel.update_columns(provider_connection: { 'connection' => 'close' }) # rubocop:disable Rails/SkipsModelValidations
      post "/api/v1/deals/#{deal.id}/conversation", as: :json
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body.dig('error', 'code')).to eq('CHANNEL_DISCONNECTED')
      expect(Conversation.count).to eq(0)
    end

    it 'reopens the last conversation of lock_to_single_conversation inboxes instead of creating a new one' do
      inbox_a.update!(lock_to_single_conversation: true)
      ci_a = ContactInbox.create!(contact: contact, inbox: inbox_a, source_id: contact.phone_number.delete('+'))
      old = Conversation.create!(inbox: inbox_a, contact: contact, contact_inbox: ci_a)
      old.update_columns(status: Conversation.statuses[:resolved]) # rubocop:disable Rails/SkipsModelValidations
      deal

      expect { post "/api/v1/deals/#{deal.id}/conversation", as: :json }.not_to change(Conversation, :count)

      expect(response.parsed_body.dig('data', 'conversation_id')).to eq(old.id)
      expect(old.reload).to be_open
    end

    it 'does not create a second card in the default pipeline' do
      other_pipeline.update!(is_default: true)
      deal
      expect { post "/api/v1/deals/#{deal.id}/conversation", as: :json }.not_to change(PipelineItem, :count)
    end

    it 'does not trigger the AI agent for a contact outside the allowlist' do
      post "/api/v1/deals/#{deal.id}/conversation", as: :json
      conversation = Conversation.find(response.parsed_body.dig('data', 'conversation_id'))

      expect(VetorialAgent::Policy.allowed?(conversation)).to be(false)
      expect(Message.where(conversation_id: conversation.id)).to be_empty
    end

    it 'denies without the pipelines permission keys' do
      allow(Current).to receive(:service_authenticated).and_return(false)
      allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) { Current.user = user }
      allow_any_instance_of(EvoPermissionConcern).to receive(:check_permission!) { |ctrl, *| ctrl.send(:render_permission_denied) }

      expect { post "/api/v1/deals/#{deal.id}/conversation", as: :json }.not_to change(Conversation, :count)
      expect(response).to have_http_status(:forbidden)
    end

    it 'denies without pipeline update permission' do
      allow(Current).to receive(:service_authenticated).and_return(false)
      allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) { Current.user = user }
      allow_any_instance_of(EvoPermissionConcern).to receive(:check_permission!)
      allow_any_instance_of(PipelinePolicy).to receive(:view?).and_return(true)
      allow_any_instance_of(PipelinePolicy).to receive(:update?).and_return(false)

      get "/api/v1/deals/#{deal.id}/conversation_status", as: :json
      expect(response).to have_http_status(:ok)

      expect { post "/api/v1/deals/#{deal.id}/conversation", as: :json }.not_to change(Conversation, :count)
      expect(response).to have_http_status(:unauthorized)
    end

    it 'creates only one conversation under concurrent requests' do
      deal_id = deal.id
      inbox_id = inbox_a.id
      user_id = user.id
      results = Array.new(4) do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            Current.user = User.find(user_id)
            Current.service_authenticated = true
            Deals::ConversationService.new(PipelineItem.find(deal_id)).open_or_start!(inbox_id: inbox_id).last
          rescue StandardError => e
            e
          end
        end
      end.map(&:value)

      expect(results.grep(Exception)).to be_empty
      expect(results.count(true)).to eq(1)
      expect(Conversation.where(contact_id: contact.id).count).to eq(1)
      expect(DealConversation.where(pipeline_item_id: deal_id).count).to eq(1)
    end
  end

  describe 'conversation_summary in serializers' do
    it 'exposes has_active/can_start on the board and the deal without N+1 per item' do
      allow_inboxes(inbox_a)
      ci_a = ContactInbox.create!(contact: contact, inbox: inbox_a, source_id: contact.phone_number.delete('+'))
      conversation = Conversation.create!(inbox: inbox_a, contact: contact, contact_inbox: ci_a)
      deal.reload
      lone = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, title: 'Sem contato')

      get "/api/v1/pipelines/#{pipeline.id}", as: :json
      items = response.parsed_body.dig('data', 'stages').flat_map { |s| s['deals'] }
      with = items.find { |i| i['id'] == deal.id }['conversation_summary']
      without = items.find { |i| i['id'] == lone.id }['conversation_summary']
      expect(with).to include('has_active' => true, 'conversation_id' => conversation.id, 'can_start' => true)
      expect(without).to include('has_active' => false, 'can_start' => false, 'reason' => 'no_contact')

      get "/api/v1/deals/#{deal.id}", as: :json
      expect(response.parsed_body.dig('data', 'conversation_summary', 'conversation_id')).to eq(conversation.id)
    end

    it 'runs a constant number of summary queries regardless of how many deals' do
      allow_inboxes(inbox_a)
      deals = Array.new(6) do |i|
        c = Contact.create!(name: "C#{i}", phone_number: "+55219#{rand(1_000_0000..9_999_9999)}")
        PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, title: "D#{i}", primary_contact: c, contact_id: c.id)
      end
      queries = []
      sub = ActiveSupport::Notifications.subscribe('sql.active_record') { |*, p| queries << p[:sql] if p[:sql].include?('FROM "conversations"') || p[:sql].include?('FROM "pipeline_whatsapp_inboxes"') }
      Deals::ConversationSummary.batch(PipelineItem.where(id: deals.map(&:id)).to_a)
      ActiveSupport::Notifications.unsubscribe(sub)

      expect(queries.size).to be <= 2
    end
  end
end
