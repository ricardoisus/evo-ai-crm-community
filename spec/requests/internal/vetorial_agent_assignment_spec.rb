require 'rails_helper'

RSpec.describe 'Managed conversation assignment grant', type: :request do
  let(:user) { User.create!(name: 'J9 operator', email: "j9-#{SecureRandom.hex(4)}@example.invalid") }
  let(:channel) do
    Channel::Whatsapp.create!(provider: 'evolution', phone_number: '+15550000001', provider_connection: { connection: 'open' },
      provider_config: { instance_name: 'synthetic-j9', existing_instance_attached: true, attachment_state: 'active',
                         attachment_token: 'synthetic-token', attachment_started_at: 100 })
  end
  let(:box) { Inbox.create!(name: 'J9', channel: channel, enable_auto_assignment: false) }
  let(:contact) do
    Contact.new(name: 'Synthetic', phone_number: '+15550000002').tap do |c|
      c.passive_observation = true
      c.skip_default_pipeline_assignment = true
      c.save!
    end
  end
  let(:conversation) do
    ci = ContactInbox.create!(inbox: box, contact: contact, source_id: '15550000002')
    Conversation.create!(inbox: box, contact: contact, contact_inbox: ci, source: :imported, status: :open)
  end
  let(:deployment) { VetorialAgent::Deployment.create!(agent_bot: AgentBot.create!(name: 'J9'), slug: 'j9', control_source: 'crm') }
  let(:granted) { true }
  before do
    ActiveJob::Base.queue_adapter = :test
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config)
    allow_any_instance_of(Api::V1::BaseController).to receive(:authenticate_request!) { Current.user = user }
    allow_any_instance_of(Api::V1::BaseController).to receive(:has_user_permission?).with(user.id, 'conversations.update').and_return(granted)
    allow(user).to receive(:assigned_inboxes).and_return(Inbox.where(id: box.id))
    payload = JSON.parse(File.read(Rails.root.join('spec/fixtures/vetorial_agent/snapshot.json')))['payload']
    payload['deployment_id'] = deployment.id
    payload['binding'].merge!('agent_bot_id' => deployment.agent_bot_id, 'inbox_ids' => [box.id])
    revision = deployment.revisions.create!(number: 1, status: 'published', payload: payload, sha256: VetorialAgent::Snapshot.digest(payload))
    deployment.update!(active_revision: revision)
    conversation.update_columns(assignee_id: user.id)
    VetorialAgent::State.create!(conversation: conversation, version: 1, paused: true, reason: 'human_assigned')
  end
  after { Current.reset }

  def resume(clear = nil)
    post "/api/v1/conversations/#{conversation.id}/vetorial_ia/resume", params: { version: 1, clear_assignee: clear }, as: :json
  end

  it 'requires the explicit choice and preserves status and read state on authorized removal' do
    before = conversation.reload.attributes.slice('status', 'agent_last_seen_at', 'assignee_last_seen_at')
    resume
    expect(response.status).to eq(409)
    expect(conversation.reload.assignee_id).to eq(user.id)
    resume(true)
    expect(response.status).to eq(200)
    expect(conversation.reload.assignee_id).to be_nil
    expect(conversation.attributes.slice(*before.keys)).to eq(before)
    expect(VetorialAgent::State.find_by!(conversation: conversation)).not_to be_paused
  end

  context 'without the existing assignment grant (conversations.update)' do
    let(:granted) { false }
    it 'leaves both assignment and pause intact' do
      resume(true)
      expect(response.status).to eq(403)
      expect(conversation.reload.assignee_id).to eq(user.id)
      expect(VetorialAgent::State.find_by!(conversation: conversation)).to be_paused
    end
  end
  { admin: [true, true], agent: [false, true], denied: [false, false] }.each do |persona, (admin, permission)|
    [[:get, ''], [:post, '/pause'], [:post, '/resume']].each do |verb, suffix|
      it "#{persona}: #{verb} conversation control #{suffix}" do
        allow(user).to receive(:administrator?).and_return(admin)
        allow_any_instance_of(Api::V1::BaseController).to receive(:has_user_permission?).and_return(permission)
        url = "/api/v1/conversations/#{conversation.id}/vetorial_ia#{suffix}"
        if verb == :get
          get url
        else
          post url, params: { version: 1, clear_assignee: true }, as: :json
        end
        expect(response.status).to eq(permission ? 200 : 403)
        if permission && verb == :get
          expect(response.parsed_body['data']).to include('mode' => 'pilot', 'health' => 'unavailable', 'reason' => 'human_assigned')
        end
      end
    end
  end

  [[:get, ''], [:post, '/pause'], [:post, '/resume']].each do |verb, suffix|
    it "hides #{verb} conversation control #{suffix} outside assigned inboxes" do
      allow_any_instance_of(Api::V1::BaseController).to receive(:has_user_permission?).and_return(true)
      allow(user).to receive(:assigned_inboxes).and_return(Inbox.none)
      url = "/api/v1/conversations/#{conversation.id}/vetorial_ia#{suffix}"
      verb == :get ? get(url) : post(url, params: { version: 1 }, as: :json)
      expect(response.status).to eq(404)
    end
  end

end
