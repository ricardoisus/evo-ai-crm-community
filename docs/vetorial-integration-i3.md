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

## J10 — sessões de teste

`POST /api/v1/vetorial_agents/:id/test_sessions` recebe `revision_id` (inclusive draft), propósito, critério, amostra 3–5, `budget_usd` decimal (padrão 0.05, máximo 0.50), `max_turns` (1–20) e Idempotency-Key. GET `.../:session_id`, POST `.../:session_id/messages` (`text`, chave UUID) e POST `.../:session_id/close` respeitam dono/admin, grant read/update e todas as caixas do perfil. Criação não chama modelo. Revisão/hash/snapshot são congelados, inclusive se o draft mudar depois. Sessão dura 30min; fechamento não libera reserva incerta.

Única autoridade financeira: `sandbox_budgets/sessions/calls` no runtime. Rails guarda autorização, plano e transcrição sintética, sem ledger financeiro; valores exibidos vêm do runtime. Ponte privada HMAC por método/caminho: POST `/test_sessions/manage` (create/show/close) e `/test_sessions/:uuid/turns`. UUID de sessão nasce no CRM e reentrega da criação não aloca duas vezes. Intent unknown é commitado antes do HTTP; retry da mensagem mantém UUID, texto e reserva; ACK perdido não autoriza nova chamada cega.

Nesta etapa só existe `simulation`, US$0, com `SimulationModel` sem cliente HTTP/chave. Usa montagem de prompt/modelo e validação de saída do OpenAI real, para ambos os papéis; resposta é identificada como simulação. Browser não escolhe modo, destinatário, URL ou credenciais. Estimador offline usa tarifa versionada, limite integral do contexto serializado/saída e UTF-8/escaping conservadores antes de construir o modelo; configuração sem limite confiável recusa 429. Não há mídia/rede nem ferramentas live neste transporte. Adaptadores FakeCRM/FakeAgenda/NoopTransport e histórico são isolados de quota 20/h e métricas live. Ativar inferência paga não faz parte desta implementação/autorização.

Validação integrada opcional: com runtime sintético HTTP local, `VETORIAL_TEST_HTTP_URL=http://127.0.0.1:58991` junto ao comando RSpec normal inclui o teste real HMAC. Secret exclusivo sintético `synthetic-j10-secret-` repetido três vezes; nunca usar secret de produção. Runtime criado com `create_app(Store(sqlite_temporario), Policy('synthetic', frozenset()), secret_sintetico)` e DDL só no banco temporário.

## J11 — catálogo C2 e matriz dos contratos

O catálogo retorna o envelope completo do Core em `data.native`, sem alterar dados, paginação, filtros AND/OR ou meta. `data.managed` é um grupo fixo, ordenado, com os perfis da caixa autorizada em todas as páginas; busca/modo/saúde/origem são aplicados no servidor. Pasta oculta os gerenciados. O total da interface é `native.meta.total + managed.length` (usando o campo de total original do Core). Origem runtime não consulta o Core; Core indisponível retorna native=null e meta.partial=true/unavailable_sources=["core"]; 401/403 são propagados. Não se compõem offsets entre origens.

A matriz roda como requests HTTP reais de Rails; autenticação e consulta remota de grants usam dublês, mas callbacks de permissão, escopo, validação, transações e respostas são reais. "Agente" tem os grants indicados, sem ser administrador. Sem grant resulta em 403 antes de carregar dados; fora da caixa resulta em 404 nas rotas de perfil/conversa e grupo gerenciado vazio no catálogo.

| Rotas | Admin com grant | Agente com grant | Sem grant | Concorrência PostgreSQL |
|---|---|---|---|---|
| GET agent_catalog | 200 | 200 | 403 | Três conexões por perfil; grupo fixo, sem escrita |
| GET perfil, revisions, revisions/:id, metrics, integrations | 200 | 200 | 403 | Três conexões por perfil; nenhuma alteração de revisão/auditoria |
| POST activation_challenges | 200 | 403 | 403 | Admin recebe três nonces distintos; agente/sem grant recusados |
| POST revisions e restore; publish; PUT activation e binding | Aceita entrada válida | 403 | 403 | Mesma chave: três 200 com data idêntica e uma auditoria; chaves distintas com If-Match igual: um 200/dois 409 |
| POST test_sessions | 200 | 200 | 403 | Admin/agente: uma sessão e uma alocação para a mesma chave |
| GET test_sessions/:id; POST messages e close | 200 para caixa/dono | 200 para dono | 403 | Admin/agente: leitura/fechamento simultâneos; mensagem repetida mantém uma entrada; runtime deduplica efeitos por request_id |
| GET conversa/vetorial_ia; POST pause e resume | 200 | 200 | 403 | Admin/agente: leituras 200; CAS da mesma versão permite um comando e recusa dois com 409; sem grant não muda estado |
| GET internal config e integrations | HMAC, independente de papel | HMAC, independente de papel | Sem HMAC: 401 | Três leituras HMAC simultâneas; configuração completa/integrations sem corpo |
| POST internal telemetry | HMAC | HMAC | Sem HMAC: 401 | Matriz J6 preservada: quatro conexões, uma ingestão/auditoria por chave |
| GET/POST internal conversa | HMAC + caixa fixa + fence | HMAC + caixa fixa + fence | Sem HMAC: 401 | Guardas/recibos da ponte preservados; sem autoridade por papel de usuário |

Entradas inválidas atravessam a mesma matriz: draft com secret em limits/provider/runtime ou modelo Astra retorna 422 sem persistir nem ecoar o segredo; sessão inexistente/fora do dono retorna 404; nonce e vínculo inválidos mantêm as recusas J9. O binding concorrente usa dublê de caixa WhatsApp já anexada (sem criar vínculo nem chamar Evolution); o sandbox HTTP usa dublê HMAC do runtime, cuja concorrência financeira real é verificada em pytest/PostgreSQL.

Evidências executáveis: `spec/requests/internal/vetorial_agent_{api_matrix,catalog,concurrency_matrix,assignment,activation,test_sessions,telemetry,configuration,integrations}_spec.rb` e `vetorial_agent_spec.rb`, `spec/services/vetorial_agent/{snapshot_contract,catalog_proxy,configuration,bridge}_spec.rb` e suíte runtime.

O contrato fechado está em `config/vetorial_snapshot.schema.json` (fonte) e na cópia técnica idêntica `services/vetorial-agente/vetorial_agent/snapshot.schema.json` do runtime, necessária à validação independente e incluída no pacote Python. Mudanças devem atualizar os dois e conferir igualdade byte a byte. São fechados os blocos de comportamento, vínculo, ativação, integrações, limites, provedor/runtime e a linguagem de schemas/ações, incluindo keywords aninhadas e referências somente locais. Objetos vazios legados em limits/provider/runtime preservam os defaults versionados existentes; campos fornecidos têm tipo, enum e teto explícitos. IDs são identificadores opacos limitados; UUID/FKs são impostos pelo CRM. O contrato A14 completo continua válido. Ruby e Python recusam expediente sobreposto e piloto sem lista.

A migração 20261113130000 impõe epoch/versão positivos, enum de origem/papel/status, número/hash/payload de revisão e FK composta que impede apontar para revisão de outro deployment. Aplicação e reversão foram exercitadas somente no banco sintético. Respostas de mutações são normalizadas para JSON antes da auditoria, mantendo a primeira resposta idêntica ao replay (inclusive timestamps).
