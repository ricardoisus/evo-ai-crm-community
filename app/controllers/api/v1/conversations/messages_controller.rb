class Api::V1::Conversations::MessagesController < Api::V1::Conversations::BaseController
  MAX_FORWARD_TARGETS = 5
  TARGET_ID_PATTERN = Regexp.union(ConversationResolver::UUID_PATTERN, /\A\d+\z/)

  require_permissions({
    index: 'conversations.read',
    create: 'conversations.update',
    update: 'conversations.update',
    destroy: 'conversations.update',
    retry: 'conversations.update',
    reaction: 'conversations.update',
    forward: 'conversations.update'
  })

  before_action :ensure_api_inbox, only: :update

  def index
    @messages = message_finder.perform

    success_response(
      data: MessageSerializer.serialize_collection(@messages, include_attachments: true, include_sender: true),
      message: 'Messages retrieved successfully'
    )
  end

  def create
    user = Current.user || @resource
    mb = Messages::MessageBuilder.new(user, @conversation, params)
    @message = mb.perform
    attach_canned_response_files if params[:canned_response_id].present?

    success_response(
      data: MessageSerializer.serialize(@message, include_attachments: true, include_sender: true),
      message: 'Message created successfully',
      status: :created
    )
  rescue StandardError => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Failed to create message',
      details: e.message,
      status: :unprocessable_entity
    )
  end

  def update
    @message = message
    previous_status = @message.status
    target_status = permitted_params[:status]
    return invalid_transition_response(previous_status, target_status) unless perform_status_update(target_status)

    success_response(
      data: MessageSerializer.serialize(@message.reload, include_attachments: true, include_sender: true),
      message: 'Message updated successfully'
    )
  rescue StandardError => e
    error_response(ApiErrorCodes::VALIDATION_ERROR, 'Failed to update message', details: e.message, status: :unprocessable_entity)
  end

  def destroy
    @message = message
    @message.update!(content_attributes: (@message.content_attributes || {}).merge(deleted: true))
    enqueue_provider_delete(@message)

    success_response(
      data: MessageSerializer.serialize(@message, include_attachments: true, include_sender: true),
      message: 'Message deleted successfully'
    )
  rescue ActiveRecord::RecordNotFound
    error_response(
      ApiErrorCodes::RESOURCE_NOT_FOUND,
      'Message not found',
      status: :not_found
    )
  rescue StandardError => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Failed to delete message',
      details: e.message,
      status: :unprocessable_entity
    )
  end

  def retry
    @message = message

    # Reset to :sent directly (StatusUpdateService would reject the no-op
    # `sent → sent` Wisper publish anyway). Channel webhooks emit the
    # subsequent delivered/read events through the canonical funnel.
    # O cartão de contato encaminhado precisa seguir como cartão, não como texto.
    forwarded = @message.content_attributes.to_h.slice('forwarded', 'shared_contacts')
    @message.update!(status: :sent, content_attributes: forwarded['forwarded'] ? forwarded : {})

    ::SendReplyJob.perform_now(@message.id)

    success_response(
      data: MessageSerializer.serialize(@message.reload, include_attachments: true, include_sender: true),
      message: 'Message retry completed successfully'
    )
  rescue StandardError => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Failed to retry message',
      details: e.message,
      status: :unprocessable_entity
    )
  end

  def reaction
    @message = message
    emoji = params[:emoji]
    refusal = reaction_refusal(emoji)
    return reaction_failed(refusal) if refusal
    return reaction_failed('provider_failed') unless reaction_provider.send_reaction(@message, emoji)

    Messages::ReactionService.new(@message, emoji: emoji, from: 'me', user_id: Current.user&.id).perform

    success_response(
      data: MessageSerializer.serialize(@message.reload, include_attachments: true, include_sender: true),
      message: 'Reaction updated successfully'
    )
  rescue ActiveRecord::RecordNotFound
    error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Message not found', status: :not_found)
  end

  def forward
    ids = forward_target_ids
    return forward_failed('invalid_targets') unless ids

    targets = ids.map { |id| forward_target(id) }
    return forward_failed('invalid_target') unless targets.all?
    return forward_failed('unsupported_channel') unless targets.all? { |target| evolution_conversation?(target) }

    service = Messages::ForwardService.new(message, targets: targets.uniq, sender: Current.user || @resource)
    refusal = service.refusal
    return forward_failed(refusal) if refusal

    forward_created(service.perform)
  rescue ActiveRecord::RecordNotFound
    error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Message not found', status: :not_found)
  rescue ActiveRecord::RecordInvalid
    forward_failed('creation_failed')
  end

  private

  def forward_target_ids
    ids = params[:target_conversation_ids]
    return unless ids.is_a?(Array)

    ids = ids.map(&:to_s).uniq
    ids if ids.size.between?(1, MAX_FORWARD_TARGETS)
  end

  # Mesma regra da conversa de origem (ver BaseController). Inexistente e sem acesso respondem igual.
  def forward_target(id)
    return unless id.match?(TARGET_ID_PATTERN)

    target = resolve_conversation(id)
    return unless target
    return target if policy(target.inbox || target).show?
  end

  def evolution_conversation?(target)
    channel = target.inbox&.channel
    channel.is_a?(Channel::Whatsapp) && channel.provider == 'evolution'
  end

  def forward_created(messages)
    success_response(
      data: MessageSerializer.serialize_collection(messages, include_attachments: true, include_sender: true),
      message: 'Message forwarded successfully',
      status: :created
    )
  end

  def forward_failed(details)
    error_response(ApiErrorCodes::VALIDATION_ERROR, 'Failed to forward message', details: details, status: :unprocessable_entity)
  end

  def reaction_refusal(emoji)
    return 'invalid_emoji' unless single_emoji_or_blank?(emoji)
    return 'unsupported_channel' unless reaction_provider
    return 'unsupported_message' if @message.private? || @message.activity? || @message.source_id.blank?
  end

  # Texto vazio remove a reação; fora isso, exatamente um emoji.
  def single_emoji_or_blank?(emoji)
    return false unless emoji.is_a?(String)

    emoji.empty? || (emoji.each_grapheme_cluster.count == 1 && !emoji.ascii_only? && emoji.match?(/\p{Emoji}/))
  end

  def reaction_provider
    channel = @conversation.inbox&.channel
    return unless channel.is_a?(Channel::Whatsapp)

    provider = channel.provider_service
    provider if provider.respond_to?(:send_reaction)
  end

  def reaction_failed(details)
    error_response(ApiErrorCodes::VALIDATION_ERROR, 'Failed to react to message', details: details, status: :unprocessable_entity)
  end

  # EVO-1891: when an agent deletes an OUTGOING message, revoke it on the provider
  # (delete-for-everyone) where supported. Done in a background job so a slow or
  # unreachable provider never blocks/delays the CRM soft-delete response.
  def enqueue_provider_delete(message)
    return unless message.outgoing?

    channel = message.conversation&.inbox&.channel
    return unless channel.respond_to?(:delete_message)

    Whatsapp::DeleteMessageOnProviderJob.perform_later(message.id)
  end

  def perform_status_update(target_status)
    Messages::StatusUpdateService.new(@message, target_status, permitted_params[:external_error]).perform
  end

  def invalid_transition_response(previous_status, target_status)
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Invalid status transition',
      details: "#{previous_status} → #{target_status}",
      status: :unprocessable_entity
    )
  end

  def message
    @message ||= @conversation.messages.find(permitted_params[:id])
  end

  def message_finder
    @message_finder ||= MessageFinder.new(@conversation, params, includes: message_includes)
  end

  def message_includes
    @message_includes ||= [
      :sender,
      :conversation,
      :inbox,
      :attachments
    ]
  end

  def permitted_params
    params.permit(:id, :status, :external_error)
  end

  # API inbox check
  def ensure_api_inbox
    # Only API inboxes can update messages
    return if @conversation.inbox.api?

    error_response(
      ApiErrorCodes::FORBIDDEN,
      'Message status update is only allowed for API inboxes',
      status: :forbidden
    )
  end

  def attach_canned_response_files
    canned = CannedResponse.find_by(id: params[:canned_response_id])
    return unless canned

    canned.attachments.find_each do |att|
      new_att = @message.attachments.build(
        file_type: att.file_type,
        extension: att.extension,
        fallback_title: att.fallback_title,
        meta: att.meta,
        external_url: att.external_url
      )

      # reuse the SAME blob from ActiveStorage (no re-upload)
      new_att.file.attach(att.file.blob) if att.file.attached?
      new_att.save!
    end
  end
end
