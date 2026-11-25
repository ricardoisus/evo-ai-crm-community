# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'WhatsApp contact photo fetch' do
  include ActiveJob::TestHelper

  before { ActiveJob::Base.queue_adapter = :test }

  def make_contact(number)
    c = Contact.new(name: number, phone_number: "+#{number}")
    c.skip_default_pipeline_assignment = true
    c.save!
    c
  end

  describe 'instance names with spaces' do
    let(:channel) do
      instance_double(Channel::Whatsapp, provider_config: {
                        'api_url' => 'https://evo.example.test', 'instance_name' => 'CR Advogados', 'admin_token' => 'synthetic'
                      })
    end
    let(:service) { Whatsapp::Providers::EvolutionService.new(whatsapp_channel: channel) }
    let(:response) { instance_double(HTTParty::Response, success?: true, parsed_response: { 'profilePictureUrl' => 'https://pps.whatsapp.net/a.jpg' }) }

    it 'encodes the instance name when asking for the picture' do
      expect(HTTParty).to receive(:post)
        .with('https://evo.example.test/chat/fetchProfilePictureUrl/CR%20Advogados', anything).and_return(response)
      expect(service.fetch_profile_picture_url('15550000010')).to eq('https://pps.whatsapp.net/a.jpg')
    end

    it 'encodes the instance name when reading the profile' do
      expect(HTTParty).to receive(:post)
        .with('https://evo.example.test/chat/findContacts/CR%20Advogados', anything)
        .and_return(instance_double(HTTParty::Response, success?: true, parsed_response: [{ 'pushName' => 'Ana' }]))
      expect(service.fetch_contact_profile('15550000010')).to include(push_name: 'Ana')
    end
  end

  describe 'fetch enqueued while the contact is still uncommitted' do
    it 'delays the job so the surrounding transaction can commit' do
      freeze_time = Time.current
      allow(Redis::Alfred).to receive(:set).and_return(true)
      Whatsapp::EvolutionHandlers::AvatarEnqueueGuard.enqueue_avatar_fetch(contact_id: 'c', phone_number: '1', channel_id: 'ch')
      expect(enqueued_jobs.sole[:at]).to be >= (freeze_time + 29.seconds).to_f
    end

    it 'retries when the contact is not visible yet' do
      Evolution::FetchContactAvatarJob.perform_now('00000000-0000-0000-0000-000000000000', '15550000010', 'channel')
      expect(enqueued_jobs.count { |j| j[:job] == Evolution::FetchContactAvatarJob }).to eq(1)
    end
  end

  describe Whatsapp::ContactAvatarSweepJob do
    let(:channel) do
      Channel::Whatsapp.create!(provider: 'evolution', phone_number: '+15550000001', provider_connection: { connection: 'open' },
                                provider_config: { instance_name: 'synthetic evo' })
    end
    let(:box) { Inbox.create!(name: 'Synthetic', channel: channel, enable_auto_assignment: false) }

    before do
      allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config)
      allow_any_instance_of(Channel::Whatsapp).to receive(:sync_templates)
      allow_any_instance_of(Channel::Whatsapp).to receive(:subscribe)
      allow(Redis::Alfred).to receive(:set).and_return(true)
    end

    def linked(number)
      c = make_contact(number)
      ContactInbox.create!(inbox: box, contact: c, source_id: number)
      c
    end

    def queued_contact_ids
      enqueued_jobs.select { |j| j[:job] == Evolution::FetchContactAvatarJob }.map { |j| j[:args].first }
    end

    it 'queues only contacts whose picture is due' do
      due = linked('15550000010')
      waiting = linked('15550000011')
      Whatsapp::ContactIdentitySync.record_avatar_result(waiting, success: false)
      pictured = linked('15550000012')
      pictured.avatar.attach(io: StringIO.new('img'), filename: 'a.jpg', content_type: 'image/jpeg')

      described_class.perform_now

      expect(queued_contact_ids).to eq([due.id])
    end

    it 'stops at the limit' do
      linked('15550000010')
      linked('15550000011')
      described_class.perform_now(limit: 1)
      expect(queued_contact_ids.size).to eq(1)
    end

    it 'is scheduled daily' do
      entry = YAML.load_file(Rails.root.join('config/schedule.yml')).values.find { |v| v['class'] == described_class.name }
      expect(entry).to include('queue' => 'scheduled_jobs')
    end
  end
end
