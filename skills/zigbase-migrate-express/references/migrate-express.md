# Migrate a Node.js/Express service to ZigBase

Express is a routing library, not an application convention. Two Express services may discover
routes, validate input, persist data, authenticate users, serve files, schedule work, and shape
errors in completely different ways. This workflow is therefore a discovery-driven re-platforming,
not a mechanical translation.

Use the generic [migration tools](https://github.com/valthon/zigbase/blob/main/docs/migration-tools.md) for target schema, NDJSON import, supported
legacy bcrypt credentials, and parity replay. Use [OpenAPI export](https://github.com/valthon/zigbase/blob/main/docs/openapi.md) to review the target
surface after custom behavior is ported.

## Supported evidence boundary

Start only when you have:

- the exact source revision and lockfile used in production;
- production build/start commands and effective environment-variable names, with values redacted;
- a recoverable database snapshot or deterministic export;
- the complete deployable source, including generated route/model files required at runtime;
- representative HTTP requests for public, authenticated, denied, and failure paths; and
- an identified owner for DNS/traffic switching and rollback.

Do not mutate the only source database. Freeze writes for the final snapshot, and rehearse from a
copy. If routes are registered from runtime plugins, database configuration, filesystem scans, or
unavailable private packages, treat the missing runtime inventory as a blocker.

## 1. Create a durable inventory

Commit a versioned `migration/inventory.json` that records the source revision, lockfile hash,
runtime version, database/export hashes, start command, and every discovered surface. At minimum,
inventory:

- every `express()`, `Router()`, `.use()`, HTTP verb, `route()`, mount prefix, and nested router;
- middleware order at application, router, and route scope;
- body parsing, validation/coercion, query parsing, uploads, static files, and response compression;
- ORM models/migrations and direct queries (`knex`, Prisma, Sequelize, TypeORM, Mongoose, SQL, or
  driver calls), including constraints and transaction boundaries;
- session stores, JWT issuance/verification, Passport strategies, password hashing, CSRF, CORS,
  cookies, rate limits, `trust proxy`, and authorization helpers;
- error middleware, status codes, redirects, headers, and response envelopes;
- cron, queues, workers, webhooks, email, object storage, caches, and outbound APIs; and
- frontend/mobile clients and externally consumed endpoint versions.

Static searches are leads, not proof. Resolve router variables and mount prefixes, inspect imported
middleware, and boot the pinned service in an isolated environment when static composition is
ambiguous. Exercise route discovery with requests; do not assume an undocumented endpoint is dead.

For every item record a stable id, source location, evidence, disposition (`map`, `port`, `retire`,
or `block`), replacement artifact, and rationale. A route list without middleware and data effects
is incomplete.

## 2. Map data and authorization

Create `migration/schema-map.json` before writing target schema. For each source table/model record:

- target collection and type;
- primary-key/id preservation policy;
- field types, null/default behavior, uniqueness, indexes, and relation delete behavior;
- timestamp and timezone semantics;
- tenant/owner fields and who is allowed to set them;
- derived fields that move to hooks; and
- records or fields deliberately omitted, with rationale.

Translate authorization as a truth table first: actor, action, record state, expected allow/deny.
Then express ordinary row visibility in ZigBase rules and trusted mutation in hooks/routes. Never
copy a frontend check or middleware name as if it were a policy. Add one allowed and one denied
`zigbase.testing` case for every protected operation.

Intentional anonymous signup maps to exact `@public` create on the auth collection and a durable
entry in `security/public-rules.json`. Production doctor reports it as a warning for review, not an
error. Unreviewed public operations still block launch.

## 3. Build deterministic imports

Write a source-aware export program inside the migration workspace. Pin its runtime and dependencies.
It must read the frozen snapshot/export, emit one NDJSON object per line, preserve stable ids needed
by relations, normalize timestamps deliberately, sort deterministically, and write a ZigBase import
manifest in dependency order. Hash every input and output and require two clean runs to be
byte-identical.

Do not extract by calling the live application's public API unless that API is the explicitly
reviewed system of record and can provide a consistent snapshot. Do not bypass ZigBase's importer
with direct target SQL.

For auth users, inspect the actual stored hash algorithm and parameters. ZigBase's legacy import
supports bcrypt only. Import bcrypt with `--legacy-hashes bcrypt`, prove wrong-password non-mutation
and correct-password rehash to argon2id, and track the remaining legacy count. For scrypt, PBKDF2,
Argon2 variants, external identity-only accounts, or unknown formats, choose a reviewed reset or
separately designed compatibility boundary. Never relabel a hash.

Source sessions, refresh tokens, password-reset tokens, and signing keys do not migrate. Plan and
communicate reauthentication.

## 4. Map the HTTP contract

Commit `migration/endpoints.json` with one entry per client-visible behavior:

- source method/path and mount prefix;
- auth and middleware preconditions;
- path/query/header/body inputs and coercion;
- success status, headers, and body shape;
- failure status and error shape;
- data reads/writes and side effects; and
- ZigBase destination: collection API, typed route, file endpoint, or retired behavior.

Keep ordinary CRUD on collection APIs. Use typed routes for commands, cross-record transactions,
or a compatibility facade. Preserve a legacy URL/shape only when a real client needs it; otherwise
version the contract and update the client deliberately. Export target OpenAPI and compare the map
against it so missing custom routes are visible.

Middleware order is behavior. Preserve validation-before-write, auth-before-data-access, rate-limit,
transaction, and error-conversion semantics where clients or security depend on them. Do not port
Express stack mechanics that have no observable or trust-boundary effect.

## 5. Record and replay

Prepare replay cases with stable ids and redacted placeholders. Before final source shutdown, use
`tools/replay/zb_replay.py record` against an isolated production-equivalent source. Include:

- health and public reads;
- signup/login and authenticated refresh behavior without recording credentials in git;
- allowed and denied owner/tenant operations;
- validation, duplicate, missing-record, and malformed-input failures;
- pagination, sorting, filters, relations, and files; and
- every custom command or externally consumed webhook response.

Strip only genuinely volatile fields. Replay against the target and classify every difference.
Subset matching is useful for additional target metadata, but it must not hide missing authorization,
status, header, or required-body behavior. Add direct database/count/file assertions for side effects
that response replay cannot prove.

## 6. Rehearse and cut over

On a fresh target:

1. lint and dry-run the schema, then apply it;
2. run full-depth rule checks;
3. import auth collections separately, then the ordinary manifest with preserved timestamps;
4. install/copy files through a reviewed, digest-verifying process;
5. boot the exact target artifact and run allow/deny, replay, side-effect, login/rehash, and restart
   checks;
6. run `doctor --production --json` and reconcile public rules; and
7. restore a backup into a second clean target and repeat critical checks.

At cutover, stop writes, capture and hash the final source snapshot, regenerate deterministic
artifacts, repeat the rehearsal, and switch traffic only after evidence matches. Keep source
snapshot, decisions, exports, target database/files, and JWT secret as one rollback unit. Do not
reverse traffic to a source that accepted post-snapshot writes without explicit reconciliation.

## Migration report

Record source/runtime/lockfile/database hashes; inventory completeness and blockers; schema and
endpoint decisions; row/file counts and output hashes; auth reset or bcrypt-rehash status; exact
commands and exits; allow/deny and replay findings; doctor findings; restart/restore proof; cutover
owner; rollback trigger; and every retired or unsupported behavior.
