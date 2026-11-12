require 'rails_helper'
require 'webmock/rspec'
WebMock.disable_net_connect!(allow_localhost: true)

RSpec.describe Evolution::AttachExistingInstance do
  let(:client) { instance_double(Evolution::ExistingInstanceClient) }
  let(:remote) { { 'id' => 'synthetic-instance-id', 'name' => 'synthetic-vetorial', 'ownerJid' => '15550000001@s.whatsapp.net', 'connectionStatus' => 'open' } }
  let(:service) { described_class.new(instance_name: remote['name'], phone_number: '+15550000001', name: 'Vetorial · WhatsApp', client: client) }
  def remote_config
    @written&.except('byEvents', 'base64')&.merge('webhookByEvents' => false, 'webhookBase64' => true)
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config)
    allow(client).to receive(:instances).with(remote['name']).and_return([remote])
    allow(client).to receive(:webhook) { remote_config }
    allow(client).to receive(:set_webhook) { |_name, config| @written = config }
    stub_const('ENV', ENV.to_h.merge('BACKEND_URL' => 'https://crm.example.test'))
  end

  it 'GETs first, creates one inert local box and only sets the free webhook' do
    box = service.perform
    expect(box.display_name).to eq('Vetorial · WhatsApp')
    expect(box.name).to eq('Vetorial · WhatsApp')
    expect(box).not_to be_enable_auto_assignment
    expect(box.channel.provider_config['mark_as_read']).to eq(false)
    expect(@written).to include('enabled' => true, 'base64' => true, 'events' => described_class::EVENTS)
    expect(@written['headers']['X-Evo-Attach-Token']).to be_present
    expect(InboxSerializer.serialize(box, include_channel: true)['provider_config']).not_to have_key('attachment_token')
    expect(service.perform.id).to eq(box.id)
    expect(client).to have_received(:set_webhook).once
  end

  it 'does not dispatch generic inbox lifecycle events containing private provider configuration' do
    stub_const('ENV', ENV.to_h.merge('BACKEND_URL' => 'https://crm.example.test', 'ENABLE_INBOX_EVENTS' => 'true'))
    allow(Rails.configuration.dispatcher).to receive(:dispatch)
    box = service.perform
    box.send(:dispatch_update_event)
    expect(Rails.configuration.dispatcher).not_to have_received(:dispatch).with('inbox.created', anything, anything)
    expect(Rails.configuration.dispatcher).not_to have_received(:dispatch).with('inbox.updated', anything, anything)
  end

  it 'refuses a foreign webhook before creating a box' do
    allow(client).to receive(:webhook).and_return({ 'url' => 'https://existing.example.test' })
    expect { service.perform }.to raise_error(described_class::Conflict, /Webhook ocupado/)
    expect(client).not_to have_received(:set_webhook)
    expect(Channel::Whatsapp.count).to eq(0)
  end

  it 'refuses a mismatched number, closed connection and ambiguous instance' do
    remote['ownerJid'] = '15550000002@s.whatsapp.net'
    expect { service.perform }.to raise_error(described_class::Conflict)
    remote['ownerJid'] = '15550000001@s.whatsapp.net'
    remote['connectionStatus'] = 'close'
    expect { service.perform }.to raise_error(described_class::Conflict)
    remote['connectionStatus'] = 'open'
    allow(client).to receive(:instances).and_return([remote, remote])
    expect { service.perform }.to raise_error(described_class::Conflict)
    expect(client).not_to have_received(:set_webhook)
  end

  it 'refuses number collision with another provider and display name collision' do
    other = Channel::Whatsapp.create!(phone_number: '+15550000001', provider: 'whatsapp_cloud', provider_config: {})
    expect { service.perform }.to raise_error(described_class::Conflict, /vinculado/)
    other.update!(phone_number: '+15550000002')
    Inbox.create!(name: 'Other', display_name: 'Vetorial · WhatsApp', channel: other)
    expect { service.perform }.to raise_error(described_class::Conflict, /vinculado/)
    expect(client).not_to have_received(:set_webhook)
  end

  it 'keeps the local box after an ambiguous setter failure and reconciles with GET' do
    allow(client).to receive(:set_webhook) do |_name, config|
      @written = config
      raise Evolution::ExistingInstanceClient::Error, 'timeout'
    end
    expect { service.perform }.to raise_error(Evolution::ExistingInstanceClient::Error)
    channel = Channel::Whatsapp.sole
    expect(channel.provider_config['attachment_state']).to eq('pending')
    expect(service.perform.channel.id).to eq(channel.id)
    expect(client).to have_received(:set_webhook).once
  end

  it 'detaches only its own webhook, retaining the box, messages and instance identity' do
    box = service.perform
    service.detach(box.channel)
    expect(box.channel.reload.provider_config['attachment_state']).to eq('detached')
    expect(Inbox.exists?(box.id)).to eq(true)
    expect(service.detach(box.channel).id).to eq(box.id)
    expect(@written).to include('enabled' => false, 'headers' => {}, 'events' => [])
    expect { box.channel.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
    expect { box.channel.disconnect_channel_provider }.to raise_error(described_class::Conflict)
  end

  it 'does not detach a webhook changed by another operator' do
    box = service.perform
    @written['url'] = 'https://new.example.test'
    expect { service.detach(box.channel) }.to raise_error(described_class::Conflict, /alterado/)
    expect(client).to have_received(:set_webhook).once
  end
end
