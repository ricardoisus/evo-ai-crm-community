require 'rails_helper'
RSpec.describe 'Snapshot nested contract' do
  let(:payload) { JSON.parse(File.read(Rails.root.join('spec/fixtures/vetorial_agent/snapshot.json')))['payload'] }
  %w[binding activation behavior limits integrations provider runtime].each do |section|
    it "rejects unknown fields in #{section}" do
      payload[section]['api_key'] = 'synthetic-secret'
      expect { VetorialAgent::Snapshot.validate!(payload) }.to raise_error(VetorialAgent::Snapshot::Invalid)
    end
  end
  [
    [%w[limits messages_per_hour], 21], [%w[limits max_tool_rounds], 0],
    [%w[runtime history_messages], 1001], [%w[runtime media_items], -1],
    [%w[provider service_tier], 'unexpected'], [%w[provider project_id], 42],
    [%w[binding inbox_ids], ['']], [%w[integrations calendar_id], nil],
    [%w[roles atendimento output_schema], []], [%w[roles atendimento actions], { 'api_key' => 'no' }],
    [%w[roles analista prompt_version], nil]
  ].each do |path, value|
    it "rejects invalid #{path.join('.')}" do
      payload.dig(*path[0...-1])[path.last] = value
      expect { VetorialAgent::Snapshot.validate!(payload) }.to raise_error(VetorialAgent::Snapshot::Invalid)
    end
  end
end

RSpec.describe 'Snapshot schema references' do
  it 'rejects nested unknown schema keywords and remote references without network access' do
    data = JSON.parse(File.read(Rails.root.join('spec/fixtures/vetorial_agent/snapshot.json')))['payload']
    [{ '$ref' => 'https://private.invalid/schema' }, { 'properties' => { 'text' => { 'api_key' => 'no' } } }].each do |schema|
      data['roles']['analista']['output_schema'] = schema
      expect { VetorialAgent::Snapshot.validate!(data) }.to raise_error(VetorialAgent::Snapshot::Invalid)
    end
  end
end

RSpec.describe 'Configuration database constraints' do
  let(:deployment) { VetorialAgent::Deployment.create!(agent_bot: AgentBot.create!(name: 'Constraints'), slug: 'constraints') }
  let(:payload) { JSON.parse(File.read(Rails.root.join('spec/fixtures/vetorial_agent/snapshot.json')))['payload'].merge('deployment_id' => deployment.id) }

  it 'rejects invalid epochs even when model validations are bypassed' do
    expect { deployment.update_columns(policy_epoch: 0) }.to raise_error(ActiveRecord::StatementInvalid, /vetorial_deployment_contract/)
  end
  it 'rejects unsupported profile roles at the database boundary' do
    profile = deployment.profiles.create!(role: 'atendimento', name: 'Constraints')
    expect { profile.update_columns(role: 'unknown') }.to raise_error(ActiveRecord::StatementInvalid, /vetorial_profile_role/)
  end
  it 'rejects invalid revision numbers when validations are bypassed' do
    revision = deployment.revisions.create!(number: 1, payload: payload, sha256: VetorialAgent::Snapshot.digest(payload))
    expect { revision.update_columns(number: 0) }.to raise_error(ActiveRecord::StatementInvalid, /vetorial_revision_contract/)
  end
  it 'rejects an active revision owned by another deployment' do
    revision = deployment.revisions.create!(number: 1, payload: payload, sha256: VetorialAgent::Snapshot.digest(payload))
    other = VetorialAgent::Deployment.create!(agent_bot: AgentBot.create!(name: 'Other'), slug: 'other')
    expect { other.update_columns(active_revision_id: revision.id) }.to raise_error(ActiveRecord::InvalidForeignKey, /vetorial_active_revision_owner/)
  end
end
