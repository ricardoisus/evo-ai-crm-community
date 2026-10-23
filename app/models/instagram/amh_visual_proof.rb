# frozen_string_literal: true

# Versioned comment automations, isolated from general journeys and campaign sends.
class Instagram::AmhVisualProof < ApplicationRecord
  self.table_name = 'instagram_amh_visual_proofs'
  validates :audience, inclusion: { in: %w[paused test active] }
  validates :create_key, presence: true
  validates :name, presence: true, length: { maximum: 100 }

  # One database transaction coordinates selectable QA mappings with link issuance.
  # Transaction advisory locks also work with the installed transaction pooler.
  def self.with_mapping_lock
    transaction do
      connection.execute('SELECT pg_advisory_xact_lock(419202619)')
      yield
    end
  end

  def publish_version!(expected_lock, actor)
    self.class.with_mapping_lock { publish_locked_version!(expected_lock, actor) }
  end

  def publish_locked_version!(expected_lock, actor)
    with_lock do
      raise ActiveRecord::StaleObjectError.new(self, 'publish') unless lock_version == expected_lock

      Instagram::AmhVisualEngine.validate!(draft)
      raise Instagram::AmhVisualEngine::Invalid, 'Limite de 100 versões; crie outra prova' if versions.size >= 100

      version = { id: SecureRandom.uuid, number: versions.size + 1, graph: draft.deep_dup,
                  digest: Digest::SHA256.hexdigest(JSON.generate(draft)), functional_digest: functional_digest(draft), at: Time.current.iso8601(6),
                  actor: actor, state: 'paused', mode: 'inert' }
      update!(versions: versions + [version])
    end
  end

  def simulate_version!(version_id, fixture, text, context = {})
    with_lock do
      version = versions.find { |v| v['id'] == version_id }
      raise Instagram::AmhVisualEngine::Invalid, 'Publique e selecione uma versão de simulação' unless version

      Instagram::AmhVisualEngine.validate_text!(text)
      text = Instagram::AmhVisualEngine.effective_text(version['graph'], fixture, text)
      key = OpenSSL::HMAC.hexdigest('SHA256', Rails.application.key_generator.generate_key('amh-proof-dedup-v1'),
                                    JSON.generate([version['id'], fixture, text, context]))
      existing = ledger.find { |run| run['key'] == key }
      existing || append_run!(version, fixture, text, key, context)
    end
  end

  def append_run!(version, fixture, text, key, context)
    raise Instagram::AmhVisualEngine::Invalid, 'Limite de 800 recibos atingido' if ledger.size >= 800

    result = if Instagram::AmhGraph.v2?(version['graph'])
               Instagram::AmhGraph.simulate(version['graph'], fixture: fixture, text: text, context: context)
             else
               Instagram::AmhVisualEngine.simulate(version['graph'], fixture: fixture, text: text)
             end
    run = result.merge(id: SecureRandom.uuid, key: key, version_id: version['id'], version_number: version['number'],
                       graph_digest: version['digest'], at: Time.current.iso8601(6))
    # Receipt writes hold the row lock but must not advance the draft revision.
    update_columns(ledger: ledger + [run], updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    run
  end

  def functional_digest(graph)
    Instagram::AmhGraph.v2?(graph) ? Instagram::AmhGraph.digest(graph) : Digest::SHA256.hexdigest(JSON.generate(graph))
  end

  def discard_draft!(expected_lock)
    with_lock do
      raise ActiveRecord::StaleObjectError.new(self, 'discard') unless lock_version == expected_lock

      baseline = versions.last&.fetch('graph')
      baseline ||= Instagram::AmhGraph.initial
      update!(draft: baseline.deep_dup)
    end
  end

  def tested_version_ids(version)
    return [] unless version

    digest = version['functional_digest']
    return [version['id']] unless digest

    versions.select { |v| v['functional_digest'] == digest }.pluck('id')
  end

  def activation_readiness(version)
    receipts = Instagram::AmhDelivery.where(proof_id: id, version_id: tested_version_ids(version),
                                            state: 'accepted').where.not(confirmation_event_id: nil)
    tested = version.present? && receipts.exists?
    tested &&= receipts.exists?(public_reply_state: 'accepted') if public_reply_required?(version)
    { 'eligible' => tested, 'reason' => tested ? nil : 'Conclua convite, clique e entrega no teste restrito desta configuração.' }
  end

  def public_reply_required?(version)
    return false unless version

    graph = version['graph']
    return graph['nodes'].any? { |n| n['type'] == 'public_reply' } if Instagram::AmhGraph.v2?(graph)

    graph['nodes'].find { |n| n['id'] == 'reply' }&.dig('data', 'publicReplyEnabled') == true
  end

  def snapshot
    as_json(only: %i[id name draft versions ledger lock_version updated_at]).merge(snapshot_state)
  end

  def snapshot_state
    { 'outbound_enabled' => audience != 'paused' && Instagram::AmhExecutor.enabled?,
      'state' => audience, 'active_version_id' => active_version_id, 'published_version_id' => versions.last&.fetch('id'),
      'draft_changed' => versions.last.nil? || draft != versions.last['graph'],
      'activation_readiness' => activation_readiness(versions.last) }
  end
end
