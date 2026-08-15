# Designing a ZigBase app

This guide is the judgment layer between an idea and ZigBase's API reference. It helps you decide
what to build before you reach for collection JSON or Zig hooks. For exact field options, rule
syntax, and callable interfaces, use [fields.md](fields.md), [api.md](api.md), and
[framework.md](framework.md).

The goal is a backend whose trust boundaries are visible in its schema, whose public surface is
intentional, and whose tests exercise the same rules and hooks production will run.

## 1. Start with journeys and trust boundaries

Write the important journeys as subjects acting on resources. Do this before naming collections.
For each action, decide who may attempt it and which fact proves that authorization.

For a community gear-lending app, a first pass might be:

| Subject | Action | Resource | Authorization fact |
| --- | --- | --- | --- |
| visitor | browse available equipment | listing | listing is published; intentionally public |
| member | create equipment | new listing | authenticated member becomes owner |
| member | request dates | request | requester identity comes from the session |
| owner | approve or reject | request | request's listing belongs to the caller |
| administrator | remove abusive content | any listing | superuser route, not a client-supplied role |

Turn vague statements into invariants. “Users can edit their listings” is incomplete; “only the
authenticated owner relation may update a listing, and the server prevents changing that owner” is
testable. Mark boundaries where the client must not supply the authoritative value: owner ids,
verified state, approval state, prices derived from protected inputs, and tenant/account ids.

Keep the first slice small enough to test end to end. Authentication, one owned resource, and one
business transition will expose most mistakes earlier than scaffolding every screen.

## 2. Choose box mode or framework mode

Start in **box mode** when collections, access rules, validation options, files, auth, realtime,
and SDK-side composition express the product. Run `npx zigbase init` to get Docker Compose, a
declarative schema document, SDK wiring, and agent instructions without requiring Zig.

Choose **framework mode** when the server must make a trusted decision that a field constraint or
rule cannot express: stamping an owner from the session, validating a transition against another
row, performing an atomic side-write, exposing a typed business operation, or running background
work. Run `npx zigbase init --framework`; the scaffold wires `zigbase.addTo`,
`zigbase.addTest`, and `zigbase.testing`.

Do not choose framework mode merely to hide ordinary REST calls behind custom endpoints. The
collection API keeps filtering, expansion, pagination, access rules, realtime, and generated SDK
types aligned. A custom route should represent a business operation, not recreate CRUD.

You can start in box mode and move to framework mode without changing the HTTP collection model.
Treat the choice as the amount of trusted server logic the product needs today, not a permanent
fork.

## 3. Model collections, relations, and indexes

Give each independently authorized or independently changing thing its own collection. A field
belongs inline when it is part of the same lifecycle and trust boundary; it belongs in a related
collection when it has its own identity, permissions, cardinality, or history.

For each proposed collection, record:

- whether it is base, auth, or view/computed data;
- which fields clients may write and which the server owns;
- required relations and their delete behavior;
- uniqueness and lookup indexes;
- the five operation rules: list, view, create, update, delete;
- the list sort and cursor needed by the first UI; and
- whether files, encrypted fields, expiry, or tenancy change its lifecycle.

Prefer an auth collection for people who can sign in. Keep domain roles and profile data on that
record or in explicit related records; never trust a role string merely because a client submitted
it.

### Worked decision: requests are records, not JSON on a listing

A gear request has its own requester, date range, state transition, timestamps, and authorization.
Store it as a `requests` collection related to `listings` and `members`, not as a JSON array inside
the listing. Separate records let rules constrain requester and owner views, indexes find pending
requests, and a hook update one request atomically without rewriting every request ever made for the
listing.

Use a select field for a small closed state machine such as `pending`, `approved`, `rejected`, and
`cancelled`. The state value is storage; the allowed transitions remain trusted server behavior.

## 4. Prefer relations plus `expand`; denormalize deliberately

Use a relation when the related entity has its own source of truth. Ask the list endpoint to
`expand` the relation when a screen needs both records. Expansion still applies the related
collection's view rule, so it cannot bypass authorization.

Denormalize only when you can name the consistency policy. Good candidates are immutable snapshots
that must preserve history—such as the display price accepted when a request was approved—or a
measured hot read whose join/expand cost matters. “It is easier for the frontend” is not a
consistency policy.

### Worked decision: owner name stays related; accepted price is a snapshot

A listing should relate to its owner and use `expand=owner` for the current public display name.
Copying `ownerName` onto every listing would become stale after a profile edit. An approved request,
however, may store `agreedPrice` as a server-written snapshot because later listing-price changes
must not rewrite the agreement's history.

If a denormalized value must remain current, identify the one write path that updates every copy and
test its transaction or recovery behavior. If there is no single reliable write path, keep the
relation.

## 5. Write access rules before seed data or UI

ZigBase rules are locked by default. An empty rule is superuser-only; only the exact `"@public"`
sentinel opens an operation to anonymous callers. Treat that asymmetry as the design tool it is.

For every collection:

1. leave all five operations locked;
2. open only the first journey you are implementing;
3. express row ownership or membership from the authenticated identity and stored relations;
4. add a focused allow and deny test; and
5. proceed to the next operation only after both pass.

Do not temporarily set every rule to `@public` to unblock frontend work. Temporary public rules
have a habit of becoming deployed public rules, and they prevent tests from proving the intended
boundary. Use a superuser for setup, mint a test session, or add the real rule.

### Account for every public rule

Public access can be correct: published content, open signup, a health-like feed, or a deliberately
anonymous form. Record each public rule in `security/public-rules.json`:

