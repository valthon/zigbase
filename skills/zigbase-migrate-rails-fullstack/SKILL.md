---
name: zigbase-migrate-rails-fullstack
description: Re-platform a complete Rails application onto a same-origin ZigBase backend and Zigapagos frontend by composing the released Rails API and Rails presentation workflows, reconciling every source route through versioned manifests, and requiring backend plus browser parity, positive and negative authorization controls, restart, rollback, and cutover evidence. Use for full Rails monolith migration planning, execution, review, troubleshooting, or launch readiness. Do not use for a deliberately backend-only Rails migration whose frontend remains on Rails.
---

# ZigBase Rails Full-Stack Migration

Replace both halves. Accept no route that disappears between them.

## Load the authoritative references

Read `references/migrate-rails-fullstack.md`, `references/migrate-rails-api.md`, and
`references/zigapagos-pairing.md` before planning or executing. Read
`references/migration-tools.md` for schema/import/replay mechanics, `references/openapi.md` before
binding frontend behavior, and `references/serve.md`, `references/deployment.md`, and
`references/docker.md` before rehearsal or cutover.

Also read the Rails migration guide shipped by the exact Zigapagos release in use. The copied
ZigBase references are authoritative for their half. If a copied reference and canonical ZigBase
docs differ, stop and report drift rather than mixing versions.

## 1. Gate contracts and freeze one source

Require Rails inventory version `1`, `zigapagos.rails-presentation/1`,
`zigapagos.rails-handoff/1`, and an OpenAPI 3.x ZigBase document. Reject an unknown version; do not
guess compatibility from similar fields. Both adapters must read one immutable source snapshot.

Stop writes, workers, and the scheduler. Record revision and lockfiles, database and Active Storage
digests, redacted configuration names, production commands, representative backend cases, browser
journeys, and direct side-effect evidence. Mark evidence observed or inferred; inference cannot
satisfy parity.

## 2. Complete the backend workflow first

Drive the Rails API migration skill against the snapshot: observed inventory, durable decisions,
deterministic extraction, locked-by-default collections, typed routes for incompatible behavior,
preserved ids/timestamps/relations/files/verified bcrypt credentials, imports, direct side-effect
checks, and backend replay.

Export target OpenAPI from a provisioned ZigBase data directory. It is the only endpoint vocabulary
Zigapagos may use for route helpers, forms, and mutating links. Never guess a URL. Retain the replay
summary and NDJSON findings; reconciliation accepts only an all-passing run.

## 3. Complete the presentation workflow

Run `zigapagos migrate --from rails --target ... --backend ...` against the same source. Pass the
same reviewed OpenAPI on every decide-then-rerun iteration. Preserve only the Zigapagos decisions
file between target runs.

Require the handoff to say `complete: true`, with no `open` route. Convert or explicitly decide every
layout, view, partial, route helper, form, asset, Turbo/Stimulus behavior, and supported component
root. Unsupported Haml/Slim, helpers, gems, engines, request-time rendering, or asset transforms
remain visible blockers. Binding a form never moves authorization into the island; the ZigBase
rule or route stays enforcement.

## 4. Reconcile the union, not either half

Create `fullstack-decisions.json` under the `zigbaseRailsFullstackDecisions: 1` contract. Include
exactly one decision for every route in the union of the Rails backend inventory and Zigapagos
manifest. Identity is verb, path, controller, action, and one-based occurrence. Record surface,
disposition, backend operation, auth boundary, parity ids, rationale, and stable blocker ids when
blocked.

Distinguish blocker identities exactly. A route-local presentation blocker with no finding or
handoff decision row is cited by its manifest blocker `code` when its `route_id` matches the route.
Finding-backed handoff work instead cites the stable ids in `routes[].findings` and
`routes[].decision.id`; never substitute a blocker code for those handoff finding and decision ids.

Run `tools/rails/fullstack.py` from a matching ZigBase source release. It resolves backend operation
ids, presentation artifacts, and passing backend/browser evidence into
`zigbase.rails-fullstack/1`. Run twice and require byte-identical output. Never edit the reconciled
manifest. Exit `2` means the owning source artifact is incomplete or incompatible.

A migrated route needs a backend operation, a converted presentation artifact/status, or both, plus
parity evidence. Supply the backend request capture as well as replay findings: backend controls are
producer fields checked against expected status, while browser controls are derived from the handoff parity kind. The
decision file cannot relabel either. Require exact method/path agreement with the selected OpenAPI
operation and never weaken its access classification. A protected mutation needs both allowed and
denied controls. Retained, blocked, and retired routes need an explicit disposition and rationale;
blocked routes must follow the blocker identity distinction above. Any intentional method change
must include the explicit reviewed contract
`"method_transform": {"from": "PUT", "to": "PATCH", "rationale": "..."}`; its methods must
match the source and selected endpoint, and its rationale must be non-empty.
`MIGRATION.handoff.json complete` alone is insufficient because it deliberately does not prove
non-GET backend coverage or backend replay.

## 5. Assemble one origin and prove all layers

Build the Zigapagos release and serve it from the replacement application's ZigBase binary. Use
`@zigbase/client`, not Rails session cookies or authenticity tokens. Use the consumer binary when
the app defines collections, hooks, routes, jobs, or other comptime behavior.

Verify converter determinism and imported bytes; in-process backend allow/deny tests; HTTP replay
and direct side effects; Zigapagos validate/release/doctor/static doctor; TypeScript and real-binary
SDK integration; browser metadata, redirects, navigation, signup/sign-in, allowed and denied
mutations, validation errors, files, interactive replacements, and responsive assets; and restart
persistence. Drive the wrong authenticated actor against the server—hidden controls are not denial
evidence.

Execute those recipes against the live replacement binary. A generated runner, replay recipe, or
report sentence is not proof until it ran successfully; keep its logs and fail the gate on a live
browser/server mismatch.

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

Refuse completion while either tool has an unacknowledged blocker, any route lacks a disposition,
backend or browser parity is missing, a protected mutation lacks positive and negative controls,
doctor finds an unreviewed public operation, or restart/rollback/cutover rehearsal is absent.
