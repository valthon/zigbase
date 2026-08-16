---
name: zigbase-migrate-laravel
description: Re-platform a Laravel backend onto ZigBase through effective route, middleware, Eloquent, policy, auth, queue, filesystem, and wire-contract discovery; durable schema and endpoint decisions; deterministic import; supported bcrypt rehash-on-login; parity replay; and rehearsed cutover. Use for Laravel migration planning, implementation, review, troubleshooting, or launch readiness.
---

# ZigBase Laravel Migration

Read `references/migrate-laravel.md`, `references/agents.md`, and
`references/migration-tools.md` before starting. Read `references/openapi.md` for route mapping and
`references/deployment.md` before cutover. Stop on reference drift.

## Discover before translating

Freeze the exact revision, PHP/Laravel versions, lockfile, deployable source, database snapshot,
storage, and representative HTTP behavior. Inventory effective routes plus middleware order, Form
Requests, Eloquent/raw SQL and transactions, casts/observers/events, policies/gates, guards and
Sanctum/Passport, queues/scheduler, files, mail, integrations, and exception/resource wire shapes.
Treat missing packages or runtime-generated behavior as blockers.

Commit stable inventory findings with evidence, disposition, replacement artifact, and rationale.

## Transplant and prove

Map models/tables to collections, ids, relations, indexes, timestamps, soft-delete policy, trusted
fields, and omissions. Turn policies/gates/scopes into actor-action-record allow/deny cases before
implementing rules, hooks, abilities, or typed routes. Add both allowed and denied in-process tests.

Build a pinned deterministic exporter from the frozen snapshot; emit NDJSON and a manifest, hash
inputs/outputs, and demand byte-identical reruns. Import only verified bcrypt through
`--legacy-hashes bcrypt`; reset or separately design other formats. Never migrate sessions/tokens or
secrets. Public signup is exact `@public` plus `security/public-rules.json` review.

Map every route's auth/middleware, validation, wire response/error, data effects, async side effects,
and target disposition. Record source cases, replay them against ZigBase, reconcile target OpenAPI,
and directly assert effects replay cannot observe.

## Rehearse and hand off

On a fresh target, lint/apply, import auth then ordinary data, verify files/counts, run allow-deny,
parity, auth rehash, doctor, restart, and restore tests. At cutover stop writes, workers, and the
scheduler; account for queued work; regenerate from the final snapshot; repeat; then switch traffic.
Keep complete source and target state as one rollback unit. Report hashes, gaps, decisions, counts,
auth/queue status, findings, restore proof, cutover owner, rollback trigger, and unsupported behavior.