```json
{
  "zigbasePublicRules": 1,
  "rules": [
    {
      "collection": "listings",
      "operation": "list",
      "rule": "@public",
      "rationale": "Published listings are the product's public catalog. Drafts remain excluded by the list rule."
    }
  ]
}
```

The inventory is a review artifact, not an authorization input. It must match the deployed schema;
an entry cannot make an unsafe rule safe. Run `zigbase doctor --production --json` and reconcile
every public-rule finding with exactly one current inventory entry.

## 6. Put trusted behavior in the narrowest server seam

Choose the least powerful mechanism that can enforce the invariant:

| Need | Place it |
| --- | --- |
| type, required, length, range, pattern, enum | field validation |
| row visibility or operation authorization | access rule |
| stamp/mutate one record or reject its write | `beforeCreate` / `beforeUpdate` hook |
| react after a committed write | `after*` hook |
| atomic side-write with a record transition | `before*` hook using `ctx.records()` |
| explicit business command with structured input/output | typed route |
| redirect, cookie exchange, webhook, or non-JSON response | untyped route |
| deferred retryable work | durable job/worker |
| scheduled maintenance | cron/job |

Client validation improves feedback but never owns an invariant. Repeat important shape constraints
as schema validation and important authorization as a rule or authenticated server path.

For the gear app, `owner` is stamped from the authenticated session in a `beforeCreate` hook; the
client's submitted owner is overwritten or rejected. Approve/reject is a typed route because it is
a named state transition requiring current-row checks and a structured error. A raw update that lets
the client set any state would expose transitions the product does not support.

Keep hooks bounded. Network delivery, slow computation, and retryable integrations belong in a job
queued after the authoritative state change—not inside a transaction holding a writer.

## 7. Design list endpoints for cursor pagination

Use cursor pagination from the first real list screen:

```text
GET /api/collections/listings/records?sort=-created&limit=20&cursor=
```

Forward `nextCursor` unchanged. Pick a deterministic sort that matches the UI; ZigBase adds `id` as
a tiebreaker. Keep the same sort and filter while walking a cursor. Rules and filters continue to
apply to every page.

Offset pagination remains useful for admin pages that need page numbers and totals. It is a poor
default for changing feeds: inserts between requests shift offsets and make rows repeat or vanish.
Starting with cursors avoids changing the client contract when the dataset becomes active.

## 8. Make realtime earn its place

Use realtime when an already-open screen materially benefits from observing another actor's write:
a request changing from pending to approved, a shared queue, or a live operational status. Do not
subscribe merely because realtime exists.

Before enabling it, answer:

- which collection and filter the client subscribes to;
- which access rule authorizes the subscription and each delivered record;
- how reconnect/refetch restores truth after missed events; and
- whether polling on user focus would be simpler and sufficient.

Realtime is an invalidation/notification path, not the database. The client must tolerate duplicate,
delayed, and missed events by re-reading authoritative state.

## 9. Put each test at the boundary it proves

Use `zigbase.testing` for most framework behavior. It boots the real app in-process against a
throwaway data directory and exercises provisioning, routes, rules, auth, hooks, migrations, and
deterministic time/randomness without a socket. Add allow and deny cases beside each feature.

Use `serve --ephemeral` or a spawned binary when the subject is HTTP itself: CORS, cookies, static
files, WebSocket upgrades, a generated SDK, or a non-Zig frontend. Use a browser only for behavior
that depends on browser state, navigation, or rendering. Keep those suites in addition to in-process
tests when they prove a different boundary.

A practical vertical slice is:

1. schema test: intended fields, relations, and rules provision;
2. rule tests: anonymous deny/allow and authenticated owner/non-owner;
3. behavior test: hook or typed route enforces the transition;
4. client test: generated SDK performs the public workflow against an ephemeral server; and
5. browser test: only the critical user journey the browser can uniquely break.

See [testing.md](testing.md) for build wiring and copyable harness examples.

## 10. Prove the app is ready to ship

Run the gates in this order so the cheapest and most actionable failures arrive first:

1. build and format/lint the application;
2. run all in-process tests;
3. run the focused spawned-server/client/browser suite;
4. run `zigbase schema apply schema/collections.json --dry-run` against the intended data copy;
5. reconcile `security/public-rules.json` with `zigbase doctor --production --json`;
6. start the Docker deployment with persistent storage;
7. verify `/api/health` and `/api/meta` through the same network path clients use; and
8. stop and restart it, proving the data and JWT secret survive.

Do not report a queued CI job as green, a successful build as passing browser tests, or a healthy
process as a production-safe configuration. Report the exact commands run and any gate not run.

For local and agent-shaped server lifecycle details, see [serve.md](serve.md). For container
ownership, healthchecks, and image tags, see [docker.md](docker.md). Use
[deployment.md](deployment.md) for systemd, reverse-proxy TLS, Fly, Railway, backup/restore, and
upgrade/rollback boundaries.

## See also

- [agents.md](agents.md) — compact orientation and the traps most likely to waste an agent loop.
- [recipes.md](recipes.md) — copyable schema, rule, hook, route, and testing recipes.
- [api.md](api.md) — rule grammar, records, expansion, cursor pagination, auth, files, and realtime.
- [framework.md](framework.md) — hooks, typed routes, jobs, context capabilities, and build wiring.
- [testing.md](testing.md) — in-process and spawned-server test boundaries.
- [serve.md](serve.md) — foreground/background/ephemeral server operation and doctor.
- [deployment.md](deployment.md) — production operation on a host, Docker, Fly, or Railway.
