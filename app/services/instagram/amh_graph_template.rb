# frozen_string_literal: true

class Instagram::AmhGraphTemplate
  def self.convert(graph)
    return graph.deep_dup if Instagram::AmhGraph.v2?(graph)

    data = graph['nodes'].to_h { |n| [n['id'], n['data']] }
    reply = data.fetch('reply')
    kinds = %w[comment scope keyword material invitation]
    kinds << 'public_reply' if reply['publicReplyEnabled']
    kinds += %w[like confirmation delivery end]
    nodes = kinds.map.with_index do |type, i|
      parameters = parameters(type, data, reply)
      { 'id' => type, 'type' => type, 'position' => { 'x' => i * 280, 'y' => 80 }, 'data' => parameters.deep_dup }
    end
    nodes << { 'id' => 'stop', 'type' => 'end', 'position' => { 'x' => 560, 'y' => 400 }, 'data' => { 'label' => 'Sem envio' } }
    { 'schema_version' => 2, 'nodes' => nodes, 'edges' => edges(kinds) }
  end

  def self.edges(kinds)
    kinds.each_cons(2).flat_map do |source, target|
      Instagram::AmhGraph::PORTS.fetch(source).map do |port|
        destination = %w[no_match blocked failed].include?(port) && %w[like public_reply].exclude?(source) ? 'stop' : target
        { 'id' => "#{source}-#{port}", 'source' => source, 'sourceHandle' => port, 'target' => destination }
      end
    end
  end

  def self.parameters(type, data, reply)
    case type
    when 'invitation' then { 'text' => fallback(reply['openingText'], 'Posso enviar o material?') }
    when 'public_reply' then { 'variants' => fallback(reply['publicReplyVariants'], [reply['publicReplyText']]) }
    when 'delivery' then { 'text' => reply['text'], 'buttonLabel' => fallback(reply['buttonLabel'], 'Acessar material') }
    else data[type] || {}
    end
  end

  def self.fallback(value, default)
    value || default
  end
end
