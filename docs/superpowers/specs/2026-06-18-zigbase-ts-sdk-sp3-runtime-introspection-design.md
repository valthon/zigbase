# ZigBase TS SDK — SP3: Runtime-Introspection Client Generator (`zigbase typegen`)

**Status:** Approved design (2026-06-18)
**Tier:** SP3 of the three-tier client SDK strategy — the "enhanced dynamic / runtime-introspection" tier. Explicitly a *lesser* tier than the SP2 comptime-bespoke SDK; it reuses SP2's emitter rather than replacing it.
**Predecessors:** SP1 (base `@zigbase/client`, shipped) · SP2.1 (typed core + comptime collection generator, shipped) · SP2.2 (typed RPC, shipped). See `2026-06-16-zigbase-ts-sdk-comptime-codegen-design.md` and `2026-06-17-zigbase-ts-sdk-sp2.2-typed-rpc-design.md`.

---

## 1. Problem & Audience

SP2's generator produces a beautiful, fully-typed `zbase.gen.ts` from **comptime introspection** of a ZigBase app's Zig source (`pub const App`). That requires the Zig source and a `build.zig` wired with `genClientStep`.

SP3 serves a different consumer: **a team that consumes a ZigBase backend as a black box** — they have a *running/deployed instance* (a binary, a data dir, or a URL) but not the Zig source, and they do not customize the engine (no custom routes). They still want the same typed client DX.

**Goal:** Emit the *same* typed `zbase.gen.ts` as SP2's generator, but sourced from a running instance's **actual persisted schema** instead of its Zig source.

**Why "lesser tier":** the runtime schema (the `_collections` system table / `GET /api/collections`) exposes the full **db / realtime / files** surface but **not** custom routes — they are comptime-only and serialized nowhere at runtime. Since SP3's audience does not define custom routes, SP3 emits **no `rpc.*` surface**. For everything it does emit, the output is byte-identical to the comptime generator.

## 2. Key Insight — One Emitter, Several Front-Ends

The SP2 emitter is already pure and schema-driven. `src/codegen/emit.zig`, `ts_type.zig`, `identifiers.zig`, and `guards.zig` operate on `[]const schema.Collection` / `schema.Field` structs — **no comptime-`type` dependency** for the collection surface. (`rpc.zig`/`rpc_ts.zig` are the only comptime-`type` parts, and they are out of scope here.)

So SP3 is **not a second generator**. It is a set of *schema-acquisition adapters* that each produce `[]schema.Collection`, feeding the **existing** `gen_client.generate(collections, routes = &.{})`. One emitter, zero drift between the comptime-generated and runtime-generated clients.

```
                                     ┌─────────────────────────┐
  --data-dir ──▶ acquire_datadir ──▶ │                         │
                                     │  []schema.Collection    │──▶ gen_client.generate(cols, routes=&.{})
  --url ───────▶ acquire_http ─────▶ │  (normalized, identical │         (existing SP2 emitter)
                  (superuser auth)   │   regardless of source) │                 │
                                     └─────────────────────────┘                 ▼
                                                                          zbase.gen.ts  (no rpc.* section)
```

## 3. Decomposition

Two independently shippable sub-projects (each its own plan → PR):

- **SP3a — the engine (all-Zig, self-validating).** Config gate + `typegen` CLI subcommand + both acquisition adapters + reuse of `gen_client.generate`. Validated entirely Zig-side: an equivalence test proving the runtime output matches the comptime output, a committed golden + `--check` staleness gate, and adapter/CLI unit tests. Fully usable via the Zig binary. **This spec fully specifies SP3a.**
- **SP3b — distribution & live proof (TS/packaging).** `@zigbase/typegen` npm wrapper bundling per-platform prebuilt static binaries (CI cross-compile with the gate enabled) + a TypeScript live e2e that imports the runtime-generated client and exercises CRUD/expand/realtime/int-coercion against `dating-server`. **Sketched in §10; gets its own spec/plan after SP3a lands.**

---

## 4. SP3a — Components

All new files live under `src/codegen/` alongside the existing generator.

### 4.1 Config gate (comptime config, not a build flag)
A boolean on the engine's existing comptime config (`src/config.zig` `Config`), defaulting **false**:

```zig
/// When true, compiles the `typegen` CLI subcommand into the binary.
/// Off by default so production server builds carry no codegen.
/// Our official static/distributed builds set this true.
enable_typegen: bool = false,
```

The CLI dispatch in `src/framework.zig` (`runCliImpl`) checks this comptime field and only wires the `typegen` subcommand when true. When false, `typegen` is not a recognized subcommand and none of the codegen acquisition code is referenced (so it can be dead-code-eliminated). No new HTTP endpoint is registered (remote auth reuses the existing superuser flow — see §5).

### 4.2 `src/codegen/typegen_cli.zig` — CLI orchestrator
Parses args, selects an adapter, runs the emitter, writes or checks the output.

