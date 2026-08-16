# Migrate a Laravel application to ZigBase

Laravel has strong conventions, but production behavior still spans routes, middleware, models,
policies, service providers, queues, filesystems, and packages. Re-platform from the exact locked
application and a recoverable data snapshot; do not infer the service from migrations alone.

Use the generic [migration tools](https://github.com/valthon/zigbase/blob/main/docs/migration-tools.md) for target schema, NDJSON import, supported
legacy bcrypt migration, and parity replay.

## Inventory the effective application

Record the source revision, PHP and Laravel versions, `composer.lock` hash, enabled extensions,
effective environment-variable names with values redacted, database/export hashes, storage disks,
and production start/worker/scheduler commands.

Capture `php artisan route:list --json` when the pinned version supports it, but verify the result
against `routes/*.php`, route service providers, package routes, domains, prefixes, names, and
middleware groups. Inventory:

- global/group/route middleware order, bindings, throttles, CSRF, CORS, trusted proxies, and cookies;
- Form Requests, validator rules, casts, accessors/mutators, observers, events/listeners, and model
  boot methods;
- Eloquent models, scopes, relationships, soft deletes, migrations, raw queries, and transactions;
- policies, gates, guards/providers, password brokers, Sanctum/Passport tokens, and social auth;
- queues, Horizon, scheduled commands, notifications/mail, cache/locks, broadcasts, webhooks, and
  filesystem disks; and
- exception rendering, redirects, status/headers/body shapes, API Resources, and pagination.

Commit stable inventory findings with source evidence, disposition, replacement artifact, and
rationale. Missing private packages or runtime-generated behavior is a blocker, not an omission.

## Map schema, data, and authorization

Create a durable table/model-to-collection map covering ids, null/default behavior, indexes,
relations, timestamps/timezones, soft-delete policy, casts, tenant/owner fields, and omissions.
Translate policies/gates/scopes into actor-action-record truth tables before implementing ZigBase
rules, hooks, abilities, or typed routes. Add allowed and denied in-process tests for each boundary.

Write a pinned exporter against the frozen snapshot. Emit deterministic NDJSON and an import
manifest, preserve required ids/timestamps, hash every input/output, and demand byte-identical
reruns. Do not import through direct target SQL.

Inspect actual password hash prefixes and parameters. Import verified bcrypt only with
`--legacy-hashes bcrypt`; Laravel Argon2, custom hashers, external-only accounts, and unknown hashes
need a reviewed reset or separate compatibility design. Never migrate sessions, remember tokens,
Sanctum/Passport tokens, reset tokens, app keys, or signing secrets. Prove wrong-password
non-mutation and successful bcrypt-to-argon2id rehash after restart.

Intentional public signup is exact `@public` auth create plus a rationale in
`security/public-rules.json`. It is a doctor warning requiring reconciliation, not an error.

## Port and prove the HTTP contract

Map each client-visible route's middleware/auth, binding/coercion, request validation, success and
failure wire shapes, database effects, events/jobs, files, mail, and external calls to a ZigBase
collection API, hook, typed route, job, or deliberate retirement. Middleware order and transaction
boundaries are behavior when they affect trust or observable results.

Record representative requests from an isolated source and replay them against the target. Cover
public/authenticated access, policy allow/deny, validation/exception rendering, resources and
pagination, soft-deleted records, uploads/downloads, and custom commands. Export target OpenAPI and
reconcile it with the endpoint map. Assert database, queue, mail, and file side effects separately.

## Rehearse cutover

On a fresh target: lint/apply schema, full-depth lint rules, import auth then ordinary records,
verify files/counts/relations/timestamps, run allow/deny and parity suites, test auth rehash, run
production doctor, restart, and restore a backup into a second target.

At cutover stop HTTP writes, queue workers, and the scheduler; drain or durably account for queued
work; take the final snapshot; regenerate deterministic artifacts; repeat the rehearsal; then switch
traffic. Keep source snapshot and complete target state as one rollback unit. Record hashes, counts,
decisions, auth transition, parity/doctor evidence, retired behavior, cutover owner, and rollback
trigger.
