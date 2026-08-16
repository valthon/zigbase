---
name: zigbase-migrate-go
description: Re-platform a Go web service onto ZigBase through router, middleware, database, transaction, auth, worker, file, and wire-contract discovery; durable schema and endpoint decisions; deterministic import; supported bcrypt rehash-on-login; parity replay; and rehearsed cutover. Use for Go service migration planning, implementation, review, troubleshooting, or launch readiness.
---

# ZigBase Go Migration

Read `references/migrate-go.md`, `references/agents.md`, and `references/migration-tools.md` before
starting. Read `references/openapi.md` for route mapping and `references/deployment.md` before
cutover. Stop on reference drift.

## Discover the built service

Freeze revision, Go version, module sums, build tags/generated inputs, deployable source, database
snapshot, files, and representative HTTP behavior. Resolve effective routes and middleware across
net/http or the selected router. Inventory decoding/validation, SQL/ORM and transactions, auth and
authorization, workers/goroutines/shutdown, files/embed/storage, jobs/webhooks/mail, streaming, and
wire errors. Missing generated/private/runtime-only behavior is a blocker.

Commit stable findings with evidence, disposition, replacement artifact, and rationale.

## Transplant and prove

Map tables to collections, ids, relations, indexes, timestamps, trusted fields, and omissions. Turn
authorization into actor-action-record allow/deny cases before rules, hooks, abilities, or typed
routes. Preserve transaction, cancellation, idempotency, and shutdown semantics when data safety or
clients depend on them. Add allowed and denied in-process tests.

Build a pinned deterministic exporter from the frozen snapshot; emit NDJSON and a manifest, hash
inputs/outputs, and require byte-identical reruns. Import verified bcrypt only; reset or separately
design other formats. Sessions/tokens/secrets never migrate. Public signup is exact `@public` plus
durable `security/public-rules.json` review.

Map each route's middleware/auth, decoding, wire response/error, data/async effects, and target
disposition. Record source cases, replay against ZigBase, reconcile target OpenAPI, and directly
assert effects replay cannot observe.

## Rehearse and hand off

On a fresh target, lint/apply, import auth then ordinary rows, verify files/counts, run allow-deny,
parity, auth rehash, doctor, restart, and restore tests. At cutover stop writes and workers, account
for in-flight work, regenerate from the final snapshot, repeat, then switch traffic. Keep complete
source and target state as one rollback unit. Report hashes, gaps, decisions, counts, auth/async
status, findings, restore proof, cutover owner, rollback trigger, and unsupported behavior.
