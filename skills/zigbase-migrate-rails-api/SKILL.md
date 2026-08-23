---
name: zigbase-migrate-rails-api
description: Re-platform a Rails API-only backend onto ZigBase through observed route, Active Record, authorization, transaction, job, and Active Storage discovery; durable decisions; deterministic extraction with preserved ids, timestamps, relations, files, and bcrypt credentials; OpenAPI reconciliation; parity replay including denied cases; and rehearsed cutover. Backend only — never claims Rails views or frontend behavior were migrated. Use for Rails API migration planning, execution, review, troubleshooting, or launch readiness.
---

# ZigBase Rails API Migration

Move the backend. Preserve the data. Never imply a frontend came with it.

## Load the authoritative references

Read `references/migrate-rails-api.md` and `references/agents.md` before inventorying, planning, or
executing. Read `references/migration-tools.md` for schema, import, legacy-hash, and replay details.
Read the rest only when the work reaches them: `references/openapi.md` after porting custom
behavior, `references/serve.md` before starting or diagnosing ZigBase or interpreting doctor, and
`references/deployment.md` with `references/docker.md` before rehearsal, cutover, or rollback.

The copied references are authoritative here. If canonical repository docs differ, stop and report
drift instead of mixing versions.

## 1. Gate the scope first

Do not start until one of these is recorded:

1. the source is genuinely API-only — no view template renders in the request path, no browser route
   returns HTML, no asset pipeline serves the application's own UI;
2. the operator explicitly selected backend-only migration and recorded the frontend as retained and
   out of scope; or
3. the operator explicitly selected a **partial** migration of the JSON API subset of a
   view-rendering application, and recorded which routes move, which stay, and how the two halves
   coexist during and after cutover.

The third case is the common one — a pure `config.api_only` application is rare, and the ordinary
shape is a view-rendering monolith with a JSON API under a namespace. It is legitimate work, but it
is a *partial* migration and must be reported as one: Rails keeps running, keeps its database, and
keeps serving HTML.

A partial migration also needs a recorded answer for shared state: the system of record per table,
the synchronization direction, and the cutover moment for each — or a table-disjoint subset. Two
writers against one dataset with no recorded owner is what this gate exists to prevent.

Enumerate `app/views/`, template-rendering actions, and the asset pipeline. If any exist, report them
as retained findings. Never describe them as migrated. Pairing a frontend is the Zigapagos pairing
skill's job, not this one's.

## 2. Freeze the source

Stop writes, workers, and the scheduler. Take an immutable, recoverable snapshot. Record the
revision, Ruby and Rails versions, `Gemfile.lock` digest, database engine and export digest, Active
Storage service and blob tree, redacted environment-variable names, and production commands. Never
edit the source.

## 3. Inventory what the framework knows

`config/routes.rb` plus `db/schema.rb` yields a plausible and wrong inventory. Routes are a DSL
evaluated at boot; associations, validations, enums, and `encrypts` are metaprogrammed; and
`default_scope` silently filters ordinary reads.

Prefer observed metadata — run `tools/rails/export_source.rb` under `bin/rails runner` against the
snapshot. Every record it emits is stamped `"source": "observed"`. When the application cannot boot,
use the documented static fallback, which stamps every record `"source": "inferred"`. Never promote
an inferred record to observed, and never let one satisfy a completion criterion.

Additionally inventory controllers and filter order, strong parameters, serializers and pagination,
exact success and error envelopes, auth/token/session behavior, policies and abilities, CSRF/CORS,
rate limits, transactions, callbacks, raw SQL, triggers, Active Job and queues, mailers, Action
Cable, webhooks, uploads, scheduled work, mounted engines, and route constraints. Commit findings
with evidence, disposition, replacement artifact, and rationale. Missing private gems and
runtime-generated behavior are blockers.

## 4. Use the converter as the only extraction path

The converter is a repository tool, not a file embedded in this skill: from a ZigBase source
checkout run `tools/rails/rails2zb.py inventory`. If the checkout lacks that path, stop and obtain
the matching ZigBase source release instead of inventing a converter.

