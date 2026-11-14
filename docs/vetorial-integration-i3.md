# Integração I3: base parcial, sem autorização de implantação

Data: 12/11/2026. Etapa: I3. Autor: Theo, CTO · Codex Sol.
Status: **INCOMPLETA**. PR em rascunho. Não usar como backend final da I4.
Fontes: plano da frente §8; I1 §§3–10; I2 C1–C14, na pasta Evo CRM Agentes.

## Implementado

- Migração aditiva para deployment, dois perfis, revisões, auditoria idempotente e heartbeat.
- Canonicalização compartilhada UTF-8, inteiros, acentos/emoji/CRLF; hash sem lease.
- Revisões publicadas imutáveis pelo modelo; CAS e chave idempotente por deployment/ação, resposta 24h.
- Importador explícito, dry-run por padrão; não cria AgentBotInbox nem consulta produção.
- Catálogo separado em managed/native, repasse do envelope nativo; perfil e versões sob escopo de inbox.
- Guardas no listener, default, jobs de inatividade e envio; comandos sem revisão recusados depois de control_source=crm.
- Pausa/devolução transacional preservando status e sem envio de histórico. Remoção de responsável recusada na API até autorização específica implementada.
- Endpoints de leitura de snapshot HMAC, sem 304; lease de 120s.

## Endpoints provisórios presentes

- GET /api/v1/agent_catalog
- GET /api/v1/vetorial_agents/:id
- GET/POST /api/v1/vetorial_agents/:id/revisions
- GET /api/v1/vetorial_agents/:id/revisions/:revision_id
- POST .../:revision_id/publish e .../:revision_id/restore
- GET /api/v1/conversations/:conversation_id/vetorial_ia
- POST .../vetorial_ia/pause e .../vetorial_ia/resume
- GET /internal/vetorial_agent/config/:deployment_id

Mutações de revisão: Idempotency-Key + If-Match (lock_version); publicar/reverter requer update+admin.
Não há contrato final para a I4: estes endpoints ainda precisam dos casos completos de request/concorrência.

## Pendências que impedem o aceite da I3

| Origem | Ação do próximo Theo |
|---|---|
| I1 R3 / I2 C3–C5 | Ligar cache ao worker/adapters/store; remover fontes de comportamento env/arquivo; fixar snapshot por execução e incluir fence em todos os efeitos, inclusive agenda |
| I1 R5/R6 | Implementar schema/ingestão/outbox de execuções, usage durável, métricas e probes sanitizados; heartbeat ainda só tem tabela/DTO |
| I1 R7 / I2 C14 | Implementar sandbox sem acesso ao transporte live e reserva de orçamento concorrente/durável; nenhuma API de teste está implementada |
| I1 R2 | Implementar ativação/desafio all, alteração de parâmetros/integrações, expediente validado, binding HTTP e autorização da remoção de responsável |
| I2 C1 | Marcador e comando concluídos na J4 abaixo; ensaio rolling integrado continua pendente |
| I1 §9 / I2 C1/C7 | Ensaiar A14→compatível→CRM e rollback, inclusive sobreposição, fila/rascunho/recibo; o teste isolado de default não substitui esse ensaio |
| I1 §9 | Importar snapshot real observado em memória, verificar identidade/pipeline/hash e valores efetivos; atual teste cobre bytes dos prompts/contratos e valores conhecidos, não equivalência completa de execução |
| I1 §10 | Completar schemas fechados aninhados, constraints e matriz de autorização/idempotência/concorrência de todos os endpoints; não promover guardas parciais como prova integral |
| I2 C9 | Atualizar operação pela interface no runbook somente após a interface/backend completos; A14 continua vigente |

Não há deploy, merge, alteração de Evolution, chamada paga ou mensagem externa nesta etapa.

## J1 — Ambiente de testes verde

Data: 13/11/2026. Autor: Theo, CTO · Codex Sol. Status: implementado e testado localmente; sem deploy.
Fonte: entrega `I3-backend-runtime.md` §J1 da frente Evo CRM Agentes.

Ruby local 3.4.10 (`.ruby-version`); Gemfile aceita patches 3.4 a partir de 3.4.4, preservando compatibilidade com o Dockerfile atual. Lock recomposto sem atualização de gems.

```sh
cd /Users/ricardohenrique/Projetos/evo-crm/_evo-i3-crm
docker start evo-i3-postgres evo-i3-redis
# No Mac: evitar OpenSSL 4 ao compilar a gem openssl 3.2.0 fixada no lock.
BUNDLE_BUILD__OPENSSL=--with-openssl-dir=/opt/homebrew/opt/openssl@3 bundle install
bundle check
RAILS_ENV=test POSTGRES_HOST=127.0.0.1 POSTGRES_PORT=55439 POSTGRES_DATABASE=evo_i3_test POSTGRES_USERNAME=postgres REDIS_URL=redis://127.0.0.1:56389 SECRET_KEY_BASE=synthetic-j1-local-only bundle exec rspec spec/services/vetorial_agent spec/controllers/api/v1/vetorial_agents_controller_spec.rb spec/requests/internal/vetorial_agent_spec.rb spec/requests/internal/vetorial_agent_configuration_spec.rb
```

Resultado: 32 exemplos, zero falhas. Banco preexistente exclusivamente sintético; nenhum reset/schema load necessário. Docker permanece aberto por instrução J1. Isso resolve o ambiente, sem conceder aceite às implementações pendentes I31–I34.


## J4 — Boot, vínculo seguro e off na transição

