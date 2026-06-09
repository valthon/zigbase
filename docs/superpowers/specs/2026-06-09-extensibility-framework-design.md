# ZigBase Extensibility Framework + v0.1 Release — Design

**Sub-project 10 (SP10).** Status: design approved, pending implementation plan.

**Goal:** Turn ZigBase from an executable-only application into an importable, extensible
Zig framework — devs `zig fetch --save` it and build their own apps on top via comptime
registration of event hooks, custom HTTP routes, and scheduled jobs — then cut a real,
documented, Apache-2.0-licensed **v0.1.0** release with cross-platform binaries.

This is the final sub-project of the ZigBase roadmap. The MVP (SP1–SP9) is complete and
merged to `main`; SP10 makes it consumable.

---

## 1. Architecture & package surface

Three cleanly separated concerns:

1. **The event bus (internal architecture).** A typed event system. Existing modules
   (`records.zig`, `auth.zig`, `files.zig`, and the server lifecycle) gain `emit()` call
   sites at well-defined points. Events carry a typed payload by reference. This is the
   spine through which all extensibility (and error handling) flows.

2. **The `App` facade (the stable public data API).** The key to keeping the public API
   both stable and powerful. Hooks, custom routes, and cron jobs never receive a raw
   SQLite connection or zap type — they receive `*App`, which offers curated, HTTP-free
   data operations (`app.records.findById(col, id)`, `app.records.create(col, json)`,
   `app.records.update(...)`, `app.records.delete(...)`, list/query helpers), reusing the
   exact `records.zig` logic the REST layer already uses. SQLite/zap types never appear in
   the public surface, so consumers don't couple to internals and the API stays stable
   across the 0.x series.

