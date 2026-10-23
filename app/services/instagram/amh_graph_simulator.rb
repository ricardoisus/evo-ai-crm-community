# frozen_string_literal: true

# Synthetic context enters the same conditions/material resolver as live events.
# No transport, callback, link issuance or subscriber is invoked here.
class Instagram::AmhGraphSimulator
  STOPS = { 'repeated' => %w[comment skipped], 'expired' => %w[invitation blocked],
            'timeout' => %w[invitation uncertain], 'conflict' => %w[comment conflict] }.freeze
  def initialize(graph, fixture:, text: nil, context: {})
    @graph = graph
    @fixture = fixture
    @text = text
    @context = context
    @trace = []
    @material = nil
    @terminal = nil
  end

  def call
    Instagram::AmhGraph.validate!(@graph)
    Instagram::AmhVisualEngine.validate_text!(@text)
    Instagram::AmhVisualEngine.require_valid!(Instagram::AmhVisualEngine::FIXTURES.include?(@fixture), 'Cenário desconhecido')
    @event = synthetic_event
    current = @graph['nodes'].find { |n| n['type'] == 'comment' }
    while current
      port, status, reason = node_result(current)
      @trace << { node: current['id'], type: current['type'], port: port, status: status, reason: reason, at: Time.current.iso8601(6), attempts: 1 }
      target = port && Instagram::AmhGraph.edge(@graph, current['id'], port)&.fetch('target')
      current = @graph['nodes'].find { |n| n['id'] == target }
    end
    result
  end

  def synthetic_event
    scope = @graph['nodes'].find { |n| n['type'] == 'scope' }&.fetch('data') || {}
    keyword = default_keyword
    event = scope.slice('account', 'ad', 'media').merge('text' => @text || (@fixture == 'negative' ? '' : keyword))
    event.merge!(@context.slice('account', 'ad', 'media'))
    event['account'] = 'mismatch' if @fixture == 'scope_mismatch'
    event
  end

  def default_keyword
    node = @graph['nodes'].find { |n| n['type'] == 'keyword' }
    node ? node['data'].fetch('keywords').first : 'AMH'
  end

  def node_result(node)
    stop = STOPS[@fixture]
    if stop && stop.first == node['type']
      @terminal = stop.last
      return [nil, @terminal, 'Cenário interrompido sem envio externo']
    end
    return material_result(node) if node['type'] == 'material'
    return condition_result(node) if %w[scope keyword].include?(node['type'])

    port = { 'comment' => 'next', 'confirmation' => 'confirmed', 'end' => nil }.fetch(node['type'], 'success')
    [port, 'passed', 'Simulação sem envio']
  end

  def condition_result(node)
    port = Instagram::AmhGraph.condition(node, @event)
    [port, port == 'match' ? 'passed' : 'rejected', port == 'match' ? 'Condição satisfeita' : 'Condição não corresponde']
  end

  def material_result(node)
    raise Instagram::AmhExecutor::Unavailable if @fixture == 'missing_material'

    @material, = Instagram::AmhGraph.resolve_material(@event, node['data'], @context['caption'])
    ['success', 'passed', "Material resolvido: #{@material}"]
  rescue Instagram::AmhExecutor::Unavailable
    ['blocked', 'blocked', 'Material sem correspondência segura; confira conteúdo e legenda.']
  end

  def result
    outcome = @terminal || (@trace.any? { |t| t[:type] == 'delivery' } ? 'simulated_accepted' : 'blocked')
    { fixture: @fixture, trace: @trace, outcome: outcome, material: @material, outbound_calls: 0,
      mautic_state: 'not_executed', mode: 'inert', preview: '', contract: 'amh-graph-v2' }
  end
end