Data: 13/11/2026. Etapa: J4. Autor: Theo, CTO · Codex Sol. Status: implementado/testado, não implantado.
Fontes: I2 §2 C1/C6; I1 §§2.2/9; entrega I3 §J4.

- `after_initialize` executa GuardBoot: marca deployments existentes, sem criar vínculo e sem exigir schema antes da migração. Importar deployment depois do boot exige novo boot guardado. Escrita comum de `guard_ready=true` é recusada pelo modelo.
- `Binding.attach!` recarrega sob lock, exige flag persistida e inventário injetável dos dois serviços. Exige digest imutável e ao menos uma task running nova por serviço. Qualquer task antiga não terminal (inclusive running/starting) recusa, mesmo com flag. Histórico terminal não impede.
- Comando explícito, separado de migração/deploy: `bundle exec rails runner script/vetorial_agent_bind.rb DEPLOYMENT_ID IMAGE@sha256:DIGEST < inventory.json`.
- Operador coleta inventário fresco completo no manager com `docker service ps --no-trunc --format '{{json .}}' NOME_DO_SERVICO` para CRM e Sidekiq. Não usar filtro desired-state; uma task com desired shutdown ainda pode estar running. Converte `CurrentState` para primeiro termo minúsculo em `state`, `Image` em `image`; JSON final: `{"crm":[{"state":"running","image":"...@sha256:..."}],"sidekiq":[...]}`. Não reutilizar snapshot antigo; não embutir secrets. Coleta é responsabilidade do operador; binding não consulta Swarm nem altera serviço.
- Guardas de listener/default/inatividade existentes preservadas. SendJob existente revalida Policy antes do transporte; teste J4 enfileira com piloto ativo e desliga durante legacy_transition: descarta sem construir transporte. Novo comando também recusado.
- RSpec do comando J1: 36 exemplos, zero falhas, zero pendentes. Inclui ausência de flag, flag com task antiga running/starting, sucesso/idempotência com tudo novo, default/listener preservados e off na fila.
- Sem produção, API paga ou evento real. C1 ensaio rolling completo permanece para etapa própria; não é aceite integral I3.

## J8 — integration status and response privacy

`GET /api/v1/vetorial_agents/:id/integrations` requires `ai_agents.read` and the same
inbox scope as the profile. Its closed DTO contains only `openai`, `groq`, `calendly`,
`google_gateway`, `evolution`, each `configured|absent|error`. Missing, future or
older-than-90s heartbeats and legacy `unverified` values become `error`. No URLs,
credentials, phones, provider bodies or exception messages are returned.

Runtime probes feed the existing HMAC heartbeat. Evolution stays under CRM ownership:
`GET /internal/vetorial_agent/integrations/:deployment_id` requires path-bound HMAC,
uses only `ExistingInstanceClient#instances` and returns empty 200/204/503 for
configured/absent/error. It never connects/reconnects an instance or changes a webhook.
Apply `20261113100000_add_vetorial_pricing_version` before accepting new runtime usage.
`pricing_version` is optional for old outboxes; the only accepted new reference is
`2026-11-13.v1`. It records the catalog consulted, not a confirmed invoice. Usage cost
remains `unknown/null` pending later authoritative reconciliation; retries remain immutable.

The test response sweep wraps both Rails controller families, including failures,
and rejects seeded opaque secrets, tokens, full provider phone and authenticated URL
canaries, plus OpenAI/Groq/Bearer patterns. Integration DTOs reject any full E.164 phone.
Operational private snapshots retain the allowlists needed to execute the existing
contract; this sweep does not remove legitimate configuration data or scan unrelated
customer/contact APIs. Malicious provider fields and stale/poisoned statuses are tested.

### J9 — operational controls (synthetic acceptance, 2026-11-13)

Admin plus `ai_agents.update` and every bound inbox are required for challenge,
activation and binding. `POST /api/v1/vetorial_agents/:id/activation_challenges`
returns `nonce`, `expires_in: 60`, `phrase`. PUT `activation` accepts `mode`, optional
shared `allowlist`/`internal_numbers`; all requires `nonce`, exact typed
`phrase: ATIVAR PARA TODOS`, and boolean `confirm: true`. Challenges are persisted
in audits, scoped to actor/profile/published hash, and consumed within the same
transaction as revision/epoch publication. Expiration, invalid scope or confirmation
returns 422; CAS conflict is 409. Mutations require If-Match and Idempotency-Key;
replaying a successful identical request returns its stored result without another
publication. Pilot needs a nonempty E.164 allowlist. Other role and human pauses
are preserved. During legacy transition only off without list edits is permitted.

PUT `binding` accepts the complete `binding` object, including nullable pipeline_id.
It also requires `pipelines.read`, an inbox visible to the actor, a locally attached
Evolution WhatsApp channel and an existing matching AgentBotInbox. It cannot create
or replace a native association: initial attachment still requires the separate
boot/task-inventory verified command. Pipeline existence is checked under the
installation's existing global pipeline permission. No Evolution calls are made.

Office hours are edited through draft/publish: enabled windows are required,
nonoverlapping, same-day `HH:MM` intervals, with `weekday` 0 (Monday) through 6.
Timezone stays America/Sao_Paulo; disabled hours require an empty array.
Explicit boolean `clear_assignee: true` on resume uses the existing native assignment
grant, `conversations.update`; no new Auth permission is invented. It clears only
the assignee and preserves commercial status/read state. Without the choice a human
assignee causes 409. The all-mode acceptance tests use synthetic data exclusively.
