# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::ContactIdentitySync do
  def make_contact(name:, attrs: {})
    c = Contact.new(name: name, phone_number: "+5511#{rand(900_000_000..999_999_999)}", additional_attributes: attrs)
    c.skip_default_pipeline_assignment = true
    c.save!
    c
  end

  describe '.placeholder_name?' do
    it 'treats blank, phone, e-mail and random names as placeholders' do
      ['', nil, '+5511999999999', '5511999999999', '(11) 99999-9999', 'ana@example.com', 'wispy-rain-123'].each do |n|
        expect(described_class.placeholder_name?(n)).to be(true), "expected #{n.inspect} to be placeholder"
      end
    end

    it 'keeps real names' do
      ['Ana Silva', 'Telas Seidel | Financeiro', 'Na'].each do |n|
        expect(described_class.placeholder_name?(n)).to be(false)
      end
    end
  end

  describe '#sync_name' do
    it 'replaces a phone-number name with the pushName and remembers it' do
      contact = make_contact(name: '5511987654321')
      expect(described_class.new(contact).sync_name('Ana Silva')).to be(true)
      expect(contact.reload.name).to eq('Ana Silva')
      expect(contact.additional_attributes['whatsapp_push_name']).to eq('Ana Silva')
    end

    it 'replaces an e-mail name (lead imported before the first WhatsApp message)' do
      contact = make_contact(name: 'laurianedeolinda@gmail.com')
      described_class.new(contact).sync_name('Lauriane')
      expect(contact.reload.name).to eq('Lauriane')
    end

    it 'follows pushName changes when WhatsApp itself wrote the current name' do
      contact = make_contact(name: '5511987654321')
      described_class.new(contact).sync_name('Ana')
      described_class.new(contact.reload).sync_name('Ana Paula')
      expect(contact.reload.name).to eq('Ana Paula')
    end

    it 'never overwrites a name edited by a person' do
      contact = make_contact(name: 'Ana (cliente VIP)', attrs: { 'whatsapp_push_name' => 'Ana' })
      expect(described_class.new(contact).sync_name('Ana Paula')).to be(false)
      expect(contact.reload.name).to eq('Ana (cliente VIP)')
    end

    it 'ignores a blank or placeholder pushName' do
      contact = make_contact(name: '5511987654321')
      expect(described_class.new(contact).sync_name(nil)).to be(false)
      expect(described_class.new(contact).sync_name('+5511987654321')).to be(false)
      expect(contact.reload.name).to eq('5511987654321')
    end

    it 'remembers the pushName when it already equals the current name' do
      contact = make_contact(name: 'Ana')
      described_class.new(contact).sync_name('Ana')
      expect(contact.reload.additional_attributes['whatsapp_push_name']).to eq('Ana')
    end
  end

  describe 'avatar policy' do
    let(:contact) { make_contact(name: 'Ana') }
    let(:now) { Time.zone.parse('2026-11-17 12:00') }

    it 'is due when never checked' do
      expect(described_class.avatar_due?(contact, now: now)).to be(true)
    end

    it 'backs off after misses and becomes due again later' do
      described_class.record_avatar_result(contact, success: false, now: now)
      expect(described_class.avatar_due?(contact.reload, now: now + 30.minutes)).to be(false)
      expect(described_class.avatar_due?(contact, now: now + 2.hours)).to be(true)
      described_class.record_avatar_result(contact, success: false, now: now + 2.hours)
      expect(described_class.avatar_due?(contact.reload, now: now + 3.hours)).to be(false)
      expect(described_class.avatar_due?(contact, now: now + 9.hours)).to be(true)
    end

    it 'caps the wait at seven days' do
      10.times { described_class.record_avatar_result(contact.reload, success: false, now: now) }
      expect(described_class.avatar_due?(contact.reload, now: now + 6.days)).to be(false)
      expect(described_class.avatar_due?(contact, now: now + 8.days)).to be(true)
    end

    it 'resets misses on success and refreshes an attached avatar only after 14 days' do
      described_class.record_avatar_result(contact, success: false, now: now)
      contact.avatar.attach(io: StringIO.new('x'), filename: 'a.jpg', content_type: 'image/jpeg')
      described_class.record_avatar_result(contact.reload, success: true, now: now)
      expect(described_class.avatar_state(contact.reload)['misses']).to eq(0)
      expect(described_class.avatar_due?(contact, now: now + 3.days)).to be(false)
      expect(described_class.avatar_due?(contact, now: now + 15.days)).to be(true)
    end

    it 'enqueues the fetch only when due' do
      channel = instance_double(Channel::Whatsapp, id: 'ch-1')
      expect(Whatsapp::EvolutionHandlers::AvatarEnqueueGuard).to receive(:enqueue_avatar_fetch).once
      expect(described_class.new(contact).schedule_avatar(channel, '5511999999999')).to be(true)
      described_class.record_avatar_result(contact.reload, success: false, now: Time.current)
      expect(described_class.new(contact.reload).schedule_avatar(channel, '5511999999999')).to be(false)
    end
  end
end
