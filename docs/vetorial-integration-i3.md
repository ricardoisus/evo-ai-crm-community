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
| I2 C1 | Implementar marcador de boot guard_ready e comando operacional separado que verifica inventário de tasks; booleano de entrada no serviço NÃO é prova operacional |
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
