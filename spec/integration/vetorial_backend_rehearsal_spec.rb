require 'rails_helper'
require 'socket'
require 'open3'
require 'tmpdir'
require 'sidekiq/embedded'
require 'sidekiq/api'

# Real loopback HTTP -> Rails request stack, Postgres, Redis/Sidekiq and Python.
# Optional external setup (absolute paths):
# VETORIAL_REHEARSAL_RUNTIME: runtime services/vetorial-agente directory.
# VETORIAL_REHEARSAL_PYTHON: Python executable with runtime test dependencies.
# POSTGRES_TEST_URL: dedicated synthetic vetorial_agent_a12_test database.
# Rails also requires evo_i3_test and Redis at 127.0.0.1:56389.
RSpec.describe 'J12 backend rehearsal', type: :request do
  self.use_transactional_tests = false
  let(:phone) { '+15550000002' }
  let(:channel) do
    @channel = Channel::Whatsapp.create!(provider: 'evolution', phone_number: '+1555' + SecureRandom.random_number(10**7).to_s.rjust(7, '0'), provider_connection: { connection: 'open' },
      provider_config: { instance_name: 'synthetic-vetorial', existing_instance_attached: true, attachment_state: 'active',
                         attachment_token: 'synthetic-token', attachment_started_at: 100 })
  end
  let(:box) { @box = Inbox.create!(name: 'Synthetic Vetorial', channel: channel, enable_auto_assignment: false) }
  let(:contact) do
    c = Contact.new(name: 'Médico sintético', phone_number: phone)
    c.passive_observation = true
    c.skip_default_pipeline_assignment = true
    c.save!
    @contact = c
  end
  let(:conversation) do
    ci = ContactInbox.create!(inbox: box, contact: contact, source_id: phone.delete_prefix('+'))
    @conversation = Conversation.create!(inbox: box, contact: contact, contact_inbox: ci, source: :imported, status: :open)
  end
  let(:digest) { 'synthetic@sha256:' + 'a' * 64 }
  let(:inventory) { %w[crm sidekiq].to_h { |name| [name, [{ 'state' => 'running', 'image' => digest }]] } }
  let(:bot) { @bot = AgentBot.create!(name: 'Ricardo IA sintético', outgoing_url: 'http://agent.invalid') }
  let(:bridge) { VetorialAgent::Bridge.new(conversation) }

  before do
    required = %w[VETORIAL_REHEARSAL_RUNTIME VETORIAL_REHEARSAL_PYTHON POSTGRES_TEST_URL]
    missing = required.select { |key| ENV[key].blank? }
    skip "Backend rehearsal requires external setup: #{missing.join(', ')} (see spec header)" if missing.any?

    ActiveJob::Base.queue_adapter = :test
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config)
    allow(ActionCableListener.instance).to receive(:message_created)
    allow(ActionCableListener.instance).to receive(:message_updated)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).with('VETORIAL_AGENT_INBOX_ID').and_return(box.id)
    allow(ENV).to receive(:fetch).with('VETORIAL_AGENT_ALLOWLIST', '').and_return(phone)
    allow(ENV).to receive(:[]).with('VETORIAL_AGENT_SEND_ENABLED').and_return('true')
    allow(ENV).to receive(:fetch).with('VETORIAL_AGENT_BOT_ID').and_return(bot.id)
  end


  it 'accepts publication, execution and rollback without losing durable work' do
    runtime = ENV.fetch('VETORIAL_REHEARSAL_RUNTIME')
    expect(ENV.fetch('POSTGRES_DATABASE')).to eq('evo_i3_test')
    expect(ENV.fetch('REDIS_URL')).to eq('redis://127.0.0.1:56389')
    secret = 'synthetic-j12-' + 's' * 40
    allow(ENV).to receive(:fetch).with('VETORIAL_AGENT_SECRET', '').and_return(secret)
    allow(ENV).to receive(:[]).with('VETORIAL_AGENT_SECRET_FILE').and_return(nil)
    allow_any_instance_of(VetorialAgent::Transport).to receive(:typing)
    allow_any_instance_of(VetorialAgent::Transport).to receive(:send_text).and_return('j12-provider-receipt')
    queue = "j12_#{SecureRandom.hex(6)}"
    old_adapter, old_queue = VetorialAgent::SendJob.queue_adapter, VetorialAgent::SendJob.queue_name
    VetorialAgent::SendJob.disable_test_adapter
    VetorialAgent::SendJob.queue_adapter = :sidekiq
    VetorialAgent::SendJob.queue_name = queue
    config = Sidekiq::Config.new
    config.redis = { url: ENV.fetch('REDIS_URL') }
    config.concurrency = 1
    config.queues = [queue]
    config[:timeout] = 5
    embedded = Sidekiq::Embedded.new(config)
    embedded.run
    server = TCPServer.new('127.0.0.1', 0)
    base = "http://127.0.0.1:#{server.addr[1]}"
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! 'localhost'
    payload_file = nil
    Dir.mktmpdir('j12-') do |dir|
      payload_file = File.join(dir, 'input.json')
      File.write(payload_file, { base: base, secret: secret, bot: bot.id, inbox: box.id,
                                conversation: conversation.id }.to_json)
      python = ENV.fetch('VETORIAL_REHEARSAL_PYTHON')
      input, output, waiter = Open3.popen2e({ 'PYTHONPATH' => runtime }, python,
        File.join(runtime, 'tests/rehearse_backend.py'), payload_file)
      input.close
      log = +''
      reader = Thread.new { output.each_line { |line| log << line } }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 90
      while waiter.alive?
        raise "J12 timed out: #{log}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        next unless IO.select([server], nil, nil, 0.1)
        client = server.accept
        request = client.gets
        method, target = request.split
        headers = {}
        while (line = client.gets) && line != "\r\n"
          name, value = line.split(':', 2)
          headers[name] = value.strip
        end
        body = client.read(headers.fetch('Content-Length', '0').to_i)
        if target.start_with?('/__j12/')
          result = rehearsal_control(target.delete_prefix('/__j12/'), JSON.parse(body.presence || '{}'))
          status, response_body = 200, result.to_json
        else
          session.process(method.downcase, target, params: body.presence,
            headers: headers.merge('CONTENT_TYPE' => 'application/json'))
          status, response_body = session.response.status, session.response.body
        end
        client.write("HTTP/1.1 #{status} Result\r\nContent-Type: application/json\r\nContent-Length: #{response_body.bytesize}\r\nConnection: close\r\n\r\n#{response_body}")
        client.close
      end
      reader.join
      expect(waiter.value.success?).to be(true), log
      puts log
    ensure
      Process.kill('TERM', waiter.pid) if waiter&.alive?
      waiter&.join
      reader&.join
      output&.close
    end
  ensure
    server&.close
    embedded&.stop
    Sidekiq::Queue.new(queue).clear if queue
    VetorialAgent::SendJob.queue_adapter = old_adapter if old_adapter
    VetorialAgent::SendJob.enable_test_adapter(old_adapter) if old_adapter
    VetorialAgent::SendJob.queue_name = old_queue if old_queue
    if @j12_deployment
      VetorialAgent::Deployment.where(id: @j12_deployment.id).update_all(active_revision_id: nil)
      [VetorialAgent::TelemetryEvent, VetorialAgent::Usage, VetorialAgent::Execution,
       VetorialAgent::RuntimeStatus, VetorialAgent::Audit, VetorialAgent::Profile,
       VetorialAgent::Revision].each { |model| model.where(deployment_id: @j12_deployment.id).delete_all }
      VetorialAgent::Deployment.where(id: @j12_deployment.id).delete_all
    end
    if defined?(@conversation) && @conversation
      VetorialAgent::Command.where(conversation_id: @conversation.id).delete_all
      VetorialAgent::Event.where(conversation_id: @conversation.id).delete_all
      VetorialAgent::State.where(conversation_id: @conversation.id).delete_all
      @conversation.messages.destroy_all
      @conversation.destroy!
    end
    AgentBotInbox.where(agent_bot_id: @bot.id).delete_all if @bot
    ContactInbox.where(contact_id: @contact.id).delete_all if @contact
    @contact&.destroy!
    @box&.delete
    @channel&.delete
    @bot&.destroy!
  end

  def rehearsal_control(action, data)
    @j12_deployment&.reload
    @j12_profile&.reload
    case action
    when 'import'
      @j12_deployment = VetorialAgent::Deployment.create!(slug: "j12-#{SecureRandom.hex(4)}", agent_bot: bot)
      payload = data.fetch('payload').merge('deployment_id' => @j12_deployment.id)
      revision = @j12_deployment.revisions.create!(number: 1, payload: payload,
        sha256: VetorialAgent::Snapshot.digest(payload), status: 'published')
      @j12_deployment.update!(active_revision: revision)
      @j12_profile = @j12_deployment.profiles.create!(role: 'atendimento', name: 'J12 atendimento')
      @j12_deployment.profiles.create!(role: 'analista', name: 'J12 analista')
      { deployment: @j12_deployment.id }
    when 'publish'
      @j12_deployment.update!(control_source: 'crm')
      service = VetorialAgent::Configuration.new(@j12_deployment)
      draft = service.draft(@j12_deployment.payload)
      service.publish(draft)
      { revision: draft.number }
    when 'incoming'
      conversation.messages.create!(inbox: box, sender: contact, source: :imported,
        message_type: :incoming, content: 'Olá, sou médico e quero conversar')
      event = VetorialAgent::Event.where(conversation: conversation).order(:created_at).last
      VetorialAgent::DispatchJob.new.send(:dispatch, event, data.fetch('runtime'))
      { event: event.payload.merge(event_id: event.id) }
    when 'metrics'
      { metrics: VetorialAgent::Metrics.new(@j12_deployment.reload, source: 'live').call,
        profile: VetorialAgent::ProfileView.summary(@j12_profile.reload),
        commands: VetorialAgent::Command.where(conversation: conversation, kind: 'send').order(:created_at).pluck(:status),
        messages: conversation.messages.outgoing.where(private: false).count }
    when 'pause', 'resume'
      state = VetorialAgent::State.find_by!(conversation: conversation)
      previous = conversation.reload.attributes.slice('status', 'agent_last_seen_at', 'assignee_last_seen_at')
      result = VetorialAgent::ConversationControl.call(conversation, action: action, version: state.version, actor_id: nil)
      expect(conversation.reload.attributes.slice(*previous.keys)).to eq(previous)
      result
    when 'off'
      VetorialAgent::Activation.new(@j12_profile, actor_id: nil).apply('mode' => 'off')
      { off: true }
    when 'compatible'
      VetorialAgent::GuardBoot.mark_ready!
      @j12_deployment.reload
      mixed = inventory.deep_dup
      mixed['sidekiq'] << { 'state' => 'running', 'image' => 'old' }
      expect { VetorialAgent::Binding.attach!(@j12_deployment, inventory: -> { mixed }, digest: digest) }
        .to raise_error(VetorialAgent::Configuration::Conflict)
      original = box.reload.default_conversation_status_value
      VetorialAgent::Binding.attach!(@j12_deployment, inventory: -> { inventory }, digest: digest)
      expect(box.reload.default_conversation_status_value).to eq(original)
      expect(AgentBotListener.instance.send(:connected_agent_bot_exist?, box)).to be(false)
      # Execute the legacy decision branches against this active association.
      allow(VetorialAgent::Deployment).to receive(:managed_bot?).and_return(false)
      expect(AgentBotListener.instance.send(:connected_agent_bot_exist?, box)).to be(true)
      expect(box.default_conversation_status_value).to eq(:pending)
      allow(VetorialAgent::Deployment).to receive(:managed_bot?).and_call_original
      expect(box.default_conversation_status_value).to eq(original)
      { compatible: true }
    when 'legacy'
      @j12_deployment.update!(control_source: 'legacy_transition')
      payload = @j12_deployment.payload.deep_dup
      payload['activation']['atendimento'] = 'pilot'
      VetorialAgent::Configuration.new(@j12_deployment).replace(payload)
      { legacy: true }
    when 'promote'
      @j12_deployment.update!(control_source: 'crm')
      { promoted: true }
    when 'rollback'
      AgentBotInbox.find_by!(agent_bot: bot, inbox: box).update!(status: :inactive)
      @j12_deployment.update!(control_source: 'legacy_transition')
      { restored: @j12_deployment.command_current?({}), native_active: box.reload.agent_bot_inbox&.active? }
    else
      raise "Unknown rehearsal control #{action}"
    end
  end
end
