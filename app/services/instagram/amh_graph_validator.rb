# frozen_string_literal: true

# Structural draft validation is separate from executable publication validation.
class Instagram::AmhGraphValidator
  PREREQUISITES = { 'invitation' => ['material:success', 'Resolva o material antes do convite.'],
                    'confirmation' => ['invitation:success', 'Confirmação exige convite aceito.'],
                    'public_reply' => ['invitation:success', 'Resposta pública exige convite aceito.'],
                    'delivery' => ['confirmation:confirmed', 'Entrega exige confirmação por clique real.'] }.freeze
  def initialize(graph)
    @graph = graph
    @problems = []
    @reached = []
  end

  def require!(condition, message)
    Instagram::AmhVisualEngine.require_valid!(condition, message)
  end

  def nodes
    @graph['nodes']
  end

  def edges
    @graph['edges']
  end

  def draft!
    require!(@graph.is_a?(Hash) && (@graph.keys - %w[schema_version nodes edges]).empty? && Instagram::AmhGraph.v2?(@graph), 'Contrato inválido')
    require!(JSON.generate(@graph).bytesize <= 100_000, 'Grafo excede 100 KB')
    draft_nodes!
    draft_edges!
    @graph
  end

  def draft_nodes!
    require!(nodes.is_a?(Array) && nodes.size.between?(1, 50) && nodes.all?(Hash), 'Use de 1 a 50 blocos')
    require!(nodes.all? { |node| valid_node?(node) }, 'Bloco inválido')
    require!(nodes.pluck('id').uniq.size == nodes.size, 'IDs dos blocos devem ser únicos')
    nodes.each { |n| Instagram::AmhVisualEngine.validate_node!(n.merge('type' => n['id'])) }
  end

  def valid_node?(node)
    node['id'].is_a?(String) && /\A[a-zA-Z0-9_-]{1,80}\z/.match?(node['id']) &&
      Instagram::AmhGraph::PORTS.key?(node['type']) && node['data'].is_a?(Hash)
  end

  def draft_edges!
    require!(edges.is_a?(Array) && edges.size <= 150 && edges.all?(Hash), 'Conexões inválidas')
    require!(edges.all? { |e| valid_edge?(e) }, 'Porta ou destino inválido')
    unique_edges!
  end

  def unique_edges!
    require!(edges.pluck('id').uniq.size == edges.size, 'IDs de conexão devem ser únicos')
    require!(edges.map { |e| e.values_at('source', 'sourceHandle') }.uniq.size == edges.size, 'Cada saída aceita uma conexão')
  end

  def valid_edge?(edge)
    source = nodes.find { |n| n['id'] == edge['source'] }
    source && nodes.any? { |n| n['id'] == edge['target'] } && edge['id'].is_a?(String) &&
      Instagram::AmhGraph::PORTS.fetch(source['type']).include?(edge['sourceHandle'])
  end

  def problem(node, field, message)
    @problems << Instagram::AmhGraph.issue(node, field, message)
  end

  def publish!
    draft!
    roots = nodes.select { |n| n['type'] == 'comment' }
    problem(nil, 'nodes', 'Use exatamente um gatilho de comentário.') unless roots.one?
    nodes.each { |node| publication_node(node) }
    topology(roots.first) if roots.one?
    raise Instagram::AmhGraph::Invalid, @problems.uniq if @problems.any?

    @graph
  end

  def publication_node(node)
    begin
      parameters!(node)
    rescue Instagram::AmhVisualEngine::Invalid => e
      problem(node['id'], 'data', e.message)
    end
    Instagram::AmhGraph::PORTS.fetch(node['type']).each do |port|
      problem(node['id'], port, "Conecte a saída #{port}.") unless Instagram::AmhGraph.edge(@graph, node['id'], port)
    end
  end

  def topology(root)
    visit(root['id'], [], [])
    nodes.each { |n| problem(n['id'], 'edges', 'Bloco desconectado do gatilho.') unless @reached.include?(n['id']) }
    problem(root['id'], 'edges', 'O gatilho não aceita entrada.') if edges.any? { |e| e['target'] == root['id'] }
  end

  def visit(id, stack, history)
    return problem(id, 'edges', 'O fluxo não pode conter ciclos.') if stack.include?(id)
    return problem(id, 'edges', 'Muitas combinações de caminhos; simplifique o fluxo.') if @reached.size > 512

    @reached << id
    kind = nodes.find { |n| n['id'] == id }['type']
    path_safety(id, kind, history)
    edges.select { |e| e['source'] == id }.each { |e| visit(e['target'], stack + [id], history + [kind, "#{kind}:#{e['sourceHandle']}"]) }
  end

  def path_safety(id, kind, history)
    prerequisite, message = PREREQUISITES[kind]
    problem(id, 'type', message) if prerequisite && history.exclude?(prerequisite)
    action_safety(id, kind, history) if Instagram::AmhGraph::ACTIONS.include?(kind)
    if %w[scope keyword material].include?(kind) && history.include?('invitation')
      problem(id, 'type', 'Condições e material devem vir antes do convite.')
    end
    delivery_path(id, kind, history)
  end

  def delivery_path(id, kind, history)
    return unless kind == 'end' && history.include?('invitation:success') && history.exclude?('delivery')

    problem(id, 'edges', 'Após convite aceito, mantenha confirmação e entrega em todos os caminhos.')
  end

  def action_safety(id, kind, history)
    problem(id, 'type', 'Uma ação de cada tipo por caminho.') if history.include?(kind)
    problem(id, 'type', 'Configure conta/conteúdo antes de enviar.') if history.exclude?('scope:match')
  end

  def parameters!(node)
    d = node['data']
    engine = Instagram::AmhVisualEngine
    case node['type']
    when 'scope' then scope!(d)
    when 'keyword' then engine.validate_keyword!(d)
    when 'material' then engine.validate_material!(d)
    when 'invitation' then require!(engine.safe_button_text?(d['text'], 1000), 'Convite: até 1000 bytes, sem links.')
    when 'public_reply' then public_reply!(d)
    when 'delivery'
      require!(engine.safe_button_text?(d['text'], 640), 'Mensagem: até 640 bytes, sem links.')
      require!(engine.valid_string?(d['buttonLabel'], 20), 'Botão: de 1 a 20 caracteres.')
    end
  end

  def scope!(data)
    require!(Instagram::AmhVisualEngine.valid_string?(data['account'], 100), 'Escolha a conta.')
    require!(data['allContent'] == true || data['media'].present? || data['ad'].present?, 'Escolha conteúdo ou todos os conteúdos.')
    require!(data['allContent'] != true || [data['media'], data['ad']].all?(&:blank?), 'Todos os conteúdos não aceita IDs específicos.')
    require!(%w[media ad].all? { |k| data[k].blank? || /\A[0-9]{1,64}\z/.match?(data[k]) }, 'Use IDs numéricos de conteúdo.')
  end

  def public_reply!(data)
    variants = data['variants']
    require!(variants.is_a?(Array) && variants.size.between?(1, 10), 'Use de 1 a 10 respostas públicas.')
    require!(variants.all? { |t| Instagram::AmhVisualEngine.safe_button_text?(t, 500) }, 'Resposta pública: até 500 bytes, sem links.')
  end
end
