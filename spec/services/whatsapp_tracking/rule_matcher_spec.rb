# frozen_string_literal: true

require_relative '../../../app/services/whatsapp_tracking/rule_matcher'

RSpec.describe WhatsappTracking::RuleMatcher do
  let(:rule) do
    {
      'account_id' => 'cra', 'trigger' => 'message_received',
      'filters' => { 'inbox_id' => 'cra-whatsapp', 'stage_id' => 'new' },
      'text' => { 'operator' => 'starts_with', 'value' => 'Olá, gostaria' }
    }
  end

  let(:event) do
    {
      'account_id' => 'cra', 'trigger' => 'message_received',
      'inbox_id' => 'cra-whatsapp', 'stage_id' => 'new',
      'text' => "OLA\u0301,   GOSTARIA de informações"
    }
  end

  it 'normalizes Unicode, case and whitespace' do
    expect(described_class.new(rule, event).result).to eq(:matched)
  end

  it 'rejects another account before evaluating its message' do
    expect(described_class.new(rule, event.merge('account_id' => 'vetorial')).result).to eq(:different_account)
  end

  it 'requires all configured filters to match' do
    expect(described_class.new(rule, event.merge('stage_id' => 'closed')).result).to eq(:filter_mismatch)
  end

  it 'excludes private notes and imported messages' do
    %w[private imported].each do |flag|
      expect(described_class.new(rule, event.merge(flag => true)).result).to eq(:ineligible_message)
    end
  end

  it 'requires provider confirmation for sent messages' do
    outgoing_rule = rule.merge('trigger' => 'message_sent')
    outgoing_event = event.merge('trigger' => 'message_sent')
    expect(described_class.new(outgoing_rule, outgoing_event).result).to eq(:ineligible_message)
    expect(described_class.new(outgoing_rule, outgoing_event.merge('confirmed' => true)).result).to eq(:matched)
  end

  it 'matches stage transitions by both stages without message text' do
    stage_rule = rule.merge('trigger' => 'stage_entered', 'text' => nil, 'filters' => {
      'stage_id' => 'qualified', 'from_stage_id' => 'new'
    })
    stage_event = { 'account_id' => 'cra', 'trigger' => 'stage_entered', 'stage_id' => 'qualified', 'from_stage_id' => 'new' }
    expect(described_class.new(stage_rule, stage_event).result).to eq(:matched)
    expect(described_class.new(stage_rule, stage_event.merge('from_stage_id' => 'closed')).result).to eq(:filter_mismatch)
  end
end
