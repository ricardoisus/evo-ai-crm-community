# frozen_string_literal: true

namespace :whatsapp do
  desc 'Backfill de nome e foto dos contatos WhatsApp (Evolution). Dry-run por padrão; APPLY=1 grava. LIMIT=n, RATE=segundos, INBOX_IDS=a,b'
  task backfill_contact_identity: :environment do
    report = Whatsapp::ContactIdentityBackfill.new(
      inbox_ids: ENV['INBOX_IDS']&.split(',')&.map(&:strip),
      apply: ENV['APPLY'] == '1',
      limit: ENV['LIMIT']&.to_i,
      rate: (ENV['RATE'] || 1.0).to_f
    ).run
    puts report.to_h_report.to_json
  end
end
