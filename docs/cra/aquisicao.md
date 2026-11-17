# Aquisição CRA

16/11/2026 · Theo/Codex · implementação para revisão, sem implantação.
Fonte: CRA `entregas/R3-spec.md` §§8.1–8.4 e R4; contrato n8n `integracoes/cra/crm.mjs` (S5).

`CRA_ACQUISITION_ENABLED` é `false` por ausência. A regra precisa de `acquisition_scope_key=client:cra`, domínio exato e caixa Evolution anexada com `attached_instance_id=23bd65f3-4d85-47d4-9ec1-09875fdc59ec`. Uma regra não excluída por escopo. Scope não pode ser removido por edição. Não executar backfill.

O contato compartilhado não recebe campos CRA. Primeiro ingresso na caixa/intake cria `lead_acquisition_scope_events`; contato antigo de outra caixa é permitido, conversa CRA anterior ao corte é inelegível. O índice global legado permanece. CTWA e metadados allowlisted ficam na mensagem/evento; payload/texto do anúncio não é copiado. A jornada hex48 usa o codec de 384 bits do site. CTWA base64url ASCII e LID alternativo são aceitos no ramo CRA.

Primeira mensagem orgânica encerra sem aquisição. Código válido sem snapshot aguarda prova da própria mensagem por24h. Enrichment é evidência autenticada do banco de tracking, nunca dado confiado ao navegador. Mesma mensagem, visitor, site_event, domínio e consentimento são exigidos. O sinal bruto permanece imutável. Somente ProcessScopedEvent cria negócio; o receptor de enrichment não cria contato/negócio. Primeiro form e mensagem concorrentes convergem sob lock do contato. Regras/jobs revalidam ativação e destinos; negócio aberto no pipeline CRA preserva owner/etapa/título/valor. Unique rule/contact impede recriação após fechamento.

## Contratos

- `/public/lead_automation_rules/:id/leads`: v1 legado preservado para regra sem scope. CRA usa v2, Bearer intake, Origin HTTPS exato, UUID event_id igual ao Idempotency-Key, opt-in de contato separado. `contact.phone_number` E.164, não `phone`. Acquisition opcional com visitor, first/last touch e consentimento explícito. Unknown keys recusadas; sem analytics, omitir acquisition (não enviar null).
- `/public/lead_automation_rules/:id/acquisitions`: servidor somente, sem Origin/CORS. Bearer enrichment diferente, até16KiB, schema version1, Idempotency-Key `acquisition_id:revision`. Instância CRA fixa. Digest canônico: igual=no-op, diferente=409; revisões antigas superseded, mudança de identidade=409. Não há IDs de negócio/contato/destino escolhidos pelo request. Pending reanexa via SweepJob existente,24h e depois review.
- `POST /api/v1/lead_automation_rules/:id/rotate_token` com revision e `purpose=enrichment` em regra CRA emite segredo exclusivo; ausência purpose mantém intake legado. Resposta no-store; persistência SHA256. Admin+permissão+pipeline exigidos. Provisionar apenas por vias privadas de deploy.
- `GET /api/v1/pipelines/:pipeline_id/pipeline_items/:id/acquisition`: admin + leitura pipeline + caixa; retorna somente últimos4caracteres mascarados de CTWA/visitor, no-store. Serializer/cartão/socket/webhook nunca entregam identificadores brutos. Sem acesso CRA, campos `cra_` são removidos do serializer.

Projeção plana `cra_` no negócio; first/last touch/consent estruturados em detalhes. CTWA/visitor brutos permanecem na auditoria restrita e nunca entram nos custom_fields. Catálogo local usa `Pipelines::CardConfiguration`, sem definição global. Na promoção, após criar regra, executar `LeadAutomations::CraProjection.configure_pipeline!(rule)` apenas no pipeline CRA; padrão origem/campanha/anúncio/responsável. Demais campos simples escolhíveis. Fontes desconhecidas não são inventadas; nomes têm fallback para IDs na UI. Links do anúncio só HTTPS Meta allowlisted, com noreferrer; texto escapado pelo React.

