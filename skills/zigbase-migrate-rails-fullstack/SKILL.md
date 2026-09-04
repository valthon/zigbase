---
name: zigbase-migrate-rails-fullstack
description: Re-platform a Rails application onto a same-origin ZigBase backend and Zigapagos frontend by composing the released Rails API and Rails presentation workflows, reconciling source routes through versioned manifests, and recording sampled backend/browser evidence and explicit review items. Use for full Rails monolith migration planning, execution, review, troubleshooting, or launch-readiness assessment. Do not use for a deliberately backend-only Rails migration whose frontend remains on Rails.
---

# ZigBase Rails Full-Stack Migration

Replace both halves. Accept no route that disappears between them.

## Load references progressively

Start with `references/migrate-rails-fullstack.md`; do not load every operational reference up
front. When entering the backend phase, read `references/migrate-rails-api.md`, then read
`references/migration-tools.md` when its schema/import/replay mechanics are needed. Read
`references/openapi.md` when binding frontend behavior and `references/zigapagos-pairing.md` when
assembling the same-origin target.
Read `references/agents.md` and `references/serve.md` for live verification. Load
`references/deployment.md` and `references/docker.md` only for a requested deployment or cutover
rehearsal.

Read the Rails migration guide shipped by the exact Zigapagos release before running its adapter.
The copied ZigBase references are authoritative for their half. If a copied reference and canonical
ZigBase docs differ, stop and report drift rather than mixing versions.

## 1. Gate contracts and take one consistent snapshot

Require Rails inventory version `1`, `zigapagos.rails-presentation/1`,
`zigapagos.rails-handoff/1`, and an OpenAPI 3.x ZigBase document. Reject an unknown version; do not
guess compatibility from similar fields. Both adapters must read one immutable source snapshot.

Prefer a transactionally consistent online database/files snapshot so discovery and implementation
do not require prolonged downtime. Record revision and lockfiles, database and Active Storage
digests, redacted configuration names, production commands, representative backend cases, browser
journeys, and direct side-effect evidence. Mark evidence observed or inferred; inference cannot
satisfy an observed check. If the source adapter cannot take a consistent online snapshot, request a
short snapshot window explicitly. Stop writes, workers, and the scheduler only for the final delta
capture and cutover.

## 2. Complete the backend workflow first

Drive the Rails API migration skill against the snapshot: observed inventory, durable decisions,
deterministic extraction, locked-by-default collections, typed routes for incompatible behavior,
preserved ids/timestamps/relations/files/verified bcrypt credentials, imports, direct side-effect
checks, and backend replay.

This is a hard phase gate, not an ordering suggestion. Do not start presentation conversion until
the replacement has an application-owned ZigBase consumer binary whenever the source has custom
controller behavior, every client-visible Rails backend route is bound to an implemented
collection operation or typed route (or explicitly retired), every required collection rule is
decided rather than left locked by default, and the backend replay passes. A data directory plus a
stock-binary OpenAPI export proves schema shape only; it is not an implemented backend.

Authentication uncertainty is route-local and never excuses unrelated backend work. Map OmniAuth
providers to ZigBase OAuth2 provider declarations—including a custom provider literal when no
preset exists—and import reviewed `(provider, providerId)` links with `--external-auths`. Missing
live client credentials may prevent a real provider round trip, but they do not prevent provider
configuration, OAuth UI/route implementation, mock-provider tests, or implementation of every
non-auth route. Record the live round trip as an outstanding launch check instead of blocking the
backend phase.

Put that OAuth configuration in the schema document applied to the migrated auth collection, or in
an explicit application schema migration that runs before import. Consumer startup provisioning is
additive and does not overwrite auth options on an already-created collection; a provider literal
in the consumer alone is therefore not evidence that OAuth is enabled. Dump the live schema and
exercise the providers endpoint after provisioning. When credentials come from environment
variables, let the consumer provision the auth collection with those variables before applying the
rest of the schema, and include the same provider metadata in that schema so its encrypted secret
is preserved. Use isolated dummy credentials for offline provider tests; never put production
secrets in a migration document.

Do not treat `omit` as the conservative answer for an observed concrete `belongs_to` merely because
the legacy database lacks a foreign-key constraint. If the association carries ownership,
authorization, routing, or referential meaning, choose `relation` and prove its target ids resolve;
flattening it to a number can make a backend look importable while making faithful rules and hooks
impossible. Run decided-schema generation, extraction, and a dry-run manifest-v2 import immediately
after decisions. Timestamped and timestamp-less collections stay in one dependency graph with
per-entry timestamp policy; prove that cycles across the policy boundary complete the deferred
patch pass rather than erasing them by omitting relations.

Export target OpenAPI from a provisioned ZigBase data directory. It is the only endpoint vocabulary
Zigapagos may use for route helpers, forms, and mutating links. Never guess a URL. Retain the replay
summary and NDJSON findings; reconciliation accepts only an all-passing run.

## 3. Complete the presentation workflow

Run `zigapagos migrate --from rails --target ... --backend ...` against the same source. Pass the
same reviewed OpenAPI on every decide-then-rerun iteration. Preserve only the Zigapagos decisions
file between target runs. Use a UTF-8 locale. Treat parser/sidecar load errors, or a zero-route
result that contradicts the frozen Rails route inventory, as failed discovery even if the
generator exits zero; never turn missing parser support into an apparently empty application.

Require the handoff to say `complete: true`, with no `open` route. Convert or explicitly decide every
layout, view, partial, route helper, form, asset, Turbo/Stimulus behavior, and supported component
root. Unsupported Haml/Slim, helpers, gems, engines, request-time rendering, or asset transforms
remain visible blockers. Binding a form never moves authorization into the island; the ZigBase
rule or route stays enforcement.