```
zigbase typegen (--data-dir <path> | --url <origin>) --out <file>
                [--api-prefix <prefix>] [--client-name <name>] [--check]
                [--admin-email <e> --admin-password <p>]   # only with --url
```

- Exactly one of `--data-dir` / `--url` is required (error if both or neither).
- `--out` required (the target `.gen.ts` path).
- `--api-prefix` defaults to `/api` (passed through to `gen_client.generate`, same as SP2).
- `--client-name` defaults to `ZbClient` (the exported client type/factory name; `generate` takes it as a parameter).
- `--check`: regenerate in memory and diff against the existing `--out` file; exit 0 if identical, exit non-zero (printing a unified diff) if drift — mirrors SP2's `genClientStep --check` staleness gate.
- With `--url`, `--admin-email`/`--admin-password` are required (superuser credentials).

### 4.3 `src/codegen/acquire_datadir.zig` — offline adapter (primary)
`pub fn acquire(alloc, data_dir: []const u8) ![]schema.Collection`

Opens the data dir's SQLite database (the engine's existing `db` open path), reads the `_collections` system table, and reconstructs each `schema.Collection` using the engine's **existing** parsers: `schema.parseCollectionInput` / `schema.fieldsFromJson` / `schema.optionsFromJson` / `schema.indexesFromJson` (the `_collections` row stores `schema`, `options`, `indexes` as JSON columns). No auth, no server, no HTTP — ideal for CI where the data dir is a file artifact.

System collections that the comptime emitter does not emit (e.g. `_superusers`, other `system = 1` rows) are filtered out to match comptime output exactly. The exact filter predicate is pinned by the equivalence test (§7).

### 4.4 `src/codegen/acquire_http.zig` — remote adapter
`pub fn acquire(alloc, io, origin, email, password) ![]schema.Collection`

1. `POST {origin}/api/collections/_superusers/auth-with-password` with `{ identity, password }` → superuser token.
2. `GET {origin}/api/collections` with `Authorization: Bearer <token>` (the endpoint requires superuser — `collections.zig` `requireSuperuser`).
3. Parse the returned JSON array into `[]schema.Collection` via the **same** `*FromJson` parsers used by the data-dir adapter, so both adapters produce byte-identical normalized collections. Apply the same system-collection filter.

### 4.5 Reuse — no emitter changes
Both adapters hand `[]schema.Collection` to the **existing** `gen_client.generate`. Its signature is already runtime-friendly:

```zig
pub fn generate(alloc, cols: []const schema.Collection, comptime routes: []const events.RouteMeta,
                in_repo: bool, auth_collection: []const u8, client_name: []const u8, api_prefix: []const u8) ![]const u8
```

`cols` is a plain runtime slice and `routes` is passed as the comptime-empty literal `&.{}` — **exactly** how `gen_client.zig`'s own unit tests already call it (e.g. `generate(a, cols, &.{}, true, "users", "BlogClient", "/api")`). So **no wrapper and no emitter edits are needed**. With empty routes the emitter's existing zero-route path emits output with **no `rpc.*` section** (proven byte-identical to the no-route case in SP2.2b). `typegen_cli` supplies the remaining args: `in_repo = false` (output is consumed outside the repo), `auth_collection = gen_client.authCollectionName(cols)` (the existing helper), `client_name` from `--client-name` (default `ZbClient`), and `api_prefix` from `--api-prefix`. `emit.zig`/`ts_type.zig`/`identifiers.zig`/`guards.zig`/`gen_client.zig` are reused untouched.

## 5. Remote Auth (v1)

v1 reuses the **existing** superuser auth flow (`/api/collections/_superusers/auth-with-password`). No new endpoint, no new token type. The data-dir adapter is the recommended primary path (no creds needed); `--url` is the remote fallback for operators who already hold superuser credentials. A dedicated short-lived schema-scoped introspection token is explicitly deferred (possible future enhancement, not in SP3).

## 6. Data Flow & Normalization

`acquire_*` → `[]schema.Collection` → (filter system collections) → `gen_client.generate` → TS string → write to `--out` **or** (`--check`) diff against existing.

**Fidelity requirement:** the normalized `[]schema.Collection` from either adapter must be field-for-field equivalent to what the comptime path holds for the same app — including field ordering (`recordFields()` order: id → auth-visible → user fields → created/updated), number `mode`/`scale`, select `values`/`maxSelect`→`multi`, relation `targetCollectionId` resolution, and `type` (base/auth/view). The equivalence test (§7) is the enforcement mechanism: any normalization gap shows up as a diff.

## 7. Validation — the Correctness Anchor (SP3a)

The `dating` fixture already compiles into a runnable `dating-server` binary (built in SP2 Plan 2) and its **comptime**-generated client is committed at `clients/typescript/test/codegen/dating/zbase.gen.ts`.

