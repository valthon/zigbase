# Migrate a full Rails application to ZigBase and Zigapagos

This guide coordinates replacement of a conventional Rails application end to end: ZigBase owns
data, authentication, authorization, files, jobs, and server behavior; Zigapagos owns routes,
pages, layouts, assets, and browser behavior. It coordinates the two released migration workflows.
It does not reimplement either adapter and it never treats one half's success as full-application
parity.

Start with this guide. Read [Migrate a Rails API](https://github.com/valthon/zigbase/blob/main/docs/migrate-rails-api.md) when entering the backend
phase, [ZigBase + Zigapagos pairing](https://github.com/valthon/zigbase/blob/main/docs/zigapagos-pairing.md) when assembling the same-origin target,
and the Zigapagos `rails-to-zigapagos` guide before running that release's adapter. Use
`tools/rails/fullstack.py` to reconcile their machine-readable artifacts. Load deployment and
container references only when preparing a requested rehearsal or cutover.

## 0. Gate on published contracts

Use a ZigBase release that provides Rails inventory version `1` and the Rails API migration tools.
Use Zigapagos v0.5.0 or later with these released contracts:

- `zigapagos.rails-presentation/1` in `MIGRATION.manifest.json`;
- `zigapagos.rails-handoff/1` in `MIGRATION.handoff.json`; and
- an OpenAPI 3.x backend document supplied to `zigapagos migrate --backend`.

The coordinator emits `zigbase.rails-fullstack/1` and accepts decisions marked
`zigbaseRailsFullstackDecisions: 1`. It rejects a different schema id instead of guessing whether
two releases remain compatible. A generator version and an artifact schema version are different:
record both.

Do not begin a full migration while either source-specific tool reports an unacknowledged blocker.
Do not downgrade to the Rails API-only skill merely because presentation conversion is difficult;
that workflow is complete only when the frontend is deliberately retained and declared out of
scope.

## 1. Snapshot and observe the same source

Prefer a transactionally consistent online snapshot containing application source, database,
Active Storage files, configuration names with values redacted, and the exact revision and
dependency lockfiles. Both migration halves must read that same immutable snapshot. If the source
adapter cannot produce a consistent online snapshot, arrange an explicit short snapshot window.
Reserve the write, worker, and scheduler freeze for the final delta capture and cutover.

Before changing anything, record:

- representative Rails HTTP cases, including successful, validation-failure, unauthenticated, and
  authenticated-but-unauthorized requests;
- browser journeys for navigation, redirects, metadata, signup, sign-in, protected mutations,
  validation presentation, files, Turbo/Stimulus behavior, and responsive assets; and
- direct evidence for database transactions, callbacks, jobs, mail, uploads, webhooks, and other
  side effects that HTTP response comparison cannot observe.

Stamp evidence as observed or inferred. Static source inspection must never satisfy an observed
parity requirement.

## 2. Build the backend contract first

Follow the Rails API guide against the snapshot. Run the Rails extractor under `bin/rails runner`,
reconcile every converter finding, extract twice, and require byte-identical bundles. Map ordinary
CRUD to locked-by-default collections and rules; use typed custom routes for incompatible
envelopes, transactions, callbacks, and domain operations. Preserve ids, timestamps, relations,
supported bcrypt credentials, and files.

On a disposable ZigBase target, apply the schema, import data, install files, port behavior, and
export OpenAPI:

```sh
zigbase migrate --data-dir migration/target-data
zigbase schema apply migration/bundle/schema.json --data-dir migration/target-data
zigbase openapi --data-dir migration/target-data \
  --api-version 1.0.0 --out migration/zigbase.openapi.json
```

Treat backend completion as a hard phase gate. A stock ZigBase binary pointed at an applied schema
is only a schema/import rehearsal: it has no application hooks or typed routes, and locked default
rules make its generated CRUD operations unusable. Before starting the presentation migration,
build the application-owned consumer binary required by the observed controllers, decide the
access rules, bind every client-visible Rails backend route to a real collection operation or typed
route (or explicitly retire it), and run an all-passing backend replay.

OpenAPI is the presentation adapter's endpoint vocabulary. Route helpers, forms, and mutating links
must bind to its `operationId` values or to an explicitly reviewed `custom:/...` route. Never guess
a URL from a Rails controller name. Generated collection resource operations carry both
`x-zigbase-collection`, the authoritative resource collection identity, and
`x-zigbase-collection-type`, the authoritative auth/base distinction. Consumer routes instead use
`x-zigbase-auth` and, when gated, `x-zigbase-auth-collection`; an authentication gate is not the
route's resource collection. The reconciled backend record preserves that authentication
collection and whether the route admits superusers. Do not re-derive these values from the URL or
infer auth type from field names.
The coordinator consumes these exporter markers and uses the selected operation's resource
collection when matching backend and browser evidence. Browser parity recipes that name
`expect.collection` must name that selected collection; custom routes use `null` because they do
not carry resource collection metadata.
Browser navigation evidence uses concrete URLs. A Rails `:capture` or OpenAPI `{capture}` in the
selected route matches exactly one non-empty concrete URL segment; query strings and fragments do
not change which route the navigation proves.
ZigBase OpenAPI deliberately does not enumerate every authentication method, so the coordinator
separately recognizes the seven standard collection auth operations:
password sign-in, refresh, logout, verification request/confirmation, and password-reset
request/confirmation. Those builtins must use their exact POST path under an exported auth
collection. For a dynamic auth method or session-management route, prefer a typed route exported
to OpenAPI. If that is not possible, implement an app-owned wrapper outside `/api/collections/`
and review it through the custom endpoint contract; never point `custom:` directly into the
engine-owned auth namespace.

Cross-check the presentation auth journey against the Rails credential mechanism before accepting
Zigapagos's `RAILS_AUTH_JOURNEY` island. Its generated `AuthForm` is a password journey; it is not a
replacement for an OmniAuth-only application merely because the backend document contains an auth
collection. Declare the source provider in ZigBase OAuth2 configuration (using explicit custom
provider endpoints and mappings when there is no preset), import the reviewed external identities,
and implement provider sign-in. Missing live client credentials may defer the real provider round
trip, but must not block provider plumbing, mock-provider verification, or any unrelated backend
route. Record that one live journey as an outstanding launch check instead of accounting the auth
route away as blocked.

Apply provider configuration as part of the target auth collection's schema or through an explicit
application migration before import. Additive consumer provisioning does not replace auth options
on a collection that the migration schema already created, so a provider declaration that appears
only in consumer source can leave the live providers endpoint disabled. Verify the dumped live
schema and the endpoint, not just the consumer literal. For environment-sourced credentials,
provision the auth collection through the consumer first, then apply a schema document carrying the
same provider metadata; the schema merge preserves the already-encrypted secret. Offline tests may
use isolated dummy credentials, but production secrets never belong in the schema document.

An observed concrete `belongs_to` without a database foreign key is not safely handled by choosing
`omit` when it carries ownership, authorization, routing, or referential meaning. Choose `relation`
and validate the preserved targets. Generate the decided schema, extract, and run a dry-run
manifest-v2 import immediately after the decisions. Timestamped and timestamp-less collections
remain in one dependency graph with per-entry timestamp policy, so relation cycles across that
policy boundary must complete the deferred patch pass rather than be erased by omitting relations.

Treat WebAuthn login and WebAuthn step-up as different contracts. Enabling ZigBase passkey login
does not reproduce a Rails journey that issues an OAuth session and then requires a second factor;
use ZigBase's [two-factor subsystem](https://github.com/valthon/zigbase/blob/main/docs/framework.md#two-factor-authentication) with
WebAuthn selected, the matching collection/application requirement, and the
[pending-authentication wire contract](https://github.com/valthon/zigbase/blob/main/docs/api.md#two-factor-authentication). Preserve
the source enrollment/recovery policy and prove pending capabilities cannot access
protected routes. Configuring a primary passkey method alone is not step-up evidence.

For a route absent from OpenAPI, bind the handoff endpoint with the exact operation id
`custom:/absolute/path` and add `backend_access` to the decision with one of `public`,
`authenticated`, `conditional`, `superuser`, or
`path-secret`. The handoff endpoint path must equal the suffix after `custom:` and must not collide
with a real OpenAPI method/path pair or an engine-owned method/path template from
`x-zigbase-reserved-routes`. Consumer routes such as `/api/collections/posts/publish` remain valid
when they do not match a reserved template; use their exported OpenAPI operation whenever present.
It also must not equal or descend from a prefix in `x-zigbase-reserved-prefixes`. In particular,
an admin-enabled binary reserves `/_` and every `/_/...` path at all depths, while `/__` remains a
distinct consumer namespace; an admin-disabled binary exports no admin prefix reservation. The
coordinator treats the trusted Zig exporter as authoritative for its reserved routes and prefixes:
it validates the metadata shape and uses those reservations to reject colliding custom draft
endpoints without independently rebuilding the Zig server's route table in Python. The six
`x-zigbase-coverage` booleans must have their exact supported values, and `consumerRoutes` must agree
with whether a consumer operation is present in `paths`.
The coordinator also requires the fixed `x-zigbase-contract-version` supported by this release;
the application-controlled OpenAPI `info.version` is descriptive and cannot impersonate a newer
exporter format.
Do not use the bare value `custom`, and do not add `backend_access` to an OpenAPI-backed decision.
The coordinator applies the same explicit access check to custom routes and derives the reconciled
authorization from the selected endpoint.

When a reviewed migration intentionally changes the HTTP method, add
`"method_change_rationale": "..."` to the route decision. The coordinator derives the source and
target methods and records them with the trimmed rationale. Method changes without a non-empty
rationale are refused, including logout conversions.

Replay the recorded backend cases against the target and retain the NDJSON findings and immutable
NDJSON request capture containing each case's method, path, and expected status.
The recorder atomically creates or replaces that capture with private `0600` permissions because
request headers, bodies, and expected responses may contain sensitive migration data.
`tools/rails/fullstack.py` accepts only evidence where every finding has `result: "pass"` and the
capture names exactly the same non-empty set of cases. The coordinator derives the replay summary
from those two bound inputs. The capture owns each allowed,
denied, or validation control, and the coordinator checks that label against expected status; a
decision cannot relabel producer evidence. Put `expect.control` in the request case before running
`record`; recording refreshes `status` and `bodySubset` but preserves that reviewed label. Uncited
captures may omit a control, while every capture cited by a decision must declare one. Status 404 is
a valid denied control for concealment policies; 409/422 are validation, and 3xx may be allowed or
journey evidence.

Use replay placeholders such as `{{id}}` for dynamic path segments and provide the value with
`--var id=...`; do not store OpenAPI template syntax such as `{id}` in an executable capture. The
coordinator matches either a concrete segment or one replay placeholder against the corresponding
OpenAPI path-template segment and rejects extra, missing, or wrong-prefix segments.

## 3. Inventory and assemble the presentation

Run the released Zigapagos Rails adapter against the same frozen source and pass the reviewed
backend document on every iteration. Use a UTF-8 locale. Treat parser/sidecar load errors, or a
zero-route result that contradicts the frozen Rails route inventory, as failed discovery even if
the generator exits zero; missing parser support must not become an apparently empty application.

```sh
zigapagos migrate source/app --from rails \
  --target migration/frontend \
  --backend migration/zigbase.openapi.json
```

The first target run normally exits `3`: artifacts were written, but at least one user-facing route
is open. Review `MIGRATION.manifest.json`, answer exact finding ids in
`MIGRATION.decisions.json`, clear generated target files while preserving that decisions file, and
run again. Do not edit the Rails source.

Require all of the following before reconciliation:

- `MIGRATION.handoff.json` says `complete: true` and contains no `open` route;
- every ERB layout, view, partial, route helper, asset, Turbo/Stimulus integration, and component
  root is converted or has an explicit retained/blocked decision;
- Haml, Slim, arbitrary helpers, request-time rendering, engines, and unsupported gems remain
  blockers unless a dedicated adapter proves their behavior;
- every form or mutating link is bound to the reviewed OpenAPI/custom-route contract;
- signup/sign-in and protected mutations retain server-side enforcement; and
- the handoff contains browser parity entries rather than an empty parity array.

The Zigapagos `complete` flag answers the presentation converter's question. It intentionally does
not prove that every non-GET backend route migrated, that backend replay passed, or that the two
inventories agree. The full-stack reconciliation step answers those questions.

## 4. Reconcile one durable route map

Populate `migration/fullstack-decisions.json`. A strong migration agent should derive obvious exact
mappings directly from the producer artifacts and ask for review only when a route is ambiguous,
changes method or semantics, contains custom behavior or uncertain authorization, is retained or
retired, or remains blocked. The resulting file covers every route in the union of the observed
Rails backend inventory and the Zigapagos presentation manifest so omissions remain detectable.
Route identity is method, path, controller, action, and a one-based occurrence, because Rails can
declare the same route more than once. Handoff v1 does not serialize a presentation route index, so a
duplicated presentation `route_id` is never paired positionally: every matching presentation
identity receives the complete ordered handoff group for collective validation. Rails compound
verbs such as `GET|POST` and `ANY` are expanded for method checks; if any expanded method mutates,
protected-mutation evidence requirements apply.

The released handoff may also emit several ordered outcomes for one presentation route (for
example, a page and a redirect). Reconciliation preserves the complete group as the route's
`presentation` array and validates every status, endpoint, decision, and finding; no row is selected
and the rest discarded. When a duplicated `route_id` has more handoff rows than presentation
occurrences, the complete ordered group is retained on every occurrence and reviewed collectively
rather than assigned by guesswork. This rule also applies when candidate and occurrence counts are
equal; equal cardinality is not attribution evidence.
POST/PATCH/PUT/DELETE presentation routes may have an empty `presentation` array because the
released Zigapagos completeness rule requires conversion rows only for GET/HEAD; their reviewed
OpenAPI operation and parity evidence still have to satisfy the full-stack decision.
A Zigapagos route classified `backend` must resolve to an implemented operation and executed
backend evidence. It cannot be converted to a full-stack `blocked` disposition merely because no
operation was bound: that is unfinished backend work and violates the phase gate above. Fix the
backend producer artifact, regenerate OpenAPI, and rerun the presentation adapter.

```json
{
  "zigbaseRailsFullstackDecisions": 1,
  "routes": [
    {
      "source": {
        "verb": "POST",
        "path": "/posts",
        "controller": "posts",
        "action": "create",
        "occurrence": 1
      },
      "surface": "browser",
      "disposition": "migrated",
      "parity": [
        {"kind": "browser", "id": "create-post-allowed"},
        {"kind": "browser", "id": "create-post-denied"},
        {"kind": "browser", "id": "create-post-invalid"}
      ],
      "rationale": "The form island submits to createPosts; its collection rule remains enforcement."
    }
  ]
}
```

`surface` is `browser`, `api`, or `internal`. `disposition` is `migrated`, `retained`, `blocked`, or
`retired`. A blocked entry also carries a non-empty `blockers` array. When a handoff endpoint is
present, omit `backend_operation_id`; the coordinator derives it. Use `backend_operation_id` only
to select an exported OpenAPI operation for a route with no handoff endpoint.

The backend routes input must be the observed `rails2zb` inventory and declare top-level
`"source": "observed"`; inferred or mixed nested provenance cannot satisfy reconciliation. The
generated manifest records that mode and the inventory digest so its Rails origin remains auditable.

Parity entries refer to passing backend replay case ids or Zigapagos handoff parity ids. Browser
controls are fixed by handoff kind (`navigate` is a journey, signup/sign-in/submission kinds retain
their named semantics, and assets cannot stand in for route parity). A protected mutation needs both
an `allowed` and `denied` control. The coordinator requires exact method/path agreement among the
captured case, handoff endpoint, and selected OpenAPI operation; it also refuses an auth declaration
that weakens the operation's OpenAPI access classification. For a route-local presentation blocker
that has no finding or handoff decision row, cite its exact manifest blocker `code` whose `route_id`
matches the route. For finding-backed handoff work, cite the exact stable ids from
`routes[].findings` and `routes[].decision.id`; a blocker code cannot substitute for those handoff
finding and decision ids. This distinction prevents invented names from hiding converter findings
while allowing source-level route blockers to remain representable.

The vendored Zigapagos handoff schema text is aligned with the released v0.5.0 contract at commit
`2c2c4936caed2a4db211b082140f0b008563b0bc`: `routes[].endpoint` may be non-null after a reviewed
backend binding. Its JSON type and `src/cli/rails/handoff.zig` are authoritative; older prose saying
the field was always null was stale. Gate compatibility on the declared schema id and successful
validation of the emitted wire shape, not a byte hash of descriptive schema annotations.

Run:

```sh
python3 tools/rails/fullstack.py \
  --backend-routes source/inventory/routes.json \
  --presentation-manifest migration/frontend/MIGRATION.manifest.json \
  --presentation-handoff migration/frontend/MIGRATION.handoff.json \
  --backend-openapi migration/zigbase.openapi.json \
  --decisions migration/fullstack-decisions.json \
  --backend-findings migration/backend-findings.ndjson \
  --backend-capture migration/backend-capture.ndjson \
  --out migration/fullstack-manifest.json
```

Run it twice and require byte-identical output. A successful command writes a
`zigbase.rails-fullstack/1` route map. `needs_review` is true while an acknowledged blocked route
remains. The coordinator makes no cutover-readiness claim because it does not execute doctor,
browser, restart, restore, or cutover checks. Exit `1` is a tool/input failure such as unreadable or malformed JSON,
an unsupported contract shape, or an output filesystem error. Exit `2` means valid artifacts still
need migration judgment or more proof, such as an incomplete handoff or incompatible access
declaration. Fix the owning artifact; never edit the reconciled output.

Fresh non-secret coordinator manifests use a deterministic `0644` mode, independent of the
process umask; rewrites preserve an existing manifest's mode. Secret extraction and replay
artifacts remain private `0600` files.

## 5. Replace Rails runtime assumptions at one origin

Build the Zigapagos release and serve it from the replacement ZigBase application. Prefer one
origin so relative `/api/...` calls, secure cookies, and realtime share a boundary. Use
`@zigbase/client`; do not reproduce Rails session cookies or authenticity tokens. Browser state can
hide or disable controls, but authorization remains in ZigBase collection rules and typed routes.

Use the application's own ZigBase binary when it defines comptime collections, hooks, routes, jobs,
or configuration. Zigapagos's stock binary cannot contain those additions. Follow
[ZigBase + Zigapagos pairing](https://github.com/valthon/zigbase/blob/main/docs/zigapagos-pairing.md) for runtime static trees, embedded assets, the
foreground-owned dev loop, and the build/release contract.

## 6. Gather representative layered evidence

The checks below are representative samples, not exhaustive application-equivalence proof. Run
them against fresh migrated state:

1. converter determinism, schema lint/dry-run/apply, data/file counts and digests;
2. in-process backend authorization tests, with an allowed and denied case per protected action;
3. HTTP replay plus direct assertions for transactions, jobs, mail, uploads, and external effects;
4. Zigapagos validate, release, doctor, and static-tree doctor;
5. TypeScript typecheck and real-binary SDK integration;
6. browser journeys executed against the live replacement binary for metadata, redirects,
   navigation, signup/sign-in, allowed and denied
   mutations, validation errors, assets, Turbo/Stimulus replacements, and responsive behavior; and
7. restart persistence with the built frontend still served by the replacement application.

Build the presentation release from an empty output tree with the exact Zigapagos runtime matching
the generator. Do not accept a successful release command by itself: verify that every SPA bundle,
island bundle, and runtime asset referenced by the routing manifest and emitted HTML exists in the
final tree. Stale output must not be allowed to satisfy this check.
`MIGRATION.handoff.json complete: true` means every route was accounted for, not that a replacement
was produced: a handoff whose routes are all blocked or retained may emit zero pages. Report the
migrated/blocked/retained/backend counts and require the generated target to build even in that
shape. A zero-page target whose generated `build.sh` fails is a producer defect, not acceptable
migration evidence and not something to hide by creating an ad hoc content directory.

A replay recipe, generated test file, or report sentence is not an execution result. Preserve the
live command logs and make a failed browser/server run fail the migration gate.

The final report must separately list behavior that was not mechanically exercised: untested
callback and transaction branches, jobs, mail, uploads, webhooks and other external effects,
dynamic authorization branches, runtime-generated routes, custom JavaScript, browser/device
combinations, and production-only configuration. A strong LLM reviews and implements those items;
passing sampled checks does not silently convert them into proof.

Do not infer an authorization pass from a hidden button. Drive the request as the wrong authenticated
actor and assert the server denial. Preserve Rails concealment semantics where an unauthorized
record was deliberately returned as `404`.

## 7. Rehearse cutover and rollback

Run `zigbase doctor --production --json` and reconcile every public rule. Reviewed public signup is
an expected warning only when the exact create rule and rationale appear in
`security/public-rules.json`; any other public operation remains unreviewed and blocks cutover.

Rehearse a final snapshot, deterministic re-extraction, restore into a second target, frontend build,
same-origin startup, data/file verification, login including bcrypt-to-argon2id rehash, all parity
layers, traffic switch, and rollback. Keep the source snapshot, decisions, migration bundle, target
database, storage, JWT material, frontend release, OpenAPI, handoffs, and full-stack manifest as one
versioned cutover unit.

At final cutover, stop writes, workers, and the scheduler; drain or durably account for queued work;
repeat the rehearsed procedure; then switch traffic. Do not deploy, publish, or mutate external
infrastructure without explicit authorization.

## Reconciliation and readiness contract

Call the route map reconciled when every source route has a disposition and the producer contracts
agree. Do not call the application complete or cutover-ready when either tool reports an
unacknowledged blocker, a route is absent from the reconciled map, a protected mutation lacks
positive and negative server controls, representative backend or browser evidence is missing,
production doctor reports an unreviewed public operation, restart/restore was not proved, or a
requested rollback and cutover rehearsal was not performed.

The handoff must name source and output digests, tool and contract versions, every route disposition,
backend and presentation artifacts, auth boundary, parity ids and results, supported and unsupported
behavior, doctor findings, restart/restore evidence, cutover owner, rollback trigger, and any action
that still requires authorization. It must distinguish executed evidence from inferred mappings and
name the mechanically unproven behavior that still requires LLM or operator review.
