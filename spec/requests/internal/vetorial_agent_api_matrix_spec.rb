require 'rails_helper'

RSpec.describe 'Managed API authorization matrix', type: :request do
  let(:user) { User.new(id: SecureRandom.uuid) }
  let(:payload) { JSON.parse(File.read(Rails.root.join('spec/fixtures/vetorial_agent/snapshot.json')))['payload'] }
  let!(:deployment) { VetorialAgent::Deployment.create!(agent_bot: AgentBot.create!(name: 'Matrix'), slug: 'matrix', control_source: 'crm') }
  let!(:revision) do
    data = payload.merge('deployment_id' => deployment.id)
    deployment.revisions.create!(number: 1, status: 'published', payload: data, sha256: VetorialAgent::Snapshot.digest(data)).tap { |r| deployment.update!(active_revision: r) }
  end
  let!(:profile) { deployment.profiles.create!(role: 'atendimento', name: 'Matrix') }
  let(:base) { "/api/v1/vetorial_agents/#{profile.id}" }
  let(:admin) { true }
  let(:permission) { true }
  let(:boxes) { payload['binding']['inbox_ids'] }
  before do
    allow_any_instance_of(Api::V1::BaseController).to receive(:authenticate_request!) { Current.user = user }
    allow_any_instance_of(Api::V1::BaseController).to receive(:has_user_permission?).and_return(permission)
    allow(user).to receive(:administrator?).and_return(admin)
    allow(user).to receive(:assigned_inboxes).and_return(double(pluck: boxes))
  end
  after { Current.reset }

  # Invalid operations deliberately reach validation/CAS, proving authorization without external calls.
  routes = [
    [:get, '', 200, false], [:get, '/revisions', 200, false],
    [:get, '/revisions/REV', 200, false], [:get, '/metrics', 200, false],
    [:get, '/integrations', 200, false], [:post, '/activation_challenges', 200, true],
    [:put, '/activation', 422, true], [:put, '/binding', 422, true],
    [:post, '/revisions', 422, true], [:post, '/revisions/REV/publish', 422, true],
    [:post, '/revisions/REV/restore', 422, true],
    [:post, '/test_sessions', 422, false],
    [:get, '/test_sessions/SESSION', 404, false],
    [:post, '/test_sessions/SESSION/messages', 404, false],
    [:post, '/test_sessions/SESSION/close', 404, false]
  ]
  { admin: [true, true, nil], agent: [false, true, nil], denied: [false, false, nil],
    outside_inbox: [true, true, []] }.each do |persona, (is_admin, granted, scope)|
    context persona.to_s do
      let(:admin) { is_admin }
      let(:permission) { granted }
      let(:boxes) { scope || payload['binding']['inbox_ids'] }
      routes.each do |verb, suffix, authorized_status, admin_only|
        it "#{verb.upcase} #{suffix.presence || 'profile'}" do
          url = base + suffix.gsub('REV', revision.id).gsub('SESSION', SecureRandom.uuid)
          verb == :get ? get(url) : public_send(verb, url, params: {}, as: :json)
          expected = !granted ? 403 : scope == [] ? 404 : !is_admin && admin_only ? 403 : authorized_status
          expect(response.status).to eq(expected), response.body[0, 500]
          expect(deployment.reload.active_revision_id).to eq(revision.id)
        end
      end
    end
  end
  [%w[limits api_key], %w[provider api_key], %w[runtime api_key], %w[roles atendimento model]].each do |path|
    it "rejects a forbidden draft field #{path.join('.')} through HTTP" do
      data = deployment.payload.deep_dup
      data.dig(*path[0...-1])[path.last] = path.last == 'model' ? 'gpt-6-astra' : 'synthetic-rejected-key'
      post base + '/revisions', params: { payload: data }, headers: {
        'If-Match' => deployment.lock_version.to_s, 'Idempotency-Key' => 'invalid-field'
      }, as: :json
      expect(response.status).to eq(422)
      expect(response.body).not_to include('synthetic-rejected-key')
      expect(deployment.revisions.count).to eq(1)
    end
  end

end
