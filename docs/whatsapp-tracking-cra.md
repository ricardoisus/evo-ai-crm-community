# Tracking nativo do WhatsApp na CRA

## Escopo

A primeira operação usa exclusivamente a caixa WhatsApp anexada à instância CRA. Use a regra ativa com escopo `client:cra` e etapa `Pré-Qualificado`. A configuração inicial publica regras para `Lead` no dataset web, `LeadSubmitted` no dataset de mensagens e `QualifiedLead` no dataset da origem selecionada.

A atribuição web usa o marcador existente e o consentimento vigente. O clique CTWA usa o identificador entregue pelo provedor. O módulo usa a mesma chave de deduplicação e o mesmo cálculo do ID da conversão que o legado. A configuração por caixa tem rascunho e publicação independentes. Os recibos mostram resultado e códigos numéricos da Meta.

## Preparação e observação

1. Conclua a revisão dos PRs Rails e frontend. Publique as imagens das revisões integradas e aplique as migrations do Rails pelo fluxo da Stack Portainer. Suba web e Sidekiq com a mesma revisão.
2. Configure as referências com os valores existentes do cofre. Use `WHATSAPP_TRACKING_CRA_DEDUP_SECRET` para a chave de deduplicação da CRA, `WHATSAPP_TRACKING_CRA_SITE_TOKEN` para o cabeçalho da borda, `WHATSAPP_TRACKING_META_CRA_SITE_TOKEN` para o dataset do site, `WHATSAPP_TRACKING_META_CRA_MESSAGING_TOKEN` para o dataset de mensagens e `WHATSAPP_TRACKING_CRA_AD_READ_TOKEN` para a leitura da conta de anúncios. Mantenha os valores fora de arquivos versionados.
3. Execute `whatsapp_tracking:configure_cra` com `WHATSAPP_TRACKING_CRA_INBOX_ID`. O comando ensaia a configuração numa transação revertida. Execute novamente com `WHATSAPP_TRACKING_COMMIT_CONFIGURATION=true` para aplicar. Defina `WHATSAPP_TRACKING_OBSERVE_INBOX_IDS` somente com o ID da caixa CRA.
4. Carregue o estado do site pelo importador com o exportador em [cra-website.sql](whatsapp-tracking/cra-website.sql). Habilite o endpoint `POST /webhook/cra-whatsapp-site-v1` com `WHATSAPP_TRACKING_CRA_SITE_ENABLED=true` e `WHATSAPP_TRACKING_CRA_SITE_MODE=observe` para espelhar eventos e revogações. A entrada CRM espelhada pode ser validada sem criar contatos ou cards.
5. Compare o histórico `observation` com a operação n8n da CRA por ID de evento, origem, nome, dataset, horário e estágio. Compare também resolução de anúncios, regras de consentimento e dados exibidos no card. Teste CAPI com um evento sintético e código de Test Events. Registre os casos de tráfego real que ainda não chegaram. Mantenha o n8n como único emissor durante a observação.

## Virada

1. Verifique profundidade e consumidores das filas dedicadas `cra.site.ingest` e `cra.messages.upsert`, além do estado de `cra.meta_outbox`, `cra.crm_outbox`, `cra.inbound` e `cra.ad_cache`. Identifique pendências elegíveis e preserve as filas e as tabelas existentes.
2. Capture os recibos e o estado do site em transações somente leitura imediatamente antes da virada. Rode os importadores em ensaio. Confira que entregas aceitas, entregas incertas e leases abertos aparecem nas contagens. Leases do legado importados ficam incertos. Não repita uma entrega incerta apenas por ausência no painel Meta.
3. Alterne o destino da borda para o Evo no ponto de transferência de tráfego e desative os consumidores da CRA somente após drenar ou reconciliar as pendências. Trate separadamente a fila do site, o consumidor das mensagens e os cronogramas CAPI e CRM. Preserve a configuração de origem e uma cópia dos estados de controle.
4. Atualize os snapshots após a última rodada do legado, então aplique `whatsapp_tracking:import_cra_website` e `whatsapp_tracking:import_cra_meta_receipts` com `WHATSAPP_TRACKING_COMMIT_WEBSITE=true` e `WHATSAPP_TRACKING_COMMIT_RECEIPTS=true`, respectivamente. Envie os JSON pelo stdin com permissão restrita. Informe a caixa CRA ao importador de recibos. Compare as contagens com o exportador e descarte os arquivos temporários.
5. Defina `WHATSAPP_TRACKING_CRA_SITE_RULE_ID` com a regra ativa da caixa e altere `WHATSAPP_TRACKING_CRA_SITE_MODE` para `native`. Quando o n8n da CRA terminar de emitir, autorize somente a caixa CRA em `WHATSAPP_TRACKING_DELIVERY_INBOX_IDS` e `WHATSAPP_TRACKING_CRA_PRODUCTION_OWNER_INBOX_ID`, então defina `WHATSAPP_TRACKING_DELIVERY_ENABLED=true`.
6. Acompanhe a profundidade e os recibos do Evo, a saúde do web e do Sidekiq, o isolamento da Vetorial e o primeiro lead de cada origem. Examine divergências com o mesmo ID antes de reprocessar.

## Reversão

Retire o proprietário de produção do Evo antes de restaurar emissores legados. Reconcilie recibos aceitos e tentativas incertas do Evo por ID na trilha do legado antes de permitir novo envio. Volte o endpoint da borda e os consumidores CRA somente após comprovar que o Evo terminou ou reteve os trabalhos em voo. Preserve bancos, versões, filas e históricos para a retomada.