Edição humana de campos derivados fica em `cra_manual_fields` e não é sobrescrita. Identidade técnica e first touch estruturado são preservados pelo modelo. Atualização automática usa lock e `update_columns` para não disparar callbacks de mensagem, Flow, agentes, owner, etapas ou etiquetas. Duas famílias não substituem a aquisição principal.

## Promoção e reversão (S9, após Helena)

1. Backup privado do banco/config/imagens e conferir HEAD aprovado; não usar dump sobre banco vivo.
2. Manter flag false. Aplicar migrações `20261116220000` e `20261116220100` antes dos serviços. Segunda usa índices CONCURRENTLY fora de transação; nunca executar com wrapper de transação DDL. Primeira relaxa somente event_id de runs para permitir scope_event_id, preservando índice global de eventos.
3. Publicar CRM/Sidekiq e frontend por digest, testar saúde. Anexar instância existente com nome `CR Advogados`; paths codificados RFC3986. Não chamar create/logout/delete nativo.
4. Criar pipeline privado CRA (Ricardo como criador/owner inicial), regra scoped inativa, catálogo local; tokens intake/enrichment separados em credentials n8n exatos. Habilitar flag CRM/Sidekiq somente na promoção ordenada. Garantir SweepJob existente em execução. Fazer ensaio sintético servidor→CRM, sem formulário público e sem mensagem enviada.
5. Reversão: flag false, regra CRA inativa e emissores pausados; imagens anteriores, mantendo tabelas/índices/recibos. Não apagar caixa, instância ou dados. Nunca migrar down com dados de produção; `event_id NOT NULL` antigo é incompatível com runs scoped e impede down destrutivo acidental.

Ensaio local: up→down→up em banco sintético vazio, índice legado único preservado. Reversão operacional em seco: flag off provada por teste, sem evento scoped, negócio ou queda no legado. Produção/backup real/digests são S9, não foram executados nesta etapa.

## Validação reproduzível

Banco exclusivo de teste PostgreSQL16, Redis exclusivo; nenhum serviço/credencial de produção. Ruby3.4/Gems do projeto. Variáveis POSTGRES_HOST/PORT/DATABASE/USERNAME apontam ao ambiente sintético; REDIS_URL exclusivo; SECRET_KEY_BASE sintético.

```sh
RAILS_ENV=test bundle exec rspec spec/services/lead_automations spec/models/lead_automations_spec.rb spec/requests/lead_automation_intake_spec.rb spec/requests/cra_acquisition_spec.rb spec/services/evolution spec/requests/api/v1/lead_automation_rules_spec.rb spec/requests/api/v1/pipeline_card_configuration_spec.rb
```

S6:116 exemplos verdes, incluindo duas conexões reais form+mensagem/processamento, v1, tokens separados, prova tardia/recusa, orgânico, conversa antiga, privacidade e U3. Frontend tem testes de fonte/fallback/link allowlist/escaping/segredos, lint de arquivos tocados e build. Revisão Helena e validação real continuam necessárias.


## S8: revisão e correções (16/11/2026)

S7 Helena aprovou a implementação e avaliou a ausência de broadcast da projeção como ajuste de UX aceitável na primeira versão. Mantido `update_columns`: o operador precisa recarregar o cartão para ver enrichment recente. Não ligar callbacks genéricos nem publicar eventos comerciais/Flow para produzir refresh. Um broadcast específico exige nova revisão de RBAC/egress e prova de ausência de automações.

Intake e enrichment **scoped CRA** passam a exigir telefone E.164 de 10–15 dígitos, alinhados ao banco de tracking e API do site. V1 legado preservado. S8 reexecutou 117 exemplos, incluindo rejeição de 7–9 dígitos em ambas as APIs sem persistir contato/enrichment.

O gate de revogação autônoma da S2/S3/S7 permanece aberto; não promover a integração ativa. Desenho e critérios de aceite na seção S8 do módulo original `Vetorial - WhatsApp Tracking/integracoes/cra/README.md` (PR atividades#71). Código aprovado/PR pronto não equivale a liberação de produção; manter flag off e regra inativa enquanto esse gate não estiver implementado, testado e revisado.
