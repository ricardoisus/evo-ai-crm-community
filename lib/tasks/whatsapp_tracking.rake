# frozen_string_literal: true

namespace :whatsapp_tracking do
  desc 'Rehearse or import sanitized legacy CRA Meta receipts from standard input'
  task import_cra_meta_receipts: :environment do
    inbox = Inbox.find(ENV.fetch('WHATSAPP_TRACKING_CRA_INBOX_ID'))
    commit = ENV['WHATSAPP_TRACKING_COMMIT_RECEIPTS'] == 'true'
    input = STDIN.read
    rows = JSON.parse(input)
    raise ArgumentError, 'expected a CRA receipt array' unless rows.is_a?(Array)

    result = WhatsappTracking::CraMetaReceiptImport.new(inbox: inbox).call(rows, commit: commit)
    puts JSON.generate(commit: commit, rows: rows.size, results: result)
  end
end

namespace :whatsapp_tracking do
  desc 'Rehearse or import the CRA website state exported by the legacy receipt ledger'
  task import_cra_website: :environment do
    snapshot = JSON.parse(STDIN.read)
    commit = ENV['WHATSAPP_TRACKING_COMMIT_WEBSITE'] == 'true'
    result = WhatsappTracking::CraSiteStateImport.new.call(snapshot, commit: commit)
    puts JSON.generate(commit: commit, results: result)
  end
end

namespace :whatsapp_tracking do
  desc 'Rehearse or configure the native CRA tracking destinations and conversion rules'
  task configure_cra: :environment do
    inbox = Inbox.find(ENV.fetch('WHATSAPP_TRACKING_CRA_INBOX_ID'))
    commit = ENV['WHATSAPP_TRACKING_COMMIT_CONFIGURATION'] == 'true'
    WhatsappTracking::CraConfiguration.new(inbox: inbox).install!(commit: commit)
    puts JSON.generate(commit: commit, inbox: inbox.id, result: 'valid_configuration')
  end
end
