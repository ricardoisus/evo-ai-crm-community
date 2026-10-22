# frozen_string_literal: true

# V2 DAG contract and deterministic traversal shared by simulator and transport.
# Layout is deliberately excluded from the executable digest.
class Instagram::AmhGraph
  PORTS = {
    'comment' => %w[next], 'scope' => %w[match no_match], 'keyword' => %w[match no_match],
    'material' => %w[success blocked], 'invitation' => %w[success failed blocked],
    'confirmation' => %w[confirmed], 'public_reply' => %w[success failed blocked],
    'like' => %w[success failed blocked], 'delivery' => %w[success failed blocked], 'end' => []
  }.freeze
  ACTIONS = %w[invitation confirmation public_reply like delivery].freeze
  class Invalid < Instagram::AmhVisualEngine::Invalid
    attr_reader :issues

    def initialize(issues)
      @issues = issues
      super(issues.first.fetch(:message))
    end
  end

  def self.v2?(graph)
    graph.is_a?(Hash) && graph['schema_version'] == 2
  end

  def self.issue(node, field, message)
    { node: node, field: field, message: message, action: 'Abra o bloco e corrija a configuração.' }
  end

  def self.validate_draft!(graph)
    Instagram::AmhGraphValidator.new(graph).draft!
  end

  def self.validate!(graph)
    Instagram::AmhGraphValidator.new(graph).publish!
  end

  def self.edge(graph, id, port)
    graph['edges'].find { |e| e['source'] == id && e['sourceHandle'] == port }
  end

  def self.digest(graph)
    nodes = graph['nodes'].map { |n| n.slice('id', 'type', 'data') }.sort_by { |n| n['id'] }
    edges = graph['edges'].map { |e| e.slice('source', 'sourceHandle', 'target') }.sort_by { |e| e.values_at('source', 'sourceHandle', 'target') }
    Digest::SHA256.hexdigest(JSON.generate(canonical('nodes' => nodes, 'edges' => edges)))
  end

  def self.canonical(value)
    case value
    when Hash then value.sort.to_h.transform_values { |v| canonical(v) }
    when Array then value.map { |v| canonical(v) }
    else value
    end
  end

  def self.condition(node, event)
    case node['type']
    when 'scope'
      scope = node['data']
      return 'no_match' unless Instagram::AmhShortLink.candidate_scope?(scope, event)

      begin
        Instagram::AmhShortLink.validate_scope!(scope, event)
        'match'
      rescue Instagram::AmhShortLink::Unavailable, Instagram::AmhShortLink::Conflict
        'no_match'
      end
    when 'keyword'
      Instagram::AmhVisualEngine.matches?(event.fetch('text', ''), node['data']) ? 'match' : 'no_match'
    else 'success'
    end
  end

  # Only pre-invitation conditions determine whether a comment is a candidate.
  def self.prelude(graph, event)
    prelude_visit(graph, event, graph['nodes'].find { |n| n['type'] == 'comment' }, [])
  end

  def self.prelude_visit(graph, event, node, path)
    return nil if prelude_stopped?(node, path)
    return path + [node] if node['type'] == 'invitation'

    candidates = prelude_ports(node, event)
    candidates.each do |port|
      target = edge(graph, node['id'], port)&.fetch('target')
      result = prelude_visit(graph, event, graph['nodes'].find { |n| n['id'] == target }, path + [node])
      return result if result
    end
    nil
  end

  def self.prelude_stopped?(node, path)
    node.nil? || node['type'] == 'end' || path.size > 50
  end

  def self.prelude_ports(node, event)
    return %w[success blocked] if node['type'] == 'material'
    return ['next'] if node['type'] == 'comment'

    [condition(node, event)]
  end

  def self.runtime_data(graph, event)
    path = prelude(graph, event)
    raise Instagram::AmhExecutor::Unavailable unless path

    scope = { 'account' => event['account'], 'media' => event['media'], 'ad' => event['ad'] }.compact
    keyword = { 'keywords' => [event['text']], 'mode' => 'contains', 'ignoreCase' => false, 'ignoreAccents' => false }
    material = path.reverse.find { |n| n['type'] == 'material' }.fetch('data')
    invitation = path.last['data']
    # The v2 runner owns subsequent actions; legacy services use this only for eligibility.
    { 'scope' => scope, 'keyword' => keyword, 'material' => material,
      'reply' => { 'confirmationRequired' => true, 'openingText' => invitation['text'] } }
  end

  def self.initial
    data = { 'scope' => { 'account' => '', 'allContent' => true },
             'keyword' => { 'keywords' => ['AMH'], 'mode' => 'word', 'ignoreCase' => true, 'ignoreAccents' => true },
             'material' => { 'material' => 'amh', 'mode' => 'fixed' },
             'reply' => { 'confirmationRequired' => true, 'openingText' => 'Oi, {{primeiro_nome}}! Posso enviar o material?',
                          'text' => 'Aqui está o acesso ao material.', 'buttonLabel' => 'Acessar material',
                          'publicReplyEnabled' => true, 'publicReplyVariants' => ['Enviei um convite no Direct!'] } }
    from_legacy('nodes' => Instagram::AmhVisualEngine::STAGES.map { |id| { 'id' => id, 'data' => data[id] || {} } })
  end

  def self.resolve_material(event, parameters, caption = nil)
    return [parameters['material'], 'configured'] unless parameters['mode'] == 'context'

    contract = { 'identity' => { 'professional_account_id' => event['account'] }, 'ad_id' => event['ad'], 'media_id' => event['media'] }
    choice = Instagram::AmhMaterialInventory.match(contract, parameters.fetch('mappings'))
    return choice if choice
    raise Instagram::AmhExecutor::Unavailable unless caption.is_a?(String)

    Instagram::AmhContextRouter.resolve_terms(caption, parameters.fetch('routes'))
  end

  def self.simulate(graph, **)
    Instagram::AmhGraphSimulator.new(graph, **).call
  end

  def self.from_legacy(graph)
    Instagram::AmhGraphTemplate.convert(graph)
  end
end
