require 'rails_helper'

RSpec.describe 'Managed API PostgreSQL concurrency matrix', type: :request do
  self.use_transactional_tests = false
  let(:user) { User.create!(name: 'J11 concurrency', email: "j11-#{SecureRandom.hex(8)}@example.invalid") }

  before do
    @bot = AgentBot.create!(name: 'J11 concurrency')
    @deployment = VetorialAgent::Deployment.create!(agent_bot: @bot, slug: "j11-#{SecureRandom.hex(8)}", control_source: 'crm')
    @data = JSON.parse(File.read(Rails.root.join('spec/fixtures/vetorial_agent/snapshot.json')))['payload']
    @data.merge!('deployment_id' => @deployment.id)
    @data['binding']['agent_bot_id'] = @bot.id
    @revision = @deployment.revisions.create!(number: 1, status: 'published', payload: @data, sha256: VetorialAgent::Snapshot.digest(@data))
    @deployment.update!(active_revision: @revision)
    @profile = @deployment.profiles.create!(role: 'atendimento', name: 'J11 concurrency')
    @base = "/api/v1/vetorial_agents/#{@profile.id}"
    actor = user
    ids = @data['binding']['inbox_ids']
    allow_any_instance_of(Api::V1::BaseController).to receive(:authenticate_request!) { Current.user = actor }
    allow_any_instance_of(Api::V1::BaseController).to receive(:has_user_permission?).and_return(true)
    allow(user).to receive(:administrator?).and_return(true)
    scope = double(pluck: ids)
    channel = Channel::Whatsapp.new
    allow(channel).to receive(:evolution_attached?).and_return(true)
    inbox = instance_double(Inbox, channel: channel, agent_bot_inbox: double(agent_bot_id: @bot.id))
    allow(inbox).to receive(:with_lock).and_yield
    allow(scope).to receive(:find).with(ids.sole).and_return(inbox)
    allow(user).to receive(:assigned_inboxes).and_return(scope)
  end

  after do
    Current.reset
    if @conversation
      [VetorialAgent::Command, VetorialAgent::Event, VetorialAgent::State].each { |model| model.where(conversation_id: @conversation.id).delete_all }
      @conversation.destroy!
      @contact_inbox.destroy!
      @contact.destroy!
      @box.delete
      @channel.delete
    end
    VetorialAgent::Deployment.where(id: @deployment.id).update_all(active_revision_id: nil)
    VetorialAgent::Audit.where(deployment_id: @deployment.id).delete_all
    VetorialAgent::TestSession.where(profile_id: @profile.id).delete_all
    VetorialAgent::Profile.where(deployment_id: @deployment.id).delete_all
    VetorialAgent::Revision.where(deployment_id: @deployment.id).delete_all
    VetorialAgent::Deployment.where(id: @deployment.id).delete_all
    @bot.delete
    User.where(id: user.id).delete_all
  end

  def concurrent(count = 3)
    pool = ActiveRecord::Base.connection_pool
    warm = Array.new(count) { pool.checkout.tap(&:verify!) }
    warm.each { |c| pool.checkin(c) }
    ready, start = Queue.new, Queue.new
    threads = Array.new(count) do |i|
      Thread.new do
        pool.with_connection do |connection|
          ready << true
          start.pop
          session = ActionDispatch::Integration::Session.new(Rails.application)
          result = yield(session, i)
          [connection.select_value('SELECT pg_backend_pid()'), result]
        ensure
          Current.reset
        end
      end
    end
    count.times { ready.pop }
    count.times { start << true }
    results = threads.map(&:value)
    expect(results.map(&:first).uniq.size).to eq(count)
    results.map(&:last)
  end

  {
    draft: [:post, '/revisions'],
    restore: [:post, '/revisions/REV/restore'],
    publish: [:post, '/revisions/REV/publish'],
    activation: [:put, '/activation'],
    binding: [:put, '/binding']
  }.each do |action, (verb, suffix)|
    [true, false].each do |same_key|
      it "#{action}: #{same_key ? 'replays one result' : 'rejects competing stale writes'} on separate connections" do
        target = @revision
        target = VetorialAgent::Configuration.new(@deployment).draft(@data) if action == :publish
        version = @deployment.reload.lock_version.to_s
        params = case action
                 when :draft then { payload: @data }
                 when :activation then { mode: 'off' }
                 when :binding then { binding: @data['binding'] }
                 else {}
                 end
        url = @base + suffix.gsub('REV', target.id)
        results = concurrent do |session, i|
          session.public_send(verb, url, params: params, headers: {
            'If-Match' => version, 'Idempotency-Key' => same_key ? 'same-key' : "key-#{i}"
          }, as: :json)
          [session.response.status, session.response.parsed_body['data']]
        end
        expect(results.map(&:first).sort).to eq(same_key ? [200, 200, 200] : [200, 409, 409])
        expect(results.map(&:last).uniq.size).to eq(1) if same_key
        expect(@deployment.audits.where(action: action.to_s).count).to eq(1)
      end
    end
  end

  ['', '/revisions', '/revisions/REV', '/metrics', '/integrations'].each do |suffix|
    it "reads #{suffix.presence || 'profile'} concurrently without mutation" do
      version = @deployment.lock_version
      statuses = concurrent do |session, _|
        session.get(@base + suffix.gsub('REV', @revision.id))
        session.response.status
      end
      expect(statuses).to eq([200, 200, 200])
      expect(@deployment.reload.lock_version).to eq(version)
      expect(@deployment.audits.count).to eq(0)
    end
  end

  [:admin, :agent, :denied].each do |persona|
    it "#{persona}: reads the catalog concurrently with the correct grant" do
      allow(user).to receive(:administrator?).and_return(persona == :admin)
      allow_any_instance_of(Api::V1::BaseController).to receive(:has_user_permission?).and_return(persona != :denied)
      expect(EvoAiCoreService).not_to receive(:catalog_agents)
      statuses = concurrent do |session, _|
        session.get('/api/v1/agent_catalog', params: { source: 'vetorial_runtime' })
        session.response.status
      end
      expect(statuses).to eq([persona == :denied ? 403 : 200] * 3)
    end
  end
  it 'issues distinct concurrent challenges without changing activation' do
    nonces = concurrent do |session, _|
      session.post(@base + '/activation_challenges', as: :json)
      expect(session.response.status).to eq(200)
      session.response.parsed_body.dig('data', 'nonce')
    end
    expect(nonces.uniq.size).to eq(3)
    expect(@deployment.audits.where(action: 'activation_challenge').count).to eq(3)
    expect(@deployment.reload.active_revision_id).to eq(@revision.id)
  end

  def sandbox_stub
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('VETORIAL_AGENT_URL').and_return('http://runtime.invalid')
    allow(VetorialAgent::Policy).to receive(:secret).and_return('synthetic-j11-secret-' * 3)
    @allocations = Queue.new
    allow(HTTParty).to receive(:post) do |url, body:, headers:, timeout:|
      path = URI(url).path
      expect(VetorialAgent::Signature.valid?(body, headers, method: 'POST', path: path)).to be(true)
      input = JSON.parse(body)
      @allocations << input if input['action'] == 'create'
      double(code: 200, body: { data: { mode: 'simulation', spent_reserved_micro_usd: 0 } }.to_json)
    end
  end

  def start_sandbox_session(session = ActionDispatch::Integration::Session.new(Rails.application))
    session.post(@base + '/test_sessions', params: { revision_id: @revision.id, purpose: 'Synthetic',
      criteria: 'No live effect', sample_count: 3 }, headers: { 'Idempotency-Key' => 'j11-session' }, as: :json)
    expect(session.response.status).to eq(200)
    session.response.parsed_body.dig('data', 'id')
  end

  [:admin, :agent].each do |persona|
    context "sandbox concurrency as #{persona}" do
      before { allow(user).to receive(:administrator?).and_return(persona == :admin) }
  it 'creates one sandbox authorization and one allocation on concurrent session creation' do
    sandbox_stub
    ids = concurrent { |session, _| start_sandbox_session(session) }
    expect(ids.uniq.size).to eq(1)
    expect(@allocations.size).to eq(1)
    expect(VetorialAgent::TestSession.where(profile: @profile).count).to eq(1)
  end

  [:show, :message, :close].each do |action|
    it "serializes sandbox #{action} requests while preserving a single transcript entry" do
      sandbox_stub
      sid = start_sandbox_session
      key = SecureRandom.uuid
      statuses = concurrent do |session, _|
        path = @base + "/test_sessions/#{sid}"
        case action
        when :show then session.get(path)
        when :message
          session.post(path + '/messages', params: { text: 'Synthetic message' }, headers: { 'Idempotency-Key' => key }, as: :json)
        when :close then session.post(path + '/close', as: :json)
        end
        session.response.status
      end
      expect(statuses).to eq([200, 200, 200])
      record = VetorialAgent::TestSession.find(sid)
      expect(record.messages.size).to eq(action == :message ? 1 : 0)
      expect(record.state).to eq(action == :close ? 'closed' : 'open')
    end
  end

    end
  end

  def conversation_fixture
    ActiveJob::Base.queue_adapter = :test
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config)
    @channel = Channel::Whatsapp.create!(provider: 'evolution', phone_number: '+15550000001',
      provider_config: { instance_name: 'j11', existing_instance_attached: true, attachment_state: 'active' })
    @box = Inbox.create!(name: 'J11 concurrency', channel: @channel, enable_auto_assignment: false)
    @data['binding']['inbox_ids'] = [@box.id]
    VetorialAgent::Configuration.new(@deployment).replace(@data)
    @contact = Contact.new(name: 'J11 synthetic', phone_number: '+15550000002')
    @contact.passive_observation = true
    @contact.skip_default_pipeline_assignment = true
    @contact.save!
    @contact_inbox = ContactInbox.create!(inbox: @box, contact: @contact, source_id: '15550000002')
    @conversation = Conversation.create!(inbox: @box, contact: @contact, contact_inbox: @contact_inbox, source: :imported, status: :open)
    state = VetorialAgent::State.find_or_initialize_by(conversation: @conversation)
    state.update!(version: 1, paused: true, reason: 'synthetic')
    allow(user).to receive(:assigned_inboxes).and_return(Inbox.where(id: @box.id))
  end

  [:admin, :agent, :denied].each do |persona|
  [:show, :pause, :resume].each do |action|
    it "#{persona}: handles concurrent conversation #{action} requests with a version fence" do
      conversation_fixture
      allow(user).to receive(:administrator?).and_return(persona == :admin)
      allow_any_instance_of(Api::V1::BaseController).to receive(:has_user_permission?).and_return(persona != :denied)
      original = @conversation.attributes.slice('status', 'agent_last_seen_at', 'assignee_last_seen_at')
      statuses = concurrent do |session, _|
        path = "/api/v1/conversations/#{@conversation.id}/vetorial_ia"
        if action == :show
          session.get(path)
        else
          session.post(path + "/#{action}", params: { version: 1 }, as: :json)
        end
        session.response.status
      end
      expect(statuses.sort).to eq(persona == :denied ? [403, 403, 403] : action == :show ? [200, 200, 200] : [200, 409, 409])
      expect(@conversation.reload.attributes.slice(*original.keys)).to eq(original)
      expect(VetorialAgent::State.find_by!(conversation: @conversation).version).to eq(action == :show || persona == :denied ? 1 : 2)
    end
  end

  end

  {
    agent: false, denied: false
  }.each do |persona, admin|
    [
      [:get, '', 200], [:get, '/revisions', 200], [:get, '/revisions/REV', 200],
      [:get, '/metrics', 200], [:get, '/integrations', 200],
      [:post, '/activation_challenges', 403], [:put, '/activation', 403], [:put, '/binding', 403],
      [:post, '/revisions', 403], [:post, '/revisions/REV/publish', 403], [:post, '/revisions/REV/restore', 403],
      [:post, '/test_sessions', 422], [:get, '/test_sessions/SESSION', 404],
      [:post, '/test_sessions/SESSION/messages', 404], [:post, '/test_sessions/SESSION/close', 404]
    ].each do |verb, suffix, agent_status|
      it "#{persona}: concurrent #{verb} #{suffix.presence || 'profile'} respects authorization" do
        allow(user).to receive(:administrator?).and_return(admin)
        allow_any_instance_of(Api::V1::BaseController).to receive(:has_user_permission?).and_return(persona != :denied)
        path = @base + suffix.gsub('REV', @revision.id).gsub('SESSION', SecureRandom.uuid)
        statuses = concurrent do |session, _|
          verb == :get ? session.get(path) : session.public_send(verb, path, params: {}, as: :json)
          session.response.status
        end
        expect(statuses).to eq([persona == :denied ? 403 : agent_status] * 3)
        expect(@deployment.reload.active_revision_id).to eq(@revision.id)
      end
    end
  end

  %w[config integrations].each do |endpoint|
    it "requires HMAC and permits simultaneous signed internal #{endpoint} reads" do
      allow(VetorialAgent::Policy).to receive(:secret).and_return('synthetic-j11-secret-' * 3)
      path = "/internal/vetorial_agent/#{endpoint}/#{@deployment.id}"
      get path
      expect(response.status).to eq(401)
      statuses = concurrent do |session, _|
        session.get(path, headers: VetorialAgent::Signature.headers('', method: 'GET', path: path))
        session.response.status
      end
      expect(statuses).to eq([endpoint == 'config' ? 200 : 204] * 3)
    end
  end

end
