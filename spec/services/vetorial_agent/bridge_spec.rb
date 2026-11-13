require 'rails_helper'
require 'webmock/rspec'
WebMock.disable_net_connect!(allow_localhost: true)

RSpec.describe 'Vetorial agent durable bridge' do
  include ActiveJob::TestHelper
  let(:phone) { '+15550000002' }
  let(:channel) do
    Channel::Whatsapp.create!(provider: 'evolution', phone_number: '+15550000001', provider_connection: { connection: 'open' },
      provider_config: { instance_name: 'synthetic-vetorial', existing_instance_attached: true, attachment_state: 'active',
                         attachment_token: 'synthetic-token', attachment_started_at: 100 })
  end
  let(:box) { Inbox.create!(name: 'Synthetic Vetorial', channel: channel, enable_auto_assignment: false) }
  let(:contact) do
    c = Contact.new(name: 'Médico sintético', phone_number: phone)
    c.passive_observation = true
    c.skip_default_pipeline_assignment = true
    c.save!
    c
  end
  let(:conversation) do
    ci = ContactInbox.create!(inbox: box, contact: contact, source_id: phone.delete_prefix('+'))
    Conversation.create!(inbox: box, contact: contact, contact_inbox: ci, source: :imported, status: :open)
  end
  let(:digest) { 'synthetic@sha256:' + 'a' * 64 }
  let(:inventory) { %w[crm sidekiq].to_h { |name| [name, [{ 'state' => 'running', 'image' => digest }]] } }
  let(:bot) { AgentBot.create!(name: 'Ricardo IA sintético', outgoing_url: 'http://agent.invalid') }
  let(:bridge) { VetorialAgent::Bridge.new(conversation) }

  before do
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

  def incoming(content = 'Oi')
    conversation.messages.create!(inbox: box, sender: contact, source: :imported, message_type: :incoming, content: content)
  end

  def command(kind = 'send', **payload)
    { 'key' => 'synthetic-key', 'version' => 1, 'kind' => kind }.merge(payload.deep_stringify_keys)
  end

  it 'skips assignment capture for unrelated conversation updates' do
    incoming
    expect(VetorialAgent::Capture).not_to receive(:assignment)
    conversation.update!(custom_attributes: { 'synthetic' => true })
  end

  it 'captures inert U8 messages within the transaction and rolls outbox back with source' do
    conversation
    Conversation.transaction do
      incoming
      expect(VetorialAgent::Event.count).to eq(1)
      raise ActiveRecord::Rollback
    end
    expect(VetorialAgent::Event.count).to eq(0)
    incoming
    expect(VetorialAgent::State.find_by!(conversation: conversation).version).to eq(1)
    expect(VetorialAgent::Event.last.payload['message_id']).to eq(conversation.messages.last.id)
  end

  it 'pauses on cellphone echo and never resumes on an incoming message or restart' do
    incoming
    conversation.messages.create!(inbox: box, source: :imported, message_type: :outgoing, content: 'Eu assumi',
                                  content_attributes: { evolution_origin: 'human_device' })
    incoming('Mais uma dúvida')
    state = VetorialAgent::State.find_by!(conversation: conversation)
    expect(state).to be_paused
    expect(conversation.reload.custom_attributes['vetorial_ia']['paused']).to eq(true)
    expect { bridge.call(command(text: 'Não enviar')) }.to raise_error(VetorialAgent::Bridge::Rejected)
    conversation.add_labels(['ia-ativa'])
    expect(state.reload).not_to be_paused
    expect(state.version).to eq(4)
    expect(VetorialAgent::Event.where("payload->>'kind' = ?", 'resume').count).to eq(1)
  end

  it 'removes previous resume label on takeover so a fresh label action is necessary' do
    incoming
    conversation.add_labels(['ia-ativa'])
    conversation.messages.create!(inbox: box, source: :imported, message_type: :outgoing, content: 'Humano')
    expect(conversation.reload.label_list).not_to include('ia-ativa')
    expect(VetorialAgent::State.find_by!(conversation: conversation)).to be_paused
    conversation.add_labels(['ia-ativa'])
    expect(VetorialAgent::State.find_by!(conversation: conversation)).not_to be_paused
  end

  it 'rejects an empty allowlist and a different inbox' do
    incoming
    allow(ENV).to receive(:fetch).with('VETORIAL_AGENT_ALLOWLIST', '').and_return('')
    expect { bridge.call(command(text: 'No')) }.to raise_error(VetorialAgent::Bridge::Rejected)
    allow(ENV).to receive(:[]).with('VETORIAL_AGENT_INBOX_ID').and_return('other')
    expect(VetorialAgent::Policy.scoped?(conversation)).to eq(false)
  end

  it 'opens only the scoped inbox with the explicit general gate and keeps team blocked' do
    incoming
    allow(ENV).to receive(:fetch).with('VETORIAL_AGENT_ALLOWLIST', '').and_return('')
    allow(ENV).to receive(:[]).with('VETORIAL_AGENT_ALL_CONTACTS').and_return('true')
    expect(VetorialAgent::Policy.allowed?(conversation)).to eq(true)
    allow(ENV).to receive(:fetch).with('VETORIAL_AGENT_INTERNAL_NUMBERS', '').and_return(phone)
    expect(VetorialAgent::Policy.allowed?(conversation)).to eq(false)
    allow(ENV).to receive(:fetch).with('VETORIAL_AGENT_INTERNAL_NUMBERS', '').and_return('')
    allow(ENV).to receive(:[]).with('VETORIAL_AGENT_INBOX_ID').and_return('other')
    expect(VetorialAgent::Policy.allowed?(conversation)).to eq(false)
  end

  it 'allows private analysis outside the send allowlist without granting public capabilities' do
    incoming
    allow(ENV).to receive(:fetch).with('VETORIAL_AGENT_ALLOWLIST', '').and_return('')
    allow(ENV).to receive(:[]).with('VETORIAL_AGENT_ANALYSIS_ALL').and_return('true')
    expect(VetorialAgent::Policy.analysis_eligible?(conversation)).to eq(true)
    expect(VetorialAgent::Policy.allowed?(conversation)).to eq(false)
    allow_any_instance_of(VetorialAgent::Bridge).to receive(:media).and_return('sucesso' => true, 'mime' => 'audio/ogg', 'base64' => 'c3ludGhldGlj')
    data = command('analysis_media', attachment_id: 'synthetic'); data['key'] = 'private-media'
    expect(bridge.call(data)['sucesso']).to eq(true)
    expect { bridge.call(command('analysis', note: 'Resumo privado')) }
      .to change { conversation.messages.where(private: true).count }.by(1)
    %w[send typing fields handoff silent media].each do |kind|
      data = command(kind, text: 'Nunca enviar'); data['key'] = "blocked-#{kind}"
      expect { bridge.call(data) }.to raise_error(VetorialAgent::Bridge::Rejected)
    end
    expect(conversation.messages.outgoing.where(private: false).count).to eq(0)
    allow(ENV).to receive(:fetch).with('VETORIAL_AGENT_INTERNAL_NUMBERS', '').and_return(phone)
    expect(VetorialAgent::Policy.analysis_eligible?(conversation)).to eq(false)
  end

  it 'deduplicates commands and rejects key collision with changed payload' do
    incoming
    one = bridge.call(command(text: 'Olá'))
    two = bridge.call(command(text: 'Olá'))
    expect(one).to eq(two)
    expect(conversation.messages.outgoing.count).to eq(1)
    expect { bridge.call(command(text: 'Mudei')) }.to raise_error(VetorialAgent::Bridge::Rejected)
    expect(VetorialAgent::State.find_by!(conversation: conversation).version).to eq(1)
  end

  it 'rechecks at delivery and discards a stale message before provider call' do
    incoming
    bridge.call(command(text: 'Rascunho'))
    incoming('Chegou mensagem nova')
    expect(VetorialAgent::Transport).not_to receive(:new)
    VetorialAgent::SendJob.perform_now(VetorialAgent::Command.last.id)
    expect(VetorialAgent::Command.last.status).to eq('discarded')
  end

  it 'records provider ID under channel lock so its echo cannot be classified as human' do
    incoming
    bridge.call(command(text: 'Resposta'))
    allow_any_instance_of(VetorialAgent::Transport).to receive(:send_text).and_return('synthetic-provider-id')
    2.times { VetorialAgent::SendJob.perform_now(VetorialAgent::Command.last.id) }
    expect(VetorialAgent::Command.last.status).to eq('sent')
    payload = { instance: 'synthetic-vetorial', event: 'messages.upsert', data: {
      key: { id: 'synthetic-provider-id', fromMe: true, remoteJid: '15550000002@s.whatsapp.net' },
      message: { conversation: 'Resposta' }, messageTimestamp: 200 } }
    expect { Webhooks::EvolutionAttachedJob.perform_now(channel.id, payload) }.not_to change(Message, :count)
    expect(VetorialAgent::State.find_by!(conversation: conversation)).not_to be_paused
  end

  it 'quarantines timeout after send and never retries the uncertain provider POST' do
    incoming
    bridge.call(command(text: 'Resposta'))
    expect_any_instance_of(VetorialAgent::Transport).to receive(:send_text).once.and_raise(Timeout::Error)
    id = VetorialAgent::Command.last.id
    2.times { VetorialAgent::SendJob.perform_now(id) }
    expect(VetorialAgent::Command.find(id).status).to eq('uncertain')
    expect(VetorialAgent::State.find_by!(conversation: conversation)).to be_paused
    expect(conversation.reload.custom_attributes['vetorial_ia']['reason']).to eq('envio_incerto')
  end

  it 'keeps silence as a private note and pauses without a public message' do
    incoming
    bridge.call(command('silent', note: 'Spam repetido', labels: ['fora-de-escopo']))
    expect(conversation.messages.outgoing.where(private: false).count).to eq(0)
    expect(conversation.messages.where(private: true).sole.content).to eq('Spam repetido')
    expect(VetorialAgent::State.find_by!(conversation: conversation)).to be_paused
  end

  it 'does not clear known fields using null or empty analyst updates' do
    incoming
    expect { bridge.call(command('analysis', fields: { cidade: nil }, note: 'Sugestão: Avaliação humana')) }
      .to change { conversation.messages.where(private: true).count }.by(1)
    expect(conversation.pipeline_items.count).to eq(0)
  end
  it 'pauses on a human assignment; removing assignee alone does not resume' do
    incoming
    user = User.create!(name: 'Humano sintético', email: "a12-#{SecureRandom.hex(4)}@example.com")
    conversation.update!(assignee: user)
    state = VetorialAgent::State.find_by!(conversation: conversation)
    expect(state).to be_paused
    conversation.add_labels(['ia-ativa'])
    expect(state.reload).to be_paused
    conversation.update!(assignee: nil)
    expect(state.reload).to be_paused
    conversation.remove_labels(['ia-ativa'])
    conversation.add_labels(['ia-ativa'])
    expect(state.reload).not_to be_paused
  end

  it 'preserves existing human fields, including false, and only updates fields previously written by this agent' do
    incoming
    user = User.create!(name: 'Humano', email: "fields-#{SecureRandom.hex(4)}@example.com")
    pipeline = Pipeline.create!(name: "A12 #{SecureRandom.hex(4)}", created_by: user, visibility: :public)
    stage = pipeline.pipeline_stages.create!(name: 'Triagem', position: 0)
    item = pipeline.pipeline_items.create!(conversation: conversation, pipeline_stage: stage, title: 'Teste',
                                           custom_fields: { cidade: 'Curitiba', atendimento_particular: false })
    allow(ENV).to receive(:fetch).with('VETORIAL_AGENT_PIPELINE_ID', nil).and_return(pipeline.id)
    bridge.call(command('fields', fields: { cidade: 'São Paulo', atendimento_particular: true, especialidade: 'Ginecologia' }))
    expect(item.reload.custom_fields).to include('cidade' => 'Curitiba', 'atendimento_particular' => false, 'especialidade' => 'Ginecologia')
    item.update!(custom_fields: item.custom_fields.merge('especialidade' => 'Cardiologia (humano)'))
    data = command('fields', fields: { especialidade: 'Ginecologia atualizada' }); data['key'] = 'second-update'
    bridge.call(data)
    expect(item.reload.custom_fields['especialidade']).to eq('Cardiologia (humano)')
  end

  it 'recovers committed sending intent as uncertain after restart without provider retry' do
    incoming
    bridge.call(command(text: 'Resposta'))
    row = VetorialAgent::Command.last
    row.update!(status: 'sending', updated_at: 3.minutes.ago)
    expect(VetorialAgent::Transport).not_to receive(:new)
    VetorialAgent::DispatchJob.perform_now
    expect(row.reload.status).to eq('uncertain')
    expect(VetorialAgent::State.find_by!(conversation: conversation)).to be_paused
  end

  def managed_deployment
    payload = JSON.parse(File.read(Rails.root.join('spec/fixtures/vetorial_agent/snapshot.json')))['payload']
    deployment = VetorialAgent::Deployment.create!(slug: 'synthetic', agent_bot: bot)
    payload['deployment_id'] = deployment.id
    payload['binding']['agent_bot_id'] = bot.id
    payload['binding']['inbox_ids'] = [box.id]
    payload['activation']['allowlist'] = [phone]
    revision = deployment.revisions.create!(number: 1, payload: payload, sha256: VetorialAgent::Snapshot.digest(payload), status: 'published')
    deployment.update!(active_revision: revision)
    deployment
  end

  it 'keeps the inbox default and excludes native listener and inactivity for managed bots' do
    deployment = managed_deployment
    original = box.reload.default_conversation_status_value
    VetorialAgent::GuardBoot.mark_ready!
    deployment.reload
    VetorialAgent::Binding.attach!(deployment, inventory: -> { inventory }, digest: digest)
    expect(AgentBotInbox.where(inbox: box, agent_bot: bot).count).to eq(1)
    expect { VetorialAgent::Binding.attach!(deployment, inventory: -> { inventory }, digest: digest) }.not_to change(AgentBotInbox, :count)
    expect(box.reload.default_conversation_status_value).to eq(original)
    expect(AgentBotListener.instance.send(:connected_agent_bot_exist?, box)).to be false
    expect(AgentBots::InactivityActionsService).not_to receive(:new)
    AgentBots::ProcessInactivityActionsJob.new.perform(conversation.id, bot.id)
  end

  it 'blocks legacy sends when the managed mode is off during transition' do
    managed_deployment
    incoming
    bridge.call(command(text: 'Resposta em fila'))
    pending = VetorialAgent::Command.find_by!(key: 'synthetic-key')
    deployment = VetorialAgent::Deployment.first
    expect(deployment.control_source).to eq('legacy_transition')
    old = deployment.payload.deep_dup
    old['revision'] = 2
    old['policy_epoch'] = 2
    old['activation']['atendimento'] = 'off'
    revision = deployment.revisions.create!(number: 2, payload: old, sha256: VetorialAgent::Snapshot.digest(old), status: 'published')
    deployment.update!(active_revision: revision, policy_epoch: 2)
    expect(VetorialAgent::Transport).not_to receive(:new)
    VetorialAgent::SendJob.perform_now(pending.id)
    expect(pending.reload.status).to eq('discarded')
    expect { bridge.call(command(text: 'Não enviar', key: 'after-off')) }.to raise_error(VetorialAgent::Bridge::Rejected)
  end

  it 'pauses and resumes without changing the commercial status or reopening history' do
    managed_deployment
    incoming
    original_status = conversation.status
    paused = VetorialAgent::ConversationControl.call(conversation, action: 'pause', version: 1, actor_id: nil)
    expect(paused[:paused]).to be true
    resumed = VetorialAgent::ConversationControl.call(conversation, action: 'resume', version: 2, actor_id: nil)
    expect(resumed[:paused]).to be false
    expect(conversation.reload.status).to eq(original_status)
    expect(VetorialAgent::Command.count).to eq(0)
    expect(VetorialAgent::Event.where("payload->>'version' = ?", '3').sole.payload['kind']).to eq('resume')
  end

end
