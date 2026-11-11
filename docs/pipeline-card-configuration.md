# Configuração de cartões por pipeline

Data: 11/11/2026. Etapa: U3. Autor: Theo, CTO · Codex Sol.
Status: implementado/testado localmente; sem merge/deploy.
Fontes: `app/services/pipelines/card_configuration.rb`, `app/controllers/api/v1/pipelines_controller.rb`, migração `20261112010000` e spec de requisição correspondente.

GET `/api/v1/pipelines/:id` retorna `card_configuration`, `card_configuration_revision` e `card_field_definitions`. O padrão do banco é `{}`/0, interpretado pelo frontend como padrão v1. Definições globais do contato/negócio e definições locais do pipeline/etapas compõem o catálogo autorizado. IDs personalizados usam a chave do atributo, que também indexa os valores.

PATCH na mesma rota recebe:

```json
{"pipeline":{"card_configuration":{"version":1,"density":"compact","fields":[{"id":"title","visible":true},{"id":"value","visible":true}]},"card_configuration_revision":0}}
```

- Permissão `pipelines.update`, política de escrita e escopo de pipeline acessível. Um usuário sem escrita recebe401 segundo o handler Pundit atual; RBAC remoto pode rejeitar antes com403. Pipeline privado alheio retorna404.
- Título obrigatório, visível e primeiro; campos únicos; versão1; densidade comfortable/compact; visibilidade booleana. Payload inválido422.
- Revisão é comparada dentro de `with_lock`; salvar incrementa uma vez. Revisão ausente/desatualizada409, sem sobrescrever configuração.
- Campo removido do catálogo pode permanecer apenas se já estava salvo; editor mostra “Campo removido”, permite excluir e não o renderiza no cartão.
- A escrita altera somente configuração/revisão. Preserva `custom_fields`, negócio e contato. Outra pipeline permanece independente.
- Projeção do item inclui canal/origem, atividade da conversa mais recente e primeira tarefa pendente por vencimento. Aproveita preloads do quadro; nenhum GET por cartão. Teste de seis negócios limita tarefas a quatro SELECTs (um preload + três agregações legadas).
- Este schema não possui `account_id` em pipelines. O novo teste prova acesso privado entre usuários; não prova roteamento entre instalações/bancos distintos.

Validação local:34 exemplos em `pipeline_card_configuration_spec.rb`, `pipeline_spec.rb` e `pipeline_item_spec.rb`; novos arquivos passam RuboCop. Arquivos legados modificados ainda têm dívida de lint; não houve reformatação geral.

Deploy futuro U6: backup e fluxo Portainer/GHCR do monorepo; aplicar a migração aditiva antes dos serviços e do frontend. Reversão de aplicação mantém as duas colunas, para preservar configurações; voltar aos digests anteriores registrados pela etapa de deploy. Nenhuma alteração em produção nesta U3.