3. **Comptime registration (the consumer's surface).** A consumer instantiates
   `zigbase.App(.{ .hooks = .{...}, .routes = .{...}, .cron = .{...}, .jobs = .{...} })`.
   The comptime config declares subscribers; at startup they are assembled into runtime
   dispatch tables keyed by event. Zero-cost enumeration, compile-time-checked handler
   signatures.

### Package surface

The repo exposes a single public module, `zigbase`, via `b.addModule("zigbase", ...)`, with
the vendored SQLite C source + include path + the `zap` dependency baked **into that
module**. A consumer:

```sh
zig fetch --save git+https://github.com/<owner>/zigbase
```
```zig
// consumer build.zig
const zigbase_dep = b.dependency("zigbase", .{ .target = target, .optimize = optimize });
exe_mod.addImport("zigbase", zigbase_dep.module("zigbase"));
```

They never see SQLite or zap; the module carries them transitively (zap already does this
for facil.io, so there is precedent in the build graph).

The shipped `zigbase` binary becomes `zigbase.App(.{})` (empty config) consuming this same
module — the framework is dogfooded by default, guaranteeing the library path stays
first-class and the binary never drifts from the public API.

### New / changed file layout

```
src/root.zig      NEW  public re-exports = the `zigbase` module entry point
src/app.zig       NEW  the App facade (data ops) + the comptime App(cfg) builder
src/events.zig    NEW  event taxonomy + bus + comptime->runtime dispatch assembly
src/cron.zig      NEW  schedule parsing + scheduler thread + job pool + state machine
src/main.zig      MOD  slims to a thin consumer of root.zig (App(.{}).runCli())
src/server.zig    MOD  custom-route dispatch (post-auth, post-builtin); lifecycle emits
src/records.zig   MOD  before/after emit() call sites around the write transaction
src/auth.zig      MOD  auth event emit() call sites
src/api/files.zig MOD  file event emit() call sites
build.zig         MOD  expose `zigbase` module (SQLite C + zap attached); keep exe
examples/blog/    NEW  standalone consumer app: own build.zig.zon, zig-fetches this repo
```

---

## 2. Event taxonomy & execution semantics

Events group by subsystem. Each `before*` is mutate/abort-capable; each `after*` is a
post-commit side-effect point.

### Record events (per-collection + a `*` wildcard for all collections)

- `record.beforeCreate` / `record.afterCreate`
- `record.beforeUpdate` / `record.afterUpdate`
- `record.beforeDelete` / `record.afterDelete`

Payload: `*RecordEvent { app: *App, ctx: *RequestContext, collection: []const u8,
record: *std.json.Value, op: enum { create, update, delete } }`. `record` is mutable in
`before*`. `ctx` carries the resolved auth identity / `is_superuser`, so hooks see who is
acting.

### Auth events

- `auth.beforeAuthWithPassword` / `auth.afterAuthSuccess` (covers password + OAuth2 via a
  `method` field)

Payload: `*AuthEvent { app: *App, ctx: *RequestContext, collection: []const u8,
record: ?*std.json.Value, method: enum { password, oauth2 } }`.

### File events

- `file.afterUpload` (record + field + stored filename)
- `file.beforeServe` (can deny → 404)

Payload: `*FileEvent { app: *App, ctx: *RequestContext, collection: []const u8,
record_id: []const u8, field: []const u8, filename: []const u8 }`.

### Lifecycle events

- `app.afterBootstrap` (post-migration, pre-listen — seed data / dynamic setup)
- `app.beforeServe`
- `app.beforeTerminate` (graceful cleanup)

Payload: `*LifecycleEvent { app: *App }`.

### Error event

- `app.onError`

Payload: `*ErrorEvent { app: *App, ctx: ?*RequestContext, err: anyerror,
phase: enum { request, before_hook, after_hook, cron, job, file_serve },
message: []const u8 }`.

Every caught/swallowed error in the framework routes here rather than being silently
dropped. Consumer `onError` handlers run **first**; a built-in backstop runs **after** them
and always executes: if `sentry_dsn` is configured it reports to Sentry via a minimal
envelope client over `std.http.Client` (reusing the OAuth `httpTransport` pattern, response
and timeout bounded), otherwise it `std.log`s. Either way the error is swallowed so it can't
cascade. New config: `sentry_dsn` (env `ZIGBASE_SENTRY_DSN`, default empty = log mode).

### Execution semantics

- **`before*` runs synchronously inside the operation's transaction / critical section.**
  Handlers fire in registration order. A handler may mutate the payload (e.g., set
  `record.slug`) and/or return an error. **An error aborts the operation** — for records,
  transaction rollback — and maps to an `ApiError` (default 400; a handler may select a
  status via a typed error). This expresses validation / authorization beyond SP4 rules.
- **`after*` runs synchronously after commit.** The write is already durable, so a handler
  error **cannot** roll it back; the error routes to `app.onError` (`phase = .after_hook`)
  and is swallowed so one flaky side-effect never 500s a succeeded write. `after` handlers
  use `*App` for follow-on work through normal transactional paths.
- **Wildcard + specific both fire**, wildcard first, so cross-cutting concerns (audit log)
  and specific logic compose.
- **Ordering vs existing machinery:** `before*` hooks run **after** SP4 access rules pass
  (rules are the gate; hooks are app logic on already-authorized ops) and **within** the
  same `createGuarded` / `updateGuarded` transaction. `after*` hooks run **before** the SP7
  realtime `broadcast`, so a hook observes the committed state but cannot unsend an event.

---

## 3. Custom HTTP routes

### Registration (comptime)

```zig
.routes = .{
    .{ .method = .POST, .path = "/api/report",        .handler = report, .auth = .superuser },
    .{ .method = .GET,  .path = "/api/public/stats",   .handler = stats,  .auth = .public },
    .{ .method = .GET,  .path = "/api/me/dashboard",   .handler = dash,   .auth = .authed },
},
```

### Handler signature

`fn(ev: *RouteEvent) anyerror!Response`, where
`RouteEvent { app: *App, ctx: *RequestContext, params: Params }`. The same
`RequestContext` (auth identity, headers, body, captured path params) and `Response` /
`ApiError` envelope the built-in handlers use — a custom route is a first-class peer of the
built-in ones with full `App` data-facade access.

### Dispatch & precedence

Custom routes are matched in `server.zig` **after the auth middleware runs** (so
`ctx.auth` / `is_superuser` are populated) and **after** the built-in API router —
built-ins win on conflict, so a consumer cannot accidentally shadow
`/api/collections/...`. Path matching reuses the existing `router.zig` segment matcher with
`:param` capture.

### Auth gating

The `.auth` field (`.public` / `.authed` / `.superuser`) is enforced by the framework
before the handler runs: `.superuser` → 403 for non-superusers, `.authed` → 401 if no
identity, `.public` is the escape hatch. Consumers don't re-implement auth checks. Errors
thrown from a route route to `app.onError` (`phase = .request`) and return a 500 `ApiError`
(or the handler's chosen status via a typed error).

---

## 4. Scheduling modes + job pool

### Three scheduling modes (per job, comptime tagged)

```zig
.jobs = .{ .pool_size = 4 },     // comptime-configurable shared worker pool
.cron = .{
    .{ .name = "cleanup", .schedule = .{ .cron = "0 3 * * *" },           .handler = cleanup },
    .{ .name = "rollup",  .schedule = .{ .interval = .hourly },           .handler = rollup },
    .{ .name = "poll",    .schedule = .{ .interval = .{ .minutes = 15 } }, .handler = poll },
    .{ .name = "backoff", .schedule = .reactive,                          .handler = backoff },
},
```

- **`.cron`** — a 5-field expression (`minute hour day-of-month month day-of-week`, with
  `*`, `,`, `-`, `*/n`). Supported for those who want it.
- **`.interval`** — `.weekly` / `.daily` / `.hourly` presets, or `.{ .minutes = N }`.
- **`.reactive`** — the handler's return value sets the next delay (custom backoff).

Schedule and handler types:

```zig
const Interval  = union(enum) { weekly, daily, hourly, minutes: u64 };
const Schedule  = union(enum) { cron: []const u8, interval: Interval, reactive };
const Reactive  = union(enum) { after: Interval, stop };
// cron/interval handler:  fn(ev: *CronEvent) anyerror!void
// reactive handler:       fn(ev: *CronEvent) anyerror!Reactive
```

The handler signature required per job is enforced at comptime by the `schedule` tag.
`CronEvent { app: *App, name: []const u8 }` (alias of `JobEvent`; system context, no
request/auth — jobs act as system).

### Scheduler → job pool

A single long-running scheduler thread does **only** timing. It owns a comptime-sized
`state: [N]JobState` array (N = number of registered jobs; no map, no dynamic allocation):

```zig
const JobState = struct {
    status: enum { idle, queued, running, stopped },
    next_fire: i64,   // unix seconds, from the injectable clock
};
```

Only the scheduler thread mutates `state`. Loop: compute the soonest `next_fire` across all
non-`stopped` jobs, sleep until then (injectable clock; testable without real sleeps), wake,
and for each due job whose status is `idle`, flip it `idle → queued` and **submit** it to
the worker pool (it does not run the body inline). The worker runs the body, then reports
completion back through a channel; the scheduler alone transitions the job `running → idle`
(or `→ stopped` for reactive `.stop`) and stamps the next `next_fire` (from the schedule,
or from the reactive `.after` return). Authoritative status → **no double-fire, no races**.

- **Per-job single-flight:** a job still `running`/`queued` is not re-submitted (no pile-up
  if a run outlasts its interval).
- **Reactive:** next fire computed only **after** the run completes — natural backoff,
  never re-entrant.

### The pool is general-purpose and shared

Exposed on the `App` facade as `app.submit(name: []const u8, task: *const fn(*JobEvent)
anyerror!void) !void`, so **custom HTTP handlers and hooks can offload background work** and
return immediately (e.g., a route kicks off a slow export). Cron and on-demand work share
one pool sized by `.jobs.pool_size`.

### Concurrency

`pool_size` controls parallelism of job *bodies*; DB writes from any worker still funnel
through the SP1 writer-spinlock (serialized, no parallel writers), reads use per-call
connections — documented so nobody expects `pool_size` to parallelize writes. Worker errors
route to `app.onError` (`phase = .cron` / `.job`). On `beforeTerminate`: the scheduler is
signalled, the pool is drained and joined for a clean exit.

### Scope guard (YAGNI)

No seconds field, no timezone config (jobs evaluate in server local time — documented), no
distributed/multi-instance coordination (single-process only), no persistent run history.
Post-v0.1 if asked.

---

## 5. Error handling & testing

### Error handling

Unified through the `app.onError` event (§2): every framework-caught failure — before-hook
abort, after-hook failure, route error, cron/job error, file-serve denial — carries a
`phase` tag, runs consumer `onError` handlers, then the Sentry-or-log backstop. Before-hook
errors additionally roll back the transaction and surface as `ApiError`. Nothing is silently
dropped.

### Testing strategy

Matches the existing pure-handler + Playwright discipline.

**Unit (Zig), pure & injectable — under `zig build test`:**
- The schedule parser: cron expression, interval presets/minutes, and reactive → next-fire
  from a fixed `now`.
- The scheduler state machine: single-flight transitions, reactive next-delay, `.stop`,
  no-double-fire — driven by an **injectable clock with no real sleeps**.
- Comptime → runtime dispatch-table assembly for hooks / routes / cron.
- The `App` data-facade operations.
- The minimal Sentry envelope **serializer** (built, not sent, in tests).

**Behavioral (event semantics):**
- before-hook mutates a record and it persists.
- before-hook error rolls back (record not written).
- after-hook fires post-commit; its failure routes to `onError` without failing the write.
- wildcard + specific ordering (wildcard first).
- custom route sees auth context; `.superuser` / `.authed` gating returns 403 / 401.
- `app.submit` from a route runs on the pool.

**Integration proof — a real example consumer.** `examples/blog/` is a standalone app with
its own `build.zig.zon` that `zig fetch`es this repo and `@import("zigbase")`, registering a
hook + a custom route + a cron job. **CI builds it against the packaged module** — this is
what actually proves "consumable as a dependency," catching build-graph / packaging
breakage (SQLite C + zap transitivity) that unit tests can't. A small Playwright test drives
the example's custom route end-to-end.

**Regression pin:** the existing 209 Zig + 10 Playwright tests must stay green through the
`main.zig` → `App(.{})` refactor — behavior-preserving by construction.

Both `zig build` (binary, to catch unreferenced `pub fn` handler bodies) and
`zig build test` gate every task, per the established rule.

---

## 6. v0.1 release engineering

The second half of the work — packaging the (now framework-capable) project into a real
release. Its own implementation plan (**10b**), run after the framework (**10a**) lands.

### Legal & docs

- **`LICENSE`** — Apache-2.0 (full text; headers where conventional).
- **`README.md` rewrite** — currently describes only the Foundation sub-project. New README
  covers the whole product: what ZigBase is, quickstart (`superuser create` → `serve` →
  log into `/_/`), the feature matrix (collections, records + query, rules, auth, OAuth2,
  realtime, files, admin), and a "build an app on it" section pointing to the framework
  guide.
- **`docs/api.md`** — user-facing REST + WebSocket reference: endpoints, the filter/sort
  query language, auth flows (cookie/CSRF + bearer), record envelope. Distinct from the
  internal design specs under `docs/superpowers/`.
- **`docs/framework.md`** — the extensibility guide: `zig fetch --save`, wiring `build.zig`,
  the comptime `App(.{...})` config, event taxonomy + semantics, custom routes, the three
  scheduling modes + job pool, the `App` data facade, `error` / Sentry config. The
  `examples/blog/` app is the worked reference.
- **`KNOWN_LIMITATIONS.md`** — documents the deferred gaps honestly, loudest first:
  **password-reset / email-verification tokens are logged, not emailed (no mailer yet)**;
  **no rate-limiting on login / reset**; cron is single-process / local-time; no Windows
  build. Linked from README.

### Versioning & release

- Bump `build.zig.zon` `version` `0.0.0` → `0.1.0`; add `CHANGELOG.md` (Keep-a-Changelog
  style; a v0.1.0 entry summarizing all 10 sub-projects).
- **`scripts/release.sh`** — cross-compiles the binary via Zig's target matrix:
  `x86_64-linux-musl`, `aarch64-linux-musl` (static), `x86_64-macos`, `aarch64-macos`;
  packages each as a `.tar.gz` with a `SHA256SUMS` file; creates the GitHub release and
  uploads artifacts via `gh release create v0.1.0`. Windows excluded (facil.io / zap —
  documented). The script prints the artifact set before publishing.
- **CI (`.github/workflows/ci.yml`)** — on push / PR: `zig build`, `zig build test`, build
  `examples/blog/` against the packaged module, run the Playwright suite. This gate keeps
  the dependency story working.
- Tag `v0.1.0` as the final step (after CI green on `main`).

### Plan slicing

- **10a** — the framework: `events.zig` (bus + taxonomy + dispatch assembly), the `App`
  facade, the comptime `App(cfg)` builder, custom routes, the scheduler + job pool + state
  machine, `examples/blog/`, and the `main.zig` → `App(.{})` refactor. Gated by its own
  Zig + Playwright tests.
- **10b** — release engineering: license, docs (README / api / framework / limitations),
  changelog, `scripts/release.sh`, CI workflow, version bump, tag. Gated by CI + the example
  build.

---

## Out of scope (post-v0.1)

- Atomic arbitrary side-writes from `before` hooks against a raw transaction handle (the
  `App` facade is the stable seam; raw-DB access is intentionally not exposed).
- Custom CLI subcommands (not selected for v0.1).
- A real mailer + auth rate-limiting (documented as known limitations).
- Windows builds; cron timezones / seconds / distributed coordination / run history.
- Auth/file event expansion beyond the listed set; a general request-level middleware chain.
