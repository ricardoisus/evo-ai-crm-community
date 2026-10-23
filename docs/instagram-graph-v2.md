# Instagram automation graph v2

Implementation of Ricardo's UX revision requested on 22 October 2026. Code and isolated tests are distinct from deployment and real Meta acceptance. No production activation is authorized by this document.

## Contract

`schema_version: 2` graphs contain typed nodes with unique IDs, `data`, and layout `position`; edges carry `source`, `target`, and `sourceHandle`. The functional digest sorts domain data and connections and excludes layout and edge IDs. Version snapshots retain the exact stored graph and their original digest. V1 versions keep their original interpreter and delivery/callback semantics.

Supported nodes: comment, scope, keyword, material, invitation, public_reply, like, confirmation, delivery, end. Conditions use match/no_match. Material uses success/blocked. Actions use success/failed/blocked; confirmation uses confirmed. Uncertain/reserved outcomes never follow an edge. No cycles, duplicate action on a path, delivery without real confirmation, public reply without invitation acceptance, or conditions after an invitation. A successful invitation must retain a confirmation/material delivery path even if public reply or like fails. Drafts may be incomplete; publication validates the complete DAG, with errors identifying node/field/action. Limits: 50 nodes, 150 edges, 100 KB, bounded path validation.

Only eligible comment executions reserve the existing globally unique delivery row. Branches on nonmatching conditions can lead into other conditions; comments outside every candidate path do not issue a link or message. Material resolution uses exact inventory bindings and the same explicit-caption resolver as simulation; unresolved material can take a configured blocked branch. Context fetches use encrypted inbound storage. Execution traces contain IDs/states/timestamps/reasons, not raw inbound text or identities.

## APIs

Existing proof endpoints retain their URLs and journey permissions. Create/PATCH accept incomplete v2 drafts with optimistic `lock_version`. New member POSTs:

- `discard`: restore the latest immutable published graph, or the initial v2 template when never published; does not modify audience/active version.
- `validate_graph`: validate the saved draft without publishing or sending. Invalid responses carry `error.details` entries with node, field, message, action.

Publish stores a new immutable snapshot and functional digest; it does not activate. Simulation accepts synthetic context `{account, media, ad, caption}` and retains only its HMAC in the deduplication key, not the raw context. Snapshot exposes published/active versions, draft divergence and server-owned activation readiness. List projection exposes published/running versions separately. Deliveries expose execution trace and cursor; historical receipts expose an empty trace and retain their legacy fields.

Test/commercial activation requires the latest published v2 configuration to match the saved draft functionally. Commercial activation requires a confirmed accepted material receipt, plus public acceptance when configured; only identical functional digests can reuse a previous test after layout-only changes. No client-supplied profile authorizes a recipient. Existing allowlist, connection, event age, identity binding, conflict, reservation, and signed callback checks remain authoritative.

## Runtime and rollback

Migration `20261022120000` adds only `execution_trace` (jsonb default []) and `graph_cursor` to deliveries. No new transport or Evo Flow service is required. The v2 runner reserves each node before I/O, checks the gate/version again, and resumes only through a verified click. Reserved or uncertain results stop for reconciliation. A verified click arriving while the invitation HTTP response or ancillary actions are pending is stored immediately; it advances the confirmation node only after invitation acceptance. This does not depend on the short NotReady job retries. An uncertain invitation still stops without issuing a link. It never automatically resends a provider operation. Public reply and like retain independent receipts; their ordinary failed/blocked edges can continue to confirmation/delivery.

Deployment order after explicit authorization: backup and restore rehearsal; additive migration; backend web/worker with both interpreters; readiness/hash checks; compatible frontend; isolated version test; separately authorized real test. Keep commercial rules disabled until the release is explicitly accepted. Before this first production rollout revalidate the currently deployed images, account and configuration; local source is not proof of production state.

Rollback must preserve database, versions, links, reservations and receipts. Pause affected rules before reverting images. Do not drop the trace columns or switch an active v2 version to a backend that only understands v1. Do not restore a dump over new events or delete reservations to force replays. Schema down/up is for an isolated rehearsal only.

## Validation

149 examples of the Instagram safety suite pass with external HTTP blocked.

`spec/safety/instagram/amh_graph_spec.rb` covers positive/negative condition paths, contextual fallback, shared resolver parity, immutable layout digests, incomplete drafts, structured HTTP errors, stale discard, verified early clicks during invitation/public HTTP, real callback requirements, pause, failure/uncertainty and duplicate deliveries. The complete Instagram safety suite additionally covers legacy links, registration, ingress, persistence and receipts. External HTTP is blocked/stubbed with WebMock against the explicitly named isolated database. The rate budget test freezes time so a busy host crossing a minute boundary cannot reset its fixed window.

Manual browser verification used the real Rails controller/model on the isolated database: add keyword → automatic PATCH → GET proves draft differs from published → discard POST → UI returns to published → inert simulation traces the graph with zero outbound. Authentication/catalog were fixture adapters in a temporary local test process, never production authentication changes. That process was stopped and its fixture removed. Production browser inspection reached the login screen; authenticated production UI and real Meta events remain unverified for this revision.
