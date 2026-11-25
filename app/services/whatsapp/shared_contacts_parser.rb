# frozen_string_literal: true

# Lê os cartões de contato do WhatsApp (contactMessage / contactsArrayMessage) e devolve
# [{ 'name' => String, 'phones' => [String], 'organization' => String | nil }].
# O vCard vem do aparelho de quem enviou: entrada inesperada é ignorada, nunca levanta erro.
module Whatsapp::SharedContactsParser
  PROPERTY = /\A(?:[\w-]+\.)?(?<name>FN|TEL|ORG)(?<params>;[^:]*)?:(?<value>.*)\z/i

  module_function

  # contacts: lista de { displayName:, vcard: }. Entradas sem nome nem telefone ficam de fora.
  def parse(contacts)
    Array(contacts).filter_map { |contact| parse_contact(contact) if contact.is_a?(Hash) }
  end

  def parse_contact(contact)
    properties = properties_from(contact[:vcard] || contact['vcard'])
    name = contact_name(properties['FN'], contact)
    phones = properties['TEL'].filter_map { |params, value| phone(params, value) }.uniq
    return if name.blank? && phones.empty?

    { 'name' => name, 'phones' => phones, 'organization' => organization(properties['ORG']) }
  end

  def contact_name(entries, contact)
    entries.filter_map { |_, value| unescape(value).presence }.first ||
      text(contact[:displayName] || contact['displayName']).strip
  end

  def properties_from(vcard)
    properties = { 'FN' => [], 'TEL' => [], 'ORG' => [] }
    # Linhas longas continuam na seguinte, que começa com espaço ou tab.
    text(vcard).gsub(/\r\n?/, "\n").gsub(/\n[ \t]/, '').each_line(chomp: true) do |line|
      match = PROPERTY.match(line)
      properties[match[:name].upcase] << [match[:params].to_s, match[:value]] if match
    end
    properties
  end

  # O waid é o número no WhatsApp; vale quando o telefone escrito não traz o código do país.
  def phone(params, value)
    number = unescape(value)
    waid = params[/;waid=(\d+)/i, 1]
    return "+#{waid}" if waid && !number.start_with?('+')

    number if number.match?(/\d/)
  end

  def organization(entries)
    _, value = entries.first
    value.to_s.split(/(?<!\\);/).filter_map { |part| unescape(part).presence }.join(', ').presence
  end

  def unescape(value)
    value.gsub(/\\(.)/) { Regexp.last_match(1).casecmp?('n') ? ' ' : Regexp.last_match(1) }.strip
  end

  def text(value)
    value.is_a?(String) ? value.dup.force_encoding(Encoding::UTF_8).scrub('') : ''
  end
end
