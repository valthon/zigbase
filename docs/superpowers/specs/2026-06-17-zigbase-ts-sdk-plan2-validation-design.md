# ZigBase TypeScript SDK — SP2.1b Plan 2: Validation & Grounding

**Status:** Design approved, pending spec review
**Date:** 2026-06-17
**Scope:** Sub-project SP2.1b **Plan 2** — deep validation of the pure-Zig client generator
(shipped in SP2.1b Plan 1, PR #20) and grounding it in a real published example. Builds on the
committed dating golden (`clients/typescript/test/codegen/dating/zbase.gen.ts`) and the SP2.1a
typed core. SP2.2 (typed RPC + framework typed-routes) follows.

## Context & strategy

SP2.1b Plan 1 delivered the generator: `zig build gen-client` walks an app's comptime
`.collections` and emits a tailored `zbase.gen.ts` instantiating the SP2.1a typed core. Plan 1
proved correctness by Zig unit tests + a committed golden snapshot that `tsc` typechecks.

Plan 2 closes the validation gap the headline promise demands — *your typed client is a build
artifact of the same schema your server runs* — by proving the generated client two ways:

1. **At the type level** — exhaustive `expectTypeOf` assertions (+ `@ts-expect-error` negatives)
   over the generated dating client, so every mapping rule is locked by a compile-time test, not
   a hand-written smoke file.
2. **Against a live server** — a real zigbase binary serving the *exact comptime schema* the
   client was generated from, driven end-to-end through the generated client.

…and grounds it in **golfsim**, a real published example, made self-contained: real app + its
generated typed client + passing e2e.

## Design principles

1. **Same schema, both sides.** The e2e server compiles the *same* `fixtures/dating/schema.zig`
   the client was generated from — no hand-mirrored runtime schema that can drift. This is the
   whole point of comptime codegen and must be what the e2e proves.
2. **Extend, don't reinvent.** A live-server integration harness already exists
   (`test/integration/harness.ts`) and a `*.test-d.ts` type-testing setup already exists
   (vitest `expectTypeOf`). Plan 2 generalizes them rather than building parallel infrastructure.
3. **Grounded in a real example.** golfsim becomes a complete reference (app + generated client +
   tests), not just a smoke check — the strongest evidence the generator works on real schemas.
4. **Break early, stay fresh.** `gen-client --check` staleness gates for both the dating fixture
   and golfsim run in CI, so a committed generated client can never silently drift from its schema.
5. **No flaky e2e.** Realtime and file-upload tests synchronize on explicit conditions (the
   lesson from the admin OAuth nav-race flake), never on timing.

## Architecture & components

Three pillars (A: dating validation, B: golfsim grounding, C: CI) + docs sync (D).

### A. Dating fixture — deep validation (`clients/typescript/`)

**A0. Fixture refinement — model photo privacy structurally.** File access is governed by
collection rules, not a per-field/per-record privacy flag, so privacy must be *structural*. Refine
`fixtures/dating/schema.zig`: keep a publicly-viewable `photos` collection and add a separate
dependent `privatePhotos` collection (an owner/auth-restricted view rule), each holding
**individual photo records** with their own attributes (owner relation, image file, caption, …).
Modeling each photo as its own record — rather than a photo *set* hung off the profile — keeps the
door open for per-photo semantics like granting access to a *specific* private photo, without
building that now (YAGNI). This supersedes the non-enforcing `visibility` select on `photos`.
Changing the fixture regenerates the committed golden (`zig build gen-dating-client`); the
type-level + e2e suites then cover `privatePhotos` too. (`select`-field coverage is retained via
`profiles.gender` / `subscriptions.plan`.)

**A1. Dating-server binary.** A new `zig build dating-server` step in the root `build.zig`
compiles `fixtures/dating/schema.zig` — which already exposes `pub const App = zigbase.App(.{…})`
and `pub fn main(init) → App.runCli(init)` — into `zig-out/bin/dating-server`. This binary serves
the dating schema with the standard subcommands (`serve` / `migrate` / `superuser create`). It is
the e2e server: client and server share one comptime schema, so the e2e proves real fidelity.

**A2. Generalized e2e harness.** Extend `test/integration/harness.ts`. Today it spawns the generic
`zig-out/bin/zigbase` binary and creates collections at runtime via `POST /api/collections`. Add a
schema-baked path:

```ts
startAppServer({ bin, seedSuperuser }: { bin: string; seedSuperuser?: {email,password} })
  : Promise<{ baseUrl: string; stop: () => void }>
```

It spawns `bin` (e.g. `zig-out/bin/dating-server` or the golfsim binary), allocates a free port,
runs `superuser create`, health-polls `GET /api/health`, and returns `{ baseUrl, stop }`. The new
path does **not** create collections at runtime — the schema is baked into `bin`. The existing 4
integration tests keep their current generic-binary + runtime-collection path unchanged (the
helper supports both); shared internals (port alloc, health poll, teardown, `ensureBuilt`) are
factored so both paths reuse them.

**A3. Dating e2e** (`test/integration/dating.integration.test.ts`). Imports the committed generated
client `test/codegen/dating/zbase.gen.ts`, points it at the dating-server `baseUrl`, and exercises
the full surface against real data it creates through that client:

- **auth** — `authWithPassword` on `profiles` (the auth collection); a superuser path for setup.
- **CRUD** — create/read/update/delete across `profiles` / `photos` / `privatePhotos` / `tags` /
  `messages` / `winks` / `subscriptions`.
- **nested-relation filter** — e.g. `photos` filtered by `owner` fields (the where-DSL's
  one-level nested relation).
- **expand** — single (`photos.owner → profile`) and multi (`photos.tags → tag[]`), asserting the
  expand-narrowed result shape at runtime.
- **native cursor** — `getPage` / `iterate` / `getFullList` server-side cursor pagination.
- **realtime** — subscribe to a collection, perform a write, assert the event arrives (synchronize
  on event receipt, with a bounded timeout — no fixed sleeps).
- **file upload** — public access via a `photos` record (`fileUrl(record, field)`, no token) and
  token-required access via a `privatePhotos` record (`files.getToken`), proving both file-access
  paths through the generated client. (See A0: privacy is structural — the restricted
  `privatePhotos` collection — not a per-field flag.)

**A4. Dating type-level suite** (`test/codegen/dating/zbase.gen.test-d.ts`). Comprehensive vitest
`expectTypeOf` assertions over the generated client, replacing the current hand-written
`typecheck.ts` smoke:

- every field→TS mapping (text/number/bool/date/json/select-union/relation/file, single + multi);
- expand-narrowing single + multi;
- all where operators + nested relation + `AND`/`OR`;
- `create`/`update` shapes (required vs optional, `file → File | Blob`, auth `password` /
  `passwordConfirm`, `Update = Partial<…>` incl. the auth `Omit`);
- fluent builder operand typing;
- concrete service signatures (`getOne`/`getList`/`getFirstListItem`/`getPage`/`iterate`/
  `getFullList`/`create`/`update`/`delete`/`filter`, with expand-narrowing generics);
- realtime alias (`RawTypedRealtime<Rec, Where>`);
- per-collection `fileUrl` / `<Rec>FileField` typing (single-value only);
- `@ts-expect-error` negatives for each rejection (wrong operator type, non-existent field,
  bad expand key, multi-value `fileUrl`, etc.).

### B. Golfsim — grounded real example (self-contained in `examples/golfsim/`)

**B1. Refactor to the codegen convention.** Split `examples/golfsim/src/main.zig`: hoist
`pub const App = zigbase.App(.{…})` to module scope and make `pub fn main(init) → App.runCli(init)`
(today the `App(.{…})` is built inline inside `main`). Behavior is unchanged; this exposes the app
type for the generator.

**B2. Wire `genClientStep`.** In `examples/golfsim/build.zig`, wire the zigbase `genClientStep`
helper so `zig build gen-client` emits a **committed** `zbase.gen.ts` under `examples/golfsim/`
(exact path chosen in the plan), plus a `zig build gen-client-check` staleness step. golfsim's `package.json` gains `@zigbase/client` +
`@zigbase/client/typed` (workspace-linked to `clients/typescript`).

**B3. Golfsim self-contained e2e.** A minimal vitest setup in `examples/golfsim/` (package.json
test script + vitest config + a small harness spawning the built `golfsim` binary, mirroring
`harness.ts`'s schema-baked path). The e2e drives **fuller** CRUD/auth across golfsim's collections
(`users` auth, `simulators`, `listings`, `bookings`, `reviews`) through the generated client.
golfsim's custom **routes** are typed-RPC = **SP2.2**, so out of scope here — collections only.

### C. CI (`.github/workflows/ci.yml`)

Extend the existing `ts-sdk` job (it already builds the zig binary + runs `npm ci` / `typecheck` /
`test` / `test:integration`):

- build the generator + `dating-server` + `golfsim` binaries;
- run `zig build gen-dating-client-check` **and** golfsim's `gen-client-check` (staleness gates);
- run the dating type-level suite + the dating e2e suite;
- run golfsim's self-contained e2e.

Reuses the job's existing zig + node (mise) setup; no new runner image. The type-level suite runs
under the existing `npm test` / `typecheck`; the e2e suites run under the integration config
(forks, `fileParallelism: false`).

### D. Docs sync

Per the standing rule that every change keeps published docs/examples in sync: update golfsim's
README (the new `pub const App` + `zig build gen-client` flow), the `site/` mirror + any
`docs/*.md` codegen pages, and the examples index to reflect the generated-client story.

## Testing strategy

- **Type-level:** compile-time — vitest `expectTypeOf` + `tsc --noEmit` (`npm run typecheck`).
- **e2e:** vitest integration config (`pool: forks`, `fileParallelism: false`, 60s test / 120s
  hook timeouts), spawning real schema-baked binaries; synchronize on explicit conditions.
- **Staleness:** `gen-client --check` for dating + golfsim in CI.
- **Zig unit tests:** the dating-server build target compiles clean under `zig build`; existing
  emit/guard unit tests are unchanged.

## Scope / out of scope

**In:** the dating-server binary target, the generalized harness, the dating e2e + type-level
suites, the golfsim refactor + `genClientStep` wiring + committed client + fuller self-contained
e2e, the CI extensions (staleness gates + suites), and the docs sync.

**Out (later):**
- **Typed RPC / golfsim custom routes** → SP2.2 (the framework route-typing change). golfsim e2e
  covers collections only.
- **The runtime-introspection client** → SP3.
- **A golfsim frontend integration** (wiring the generated client into golfsim's Astro/React UI) —
  a possible future demo, not required for validation.

## Risks & mitigations

- **CI build time** — two extra binaries (dating-server, golfsim) add compile time. Acceptable;
  they build in the existing job alongside the main binary and can share the zig cache.
- **Realtime / file-upload flakiness** — synchronize on event receipt / upload completion with
  bounded timeouts, never fixed sleeps (the admin OAuth nav-race lesson).
- **golfsim → SDK workspace wiring** — golfsim must resolve `@zigbase/client` from the local
  package; use the repo's workspace/link mechanism and verify in CI.
- **Harness regression** — generalizing `harness.ts` must not break the existing 4 integration
  tests; keep their path intact and covered.

## Task order (for the implementation plan)

dating fixture refinement (split `photos` / `privatePhotos`, regenerate golden) → dating-server
binary → harness generalization → dating e2e → dating type-level suite → golfsim refactor +
`genClientStep` wiring + committed client → golfsim e2e → CI extensions → docs sync.
