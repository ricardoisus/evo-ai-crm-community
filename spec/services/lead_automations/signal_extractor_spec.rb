require 'rails_helper'
RSpec.describe LeadAutomations::SignalExtractor do
  let(:box) { double(id: SecureRandom.uuid, channel: double(provider_config: { 'instance_name' => 'synthetic' })) }
  let(:ad) { { externalAdReply: { ctwaClid: 'synthetic-click' } } }
  let(:raw) { { key: { id: 'synthetic', fromMe: false, remoteJid: '15550000002@s.whatsapp.net' }, messageTimestamp: Time.current.to_f, message: { conversation: 'Synthetic' }, contextInfo: ad } }
  def extract(r = raw, **args)
    described_class.call(r, inbox: box, instance_name: 'synthetic', **args)
  end
  it 'extracts top-level and nested image/wrappers without following quoted messages' do
    expect(extract[:source]).to eq('ctwa')
    nested = raw.except(:contextInfo).merge(message: { ephemeralMessage: { message: { viewOnceMessage: { message: { imageMessage: { contextInfo: ad } } } } } })
    expect(extract(nested)[:source]).to eq('ctwa')
    quoted = raw.merge(contextInfo: { quotedMessage: { imageMessage: { contextInfo: ad } } })
    expect(extract(quoted)[:source]).to eq('none')
  end
  it 'gives top-level context precedence and supports snake_case click ids' do
    p = raw.merge(contextInfo: {}, message: { imageMessage: { contextInfo: ad } })
    expect(extract(p)[:source]).to eq('none')
    expect(extract(raw.merge(contextInfo: { ctwa_clid: 'synthetic' }))[:source]).to eq('ctwa')
  end
  it 'requires the click, not source type, URL or referral' do
    [{ externalAdReply: { sourceType: 'ad', sourceUrl: 'https://fb.me/synthetic' } }, { referral: ad }, { ctwaClid: ' ' }, { ctwaClid: 'x' * 2001 }].each do |context|
      expect(extract(raw.merge(contextInfo: context))[:source]).to eq('none')
    end
  end
  it 'rejects fromMe, missing direction, groups, append, reaction, protocol and invalid/future timestamps' do
    [raw.merge(key: raw[:key].merge(fromMe: true)), raw.merge(key: raw[:key].except(:fromMe)),
     raw.merge(key: raw[:key].merge(remoteJid: '123@g.us')), raw.merge(type: 'append'),
     raw.merge(message: { reactionMessage: {} }), raw.merge(message: { protocolMessage: {} }),
     raw.merge(messageTimestamp: nil), raw.merge(messageTimestamp: (Time.current + 61).to_f)].each { |p| expect(extract(p)).to be_nil }
    expect(extract(raw, envelope_type: 'append')).to be_nil
  end
end
