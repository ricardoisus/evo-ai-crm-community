class VetorialAgent::Bridge
  class Rejected < StandardError; end
  FIELDS = %w[especialidade cidade atendimento_particular anos_particular contexto_clinico objecoes interesse_nivel origem proxima_acao].freeze
  LABELS = %w[mql-declarado reuniao-agendada sem-aderencia objecao-preco objecao-tempo objecao-ja-tentei pediu-humano fora-de-escopo
              aguardando-lead retomada spam].freeze

  def initialize(conversation)
    @conversation = conversation
  end

  def call(data)
    @conversation.with_lock do
      existing = VetorialAgent::Command.find_by(key: data['key'])
      if existing
        raise Rejected unless existing.conversation_id == @conversation.id && receipt_replay?(existing, data)

        next existing.result.merge('status' => existing.status)
      end
      state = authorized_state(data)
      next media(data) if %w[media analysis_media].include?(data['kind'])

      command = VetorialAgent::Command.create!(conversation: @conversation, key: data['key'], kind: data.fetch('kind'), payload: data)
      result = execute(command, state, data)
      command.update!(result: result, status: command.kind == 'send' ? 'pending' : 'done')
      result.merge('status' => command.status)
    end
  end

  private

  # A completed A14 effect retains its original payload. Promotion may add a
  # fence to a receipt lookup, but must never recreate or alter that effect.
  def receipt_replay?(command, data)
    return true if command.payload == data
    return false unless %w[sent done].include?(command.status)

    fence_keys = %w[revision policy_epoch sha256]
    deployment = VetorialAgent::Deployment.for_conversation(@conversation)
    deployment && deployment.command_current?(data) &&
      command.payload.except(*fence_keys) == data.except(*fence_keys)
  end

  def authorized_state(data)
    deployment = VetorialAgent::Deployment.for_conversation(@conversation)
    raise Rejected if deployment && !deployment.command_current?(data)
    state = VetorialAgent::State.find_or_create_by!(conversation: @conversation)
    eligible = if %w[analysis analysis_media].include?(data['kind'])
                 VetorialAgent::Policy.analysis_eligible?(@conversation)
               else
                 VetorialAgent::Policy.allowed?(@conversation) && !state.paused
               end
    raise Rejected unless eligible && state.version == data['version']
    raise ArgumentError unless data['key'].to_s.match?(/\A[a-zA-Z0-9:_-]{1,160}\z/)

    state
  end

  def execute(command, state, data)
    case command.kind
    when 'send'
      enqueue_send(command, data)
    when 'note', 'analysis', 'fields', 'handoff', 'silent'
      internal_action(command, state, data)
    when 'typing'
      VetorialAgent::Transport.new(@conversation).typing if ENV['VETORIAL_AGENT_SEND_ENABLED'] == 'true'
      { 'sucesso' => true }
    else
      raise ArgumentError
    end
  end

  def enqueue_send(command, data)
    raise ArgumentError unless data['text'].is_a?(String) && data['text'].length.between?(1, 300)
    raise Rejected unless ENV['VETORIAL_AGENT_SEND_ENABLED'] == 'true'

    count = VetorialAgent::Command.where(conversation: @conversation, kind: 'send').where('created_at > ?', 1.hour.ago).count
    raise Rejected if count > 20

    message = @conversation.messages.create!(
      inbox: @conversation.inbox, sender: bot, source: :imported, message_type: :outgoing, status: :failed, content: data['text'],
      content_attributes: { 'whatsapp_observed' => true, 'vetorial_agent' => command.key }
    )
    VetorialAgent::SendJob.perform_later(command.id)
    { 'sucesso' => true, 'message_id' => message.id }
  end

  def bot
    AgentBot.find(ENV.fetch('VETORIAL_AGENT_BOT_ID'))
  end

  def internal_action(command, state, data)
    fields = (data['fields'] || {}).slice(*FIELDS).reject { |_, value| absent_value?(value) }
    update_fields(state, fields) if fields.any?
    apply_labels(Array(data['labels']) & LABELS)
    private_note(data['note'], command.key) if data['note'].present?
    if %w[handoff silent].include?(command.kind)
      state.update!(version: state.version + 1, paused: true, reason: command.kind)
      VetorialAgent::Capture.persist(@conversation, state, 'human')
    end
    { 'sucesso' => true }
  end

  def private_note(text, key)
    @conversation.messages.create!(
      inbox: @conversation.inbox, message_type: :outgoing, private: true, source: :imported, sender: bot, content: text.to_s.first(5000),
      content_attributes: { 'whatsapp_observed' => true, 'vetorial_agent' => key }
    )
  end

  def scoped_items
    @conversation.pipeline_items.active.where(pipeline_id: ENV.fetch('VETORIAL_AGENT_PIPELINE_ID', nil))
  end

  def apply_labels(labels)
    return if labels.empty?

    @conversation.add_labels(labels)
    scoped_items.find_each { |item| item.add_labels(labels) }
  end

  def update_fields(state, fields)
    raise ArgumentError unless fields.all? { |key, value| valid_field?(key, value) }

    state.fields = state.fields.merge(fields)
    scoped_items.find_each { |item| merge_item_fields(item, state, fields) }
    state.save!
  end

  def absent_value?(value)
    value.nil? || (value.respond_to?(:empty?) && value.empty?)
  end

  def valid_field?(key, value)
    case key
    when 'atendimento_particular' then [true, false].include?(value)
    when 'anos_particular' then value.is_a?(Numeric) && value.between?(0, 100)
    when 'objecoes' then valid_objections?(value)
    else value.is_a?(String) && value.length <= 2000
    end
  end

  def valid_objections?(value)
    value.is_a?(Array) && value.length <= 20 && value.all? { |entry| entry.is_a?(String) && entry.length <= 500 }
  end

  def merge_item_fields(item, state, fields)
    item.with_lock do
      old = state.field_values.fetch(item.id, {})
      updates = fields.select { |key, _| item.custom_fields.to_h[key].nil? || item.custom_fields.to_h[key] == old[key] }
      item.update!(custom_fields: item.custom_fields.to_h.merge(updates)) if updates.any?
      state.field_values = state.field_values.merge(item.id => old.merge(updates))
    end
  end

  def media(data)
    attachment = @conversation.attachments.find(data.fetch('attachment_id'))
    raise ArgumentError if attachment.file.blob.byte_size > 20.megabytes

    # Read-only response: never duplicate blobs in command receipts.
    { 'sucesso' => true, 'mime' => attachment.file.blob.content_type, 'base64' => Base64.strict_encode64(attachment.file.download) }
  end
end
