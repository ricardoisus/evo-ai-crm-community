# frozen_string_literal: true

# Every action is durably reserved before I/O. A crash or uncertain receipt never
# replays that node. Conditions and material resolution share the simulator rules.
class Instagram::AmhGraphExecutor
  include Instagram::AmhGraphActions

  Unavailable = Instagram::AmhExecutor::Unavailable
  HANDLERS = { 'comment' => :comment, 'scope' => :condition, 'keyword' => :condition, 'material' => :material,
               'invitation' => :invitation, 'public_reply' => :public_reply, 'like' => :like,
               'delivery' => :deliver, 'end' => :finish }.freeze

  def self.call(event:, proof:, explicit_test: false)
    new(event, proof, explicit_test: explicit_test).start
  end

  def self.confirm(event:, delivery:)
    new(delivery.inbound_event, delivery.proof, explicit_test: false).confirm(event, delivery)
  end

  def initialize(event, proof, explicit_test:)
    @event = event
    @proof = proof
    @explicit_test = explicit_test
  end

  def start
    @row = Instagram::AmhVisualProof.with_mapping_lock do
      @inbox, @version, _, @payload = Instagram::AmhExecutor.eligible!(@event, @proof.reload, explicit_test: @explicit_test, resolve_material: false)
      raise Unavailable if ambiguous?

      reserve_delivery
    end
    raise Unavailable unless @row.proof_id == @proof.id && @row.version_id == @version['id']

    drive
  end

  def ambiguous?
    Instagram::AmhVisualProof.where(audience: %w[test active]).any? do |other|
      next false if other.id == @proof.id

      begin
        Instagram::AmhExecutor.eligible!(@event, other, explicit_test: @explicit_test, resolve_material: false)
        true
      rescue Unavailable
        false
      end
    end
  end

  def reserve_delivery
    Instagram::AmhDelivery.create_or_find_by!(inbound_event_id: @event.id) do |row|
      row.proof = @proof
      row.version_id = @version['id']
      row.like_state = 'not_requested'
      row.public_reply_state = 'not_requested'
      row.graph_cursor = @version['graph']['nodes'].find { |n| n['type'] == 'comment' }['id']
    end
  end

  def confirm(event, delivery)
    @row = delivery
    @inbox, @version, _, @payload, clicked_at = Instagram::AmhConfirmation.validate!(event, delivery)
    confirmed = @row.with_lock do
      raise Instagram::AmhConfirmation::NotReady if @row.state == 'pending' && @row.graph_cursor
      next false unless awaiting_confirmation?

      confirmation_node!

      @row.update!(confirmation_event_id: event.id, confirmation_received_at: clicked_at)
      advance(['confirmed', 'passed', 'Clique real confirmado'])
      true
    end
    return @row unless confirmed

    drive
  end

  def confirmation_node!
    @node = graph['nodes'].find { |n| n['id'] == @row.graph_cursor }
    raise Unavailable unless @node && @node['type'] == 'confirmation'
  end

  def awaiting_confirmation?
    @row.state == 'awaiting_confirmation' && @row.graph_cursor.present?
  end

  def graph
    @version['graph']
  end

  def active!
    raise Unavailable unless Instagram::AmhExecutor.enabled?

    proof = @proof.reload
    raise Unavailable unless proof.active_version_id == @version['id'] && %w[test active].include?(proof.audience)
    raise Unavailable if proof.audience == 'test' && !Instagram::AmhExecutor.test_identity?(@event.contract)
  end

  def reserve_node
    @row.with_lock do
      next false unless @row.graph_cursor
      # A prior worker may have reached Meta after recording this reservation.
      next false if @row.execution_trace.last&.fetch('status') == 'sending'

      active!
      @node = graph['nodes'].find { |n| n['id'] == @row.graph_cursor }
      raise Unavailable unless @node

      if @node['type'] == 'confirmation'
        @row.update!(state: 'awaiting_confirmation', reason: 'waiting_for_button_click')
        next false
      end
      @row.update!(execution_trace: @row.execution_trace + [trace('sending', 'Etapa reservada')])
      true
    end
  end

  def drive
    while reserve_node
      active!
      result = send(HANDLERS.fetch(@node['type']))
      @row.with_lock { advance(result) }
    end
    @row
  rescue Unavailable
    stop('blocked', 'rule_unavailable')
  rescue StandardError => e
    Rails.logger.error("AMH graph execution stopped: #{e.class}")
    stop('uncertain', 'graph_result_unknown')
  end

  def stop(state, reason)
    @row.with_lock do
      @row.update!(state: state, reason: reason, graph_cursor: nil, execution_trace: @row.execution_trace + [trace(state, reason)])
    end
    @row
  end

  def trace(status, reason, port = nil)
    { 'node' => @node&.fetch('id'), 'type' => @node&.fetch('type'), 'status' => status, 'reason' => reason,
      'port' => port, 'at' => Time.current.iso8601(6), 'attempts' => 1 }.compact
  end

  def advance(result)
    port, status, reason = result
    target = port && Instagram::AmhGraph.edge(graph, @node['id'], port)&.fetch('target')
    attributes = { graph_cursor: target, execution_trace: @row.execution_trace + [trace(status, reason, port)] }
    attributes = terminal_attributes(attributes, status, reason, target)
    @row.update!(attributes)
  end

  def terminal_attributes(attributes, status, reason, target)
    if status == 'uncertain'
      attributes[:state] = 'uncertain'
      attributes[:reason] = reason
    elsif !target && @row.state == 'pending'
      attributes[:state] = 'blocked'
      attributes[:reason] = 'graph_ended_without_delivery'
    end
    attributes
  end

  def outcome(state, reason)
    return [nil, 'uncertain', reason || 'Resultado incerto'] if %w[uncertain sending].include?(state)

    port = { 'accepted' => 'success', 'blocked' => 'blocked' }.fetch(state, 'failed')
    [port, state == 'accepted' ? 'passed' : state, reason || state]
  end

  def comment
    ['next', 'passed', 'Comentário recebido']
  end

  def condition
    port = Instagram::AmhGraph.condition(@node, @payload)
    [port, port == 'match' ? 'passed' : 'rejected', port == 'match' ? 'Condição satisfeita' : 'Condição não corresponde']
  end
end
