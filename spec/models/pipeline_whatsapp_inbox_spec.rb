# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PipelineWhatsappInbox, type: :model do
  let(:user) { User.create!(name: 'Owner', email: "owner-#{SecureRandom.hex(4)}@example.com") }
  let(:pipeline) { Pipeline.create!(name: "P #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: user) }

  def whatsapp_inbox
    channel = Channel::Whatsapp.new(phone_number: "+5511#{rand(900_000_00..999_999_99)}", provider: 'evolution',
                                    provider_config: { 'api_url' => 'http://x', 'api_key' => 'k', 'instance_name' => SecureRandom.hex(3) })
    channel.save!(validate: false)
    Inbox.create!(name: "WA #{SecureRandom.hex(2)}", channel: channel)
  end

  it 'accepts only WhatsApp inboxes' do
    widget = Inbox.create!(name: 'W', channel: Channel::WebWidget.create!(website_url: "https://#{SecureRandom.hex(3)}.example.com"))

    expect(described_class.new(pipeline: pipeline, inbox: whatsapp_inbox)).to be_valid
    expect(described_class.new(pipeline: pipeline, inbox: widget)).not_to be_valid
  end

  it 'is unique per pipeline+inbox and allows a single active default per pipeline' do
    a = whatsapp_inbox
    b = whatsapp_inbox
    described_class.create!(pipeline: pipeline, inbox: a, is_default: true)

    expect(described_class.new(pipeline: pipeline, inbox: a)).not_to be_valid
    expect { described_class.create!(pipeline: pipeline, inbox: b, is_default: true) }.to raise_error(ActiveRecord::RecordNotUnique)
    expect(described_class.new(pipeline: pipeline, inbox: b, is_default: true, is_active: false)).not_to be_valid
  end

  it 'exposes only active inboxes through Pipeline#whatsapp_inboxes' do
    a = whatsapp_inbox
    b = whatsapp_inbox
    described_class.create!(pipeline: pipeline, inbox: a)
    described_class.create!(pipeline: pipeline, inbox: b, is_active: false)

    expect(pipeline.whatsapp_inboxes).to contain_exactly(a)
  end
end
