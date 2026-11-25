# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::Providers::EvolutionService, '#send_reaction' do
  let(:channel) do
    instance_double(Channel::Whatsapp,
                    provider_config: { 'api_url' => 'http://localhost:8081', 'instance_name' => 'CR Advogados', 'admin_token' => 'tok' })
  end
  let(:service) { described_class.new(whatsapp_channel: channel) }
  let(:conversation) { double(contact_inbox: double(source_id: '5511999999999')) }
  let(:message) { double(source_id: 'MSGID123', outgoing?: false, template?: false, conversation: conversation) }

  it 'posts the WhatsApp key and the emoji to sendReaction' do
    expect(HTTParty).to receive(:post) do |url, opts|
      expect(url).to eq('http://localhost:8081/message/sendReaction/CR%20Advogados')
      expect(opts[:headers]['apikey']).to eq('tok')
      expect(opts[:timeout]).to be_present
      expect(JSON.parse(opts[:body])).to eq(
        'key' => { 'remoteJid' => '5511999999999@s.whatsapp.net', 'fromMe' => false, 'id' => 'MSGID123' },
        'reaction' => '👍'
      )
      double(success?: true, code: 201)
    end
    expect(service.send_reaction(message, '👍')).to be(true)
  end

  it 'marks our own message as fromMe and sends an empty reaction to remove' do
    own = double(source_id: 'MINE', outgoing?: true, template?: false, conversation: conversation)
    expect(HTTParty).to receive(:post) do |_url, opts|
      body = JSON.parse(opts[:body])
      expect(body.dig('key', 'fromMe')).to be(true)
      expect(body['reaction']).to eq('')
      double(success?: true, code: 201)
    end
    expect(service.send_reaction(own, '')).to be(true)
  end

  it 'returns false on provider failure or network error' do
    allow(HTTParty).to receive(:post).and_return(double(success?: false, code: 400))
    expect(service.send_reaction(message, '👍')).to be(false)

    allow(HTTParty).to receive(:post).and_raise(Net::ReadTimeout)
    expect(service.send_reaction(message, '👍')).to be(false)
  end

  it 'does not call the provider without source_id' do
    expect(HTTParty).not_to receive(:post)
    expect(service.send_reaction(double(source_id: nil), '👍')).to be(false)
  end
end