1. **Equivalence test (the killer test).** Run `typegen` against the dating schema in **both** modes:
   - `--data-dir <dating data dir>`
   - `--url <dating-server origin>` (with the test superuser creds)

   Assert each output equals the committed comptime dating client **with its `rpc` section and provenance header removed**. The dating fixture has custom routes (so its comptime client has an `rpc.*` block) but the runtime path emits none, so the only legitimate delta is that block plus the header line. A small, well-documented `stripRpcAndHeader()` helper normalizes the comptime baseline for comparison. Byte-identical collection surface from both runtime adapters proves the front-ends are faithful and the emitter reuse is real.

2. **Golden + `--check` staleness gate.** Commit a runtime-generated golden (`clients/typescript/test/codegen/dating/zbase.runtime.gen.ts`) and a CI gate that runs `typegen --data-dir … --check` against it, failing on drift — mirroring SP2's `gen-test`/`--check` gates.

3. **Unit tests.**
   - `acquire_datadir`: `_collections` read + JSON→Collection parse fidelity against a known fixture data dir; system-collection filtering.
   - `acquire_http`: JSON→Collection parse from a captured `/api/collections` response fixture (parser-level; the live HTTP round-trip is covered by the equivalence test).
   - `typegen_cli`: arg parsing (mutually-exclusive sources, required args), `--check` exit codes (0 on match, non-zero + diff on drift).

The TypeScript **live e2e** (import the generated client, run it against `dating-server`) belongs to SP3b, where the npm packaging lives.

## 8. Error Handling

Friendly, actionable errors for: both/neither source given; unreachable `--url`; auth failure (bad creds / non-superuser); missing or locked data dir; malformed `_collections` row / unparseable schema JSON; `--out` unwritable. `--check` drift prints a unified diff and exits non-zero. Ambiguous-identifier rejection reuses the existing emitter `guards` (e.g. operator-name clashes), so SP3 inherits SP2's validation for free.

## 9. Scope Boundaries ("lesser tier")

- **No `rpc.*`.** Routes are not introspectable at runtime; SP3's audience does not define them.
- **Fidelity bounded** to what `_collections` / `GET /api/collections` expose — which is the complete db/realtime/files surface (byte-identical to comptime), nothing less.
- **Distinct from SP1.** SP1 is a hand-written, untyped dynamic client. SP3 produces a *static, fully-typed artifact* (`zbase.gen.ts`) — same file the comptime tier produces, minus rpc.
- **One emitter.** SP3 adds acquisition adapters + a CLI; it does not fork or reimplement the emitter.

## 10. SP3b — Distribution & Live Proof (follow-on sketch)

To be detailed in its own spec/plan after SP3a merges:

- **`@zigbase/typegen` npm package** — a thin wrapper that bundles per-platform prebuilt static binaries (built in CI with `enable_typegen = true`) and launches the bundled binary's `typegen` subcommand. `npx @zigbase/typegen --data-dir ./pb_data --out zbase.gen.ts`.
- **CI cross-compilation & publishing** of the static binaries (the matrix + release wiring).
- **TypeScript live e2e** — import the runtime-generated dating client and run CRUD / nested-filter / expand / realtime / int-and-fixed coercion against `dating-server` via the existing `startAppServer` harness, proving the emitted types + runtime coercion work end-to-end (parallels SP2.2b's `rpc.integration.test.ts`).
- **Docs** — new `@zigbase/typegen` README; the runtime-introspection section in `docs/typescript-sdk.md` ↔ `site/` mirror; a framework-docs note that `enable_typegen` gates the subcommand.

## 11. Documentation Sync (SP3a)

Per the project's docs-sync requirement, SP3a updates: a "Runtime introspection (`zigbase typegen`)" subsection in `docs/typescript-sdk.md` and its `site/src/content/docs/typescript-sdk.md` mirror; a note in `docs/framework.md` ↔ `site/` mirror that `config.enable_typegen` compiles in the subcommand (off by default); and a short mention in `clients/typescript/README.md`. The published `@zigbase/typegen` README is SP3b (it ships with that package).

## 12. File Map (SP3a)

- **Create:** `src/codegen/typegen_cli.zig`, `src/codegen/acquire_datadir.zig`, `src/codegen/acquire_http.zig`.
- **Modify:** `src/config.zig` (add `enable_typegen`), `src/framework.zig` (`runCliImpl` subcommand dispatch under the gate), `build.zig` (a `typegen`-enabled build + a `gen-test`-style staleness step for the runtime golden, if added there), CI workflow (run the `--check` gate), the docs files in §11.
- **Create (tests/fixtures):** `clients/typescript/test/codegen/dating/zbase.runtime.gen.ts` (golden), a captured `/api/collections` response fixture, and Zig test files for the three new modules (equivalence test may live alongside `gen_client`'s existing test or in a new `typegen_test.zig`).
- **Reuse untouched:** `src/codegen/emit.zig`, `ts_type.zig`, `identifiers.zig`, `guards.zig`, `gen_client.zig` (collection surface), `src/schema.zig` parsers (`parseCollectionInput`/`fieldsFromJson`/`optionsFromJson`/`indexesFromJson`).
