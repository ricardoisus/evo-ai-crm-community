# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Evolution::FetchContactAvatarJob do
  let(:contact) do
    c = Contact.new(name: 'Ana', phone_number: '+5511999999999')
    c.skip_default_pipeline_assignment = true
    c.save!
    c
  end
  let(:channel) { instance_double(Channel::Whatsapp, id: 'channel-uuid') }
  let(:provider_service) { instance_double(Whatsapp::Providers::EvolutionService) }

  before do
    allow(Channel::Whatsapp).to receive(:find_by).with(id: 'channel-uuid').and_return(channel)
    allow(Whatsapp::Providers::EvolutionService).to receive(:new).with(whatsapp_channel: channel).and_return(provider_service)
  end

  def run
    described_class.new.perform(contact.id, '5511999999999', 'channel-uuid')
  end

  it 'downloads the picture when the provider returns a URL and records success' do
    allow(provider_service).to receive(:fetch_profile_picture_url).and_return('https://pps.whatsapp.net/p.jpg')
    expect(Avatar::AvatarFromUrlJob).to receive(:perform_now).with(contact, 'https://pps.whatsapp.net/p.jpg') do
      contact.avatar.attach(io: StringIO.new('img'), filename: 'p.jpg', content_type: 'image/jpeg')
    end
    run
    state = Whatsapp::ContactIdentitySync.avatar_state(contact.reload)
    expect(state['misses']).to eq(0)
    expect(state['synced_at']).to be_present
  end

  it 'records a miss (backoff) when the provider has no picture' do
    allow(provider_service).to receive(:fetch_profile_picture_url).and_return(nil)
    expect(Avatar::AvatarFromUrlJob).not_to receive(:perform_now)
    run
    expect(Whatsapp::ContactIdentitySync.avatar_state(contact.reload)['misses']).to eq(1)
    expect(Whatsapp::ContactIdentitySync.avatar_due?(contact)).to be(false)
  end

  it 'records a miss when the download did not attach an avatar' do
    allow(provider_service).to receive(:fetch_profile_picture_url).and_return('https://pps.whatsapp.net/p.jpg')
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_now)
    run
    expect(Whatsapp::ContactIdentitySync.avatar_state(contact.reload)['misses']).to eq(1)
  end

  it 'does not query WhatsApp again inside the backoff window' do
    Whatsapp::ContactIdentitySync.record_avatar_result(contact, success: false)
    expect(provider_service).not_to receive(:fetch_profile_picture_url)
    run
  end

  it 'refreshes an old avatar after the renewal period' do
    contact.avatar.attach(io: StringIO.new('old'), filename: 'o.jpg', content_type: 'image/jpeg')
    Whatsapp::ContactIdentitySync.record_avatar_result(contact.reload, success: true, now: 20.days.ago)
    allow(provider_service).to receive(:fetch_profile_picture_url).and_return('https://pps.whatsapp.net/new.jpg')
    expect(Avatar::AvatarFromUrlJob).to receive(:perform_now).with(contact, 'https://pps.whatsapp.net/new.jpg')
    run
  end

  it 'does nothing when the contact cannot be found' do
    expect(Avatar::AvatarFromUrlJob).not_to receive(:perform_now)
    described_class.new.perform('00000000-0000-0000-0000-000000000000', '5511999999999', 'channel-uuid')
  end

  describe 'retry behavior' do
    it 'configures retry_on for network timeouts so transient failures recover' do
      retry_classes = described_class.rescue_handlers.map(&:first).map(&:to_s)
      expect(retry_classes).to include('Net::OpenTimeout', 'Net::ReadTimeout')
    end
  end
end