Treat exit `2` as judgment required, not failure. Build a versioned `decisions.json` keyed by every
exact finding id, each with a non-empty rationale and a typed replacement artifact. Never replace a
durable decision with a comment, an unstructured note, or warning suppression.

Run `extract` only after every finding reconciles. Review source and decision digests, counts,
omissions, replacement artifacts, public rules, unreferenced objects, and credential redaction. Run
it twice and require byte-identical bundles.

These never convert silently — each needs a decision: `default_scope` (extraction reads `unscoped`;
a scoped read is data loss), Active Record encryption (ciphertext never migrates), polymorphic
associations and single-table inheritance, database triggers and views and raw SQL, non-bcrypt
password hashes, and sessions, `secret_key_base`, signed or encrypted cookies, and API tokens.

## 5. Map schema, data, and authorization

Map tables to collections with ids, types, null and default semantics, indexes, relations,
timestamps and time zones, enums, counter caches, soft-delete policy, owner and tenant fields, and
omissions. Preserve ids so relations resolve.

Express authorization as actor, action, record state, allow or deny before choosing a mechanism.
Ordinary CRUD becomes collections and rules; incompatible envelopes, transactions, callbacks, and
domain operations become typed routes; multi-record invariants keep their transaction boundary. Add
at least one allow and one deny test per replacement.

Import auth files separately from the ordinary manifest, both with `--preserve-timestamps`, using
`--legacy-hashes bcrypt` for verified `has_secure_password` hashes only. Install files only after row
validation. Verify counts, ids, relations, exact timestamps, and file digests directly rather than
trusting a tool summary. Intentional public signup is exact `@public` create plus a rationale in
`security/public-rules.json` — a doctor warning to reconcile, not an error to suppress.

## 6. Port behavior before declaring parity

Map every client-visible route's filter chain and auth, coercion and validation, success and failure
wire shape, data and transaction effects, enqueued jobs, mail, files, and outbound calls to a
collection API, hook, typed route, job, or deliberate retirement.

Rails envelopes rarely match ZigBase's. A `{"data": …, "meta": …}` index or an `{"error": {"code": …}}`
failure is a client contract: port it behind a typed route or record the client change as a
decision. An envelope change is never parity.

Record representative source requests and replay them against the target. Parity must include a
success, a validation failure, an unauthenticated request, and an authenticated-but-unauthorized
request. Preserve concealment semantics — where Rails returns `404` for a record the actor may not
see, the target must too; do not "fix" it into a `403` mid-migration. Preserve ZigBase's own
semantics as well: a list whose rule hides every row is `200` with an empty `items` array, not `403`.

Export target OpenAPI and reconcile it with the observed Rails contract. Assert database, job, mail,
and file side effects directly; replay cannot observe them.

## 7. Rehearse cutover and preserve rollback

On a fresh disposable target: syntax-lint and dry-run the schema, apply it, run full-depth rule lint,
import auth then ordinary data, verify counts and files, run allow/deny and parity suites, prove
bcrypt-to-argon2id rehash on login survives a restart, run production doctor and reconcile exact
public-rule warnings, restart, and restore a backup into a second target.

At final cutover stop writes, workers, and the scheduler; drain or durably account for enqueued jobs;
take the final snapshot; regenerate from the already-reviewed decisions; repeat every rehearsal
check; then switch traffic. Keep snapshot, decisions, bundle, target database, storage, and JWT
secret as one rollback unit. Do not deploy or mutate external infrastructure without authorization.

## Handoff

Report source and bundle digests, whether the inventory was observed or inferred, decisions and
replacements, counts, exact commands and exit codes, rule and doctor findings, parity results
including the denied cases, the legacy-hash transition, restart and restore proof, the cutover owner,
and the rollback trigger.

Name every unsupported and unresolved behavior plainly. State explicitly that Rails views and
frontend behavior were not migrated, and name the retained frontend if one exists.
