# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::SharedContactsParser do
  def vcard(*lines)
    ['BEGIN:VCARD', 'VERSION:3.0', *lines, 'END:VCARD'].join("\n")
  end

  def parse(*contacts)
    described_class.parse(contacts)
  end

  it 'reads name from FN, phones from TEL (with waid) and organization from ORG' do
    card = vcard('N:Sintética;Ana;;;', 'FN:Ana Sintética', 'ORG:Clínica Exemplo;',
                 'item1.TEL;waid=15550000010:+1 555-000-0010', 'item1.X-ABLabel:Celular')

    expect(parse({ displayName: 'Ana (agenda)', vcard: card })).to eq(
      [{ 'name' => 'Ana Sintética', 'phones' => ['+1 555-000-0010'], 'waids' => ['15550000010'],
         'organization' => 'Clínica Exemplo' }]
    )
  end

  it 'keeps several phones in order, without repeating them, and several contacts' do
    first = vcard('FN:Ana', 'TEL;type=CELL:+15550000010', 'TEL;type=WORK:+15550000011', 'TEL:+15550000010')
    second = vcard('FN:Beto', 'TEL:+15550000012')

    result = parse({ displayName: 'Ana', vcard: first }, { displayName: 'Beto', vcard: second })

    expect(result.map { |c| c['phones'] }).to eq([%w[+15550000010 +15550000011], ['+15550000012']])
  end

  it 'uses the waid when the TEL value has no country code or is empty' do
    card = vcard('FN:Ana', 'TEL;type=CELL;waid=15550000010:(555) 000-0010', 'TEL;waid=15550000011:')

    expect(parse({ vcard: card }).sole['phones']).to eq(%w[+15550000010 +15550000011])
  end

  it 'keeps the waid of each phone aside, aligned with phones' do
    card = vcard('FN:Ana', 'TEL:+551130000000', 'TEL;waid=553190000001:+55 31 99000-0001')

    expect(parse({ vcard: card }).sole.values_at('phones', 'waids'))
      .to eq([['+551130000000', '+55 31 99000-0001'], [nil, '553190000001']])
  end

  it 'unfolds long lines, unescapes values and accepts CRLF' do
    card = "BEGIN:VCARD\r\nFN:Ana Sin\r\n tética\\, Dra.\r\nORG:Exemplo\\; Cia;Vendas\r\nTEL:+15550000010\r\nEND:VCARD"

    expect(parse({ vcard: card }).sole.values_at('name', 'organization'))
      .to eq(['Ana Sintética, Dra.', 'Exemplo; Cia, Vendas'])
  end

  it 'keeps a contact without phone, falling back to displayName' do
    expect(parse({ displayName: 'Sem Telefone', vcard: vcard('NOTE:x') }))
      .to eq([{ 'name' => 'Sem Telefone', 'phones' => [], 'organization' => nil }])
  end

  it 'does not break on a malformed or missing vCard and drops entries with nothing to show' do
    result = parse(nil, 'texto', {}, { vcard: 123 }, { vcard: ":::\nTEL\nFN" },
                   { displayName: 'Só nome', vcard: "lixo \xFF".dup.force_encoding('UTF-8') })

    expect(result).to eq([{ 'name' => 'Só nome', 'phones' => [], 'organization' => nil }])
  end
end
