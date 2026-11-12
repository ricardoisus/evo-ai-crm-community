# Anexar uma instância Evolution existente

Operação administrativa aditiva. Não usa `/evolution/authorization`, QR,
connect, logout ou delete. Configuração global Evolution já deve existir.

`POST /api/v1/evolution/attachments` exige `inboxes.create` e corpo JSON com
`instance_name`, `phone_number` (E.164) e `name` (nome exibido).
O serviço GET verifica instância única, número, conexão open e webhook vazio.
Recusa colisões locais de nome/número e webhook existente de outro consumidor.
Depois cria a caixa local, configura somente o webhook e confirma via GET.
Timeout mantém a caixa pending. Repetir os mesmos parâmetros reconcilia pelo
GET, sem apagar nada. Não repetir às cegas com outro nome ou número.

Webhook: `/webhooks/evolution_attached`, header privado `X-Evo-Attach-Token`,
criado em memória pelo serviço e mantido na configuração privada da caixa.
Token não aparece na serialização da caixa, URL ou logs. O envelope é limitado
à instância/evento/data; a API key da Evolution não vai para o job.
Callback sem autenticação é recusado, inclusive pelo trajeto legado.

Recepção de texto/mídia base64 e eco humano usa persistência observada inerte,
com lock da caixa e dedup por source_id. `source=imported` é o mecanismo interno
existente para suprimir callbacks, não uma importação histórica. Apenas eventos
novos com timestamp >= início da anexação são aceitos. Grupos/status broadcast,
histórico, contatos em lote e remetente sem direção são ignorados.
Status entregue/lido atualiza mensagem existente; não emite recibo de leitura.
Mídia base64 até 25 MiB vira anexo; ausência de bytes registra `media_unavailable`.
Nenhuma URL arbitrária da mensagem é baixada. Eventos sem timestamp são rejeitados.

Contatos novos não disparam automações, busca de avatar ou pipeline automático.
Conversa e mensagem observadas só notificam a interface. Nenhum bot é ligado.
A1 deve consumir explicitamente esse trajeto para sua outbox: o listener genérico
de Agent Bot não recebe as observações. Mensagem com `evolution_origin=human_device`
é eco do celular. A1 deve pausá-la conforme o plano antes de responder.

## Reversão

`DELETE /api/v1/evolution/attachments/:channel_id` exige `inboxes.update` e os
mesmos parâmetros. Confere a propriedade integral do webhook antes da alteração.
Desativa só esse webhook, esvazia eventos/headers e confirma por GET. Evolution
não tem DELETE de webhook: fica um registro desativado, sem assinatura ativa.
Caixa, mensagens e instância são preservadas; remoção/desconexão do canal é bloqueada.
Um webhook alterado por terceiro nunca é desativado por essa operação.
Após detach, reanexação automática é recusada: reconciliar explicitamente.

Se a aplicação precisar voltar à imagem anterior, desative primeiro o webhook
por esta versão. Depois restaure a imagem anterior pelo Portainer. Nenhuma
migração de banco é necessária. Não restaurar dump sobre mensagens novas.

## Testes locais

RSpec: `spec/services/evolution/attach_existing_instance_spec.rb`,
`spec/services/whatsapp/attached_evolution_message_service_spec.rb` e
`spec/requests/webhooks/evolution_attached_spec.rb`. Só payloads sintéticos;
WebMock bloqueia rede externa. Regredir também `spec/services/whatsapp/standby_spec.rb`.
