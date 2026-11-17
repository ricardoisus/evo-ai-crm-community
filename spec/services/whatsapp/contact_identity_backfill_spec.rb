# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::ContactIdentityBackfill do
  let(:channel) do
    Channel::Whatsapp.create!(provider: 'evolution', phone_number: '+15550000001', provider_connection: { connection: 'open' },
                              provider_config: { instance_name: 'synthetic-vetorial' })
  end
  let(:box) { Inbox.create!(name: 'Synthetic', channel: channel, enable_auto_assignment: false) }
  let(:service) { instance_double(Whatsapp::Providers::EvolutionService) }
  let(:sleeper) { class_double(Kernel, sleep: nil) }

  def make_contact(name, number)
    c = Contact.new(name: name, phone_number: "+#{number}")
    c.skip_default_pipeline_assignment = true
    c.save!
    ContactInbox.create!(inbox: box, contact: c, source_id: number)
    c
  end

  before do
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config)
    allow_any_instance_of(Channel::Whatsapp).to receive(:sync_templates)
    allow_any_instance_of(Channel::Whatsapp).to receive(:subscribe)
    box
    allow(Whatsapp::Providers::EvolutionService).to receive(:new).and_return(service)
    allow(service).to receive(:fetch_contact_profile).and_return(nil)
  end

  it 'dry-run reports what would change and writes nothing' do
    a = make_contact('15550000010', '15550000010')
    allow(service).to receive(:fetch_contact_profile).with('15550000010')
                                                     .and_return(push_name: 'Ana Real', profile_picture_url: 'https://pps.whatsapp.net/a.jpg')
    expect(Avatar::AvatarFromUrlJob).not_to receive(:perform_now)
    report = described_class.new(inbox_ids: [box.id], sleeper: sleeper).run
    expect(report.to_h_report).to include(scanned: 1, name_updates: 1, avatar_updates: 1, mode: 'dry-run')
    expect(a.reload.name).to eq('15550000010')
    expect(sleeper).not_to have_received(:sleep)
  end

  it 'applies name and photo, rate-limited, and is idempotent on a second run' do
    a = make_contact('15550000010', '15550000010')
    allow(service).to receive(:fetch_contact_profile).with('15550000010')
                                                     .and_return(push_name: 'Ana Real', profile_picture_url: 'https://pps.whatsapp.net/a.jpg')
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_now) do |contact, _url|
      contact.avatar.attach(io: StringIO.new('img'), filename: 'a.jpg', content_type: 'image/jpeg')
    end
    first = described_class.new(inbox_ids: [box.id], apply: true, rate: 0.5, sleeper: sleeper).run
    expect(first.to_h_report).to include(name_updates: 1, avatar_updates: 1, mode: 'apply')
    expect(a.reload.name).to eq('Ana Real')
    expect(a.avatar).to be_attached
    expect(sleeper).to have_received(:sleep).with(0.5)

    second = described_class.new(inbox_ids: [box.id], apply: true, sleeper: sleeper).run
    expect(second.to_h_report).to include(name_updates: 0, avatar_updates: 0)
  end

  it 'respects LIMIT, skips unknown profiles and keeps human-edited names' do
    make_contact('Maria Editada', '15550000011')
    allow(service).to receive(:fetch_contact_profile).with('15550000011').and_return(push_name: 'Maria', profile_picture_url: nil)
    make_contact('15550000012', '15550000012')
    report = described_class.new(inbox_ids: [box.id], apply: true, limit: 1, rate: 0, sleeper: sleeper).run
    expect(report.scanned).to eq(1)
    expect(Contact.find_by(phone_number: '+15550000011').name).to eq('Maria Editada')
  end

  it 'counts errors without aborting' do
    make_contact('15550000013', '15550000013')
    allow(service).to receive(:fetch_contact_profile).and_raise(StandardError, 'boom')
    report = described_class.new(inbox_ids: [box.id], apply: true, rate: 0, sleeper: sleeper).run
    expect(report.errors).to eq(1)
  end
end
