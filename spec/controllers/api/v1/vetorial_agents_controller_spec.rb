require 'rails_helper'

RSpec.describe Api::V1::VetorialAgentsController, type: :controller do
  let(:user) { User.new(id: SecureRandom.uuid) }
  let(:data) { JSON.parse(File.read(Rails.root.join('spec/fixtures/vetorial_agent/snapshot.json')))['payload'] }
  let(:bot) { AgentBot.create!(name: 'Synthetic controller', outgoing_url: 'http://agent.invalid') }
  let(:deployment) { VetorialAgent::Deployment.create!(agent_bot: bot, slug: 'synthetic') }
  let(:profile) do
    payload = data.merge('deployment_id' => deployment.id)
    revision = deployment.revisions.create!(number: 1, status: 'published', payload: payload, sha256: VetorialAgent::Snapshot.digest(payload))
    deployment.update!(active_revision: revision)
    deployment.profiles.create!(role: 'atendimento', name: 'Synthetic')
  end

  before do
    allow(user).to receive(:administrator?).and_return(false)
    allow(controller).to receive(:authenticate_request!) { Current.user = user }
    allow(controller).to receive(:check_permission!).and_return(true)
    allow(user).to receive(:assigned_inboxes).and_return(Inbox.where(id: []))
  end

  after { Current.reset }

  it 'returns 404 outside the authorized inbox scope' do
    get :show, params: { id: profile.id }
    expect(response.status).to eq(404)
    expect(response.body).not_to include(data['roles']['atendimento']['prompt'])
  end

  it 'allows read-only profile access and rejects editing by a non-admin' do
    record = profile
    scope = double('inbox scope', pluck: data['binding']['inbox_ids'])
    allow(user).to receive(:assigned_inboxes).and_return(scope)
    get :show, params: { id: record.id }
    expect(response.status).to eq(200)
    expect(JSON.parse(response.body).dig('data', 'source')).to eq('vetorial_runtime')
    post :create_revision, params: { id: record.id, payload: data }
    expect(response.status).to eq(403)
  end
end
