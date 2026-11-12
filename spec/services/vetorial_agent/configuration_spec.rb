require 'rails_helper'

RSpec.describe 'Vetorial CRM configuration foundation' do
  let(:fixture) { JSON.parse(File.read(Rails.root.join('spec/fixtures/vetorial_agent/snapshot.json'))) }
  let(:payload) { fixture.fetch('payload') }
  let(:bot) { AgentBot.create!(name: 'Synthetic configuration', outgoing_url: 'http://agent.invalid') }
  let(:deployment) { VetorialAgent::Deployment.create!(agent_bot: bot, slug: 'synthetic') }

  def published
    data = payload.deep_dup.merge('deployment_id' => deployment.id)
    data['binding']['agent_bot_id'] = bot.id
    revision = deployment.revisions.create!(number: 1, payload: data, sha256: VetorialAgent::Snapshot.digest(data), status: 'published')
    deployment.update!(active_revision: revision, control_source: 'crm')
    revision
  end

  it 'matches the Python canonical hash, including accents emoji and CRLF' do
    expect(VetorialAgent::Snapshot.digest(payload)).to eq(fixture['sha256'])
    expect(VetorialAgent::Snapshot.validate!(payload)).to be true
    expect { VetorialAgent::Snapshot.digest('delay' => 0.5) }.to raise_error(VetorialAgent::Snapshot::Invalid)
  end

  it 'rejects Astra, unknown root keys, invalid activation and scheduling' do
    bad = payload.deep_dup
    bad['roles']['atendimento']['model'] = 'gpt-6-astra'
    expect { VetorialAgent::Snapshot.validate!(bad) }.to raise_error(VetorialAgent::Snapshot::Invalid)
    bad = payload.merge('api_key' => 'never accepted')
    expect { VetorialAgent::Snapshot.validate!(bad) }.to raise_error(VetorialAgent::Snapshot::Invalid)
    bad = payload.deep_dup
    bad['activation']['allowlist'] = []
    expect { VetorialAgent::Snapshot.validate!(bad) }.to raise_error(VetorialAgent::Snapshot::Invalid)
    bad = payload.deep_dup
    bad['behavior']['office_hours']['enabled'] = true
    expect { VetorialAgent::Snapshot.validate!(bad) }.to raise_error(VetorialAgent::Snapshot::Invalid)
  end

  it 'keeps published revisions immutable and preserves activation in restored drafts' do
    old = published
    old.payload['roles']['atendimento']['prompt'] = 'Changed'
    expect(old.save).to be false
    old.reload
    service = VetorialAgent::Configuration.new(deployment)
    draft = service.draft(old.payload, restored_from_id: old.id)
    expect(draft.number).to eq(2)
    expect(draft.payload['activation']).to eq(old.payload['activation'])
    expect(deployment.reload.active_revision_id).to eq(old.id)
    service.publish(draft)
    expect(deployment.reload.active_revision_id).to eq(draft.id)
    expect(deployment.policy_epoch).to eq(2)
  end

  it 'stores responses atomically and rejects changed requests and stale versions' do
    published
    service = VetorialAgent::Configuration.new(deployment, actor_id: nil)
    version = deployment.lock_version
    call = ->(input = {}) { service.mutate(action: 'draft', key: 'synthetic-idempotency', expected_version: version, input: input) { { 'ok' => true } } }
    expect(call.call).to eq('ok' => true)
    expect(call.call).to eq('ok' => true)
    expect(deployment.audits.count).to eq(1)
    expect { call.call('changed' => true) }.to raise_error(VetorialAgent::Configuration::Conflict)
    expect { service.mutate(action: 'draft', key: 'another', expected_version: version, input: {}) {} }.to raise_error(VetorialAgent::Configuration::Conflict)
  end

  it 'does not accept command without revision after CRM promotion' do
    revision = published
    expect(deployment.command_current?({})).to be false
    expect(deployment.command_current?('revision' => 1, 'policy_epoch' => 1, 'sha256' => revision.sha256)).to be true
    deployment.update!(control_source: 'legacy_transition')
    expect(deployment.command_current?({})).to be true
  end

  it 'refuses binding without both the boot guard and task inventory confirmation' do
    published
    expect { VetorialAgent::Binding.attach!(deployment, guard_ready: true, all_tasks_on_guarded_digest: true) }.to raise_error(VetorialAgent::Configuration::Conflict)
    deployment.update!(guard_ready: true)
    expect { VetorialAgent::Binding.attach!(deployment, guard_ready: true, all_tasks_on_guarded_digest: false) }.to raise_error(VetorialAgent::Configuration::Conflict)
  end
end
