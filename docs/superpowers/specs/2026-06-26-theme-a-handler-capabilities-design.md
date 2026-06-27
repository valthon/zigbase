# Theme A — Unified Handler/Hook Capability Context (`ctx`)

**Status:** Design approved 2026-06-26. Pending implementation plan.

## Background

Open issues #80–#88 were filed by agents porting a real application onto ZigBase.
They are deliberately narrow — each describes a specific hole the port fell into.
Read together, they share one meta-pattern: **the consumer-facing surface
(handler/hook `ctx`/`data`, collections, auth) lags the framework's own internal
surface.** The moment a consumer writes custom Zig code, they fall off a cliff and
must re-implement what the framework already does internally.

The nine issues regroup into four foundational themes (see memory
`zigbase-improvements-four-themes`). **This spec covers Theme A only.**

Theme A — *the handler/hook capability layer* — contains #85 (query API for
handlers), #83 (outbound HTTP client), #86 (clearSession; the seam where Theme A
meets Theme D), and the request-context half of #80. The governing principle:

> Anything the framework can do in service of a request, a consumer handler can do
> too — through one coherent capabilities object at parity with the HTTP layer.

A second governing constraint (see memory `progressive-disclosure-defaults`):

> Every new capability ships with sane defaults and shortcuts so the common case
> stays a one-liner. Power is available but never mandatory.

## Goals

- Replace the scattered consumer surface (`RouteEvent` + `Data` + `reader()`/`writer()`
  RAII handles + `ctx`/`rctx`) with a single, discoverable `Ctx` object.
- Give handlers capability parity with the HTTP layer: filtered/sorted/paginated
  queries **with expand/relations**, multi-write transactions, an outbound HTTP
  client, a standard error contract.
- Keep the 90% case a one-liner — connection lifetime and transactions are managed
  for the consumer by default.
- Make the change once, cleanly, while pre-1.0 (breaking changes are acceptable).

## Non-goals (this cycle)

- `ctx.mail`, `ctx.storage`, `ctx.realtime.broadcast`, and the `ctx.auth` session
  verbs (`clearSession`, refresh/rotate/list/revoke). These **slots are defined in
  the design** so later work plugs in cleanly, but they are built in follow-up
  slices (mail/storage/realtime) or with **Theme D** (`ctx.auth`).
- Themes B (data shapes/policies), C (determinism), D (auth lifecycle). Separate
  specs.

## Current state (grounding)

- `Data` facade — `src/data.zig:27`, re-exported `src/root.zig:9`. Methods:
  `findById`, `create`, `update`, `delete`, `list(col, records.ListQuery)`.
  `data.list` already reaches the query engine, so #85's engine exists; the gap is
  ergonomics, expand parity, and discoverability.
- `RouteEvent` — `src/events.zig:129`. Fields `app`, `ctx: *http.RequestCtx`,
  `rctx: request.RequestContext`; methods `writer()` → `WriterData`, `reader()` →
  `ReaderData`, `issueSession()`. RAII handles at `src/events.zig:39`.
- Query engine — `src/query/` (lexer → parser → compiler), internal; driven by
  `records.list` (`src/records.zig`), which compiles filter/sort into
  parameter-bound SQL. `ListQuery`/`ListResult` shapes already support expand-less
  filter/sort/paginate/cursor.
- Internal HTTP client — used by the OAuth2 token exchange (`src/oauth/`); not
  exposed to consumers.
- DB model — `src/db.zig`: pool of warm readers + single mutex-guarded writer; WAL.
- before-hooks today run **outside** the write transaction (`src/db.zig` / hook
  dispatch); after-hooks are post-write side effects.

## Design

### 1. The `Ctx` object

A single `Ctx` is constructed per invocation (per request for route handlers, per
write for record hooks, per fire for cron jobs) and passed to all consumer code. It
holds a reference to the App (capability backend), the request-scoped arena,
internal lazy-connection state, and optional request/auth info. Capability surface:

