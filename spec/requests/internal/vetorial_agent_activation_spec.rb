require 'rails_helper'

RSpec.describe 'Managed activation HTTP', type: :request do
  include ActiveSupport::Testing::TimeHelpers
  let(:user) { User.create!(name: 'Synthetic J9', email: "j9-#{SecureRandom.hex(4)}@example.invalid") }
  let(:deployment) { VetorialAgent::Deployment.create!(agent_bot: AgentBot.create!(name: 'J9'), slug: 'j9', control_source: 'crm') }
  let(:payload) { JSON.parse(File.read(Rails.root.join('spec/fixtures/vetorial_agent/snapshot.json')))['payload'].merge('deployment_id' => deployment.id) }
  let!(:profile) do
    revision = deployment.revisions.create!(number: 1, status: 'published', payload: payload, sha256: VetorialAgent::Snapshot.digest(payload))
    deployment.update!(active_revision: revision)
    deployment.profiles.create!(role: 'atendimento', name: 'J9')
  end
  let(:path) { "/api/v1/vetorial_agents/#{profile.id}" }
  let(:admin) { true }
  let(:allowed) { true }
  let(:boxes) { payload['binding']['inbox_ids'] }

  before do
    allow_any_instance_of(Api::V1::BaseController).to receive(:authenticate_request!) { Current.user = user }
    allow_any_instance_of(Api::V1::BaseController).to receive(:has_user_permission?).and_return(allowed)
    allow(user).to receive(:administrator?).and_return(admin)
    allow(user).to receive(:assigned_inboxes).and_return(double(pluck: boxes))
  end
  after { Current.reset }

  def challenge
    post "#{path}/activation_challenges", as: :json
    expect(response.status).to eq(200)
    response.parsed_body.dig('data', 'nonce')
  end

  def activate(nonce, **changes)
    put "#{path}/activation", params: { mode: 'all', nonce: nonce, phrase: 'ATIVAR PARA TODOS', confirm: true }.merge(changes),
      headers: { 'If-Match' => deployment.reload.lock_version.to_s, 'Idempotency-Key' => SecureRandom.hex(12) }, as: :json
  end

  it 'rejects expiration, wrong phrase and missing explicit confirmation without publishing' do
    nonce = challenge
    activate(nonce, phrase: 'ativar para todos')
    expect(response.status).to eq(422)
    activate(nonce, confirm: false)
    expect(response.status).to eq(422)
    travel 61.seconds do
      activate(nonce)
      expect(response.status).to eq(422)
    end
    expect(deployment.reload.payload['activation']['atendimento']).to eq('pilot')
  end

  it 'publishes atomically, consumes once, preserves the other role and supports off and pilot' do
    nonce = challenge
    activate(nonce)
    expect(response.status).to eq(200)
    expect(deployment.reload.payload['activation'].slice('atendimento', 'analista')).to eq('atendimento' => 'all', 'analista' => 'pilot')
    activate(nonce)
    expect(response.status).to eq(422)
    activate(nil, mode: 'off')
    expect(response.status).to eq(200)
    activate(nil, mode: 'pilot', allowlist: [])
    expect(response.status).to eq(422)
    activate(nil, mode: 'pilot')
    expect(response.status).to eq(200)
  end

  it 'binds the challenge to actor, profile and revision' do
    nonce = challenge
    other = deployment.profiles.create!(role: 'analista', name: 'Analyst')
    put "/api/v1/vetorial_agents/#{other.id}/activation", params: { mode: 'all', nonce: nonce, phrase: 'ATIVAR PARA TODOS', confirm: true },
      headers: { 'If-Match' => deployment.reload.lock_version.to_s, 'Idempotency-Key' => 'other-profile' }, as: :json
    expect(response.status).to eq(422)
    deployment.audits.find_by!(action: 'activation_challenge').update!(actor_id: SecureRandom.uuid)
    activate(nonce)
    expect(response.status).to eq(422)
    nonce = challenge
    activate(nil, mode: 'off')
    activate(nonce)
    expect(response.status).to eq(422)
  end

  it 'accepts only an existing native attached WhatsApp binding and keeps both profiles on the bundle' do
    scope = double(pluck: boxes)
    inbox = instance_double(Inbox)
    channel = Channel::Whatsapp.new
    allow(channel).to receive(:evolution_attached?).and_return(true)
    allow(inbox).to receive(:channel).and_return(channel)
    allow(inbox).to receive(:with_lock).and_yield
    allow(inbox).to receive(:agent_bot_inbox).and_return(double(agent_bot_id: deployment.agent_bot_id))
    allow(scope).to receive(:find).with(boxes.sole).and_return(inbox)
    allow(user).to receive(:assigned_inboxes).and_return(scope)
    input = payload['binding'].merge('agent_bot_id' => deployment.agent_bot_id)
    put_binding = lambda do
      put "#{path}/binding", params: { binding: input }, headers: {
        'If-Match' => deployment.reload.lock_version.to_s, 'Idempotency-Key' => SecureRandom.hex(12) }, as: :json
    end
    put_binding.call
    expect(response.status).to eq(200)
    expect(deployment.reload.payload['binding']).to eq(input)
    allow(inbox).to receive(:agent_bot_inbox).and_return(double(agent_bot_id: SecureRandom.uuid))
    put_binding.call
    expect(response.status).to eq(409)
    allow(inbox).to receive(:agent_bot_inbox).and_return(nil)
    put_binding.call
    expect(response.status).to eq(409)
    expect(AgentBotInbox.count).to eq(0)
  end

  it 'validates office windows through HTTP drafts without applying them until publish' do
    data = deployment.payload.deep_dup
    data['behavior']['office_hours'] = { 'enabled' => true, 'windows' => [
      { 'weekday' => 0, 'start' => '09:00', 'end' => '12:00' },
      { 'weekday' => 0, 'start' => '12:00', 'end' => '18:00' }] }
    create_draft = lambda do
      post "#{path}/revisions", params: { payload: data }, headers: {
        'If-Match' => deployment.reload.lock_version.to_s, 'Idempotency-Key' => SecureRandom.hex(12) }, as: :json
    end
    create_draft.call
    expect(response.status).to eq(200)
    expect(deployment.reload.payload['behavior']['office_hours']['enabled']).to be(false)
    data['behavior']['office_hours']['windows'][1]['start'] = '11:59'
    create_draft.call
    expect(response.status).to eq(422)
    data['behavior']['office_hours']['windows'] = []
    create_draft.call
    expect(response.status).to eq(422)
  end

  context 'non-admin with update grant' do
    let(:admin) { false }
    it 'cannot issue or apply challenges' do
      post "#{path}/activation_challenges", as: :json
      expect(response.status).to eq(403)
      activate(nil, mode: 'off')
      expect(response.status).to eq(403)
    end
  end
  context 'admin without update grant' do
    let(:allowed) { false }
    it 'is forbidden' do
      post "#{path}/activation_challenges", as: :json
      expect(response.status).to eq(403)
    end
  end
  context 'outside inbox scope' do
    let(:boxes) { [] }
    it 'is not found' do
      post "#{path}/activation_challenges", as: :json
      expect(response.status).to eq(404)
    end
  end
end
