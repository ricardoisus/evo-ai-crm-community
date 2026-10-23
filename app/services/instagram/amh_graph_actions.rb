# frozen_string_literal: true

# Reserved graph actions reuse existing transports, receipts and signed links.
module Instagram::AmhGraphActions
  Unavailable = Instagram::AmhExecutor::Unavailable

  def material
    parameters = @node['data']
    begin
      choice = Instagram::AmhGraph.resolve_material(@payload, parameters)
    rescue Unavailable
      raise unless parameters['mode'] == 'context'

      choice = Instagram::AmhGraph.resolve_material(@payload, parameters, cached_caption)
    end
    @row.update!(resolved_material: choice.first, routing_source: choice.last)
    ['success', 'passed', "Material resolvido: #{choice.first}"]
  rescue Unavailable, Net::ReadTimeout, Net::OpenTimeout, SocketError
    ['blocked', 'blocked', 'Material sem correspondência segura']
  end

  def cached_caption
    @event.with_lock do
      cached = Instagram::AmhContextRouter.load_context(@event) || {}
      unless cached.key?('caption')
        cached.merge!(Instagram::AmhContextRouter.fetch_context(@event, @inbox))
        @event.update!(encrypted_routing_context: Instagram::AmhInboundEvent.encryptor.encrypt_and_sign(cached))
      end
      cached['caption']
    end
  end

  def invitation
    @row.update!(state: 'prompt_sending', prompt_state: 'sending', reason: 'invitation_reserved')
    active!
    result = Instagram::AmhPrivateReply.prompt(channel: @inbox.channel, comment_id: @event.contract['event_id'],
                                               text: invitation_text,
                                               payload: Instagram::AmhConfirmationToken.issue(@row))
    persist_invitation(result)
    outcome(result.state, result.reason)
  end

  def invitation_text
    Instagram::AmhInvitation.render(text: @node['data']['text'], contract: @event.contract, inbox: @inbox)
  end

  def persist_invitation(result)
    accepted = result.state == 'accepted'
    @row.update!(state: accepted ? 'pending' : "prompt_#{result.state}", prompt_state: result.state, reason: result.reason,
                 encrypted_prompt_receipt: encrypted(result.receipt), prompt_accepted_at: accepted ? Time.current : nil,
                 prompt_expires_at: accepted ? 7.days.from_now : nil)
  end

  def public_reply
    raise Unavailable unless @row.prompt_state == 'accepted'

    variants = @node['data'].fetch('variants')
    index = Digest::SHA256.hexdigest("#{@event.id}:#{@row.version_id}").to_i(16) % variants.size
    return outcome('blocked', 'reply_rate_limited') unless reserve_public(index)

    active!
    response = Instagram::AmhPublicReply.request(@inbox.channel, @event.contract['event_id'], variants[index])
    Instagram::AmhPublicReply.persist(@row, response)
    outcome(@row.public_reply_state, @row.public_reply_reason)
  end

  def reserve_public(index)
    Instagram::AmhVisualProof.with_mapping_lock do
      if Instagram::AmhDelivery.where('public_reply_requested_at > ?', 5.seconds.ago).count >= 40
        @row.update!(public_reply_state: 'blocked', public_reply_reason: 'reply_rate_limited')
        next false
      end
      @row.update!(public_reply_state: 'sending', public_reply_requested_at: Time.current, public_reply_variant: index)
      true
    end
  end

  def like
    @row.update!(like_state: 'pending')
    Instagram::AmhCommentLike.call(delivery: @row, explicit_test: @explicit_test)
    outcome(@row.reload.like_state, @row.like_reason)
  end

  def deliver
    raise Unavailable unless @row.confirmation_event_id && @row.prompt_state == 'accepted'

    link = material_link
    @row.update!(state: 'sending', reason: 'confirmed_delivery_reserved')
    active!
    result = Instagram::AmhPrivateReply.deliver(channel: @inbox.channel, recipient_id: @event.contract.dig('identity', 'igsid'),
                                                text: @node['data']['text'], url: link.fetch(:url), label: @node['data']['buttonLabel'])
    @row.update!(state: result.state, reason: result.reason, encrypted_receipt: encrypted(result.receipt))
    outcome(result.state, result.reason)
  end

  def material_link
    key = OpenSSL::HMAC.hexdigest('SHA256', Rails.application.key_generator.generate_key('amh-link-event-v1'),
                                  JSON.generate(@payload.values_at('account', 'app', 'comment')))
    Instagram::AmhShortLink.issue_unique!(key, @version, @row.resolved_material, @payload)
  end

  def encrypted(receipt)
    receipt && Instagram::AmhInboundEvent.encryptor.encrypt_and_sign(receipt)
  end

  def finish
    [nil, 'passed', 'Caminho encerrado']
  end
end