| Member | Shape | Purpose |
|--------|-------|---------|
| `ctx.records` | namespace | CRUD + query + expand |
| `ctx.tx(fn)` | method | transactional scope |
| `ctx.http` | namespace | outbound HTTP client (#83) |
| `ctx.request` | `?Request` | method/path/query/headers/body/params/cookies/files |
| `ctx.user` | `?User` | id, collection, is_superuser |
| `ctx.fail` / `ctx.invalid` | methods | error helpers |
| `ctx.mail` *(deferred)* | namespace | configured mailer |
| `ctx.storage` *(deferred)* | namespace | Storage vtable |
| `ctx.realtime` *(deferred)* | namespace | custom event broadcast |
| `ctx.auth` *(deferred → Theme D)* | namespace | session verbs incl. clearSession (#86) |

### 2. Uniform delivery (the breaking change)

All consumer signatures move to `ctx`-first:

```zig
// route handler
fn handler(ctx: *Ctx) !Response { ... }
// record hook
fn onBeforeCreate(ctx: *Ctx, ev: *RecordEvent) !void { ... }
// cron job
fn nightly(ctx: *Ctx, ev: *JobEvent) !void { ... }
```

In a cron job, `ctx.request` and `ctx.user` are `null`, but `ctx.records`,
`ctx.tx`, and `ctx.http` still work. This is a deliberate pre-1.0 reshape: all three
examples (`blog`, `golfsim`, `plugins`), `docs/framework.md`, and the `site/` mirror
are updated; a `changelog.d/` fragment records it under **Breaking** + **Features**.

### 3. Connection & transaction model

- **Reads:** `ctx` lazily checks out one reader from the pool on the first read and
  reuses it for the ctx's lifetime; released at teardown. (One cached reader per
  ctx — not one per call.)
- **Single writes:** `ctx.records.create/update/delete` grabs the writer mutex, runs
  the statement (+ folded before-hooks, see below), releases immediately. The writer
  is **never** held across `ctx.http` or other arbitrary handler work, so writes do
  not serialize behind network round-trips.
- **`ctx.tx(fn)`:** acquire writer → `BEGIN IMMEDIATE` → run `fn` with a `*Tx`
  exposing the same `records` namespace bound to the transaction connection →
  `COMMIT`; auto-`ROLLBACK` on any returned error. **Nested `tx` is disallowed in
  v1** and returns `error.NestedTransaction`. Closures are expressed via Zig's
  struct-with-`fn` pattern (no native closures); the exact carrier is an
  implementation-plan detail.
- **before-hooks folded into the write transaction.** The write path becomes:
  acquire writer → `BEGIN` → run before-hooks (may mutate `ev.record` via the arena;
  may `return error` to abort → `ROLLBACK`, the write fails closed) → execute write
  → `COMMIT`. **after-hooks stay post-commit** (they are side effects). Hooks receive
  a `ctx` bound to the **same** transaction connection, so a hook's own reads/writes
  participate in the transaction.

### 4. `ctx.records` + expand

```zig
const page = try ctx.records.list("orders", .{
    .filter = "status = 'open' && created >= :since",
    .sort = "-created",
    .expand = "customer,items",
    .limit = 30,
});
const order = try ctx.records.get("orders", id, .{ .expand = "customer" });
_ = try ctx.records.create("orders", value);
_ = try ctx.records.update("orders", id, patch);
_ = try ctx.records.delete("orders", id);
```

`list`/`get` accept the existing filter/sort/paginate/cursor options **plus
`expand`**, reusing the HTTP layer's expand resolver (shared code) to close the
parity gap. **Default: handler record ops are trusted and bypass collection access
rules** (matching today's `Data` facade). A handler that wants to act *as the
caller* opts in via `.rule` / `asUser(ctx.user)` to enforce rules. Results are typed
record values owned by the ctx arena.

### 5. `ctx.http` (#83)

```zig
const res = try ctx.http.get(captcha_url);              // one-liner
const res2 = try ctx.http.post(url, .{ .headers = h, .body = json });
const res3 = try ctx.http.request(.{ .method = .PUT, .url = u, ... });
// res: { status: u16, headers, body: []const u8 }  (arena-owned)
```

Wraps the existing internal OAuth HTTP client. **TLS-verified by default; default
timeout ~10s**, overridable per call. The simple case is a one-liner; an options
struct exposes headers/body/timeout. (SSRF guardrails are noted as a future
hardening item, not built this cycle.)

### 6. Error model

Canonical envelope, matching the records HTTP API:

```json
{ "status": 404, "message": "no such order", "data": {} }
```

A framework error set maps to status codes:

| Zig error | HTTP |
|-----------|------|
| `error.NotFound` | 404 |
| `error.Forbidden` | 403 |
| `error.Unauthorized` | 401 |
| `error.BadRequest` | 400 |
| `error.Conflict` | 409 |
| any other / uncaught | 500 (safe generic body; details logged, never leaked) |

Helpers: `ctx.fail(status, msg)` and `ctx.invalid(fieldMap)` (→ 400 with a field
error map). An explicit `Response{…}` remains the escape hatch for fully bespoke
responses (custom headers, file streaming, redirects).

### 7. Public-surface cleanup

`ctx.records` is implemented over the same internal record functions the `Data`
facade uses today. **The public `Data` re-export is removed from `src/root.zig`;**
`Data` remains internal. Consumers use `ctx`. This is part of the breaking reshape.

## Testing

- **Zig unit tests:** `ctx.records` CRUD + list/get with expand; `ctx.tx` commit and
  rollback; **before-hook abort rolls back the write** (atomicity); error→status
  mapping and envelope shape; `ctx.http` against a local test server.
- **Browser/pytest suite (`tests/admin/`):** confirm existing admin flows survive
  the signature reshape (unit-green has repeatedly hidden browser regressions); add
  a custom route that exercises `ctx.records` + `ctx.http` + `ctx.tx` end-to-end.
- **Examples:** update all three to the new signatures — `golfsim` showcases
  `ctx.records`/`ctx.tx`, `plugins` the advanced surface, `blog` stays minimal.

## Docs & changelog

- `docs/framework.md` rewritten for the `ctx` surface; **`site/src/content/` mirror**
  updated; READMEs/examples synced (see memory `keep-published-docs-and-examples-in-sync`).
- `changelog.d/<slug>.md` fragment with `### Breaking` (signature reshape, `Data`
  re-export removal) and `### Features` (`ctx`, transactions, expand-in-handlers,
  HTTP client, error model). Do **not** edit `CHANGELOG.md` directly.

## Committed defaults (decision record)

- One cached reader per `ctx` (not per call).
- Nested `ctx.tx` disallowed in v1 (`error.NestedTransaction`).
- after-hooks remain post-commit; only before-hooks fold into the transaction.
- Handler record ops bypass access rules by default; rule enforcement is opt-in.
- `ctx.http` TLS-verified, ~10s default timeout.
- Public `Data` re-export removed.

## Out of scope / follow-ups

- `ctx.mail`, `ctx.storage`, `ctx.realtime.broadcast` — slots defined; built later.
- `ctx.auth` session verbs incl. `clearSession` (#86) — built with **Theme D**.
- SSRF guardrails for `ctx.http`.
- Savepoint-based nested transactions.
