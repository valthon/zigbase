---
name: zigbase-migrate-express
description: Re-platform a Node.js Express backend onto ZigBase through discovery of routes, middleware, persistence, auth, jobs, files, and wire behavior; durable schema and endpoint decisions; deterministic NDJSON extraction; bcrypt rehash-on-login; parity replay; and rehearsed cutover or rollback. Use for Express migration planning, implementation, review, troubleshooting, or launch readiness.
---

# ZigBase Express Migration

Read `references/migrate-express.md`, `references/agents.md`, and
`references/migration-tools.md` before inventorying or changing a migration. Read
`references/openapi.md` when mapping target routes, `references/serve.md` before live verification,
and `references/deployment.md` plus `references/docker.md` before cutover.

The copied references are authoritative. Stop and report drift instead of combining mismatched
canonical and embedded versions.

## 1. Freeze and discover

Require a source revision, lockfile, runtime version, deployable source, recoverable database
snapshot/export, and representative HTTP behavior. Never mutate the only source data.

Inventory nested routers and mount prefixes, middleware order, validation, ORM/direct queries,
transactions, auth/session/JWT/Passport behavior, uploads/static files, jobs/workers, integrations,
errors, proxy/CORS/cookies, and every client-visible route. Static grep is a lead: boot the pinned
service in isolation when runtime composition is ambiguous. Dynamic undiscoverable registration is
a blocker, not permission to omit behavior.

Commit versioned inventory and decision artifacts with stable ids, evidence, disposition,
replacement artifact, and rationale.

## 2. Transplant data and policy

Map every source model/table to collections, fields, ids, relations, indexes, timestamps, omissions,
and trusted derived values. Express authorization as actor/action/state allow-deny cases before
writing ZigBase rules, hooks, or typed routes. Keep ordinary CRUD on collection APIs.

Build a pinned source-aware exporter from the frozen snapshot. Emit deterministic NDJSON and an
import manifest, preserve required ids/timestamps, hash inputs and outputs, and require two
byte-identical runs. Never write target tables directly.

Only import verified bcrypt credentials through `--legacy-hashes bcrypt`. Never relabel another
algorithm. Use a reviewed reset or separately designed compatibility boundary otherwise. Source
sessions/tokens never migrate.

## 3. Port and prove behavior

Create a durable endpoint parity map including middleware/auth preconditions, input coercion,
status/headers/body, failures, data effects, side effects, and target disposition. Preserve legacy
facades only for real client requirements. Export target OpenAPI and reconcile it with the map.

Record representative source requests, then replay against the target. Cover public/authenticated,
allow/deny, validation/error, pagination/filter/relation/file, and custom-command paths. Add direct
assertions for side effects replay cannot see and in-process allow/deny tests for every protected
operation.

Intentional public signup is supported: use exact `@public`, record it in
`security/public-rules.json`, and reconcile the production-doctor warning. Do not suppress newly
public behavior.

## 4. Rehearse cutover and rollback

On a fresh target, lint/apply schema, import auth then ordinary rows, verify files and counts, run
allow/deny and replay checks, prove bcrypt wrong-password non-mutation and successful rehash, run
production doctor, restart against persistent state, and rehearse restore.

At cutover, stop writes, regenerate from the final snapshot, repeat the whole rehearsal, and switch
traffic only when evidence matches. Keep the source snapshot and complete target state as one
rollback unit. Do not deploy or mutate external infrastructure without authorization.

## Handoff

Report hashes, inventory gaps, decisions, counts, auth transition, endpoint/replay findings, doctor
review, restart/restore proof, cutover ownership, rollback trigger, and every unsupported or retired
behavior.