## 4. Reconcile the union, not either half

Populate `fullstack-decisions.json` under the `zigbaseRailsFullstackDecisions: 1` contract. Handle
obvious exact mappings mechanically: copy producer-owned route identity, endpoint, access, and
evidence without asking the user to transcribe them. Present only exceptions for review: ambiguous
bindings, method changes, retained/retired routes, custom behavior, auth uncertainty, and blockers.
Before accepting a generated auth island, match it to the observed Rails credential mechanism. A
Zigapagos `AuthForm` is password-based and does not replace an OmniAuth-only journey just because
OpenAPI contains an auth collection. Configure the source provider, import `externalAuths`, and
implement the provider-sign-in UI. If real client credentials are unavailable, require an offline
or mock-provider exercise and record only the live provider round trip as an outstanding launch
check; do not mark the auth route blocked and do not let it halt unrelated route implementation.
Also distinguish WebAuthn login from post-login WebAuthn step-up. A source that issues an OAuth
session and then requires a second-factor ceremony is not reproduced merely by enabling ZigBase's
passkey login endpoints; preserve that journey through an explicit custom-auth/session design or
record it as a launch blocker while the rest of the backend continues.
The resulting file still covers the route union so omissions remain detectable; duplicated source
routes use their one-based occurrence.

Distinguish blocker identities exactly. A route-local presentation blocker with no finding or
handoff decision row is cited by its manifest blocker `code` when its `route_id` matches the route.
Finding-backed handoff work instead cites the stable ids in `routes[].findings` and
`routes[].decision.id`; never substitute a blocker code for those handoff finding and decision ids.

Run `tools/rails/fullstack.py` from a matching ZigBase source release. It resolves backend operation
ids, presentation artifacts, and recorded backend/browser evidence into
`zigbase.rails-fullstack/1`. Run twice and require byte-identical output. Never edit the reconciled
manifest. Exit `2` means the owning source artifact is incomplete or incompatible.

The manifest is emitted only after its input route sets and decisions agree. `needs_review`
remains true while any route is blocked. Reconciliation does not claim live cutover readiness.

A migrated route needs a backend operation, a converted presentation artifact/status, or both, plus
parity evidence. Supply the backend request capture as well as replay findings: the coordinator
derives backend controls from the capture and browser controls from the handoff parity kind. Require
exact method/path agreement with the selected OpenAPI operation. A protected mutation needs both allowed and
denied controls. Retained, blocked, and retired routes need an explicit disposition and rationale;
blocked routes must follow the blocker identity distinction above. Any intentional method change
must include a non-empty `method_change_rationale`; the coordinator derives both methods.
`MIGRATION.handoff.json complete` alone is insufficient because it deliberately does not prove
non-GET backend coverage or backend replay.

## 5. Assemble one origin and prove all layers

Build the Zigapagos release and serve it from the replacement application's ZigBase binary. Use
`@zigbase/client`, not Rails session cookies or authenticity tokens. Use the consumer binary when
the app defines collections, hooks, routes, jobs, or other comptime behavior.

Verification is representative and sampled, not exhaustive equivalence proof. Verify converter
determinism and imported bytes; in-process backend allow/deny tests; HTTP replay
and direct side effects; Zigapagos validate/release/doctor/static doctor; TypeScript and real-binary
SDK integration; browser metadata, redirects, navigation, signup/sign-in, allowed and denied
mutations, validation errors, files, interactive replacements, and responsive assets; and restart
persistence. Drive the wrong authenticated actor against the server—hidden controls are not denial
evidence.

Execute those recipes against the live replacement binary. A generated runner, replay recipe, or
report sentence is not proof until it ran successfully; keep its logs and fail the gate on a live
browser/server mismatch. Explicitly list behavior not mechanically proven, including unexercised
callbacks and transactions, background jobs, mail, uploads, webhooks/external effects, dynamic
authorization branches, runtime-generated routes, custom JavaScript, browser/device combinations,
and production-only configuration.

Build the presentation release from an empty output tree with the exact Zigapagos runtime that
matches the generator. A zero exit status is not sufficient: verify that every SPA bundle, island
bundle, and runtime asset referenced by the routing manifest and emitted HTML exists in the final
tree before doctor or browser evidence can pass. Never let stale output satisfy this check.
Treat `handoff.complete` as scope accounting, not replacement success. Report route status counts;
an all-blocked/retained handoff may emit zero pages and must not be called a full migration. Its
generated target still has to build cleanly—do not patch around a missing required output directory.

## 6. Rehearse cutover and rollback

Run production doctor and reconcile every public rule. Reviewed public signup is a warning only
when its exact rule and rationale are durably inventoried; any other public operation blocks launch.

Restore the full cutover unit into a second target and repeat build, startup, login/rehash,
data/file, backend, browser, doctor, and restart checks. At final cutover stop writes/workers/the
scheduler, drain or durably account for queued work, regenerate from reviewed decisions, rerun the
rehearsal, then switch traffic. Do not deploy or mutate external infrastructure without explicit
authorization.

## Handoff

Report source and output digests, tool and contract versions, every reconciled route disposition,
backend and presentation artifacts, auth boundaries, parity results including denied cases, public
rule review, restart/restore proof, cutover owner, rollback trigger, unsupported behavior, and any
remaining action requiring authorization.

Call the route map reconciled only when every route has a disposition. Do not call the application
complete or cutover-ready while either tool has an unacknowledged blocker, sampled backend or
browser checks are missing, a protected mutation lacks positive and negative controls, doctor finds
an unreviewed public operation, or requested restart/rollback/cutover rehearsal is absent. Report
the limits of the sampled evidence even when every executed check passes.
