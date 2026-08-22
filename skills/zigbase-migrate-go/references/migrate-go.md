# Migrate a Go web service to ZigBase

A Go service may use `net/http`, chi, Gin, Echo, Fiber, generated transports, or a custom router;
database and worker conventions vary just as widely. Treat this as evidence-driven re-platforming,
not source-to-source translation.

Use the generic [migration tools](https://github.com/valthon/zigbase/blob/main/docs/migration-tools.md) for target schema, NDJSON import, supported
legacy bcrypt migration, and parity replay.

## Inventory the built service

Record the source revision, Go/toolchain version, `go.mod` and `go.sum` hashes, build tags, generated
code inputs, embed directives, effective environment-variable names with values redacted, database
snapshot/export hashes, and production server/worker commands.

Inventory router construction and mount prefixes across `Handle`, `HandleFunc`, method helpers,
groups/subrouters, generated servers, and adapters. Follow function values and middleware wrapping;
grep output alone does not establish effective routes. Also inventory:

- middleware order, request decoding/validation, limits, CORS, proxy headers, cookies, and errors;
- SQL migrations, sqlc/generated queries, GORM/ent/bun models, raw SQL, constraints, and transactions;
- auth/JWT/session/password code, authorization helpers, tenant/owner scoping, and rate limits;
- goroutine lifecycles, cron/worker/queue consumers, retries, shutdown, idempotency, and outbox use;
- multipart/files, object storage, `go:embed`, mail, webhooks, caches/locks, and outbound clients; and
- status/headers/JSON envelopes, streaming, redirects, WebSockets/SSE, and client contracts.

Runtime plugin registration, unavailable generated inputs, reflection-only routing, or missing
private modules is a blocker unless effective behavior can be captured and durably inventoried.
Commit stable findings with evidence, disposition, replacement artifact, and rationale.

## Map schema, data, and policy

Create a source-table-to-collection map for ids, types, null/default semantics, indexes, relations,
timestamps, tenant/owner fields, derived fields, and omissions. Express authorization as actor,
action, record state, allow/deny cases before choosing rules, hooks, abilities, or typed routes.
Preserve transaction boundaries for multi-record invariants; add allowed and denied in-process tests.

Build a pinned exporter from the frozen snapshot using the source schema/query layer only when that
does not mutate or filter records invisibly. Emit deterministic NDJSON plus a dependency manifest,
preserve ids/timestamps, hash inputs/outputs, and require byte-identical reruns. Never write target
tables directly.

Import only verified bcrypt hashes with `--legacy-hashes bcrypt`. Other formats require a reviewed
reset or separate security design. Provider-only accounts have no hash to import: carry each
`(provider, providerId)` pair on the auth row and import it with `--external-auths`
([migration-tools.md §4b](https://github.com/valthon/zigbase/blob/main/docs/migration-tools.md#4b-external-identities-oauth--omniauth--social-login)),
after configuring the same provider on the target collection. Sessions, refresh/reset tokens,
provider access/refresh tokens, JWT signing material, API keys, and encrypted cookie state never
migrate. Prove wrong-password non-mutation, correct-password
argon2id upgrade, and post-restart login.

Intentional anonymous signup uses exact `@public` create and a durable
`security/public-rules.json` rationale; reconcile its doctor warning without suppressing new public
operations.

## Port and prove behavior

Map every client-visible route's middleware/auth, decoding/coercion, success/failure wire shape,
data/transaction effects, async work, and external calls to collection APIs, hooks, typed routes,
jobs, or retirement. Treat context cancellation, timeouts, idempotency, graceful shutdown, and
streaming semantics as required behavior when clients or data safety depend on them.

Record representative source requests and replay against the target. Cover public/authenticated,
owner/tenant allow-deny, validation/errors, pagination/filtering/relations/files, and custom
commands. Export target OpenAPI and reconcile the endpoint map. Assert database, job, webhook, and
file effects outside response replay.

## Rehearse cutover

On a fresh target, lint/apply schema, import auth then ordinary rows, verify files/counts/relations,
run allow-deny/replay/side-effect/auth tests, production doctor, restart, and backup restore. Before
cutover, stop writes and workers, account for in-flight work, take the final snapshot, regenerate,
repeat, then switch traffic. Keep source snapshot and full target state as one rollback unit.

Report source/build hashes, discovery blockers, decisions, counts, auth transition, parity and
doctor findings, async-work disposition, restart/restore evidence, cutover owner, rollback trigger,
and every unsupported or retired behavior.
