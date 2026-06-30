---
title: Framework
description: Embed ZigBase as a Zig library — comptime record hooks, custom routes, scheduled jobs, a comptime schema with additive auto-migration, pluggable storage/mailer backends, and footprint levers.
order: 2
group: guides
---

# Building a Zig app on ZigBase

ZigBase is not only a standalone backend binary — it is an **embeddable Zig framework**.
You `zig fetch --save` it, `@import("zigbase")`, and configure `zigbase.App(.{...})` with
comptime hooks, custom routes, scheduled jobs, and lifecycle/auth/file event handlers.
Your app *is* the ZigBase server, plus your extensions.

> For runnable, end-to-end usage of these APIs (hooks, a custom route with a path param,
> and a DB-touching cron job), see the [Tutorial](./tutorial) and the [Recipes](./recipes).
> This page is the framework reference.

## 1. Overview

The shipped binary is, in its entirety:

```zig
const std = @import("std");
const zigbase = @import("zigbase");

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{}).runCli(init); // no extensions = the stock server
}
```

`App(cfg)` is a **comptime** application builder. Everything you register is assembled and
validated when your program compiles:

- An unknown config key (e.g. `.hook` instead of `.hooks`) is a **compile error**.
- A typo'd hook phase (e.g. `.beforeCreat`) is a **compile error**.
- A route or job spec missing a required field, or with a wrong-typed handler, is a
  **compile error**.
- An unknown key on a `.collections` collection or field spec (e.g. `.requied`,
  `.encrypte`, `.ttl_filed`, or a misspelled rule under `.rules`) is a
  **compile error** — the message lists the recognized keys for that spec.

So a misconfigured extension never reaches runtime — it fails the build loudly.

`runCli(init)` parses argv and dispatches the usual CLI (`serve`, `migrate`, superuser
creation, help), wiring your assembled extensions into the running server.
(`App(...).run(init, cfg)` starts the HTTP server directly with an explicit
`zigbase.Config`, skipping CLI parsing.)

## 2. Add the dependency

```sh
zig fetch --save git+https://github.com/valthon/zigbase
```

In your `build.zig`:

```zig
const zb = b.dependency("zigbase", .{ .target = target, .optimize = optimize });
exe_mod.addImport("zigbase", zb.module("zigbase"));
// exe_mod must link libc: zigbase carries the SQLite C source and zap transitively.
```

Your `exe_mod` must be created with `.link_libc = true` (the `zigbase` module itself is
built with `link_libc` and the bundled SQLite amalgamation + zap).

Minimal `src/main.zig`:

```zig
const std = @import("std");
const zigbase = @import("zigbase");

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{}).runCli(init); // no extensions = the stock server
}
```

## 3. The `App(.{...})` config keys

`App(.{...})` accepts exactly these optional keys. **Any other key is a compile error.**

| Key | Purpose |
| --- | --- |
| `hooks` | Per-collection record lifecycle hooks (before/after create/update/delete). |
| `onError` | Consumer error handler, runs before the built-in backstop. |
| `routes` | Custom HTTP routes. |
| `onAuth` | Notify-only: fires *after* a session is issued (login / oauth2). |
| `beforeAuthSuccess` | Writable, transactional, abortable hook that runs *before* the session is issued (claim records on first login; veto a login). |
| `auth` | Auth lifecycle hooks: before/after `register`, `logout`, `refresh`, `password-change`. |
| `onFileServe` | Fires before serving a file download (may deny). |
| `onFileUpload` | Fires after a file upload. |
| `onBootstrap` | Lifecycle: after bootstrap. |
| `onBeforeServe` | Lifecycle: just before the server starts serving. |
| `onBeforeTerminate` | Lifecycle: just before shutdown. |
| `cron` | Scheduled job table. |
| `jobs` | Scheduler `.pool_size` **and** the queue job-kind registry (kind → handler). See [Background jobs & queues](#7b-background-jobs--queues-queues--workers--jobs). |
| `queues` | Named background-job queues (backend `memory`/`durable`, priority, retry). A `.default` queue is always synthesized. See [Background jobs & queues](#7b-background-jobs--queues-queues--workers--jobs). |
| `workers` | Named queue workers (queue subset drained in strict priority + concurrency). Omit → one implicit worker over all queues. |
| `collections` | Comptime schema: collections provisioned at startup (additive auto-migration). |
| `migrations` | Explicit migrations (the escape hatch for non-additive schema changes). |
| `static_files` | Comptime static-file mode: absent (default flag), `.disabled`, `.{ .dir = "..." }`, `.{ .embedded = ... }`. |
| `storage` | Storage plugin TYPE (defaults to local-disk storage). |
| `mailer` | Mailer plugin TYPE (defaults to log/SMTP mailer). |
| `auth_methods` | Register custom `AuthMethod` plugin TYPES (comptime, like `.storage`/`.mailer`). |
| `pools` | Footprint levers: reader pool, job pool, thread stack size, SQLite page cache. |
| `pagination` | Enable/disable offset & cursor list paging and pick the cursor token format. |
| `session_store` | Session-management model: `.epoch` (default, stateless token-epoch revocation, zero extra DB work) or `.table` (server-side `_sessions` store for per-device list/revoke, one extra read per request). See [Revoking sessions](#revoking-sessions-99). |
| `session_gc_cron` | Cadence (UTC cron) for the table-mode expired-`_sessions` GC sweep. Default `"0 * * * *"` (hourly). Only valid with `.session_store = .table` — setting it otherwise is a `@compileError`. |
| `flags` | Declared boolean feature flags. See [Feature flags + experiments](#feature-flags--experiments-declared). |
| `experiments` | Declared A/B/n experiments (variants + weights, optional `.sticky`). See [Feature flags + experiments](#feature-flags--experiments-declared). |
| `experiment_assignment_ttl` | TTL in **days** for sticky `_experiment_assignments` rows (default `90`). Only valid when a `.sticky` experiment is declared — setting it otherwise is a `@compileError`. |
| `enable_typegen` | Enable the `typegen` CLI subcommand (default `false`). Set `true` only for client-generation builds. |
| `realtime` | Realtime broadcast guard: `.{ .canSubscribe = fn }` gates who may subscribe to a custom (non-collection) topic (default: custom topics are public). See [`ctx.realtime()`](#ctxrealtime--broadcast-on-custom-channels). |

## 3b. The `typegen` gate (`.enable_typegen`) {#the-apptypegen-gate-enable_typegen}

Setting `.enable_typegen = true` in the `App(.{ … })` literal gates in the `typegen`
subcommand, which generates a typed TypeScript client from the server's live schema (runtime
introspection). It is `false` by default so that production binaries carry no codegen code or
dependencies.

```zig
// client-generation build target — NOT your production binary
zigbase.App(.{
    .collections = .{ /* … */ },
    .enable_typegen = true,
}).runCli(init);
```

Invoke the subcommand against a provisioned data directory (no server required) or against a
running instance:

```bash
# Offline — reads an already-provisioned data directory:
./myserver-gen typegen --data-dir ./zb_data --out src/zbase.gen.ts

# Live — against a running instance (superuser credentials required):
./myserver-gen typegen --url https://api.example.com --admin-email admin@x.io --admin-password '…' --out src/zbase.gen.ts
```

The generated output is the typed `db` / realtime / files surface. Because custom routes are
not introspectable at runtime, `rpc.*` is **not** emitted — use the comptime generator (`zig
build gen-client`) if you need typed RPC. See the [TypeScript SDK docs](./typescript-sdk#runtime-introspection-zigbase-typegen)
for flags and a CI staleness-gate recipe.

> **Recommendation:** keep `enable_typegen = false` in your main application binary and true
> only in a dedicated client-generation build step or a separate `build.zig` target.

## 4. Record hooks (`.hooks`)

Record hooks fire around collection record writes. The shape is a struct keyed by
collection name, plus an optional `any` wildcard group:

```zig
.hooks = .{
    .any = .{ // fires for EVERY collection (before the collection-specific group)
        .beforeCreate = auditCreate,
    },
    .posts = .{
        .beforeCreate = slugify,
        .afterUpdate  = reindex,
        .beforeDelete = guardDelete,
    },
},
```

The six valid phase fields are `beforeCreate`, `afterCreate`, `beforeUpdate`,
`afterUpdate`, `beforeDelete`, `afterDelete`. Within a triggered write, the `any` group
runs first, then the collection-specific group; only the field matching the current phase
runs.

Every hook has the signature:

```zig
fn (ctx: *zigbase.Ctx, ev: *zigbase.RecordEvent) anyerror!void
```

The first parameter is the per-request capability object (`ctx.records()` for DB access,
`ctx.http()` for outbound HTTP, etc. — see [§5b](#handler-capabilities-ctx)). Add `_ = ctx;`
when a hook doesn't use it.

`zigbase.RecordEvent` fields:

- `app: *Runtime` — the runtime app context.
- `ctx` — the request context; `ev.ctx.auth` is the authenticated record (if any).
- `arena: std.mem.Allocator` — the **request-scoped** allocator that owns `record`'s JSON
  storage.
- `collection: []const u8` — the collection name.
- `record: *std.json.Value` — mutable in `before_*`; the persisted record in `after_*`.
- `phase: RecordPhase`.

### Semantics

- **`before*` hooks** may MUTATE `ev.record` and may return an error to REJECT the write
  (the request fails with `400`). They run AFTER access rules pass.
- **`after*` hooks** are post-commit. An error returned from an after-hook is swallowed and
  routed to the error backstop (it does not undo the committed write).

### CRITICAL: use `ev.arena`, not `ev.app.allocator`

Any allocation that becomes part of `ev.record` MUST use `ev.arena` (the request allocator
that owns the record's JSON map), **not** `ev.app.allocator` (the long-lived gpa). Mixing
allocators on the arena-backed JSON map is undefined behavior.

From the worked example's `slugify` (`before_create` on `posts`):

```zig
fn slugify(ctx: *zigbase.Ctx, ev: *zigbase.RecordEvent) anyerror!void {
    _ = ctx;
    if (ev.record.* != .object) return;
    if (ev.record.object.get("slug") != null) return;
    const title = if (ev.record.object.get("title")) |t| switch (t) {
        .string => |s| s,
        else => return,
    } else return;

    const buf = try ev.arena.alloc(u8, title.len); // <-- ev.arena, NOT ev.app.allocator
    var len: usize = 0;
    // ... build the slug into buf ...
    try ev.record.object.put(ev.arena, "slug", .{ .string = buf[0..len] }); // <-- ev.arena
}
```

### DB access from a hook (`ctx.records()`)

A hook reaches the database through `ctx.records()` (the `Records` handle described in
[§5b](#handler-capabilities-ctx)). In a `before*` hook it is bound to the triggering write's
in-transaction connection, so side-writes commit atomically with the triggering write:

- `get(collection, id, .{}) !?std.json.Value` — returns `null` for both an unknown
  collection and a missing record (the 3rd arg is `GetOptions`, e.g. `.{ .expand = "author" }`).
- `create(collection, value) !std.json.Value`
- `update(collection, id, value) !?std.json.Value`
- `delete(collection, id) !bool`
- `list(collection, opts) !ListResult`

`create`/`update`/`delete`/`list` return `error.UnknownCollection` when the collection name
does not resolve.

> **Result lifetime:** a `std.json.Value` returned by `ctx.records()` is not part of the
> `ev.arena`-owned `ev.record` map. It is fine to read for the duration of the hook, but do
> **not** store one *into* `ev.record` without first copying it with `ev.arena` (mixing
> allocators on the arena-backed JSON map is UB).

> **Atomicity:** on the HTTP create/update/delete path a `before*` hook runs **inside**
> the triggering write's transaction. Side-writes a hook issues via `ctx.records()` commit
> atomically with the triggering write, and a before-hook that returns an error — or a
> denied access rule — rolls the whole transaction back, so a rejected write persists
> nothing (fail closed).

## 5. Custom HTTP routes (`.routes`)

```zig
.routes = .{
    .{ .method = .GET, .path = "/api/blog/ping", .handler = ping, .auth = .public },
},
```

Each spec needs `.method`, `.path`, and `.handler` (a missing field or wrong-typed handler
is a compile error). `.auth` is optional and **defaults to `.superuser`** (the safe
default) when omitted. The three auth levels are:

- `.public` — anyone (anonymous identity still provided).
- `.authed` — any authenticated user.
- `.superuser` — superusers only.

The handler signature is:

```zig
fn (ctx: *zigbase.Ctx) anyerror!zigbase.http.Response
```

```zig
fn ping(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    _ = ctx;
    return .{ .status = 200, .body = "{\"pong\":true}" };
}
```

The `*zigbase.Ctx` is the per-request capability object: reach the raw HTTP request via
`ctx.request.?` (a `*http.RequestCtx`), the authenticated identity via `ctx.user()`, DB
access via `ctx.records()`, and outbound HTTP via `ctx.http()`. The framework **enforces
`.auth` before** calling the handler. **Built-in routes always win** over custom routes that
would match the same method + path.

### Route guards: path-secret + per-route rate limit

Routes run an ordered **guard chain** before the handler: (1) the `.auth` level above,
(2) an optional **path-secret** guard, (3) an optional **per-route rate limit**. The first
guard to deny short-circuits — the handler never runs.

**Path-secret (`#139`).** Instead of an `AuthLevel`, `.auth` may be a guard struct that gates
the route on a shared secret the caller presents (think unguessable webhook/deploy URLs):

```zig
.{ .method = .POST, .path = "/api/hooks/deploy/:token", .handler = onDeploy,
   .auth = .{ .path_secret = .{
       .param = "token",                    // path param / query key / header name (per .in)
       .source = .{ .kv = "deploy_secret" },// .kv | .settings | .config = "..."
       .in = .path,                         // .path (default) | .query | .header
       .on_mismatch = .not_found,           // .not_found (default, bare 404) | .forbidden (403)
   } } },
```

- **Source** — `.kv`/`.settings` resolve the secret from the named `_kv` entry at request time
  (rotate it live with `ctx.kv().set(...)` or the settings API); `.config` is a static
  compile-time string baked into the binary.
- **Constant-time + no oracle (security).** The submitted value is compared to the stored secret
  in **constant time** (no `==` timing leak), and a mismatch returns a **bare 404** by default —
  indistinguishable from a route that doesn't exist, so an attacker can't probe for the
  endpoint's existence. Set `.on_mismatch = .forbidden` for an explicit 403 when the path itself
  is already public knowledge. An empty/absent stored secret fails closed (never matches).
- **Rotation.** Write a new secret to the source and every link carrying the old one immediately
  404s. There is no grace window — old URLs break the moment the secret changes.
- A guard-gated route is `.public` at the AuthLevel layer (the secret *is* the gate). For ad-hoc
  checks, `ctx.verifyPathSecret(param, stored)` does the same constant-time path-param comparison
  inside a handler (return `ctx.notFound()` on `false` to mirror the bare-404 behavior).

**Per-route rate limit (`#142`).** Add a `.rate_limit` (and optional `.rate_limit_key`):

```zig
.{ .method = .POST, .path = "/api/contact", .handler = contact, .auth = .public,
   .rate_limit = .{ .custom = .{ .max = 5, .window_s = 60 } } }, // 5 / 60s per client
```

- `.rate_limit` is `.default`/`.off` (no per-route bucket — routes are unthrottled by default)
  or `.{ .custom = .{ .max = N, .window_s = S } }`. A denied request returns **`429` with a
  `Retry-After`** header.
- **Bucket key (security).** By default the bucket keys on the client IP, which honors
  `ZIGBASE_TRUST_PROXY`: when proxies are untrusted a spoofed `X-Forwarded-For` resolves to an
  empty IP, so a forged header **cannot evade or poison** another client's bucket. Supply
  `.rate_limit_key = fn(*Ctx) ?[]const u8` to key on something you resolve instead (API key,
  tenant id, user id); returning `null` falls back to the IP key.
- Both guards **compose** on one route — the path-secret check is ordered first, so a wrong
  secret 404s without consuming the rate-limit budget.

> **Ordering caveat.** Because `path_secret` runs *before* `rate_limit`, a `.rate_limit` on a
> path-secret route throttles **authorized** traffic (requests that pass the secret check) — it
> does **not** throttle secret-*guessing*, since a wrong secret 404s before reaching the limiter.
> This ordering is intentional (a flood of bad guesses can't exhaust a legitimate caller's
> budget). Rely on a **high-entropy secret** for brute-force resistance — the constant-time
> compare already makes guessing infeasible — not on the per-route rate limit.

### Response builders + deferred cookies/headers (`ctx`)

The raw `http.Response` literal is always available — but for the common shapes the `ctx`
carries builders (all allocating on `ctx.arena`) and a deferred-mutation accumulator. They
are conveniences layered over the same `http.Response`; mixing them with a hand-built
literal is fine.

**Response builders:**

- `ctx.json(status, value)` — serialize any JSON-encodable value (incl. a `std.json.Value`)
  into an `application/json` response.
- `ctx.jsonError(status, code)` — a terse `{"error":"<code>"}` JSON body (distinct from the
  framework's `{code,message,data}` envelope; use `ctx.errorResponse` for that one).
- `ctx.html(status, body)` — a `text/html; charset=utf-8` response.
- `ctx.redirect(status, location)` — a redirect with a `Location` header.
- `ctx.notFound()` — the canonical `404 Not found.` envelope.

**Reading the request:**

- `ctx.query()` — the URL query string, lazily parsed (and cached) into **decoded**
  key/value pairs: `+` → space, `%XX` percent-decoded. `q.get("k")` returns `?[]const u8`.
  In a job/hook context (no request) it is empty rather than an error.
- `ctx.randomToken(n)` / `ctx.randomHex(n)` — arena-owned random tokens (base36 / hex).

**Deferred response mutation** — `ctx.setCookie(cookie)` and `ctx.addHeader(header)` queue a
cookie/header that the framework merges onto whatever response the handler returns. Crucially
this happens on **both** the success and the error path, so a Set-Cookie you queue still
reaches the client even if the handler then returns `error.NotFound` / `ctx.fail(...)`:

```zig
fn track(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    // Read-or-mint an opaque, anonymous-friendly visitor id (one Set-Cookie, idempotent
    // within the request). An existing well-formed cookie is returned verbatim.
    const visitor = try ctx.subjectCookie("zb_subject", .{ .max_age_s = 60 * 60 * 24 * 365 });
    const q = try ctx.query();
    if (q.get("ref")) |ref| {
        // ... record the referral for `visitor` ...
        _ = ref;
    }
    return ctx.json(200, .{ .visitor = visitor });
}
```

`ctx.subjectCookie(name, opts)` reads `name` from the incoming request; if present and
well-formed it returns that value (no Set-Cookie), otherwise it mints a fresh opaque id and
queues a single Set-Cookie. It is **not** a signed/authenticated identity — just a stable
handle for anonymous attribution. `SubjectCookieOpts` defaults to a secure, `SameSite=Lax`,
http-only, root-path cookie (`max_age_s = 0` is a session cookie); set `max_age_s`/`domain`
for a persistent or cross-subdomain id. An explicit `?subject=` query param still wins where
the framework consumes it.

### DB access from a route (`ctx.records()`)

An untyped route handler reaches the database through `ctx.records()` — the same `Records`
handle described in [§5b](#handler-capabilities-ctx). It lazily checks out a pooled reader
for reads and acquires the pool writer per write call, releasing both when the framework
tears the ctx down, so there is no manual `acquireReader` / `acquireWriter` + `Data` wiring:

```zig
// reads + writes both go through the same handle
const created = try ctx.records().create("posts", value);
const rec = try ctx.records().get("posts", id, .{});
```

A **typed** route reaches the identical handle via `req.ctx.records()` (see
[Typed routes](#typed-routes-and-the-generated-rpc-surface)).

For raw SQL on a **migration-owned** table (not a collection), acquire the pooled writer
directly and hand it back:

```zig
const w = ctx.app.pool.acquireWriter();
defer ctx.app.pool.releaseWriter();
try w.exec("INSERT INTO plugin_audit_log(note) VALUES('...');");
```

> **Auth collections:** `ctx.records().create(collection, fields)` on an auth collection runs
> the same credential transforms as the HTTP layer (generates the per-record `tokenKey`,
> forces `verified=false`, and hashes `password` if one is supplied). A `password` is
> **optional**, so a passwordless flow can provision a credential-less account that
> `zigbase.auth.issueSession` / `mintLinkToken` can immediately operate on. Non-auth
> collections take the plain insert path. (The lower-level engine `records.create` does
> *not* provision — reach for it directly only for raw import/migration.)

### Typed routes and the generated `rpc` surface

For routes that carry a structured input or output, ZigBase supports **typed routes** declared with a `Req(Input)` / `Output` handler signature instead of the raw untyped `fn(*zigbase.Ctx) anyerror!zigbase.http.Response` form. A typed route handler looks like:

```zig
// Input and Output are Zig types in the bounded Zig→TS subset: bool, int/float,
// []const u8 (string), enums (→ string-literal union), std.json.Value (→ unknown),
// optionals ?T, slices []T, and nested structs — applied recursively, so ?Struct
// and []Struct are allowed. Anything else is a comptime error. (Caveat: a GET/DELETE
// query Input must be a flat struct of scalars/enums/strings/optionals-of-those.)
fn handler(req: *zigbase.Req(InputType)) zigbase.RouteError!OutputType {
    const id = req.param("id");   // ?[]const u8 — a :param from the path
    const input = req.input;      // InputType — parsed request body (POST/PUT/PATCH) or query (GET/DELETE)
    // ...
    return OutputType{ ... };
    // or: return req.fail(404, "not found");   // → RouteError propagated as HTTP 404
}
```

A typed handler reaches the per-request capability object through `req.ctx`:
`req.ctx.records()` for DB access, `req.ctx.http()` for outbound HTTP, `req.ctx.arena` for
allocations, and `req.ctx.app` for the runtime. (`req.app` / `req.arena` remain as legacy
aliases; prefer `req.ctx.*`.)

Register typed routes in `.routes` identically to untyped ones (`.method`, `.path`, `.handler`, optional `.auth` defaulting to `.superuser`). The generator (`zig build gen-client`) reads the comptime `App` declaration and emits a `zb.rpc.*` method for each typed route — named by camel-joining the path segments (`:param` segments omitted):

| Path | Method | Generated name |
| --- | --- | --- |
| `/api/bookings/:id/confirm` | POST | `bookingsConfirm` |
| `/api/bookings/:id/cancel` | POST | `bookingsCancel` |
| `/api/listings/:id/availability` | GET | `listingsAvailability` |
| `/api/golfsim/health` | GET | `golfsimHealth` |

The generated TypeScript method signature mirrors the route shape:
- **`params` object** (e.g. `{ id: string }`) when the path has `:param` segments.
- **`input` argument** when the Zig `Input` type is non-void (POST/PUT/PATCH routes serialize as the request body; GET/DELETE routes pass as query parameters).
- Output is the TypeScript equivalent of the Zig return type; `std.json.Value` maps to `unknown`.
- `.auth` defaults to `.superuser` when omitted — typed routes are locked to superusers unless explicitly set.

Untyped routes (the raw `fn(*zigbase.Ctx) anyerror!zigbase.http.Response` form) own their full response — status, cookies, redirect, content-type — and carry no typed `Input`/`Output`, so the generator deliberately **skips** them: they do not appear in `zb.rpc.*`. Call them with your own `fetch`/HTTP client. This is what lets an untyped handler set a session cookie, return a `307` redirect, or serve a non-JSON body (e.g. `text/calendar`) that a typed `zb.rpc.*` method could not express.

See the [TypeScript SDK docs](./typescript-sdk#typed-rpc--zbrpc) and `examples/golfsim/` for the full worked example.

## 5b. Handler capabilities (`ctx`) {#handler-capabilities-ctx}

Every handler type — route, hook, and job — receives a `*zigbase.Ctx` as its first
parameter. It provides curated DB access, an outbound HTTP client, outbound mail
(`ctx.mail()`), and a standard error model, without manually acquiring connections from
the pool.

### `ctx.records()` — records access

`ctx.records()` returns a `Records` handle. For reads it lazily checks out and caches a
pooled reader (released by the framework when the ctx is torn down); write methods
(`create`/`update`/`delete`) acquire the pool writer and release it per-call. This replaces
hand-built `pool.acquireWriter()` + `Data` wiring — e.g. a cron job that expires stale
booking holds (the form used by `examples/golfsim`):

```zig
fn expireHolds(ctx: *zigbase.Ctx, ev: *zigbase.events.JobEvent) anyerror!void {
    const stale = try ctx.records().list("bookings", .{
        .filter = "status = \"pending\" && starts_at < @now",
        .perPage = 200,
    });
    // stale.items: []std.json.Value  |  stale.totalItems: ?i64 (null in cursor mode)

    for (stale.items) |item| {
        const id = item.object.get("id").?.string;
        var patch: std.json.ObjectMap = .empty;
        defer patch.deinit(ev.app.allocator);
        try patch.put(ev.app.allocator, "status", .{ .string = "cancelled" });
        _ = try ctx.records().update("bookings", id, .{ .object = patch });
    }
}
```

Available `Records` methods:

| Method | Notes |
| --- | --- |
| `list(col, opts) !ListResult` | `opts`: `filter`, `sort`, `page`, `perPage`, `limit`, `cursor`, `expand` |
| `get(col, id, opts) !?Value` | `opts`: `expand`; returns `null` for a missing record |
| `create(col, value) !Value` | acquires + releases the pool writer |
| `update(col, id, value) !?Value` | acquires + releases the pool writer |
| `delete(col, id) !bool` | acquires + releases the pool writer |

**Expanding relations** — pass `.expand` in opts to inline related records under an `"expand"` key:

```zig
// get a post and expand its author relation
const post = (try ctx.records().get("posts", id, .{ .expand = "author" })).?;
const author_name = post.object.get("expand").?.object.get("author").?.object.get("name").?.string;

// list with expand
const page = try ctx.records().list("posts", .{
    .filter = "status = \"published\"",
    .sort = "-created",
    .perPage = 50,
    .expand = "author",
});
```

### `ctx.mail()` — send application mail

`ctx.mail()` sends outbound application email from any route, hook, or job. The framework
owns the security-critical parts so a consumer never re-rolls them: recipient (and
`reply_to`) **address validation** and **CRLF / control-char header-injection rejection**
in `to` / `subject` / `reply_to` happen before any byte reaches a backend or a queue row.

A `MailMessage` is `{ to, subject, text?, html?, reply_to? }` — supply `text`, `html`, or
both (at least one is required). When both are present the message is built as
`multipart/alternative` (plain-text part first, HTML last) so capable clients render the
HTML and the rest fall back to text.

```zig
// Synchronous: build + deliver through the configured mailer right now.
try ctx.mail().send(.{
    .to       = "user@example.com",
    .subject  = "Welcome",
    .text     = "Thanks for signing up!",
    .html     = "<h1>Thanks for signing up!</h1>",
    .reply_to = "support@example.com",
});

// Background: hand it to the queue (the built-in "mail" job kind). Routed to the
// queue's backend — durable (survives restart) or memory (in-process). Pick the queue
// by name; defaults to the always-present "default" queue.
try ctx.mail().enqueue(.{ .to = "user@example.com", .subject = "Digest", .html = "<p>…</p>" }, .{ .queue = "emails" });
```

`send` delivers through the same `Mailer.send` vtable seam every backend (Log / SMTP /
Command / a custom `.mailer` plugin) routes through — including the dev-only
`testcapture.mail` outbox, so consumer mail is assertable in tests exactly like the
framework's own auth mail (see [Test-mode capture](#test-mode-capture--assert-sent-mail--mock-outbound-http-zigbasetestcapture)).
When no mailer is wired (CLI/tests), `send` logs a fallback line. `enqueue` validates the
message **up front**, so a malformed or injection-bearing message fails at the call site
rather than later inside a worker; it requires a wired queue (see [§7b Background jobs &
queues](#7b-background-jobs--queues-queues--workers--jobs)). Errors: `error.InvalidAddress`,
`error.HeaderInjection`, `error.EmptyBody`.

#### Email subsystem (#154): templates, providers, verified senders, suppression

The transactional-mail core layers on top of `ctx.mail()`. Everything below is **additive and off
by default** — an app that only calls the existing mailer is unaffected.

**Templates (`zigbase.mail_template`).** A small, safe renderer for transactional mail — no
arbitrary code, no loops/conditionals, just variable interpolation, named partials, and a shared
layout. Interpolation is **HTML-escaped by default** (`{{ name }}`); raw output is an explicit
opt-in (`{{{ name }}}`). `{{> partial }}` includes a named partial; `renderInLayout` wraps a body in
a layout (which references the child via `{{{ body }}}`). `renderHtml` escapes; `renderText` does
not (text/plain has no markup). Render both parts and pass them as `.html` / `.text`.

```zig
const tpl = zigbase.mail_template;
const html = try tpl.renderHtml(ctx.arena, "<p>Hi {{ name }}</p>", &.{ .{ .key = "name", .value = user_name } }, &.{});
```

**HTTP-API providers.** Two first-class backends implement the same `Mailer` vtable as SMTP, so
call sites are provider-agnostic — select one via `App(.{ .mailer = MyMailerPlugin })`:

- `zigbase.SesMailer.init(region, access_key, secret_key, from)` — Amazon SES v2 `SendEmail`,
  AWS SigV4-signed.
- `zigbase.PostmarkMailer.init(server_token, from)` — Postmark `/email` API.

A message may set a per-message `from` (additive, `null` default) to override the backend's global
sender — the seam verified per-account senders ride on. For tests, `zigbase.CaptureMailer` records
messages in memory so you can assert subject/recipient/both body parts with no network.

**Verified per-account sender identities.** Prove an account controls a From address before it may
send as it. Enforcement engages **only** when you set `.mail.require_verified_sender = true` AND the
send is account-scoped (`ctx.mail()` attributes mail to the request's active account automatically);
a system/superuser send (no account) bypasses, so existing simple-SMTP apps never start rejecting.
Routes (tenant-scoped, fail closed):

- `POST /api/senders` `{ "email": "from@acct.com" }` — request verification (emails a single-use token).
- `POST /api/senders/:id/verify` `{ "token": "…" }` — confirm.
- `GET /api/senders` — list the active account's identities.

A send whose From is not a verified identity for the account is **rejected** (`error.SenderNotVerified`).
Addresses are compared **case-insensitively** (normalized/lowercased on store and lookup), so
`From@Acct.com` and `from@acct.com` are one identity. Verification-email **(re)sends are rate-limited**
per `(account, email)` (a repeat within ~60s returns `429`) so an authenticated member cannot amplify
mail at an arbitrary recipient. The verification token is matched in **constant time**.

**Bounce/complaint suppression.** `POST /api/mail/webhooks/:provider` (`ses` | `postmark`) ingests
delivery events. It verifies a shared-secret **HMAC-SHA256 signature with a constant-time compare** —
the signed string is `"<X-Webhook-Timestamp>.<provider>.<X-Account-Id>.<body>"`, so the body AND the
target account are authenticated (a replayer can't redirect a captured event to another tenant). A
stale `X-Webhook-Timestamp` (outside ±5m) and a wrong/missing signature are rejected (401), and with
no `.mail.webhook_secret` set the route is disabled (404) — ingestion is opt-in. A hard bounce or
complaint upserts a `_suppressions` row. When `.mail.check_suppression = true`, a send to a suppressed
recipient (case-insensitive) is **blocked** (`error.RecipientSuppressed`).

> **Attribution honesty (per-tenant vs global).** A *genuine* provider webhook (SES SNS / Postmark)
> cannot compute our HMAC and cannot add `X-Account-Id`, so it can only reach this endpoint via an
> **operator-run relay** that decides the owning account, injects `X-Account-Id`, and signs the
> string above. A suppression with an empty account is **GLOBAL** (blocks the address for *every*
> tenant). Do not assume per-tenant isolation from a raw provider webhook — only the signed relay
> provides it.

> **Enforcement boundary.** Verified-sender + suppression checks are a **policy of the `ctx.mail()`
> layer**, not of the `Mailer.send` vtable seam. Code that bypasses `ctx.mail()` and calls a backend
> directly skips them (header/CRLF rejection still applies). Always send application mail through
> `ctx.mail()`.

```zig
const App = zigbase.App(.{
    .mailer = MyProviderPlugin, // SES / Postmark / SMTP
    .mail = .{
        .require_verified_sender = true, // tenant sends must use a verified From
        .check_suppression = true,       // block hard-bounced / complained recipients
        .webhook_secret = "…",           // enable the bounce/complaint webhook (signed relay)
    },
});
```

The data model: migration `0016_email` seeds two system collections — `_sender_identities(account,
email, verified_at, verification_token, status)` (UNIQUE `(account,email)`) and
`_suppressions(account, email, reason, source)` (UNIQUE `(account,email)`).

**Deferred (planned 0.9.x fast-follows, NOT in this release):** bulk/throttled personalized list
sends; scheduled/sequenced (drip) sends; CSS-inlining + inline-image hosting; one-click unsubscribe /
list management. The send job + suppression + verified-sender checks are the seams those build on.

### `ctx.http()` — outbound HTTP client

Returns an `HttpClient` bound to the Ctx's arena and the app's `io`:

```zig
const client = ctx.http();

const res = try client.get("https://api.example.com/data");
// res: HttpResponse{ status: u16, headers: []const Header, body: []const u8 }

const res2 = try client.post("https://webhook.example.com/notify", .{
    .body = "{\"event\":\"booking_confirmed\"}",
    .headers = &.{ .{ .name = "Content-Type", .value = "application/json" } },
});
```

### `ctx.webhook()` — managed outbound webhooks (#144)

`ctx.http()` is a one-shot client — fire-and-handle-the-result yourself. `ctx.webhook()`
is its **managed, retrying** counterpart: it serializes `payload` to JSON, enqueues a
background `"webhook"` job (a built-in queue kind, like `"mail"`), and a worker POSTs it
with automatic retries and back-off.

```zig
try ctx.webhook("https://hooks.example.com/booking", .{
    .event = "booking_confirmed",
    .id    = booking_id,
}, .{
    .queue   = "outbound",          // null → the always-present "default" queue
    .retries = 5,                    // max delivery attempts (1 = no retry)
    .backoff = .exponential,         // .fixed | .exponential (queue back-off math)
    .timeout_s = 10,                 // per-attempt request timeout
    .sign    = .{ .secret = "whsec_…" }, // optional HMAC-SHA256 body signature
    // .idempotency = true,          // default: stable Idempotency-Key across retries
});
```

**Response classification.** A `2xx` is delivered. A **network/transport error, any `5xx`,
or a `429`** (honoring an integer `Retry-After` in preference to the configured back-off)
is **retryable** up to `retries`. **Any other `4xx`** (and `1xx`/`3xx`) is **terminal** —
the receiver rejected it, so retrying is pointless. When delivery is terminally rejected
**or** attempts are exhausted, the framework fires your `.onError` hook with phase
**`.webhook`**; the job itself then succeeds so the queue does not double-retry.

**Signing (`opts.sign`).** When set, each attempt adds `X-Signature:
hex(HMAC-SHA256(secret, "<timestamp>.<body>"))` and `X-Webhook-Timestamp: <unix>`. The
timestamp is bound into the signed string (and is fresh per attempt) so a captured request
cannot be replayed indefinitely; a receiver recomputes the digest over `"<timestamp>.<raw
body>"` and compares. Header names are overridable on the `Hmac` struct.

**Idempotency (`opts.idempotency`, default on).** A single `Idempotency-Key` is minted
**once** at enqueue time and frozen onto the (durable) job row, so every retry — and any
at-least-once replay after a crash — reuses the same key, letting the receiver dedupe.

> Worker-stall caveat: retries back off by **sleeping in the worker thread** for the full
> retry duration. Under the default single-worker topology a slow or failing endpoint
> therefore stalls draining of **every** queue (including `"mail"`). For production, give
> webhooks a **dedicated queue + worker** so their backoff never blocks other jobs —
> `.queues = .{ .webhooks = .{ .backend = .durable } }` plus a worker bound to it
> (`.workers = .{ .hooks = .{ .queues = .{"webhooks"} } }`), then pass `.queue = "webhooks"`.

> Security note: a **durable**, **signed** webhook persists the signing secret inside the
> `_queue_jobs.payload` column (your own DB). Prefer a `memory` queue, a short
> `done_ttl_s`, or DB-at-rest encryption if that is a concern. TLS verification is always
> on. Requires a wired queue (see [§7b Background jobs & queues](#7b-background-jobs--queues-queues--workers--jobs)).

### `ctx.verifyCaptcha()` — CAPTCHA verification (#140)

Verify a browser-submitted CAPTCHA token against one of four supported providers:
`recaptcha_v2`, `recaptcha_v3`, `hcaptcha`, `turnstile`.

**Configure the provider + secret** in `App(cfg)`:

```zig
pub const app = zigbase.App(.{
    .captcha = .{
        .provider = .recaptcha_v3,   // .recaptcha_v2 | .recaptcha_v3 | .hcaptcha | .turnstile
        .secret   = "6LeXXXXXXXXX",  // server-side site-verify secret
    },
    // ...
});
```

**Verify in a route handler:**

```zig
// Untyped route handler: a single `*zigbase.Ctx` argument returning an `http.Response`.
fn submitHandler(ctx: *zigbase.Ctx) anyerror!http.Response {
    // Read the token however your frontend submits it — here from the query string;
    // for a JSON/form POST, read `ctx.request.?.body` / `ctx.request.?.form_fields`.
    const token = (try ctx.query()).get("captcha") orelse "";
    const r = try ctx.verifyCaptcha(.recaptcha_v3, token);
    if (!r.ok) return ctx.jsonError(403, "captcha_required");
    // reCAPTCHA v3: score 0.0 (bot) → 1.0 (human); block suspicious traffic.
    if (r.score) |score| if (score < 0.5) return ctx.jsonError(403, "suspicious_request");
    // ... proceed with the submission ...
}
```

**`CaptchaResult` fields:**

| Field      | Type              | Present              | Notes                               |
|-----------|-------------------|----------------------|-------------------------------------|
| `ok`      | `bool`            | always               | `true` = token accepted             |
| `score`   | `?f32`            | reCAPTCHA v3 only    | 0.0 = bot, 1.0 = human              |
| `action`  | `?[]const u8`     | reCAPTCHA v3 only    | Action name from the frontend call  |
| `hostname`| `?[]const u8`     | all providers        | Domain that issued the token        |
| `errors`  | `[]const []const u8` | when `ok=false`   | Provider error codes                |

**Provider URL mapping:**

| Provider      | Verify URL                                                          |
|--------------|---------------------------------------------------------------------|
| `recaptcha_v2` | `https://www.google.com/recaptcha/api/siteverify`                 |
| `recaptcha_v3` | `https://www.google.com/recaptcha/api/siteverify`                 |
| `hcaptcha`     | `https://hcaptcha.com/siteverify`                                 |
| `turnstile`    | `https://challenges.cloudflare.com/turnstile/v0/siteverify`       |

**Dev-bypass:** when `app.captcha_secret` is empty (the default when `.captcha` is not
configured), `ctx.verifyCaptcha` returns `.{.ok = true}` immediately — no network call,
no live key needed. This lets local development and unit tests work without a real provider.
A configured-provider-with-empty-secret logs a loud startup warning.

> **Never deploy with an empty secret** — every `verifyCaptcha` call returns `ok=true`
> without contacting the provider.

**Errors** propagate as a Zig error so the handler can tell a verdict (`ok=false`) apart from a
non-verdict (an error) and decide fail-open vs fail-closed: `error.TransportFailed` (network),
`error.CaptchaProviderError` (non-2xx reply), `error.CaptchaParseError` (malformed/non-object JSON):

```zig
const r = ctx.verifyCaptcha(.turnstile, token) catch |e| {
    std.log.warn("captcha provider unreachable: {s}", .{@errorName(e)});
    // fail-open: proceed; or return ctx.jsonError(503, "captcha_unavailable") to fail-closed
    return process(ctx, ev);
};
```

### `ctx.realtime()` — broadcast on custom channels

The realtime layer auto-publishes record-change events on `<collection>` / `<collection>/<id>`
topics. `ctx.realtime()` lets a handler — a route **or** a background job — publish its own
events on **custom** (non-record) channels over the same WebSocket, using the same
subscribe/unsubscribe protocol clients already use:

```zig
// Signal-only (no payload). Subscribers receive {"type":"signal","topic":"availability"}
// and should re-fetch over an authenticated GET. The recommended default for private /
// per-subject state, since the channel carries nothing sensitive.
ctx.realtime().signal("availability");

// Payload-carrying. Subscribers receive
// {"type":"message","topic":"orders","data":{"type":"order.shipped","id":"REC1"}} verbatim.
try ctx.realtime().broadcast("orders", .{ .type = "order.shipped", .id = id });
```

A client subscribes to a custom topic exactly like a collection topic:

```js
const ws = new WebSocket(`ws://${location.host}/api/realtime`);
ws.onopen = () => ws.send(JSON.stringify({ action: "subscribe", topic: "availability" }));
ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.topic === "availability") refreshSlots(); };
```

Both publish entry points are a **no-op when the realtime reactor isn't running** (tests/CLI),
so they are safe to call unconditionally and from a background job (`ctx.app.submit` / a queue
handler) where there is no HTTP request.

**A custom topic is any topic name that is not a collection.** Subscribing to a *collection*
name always goes through that collection's normal record-channel authorization (per-record
`viewRule`); the custom-topic path can never be used to reach a collection's records.

#### Who may subscribe (`.realtime = .{ .canSubscribe = fn }`)

By **default, custom topics are public signal channels** — anyone, including an anonymous
socket, may subscribe (exactly the framework's own `__features` signal). To gate a private
channel, supply a predicate:

```zig
const App = zigbase.App(.{
    .realtime = .{
        // Return true to allow the subscription, false to deny it. `ctx` carries the
        // socket's resolved identity (ctx.user() / ctx.rctx); `topic` is the requested
        // custom channel name.
        .canSubscribe = struct {
            fn f(ctx: *zigbase.Ctx, topic: []const u8) bool {
                if (std.mem.startsWith(u8, topic, "admin:")) {
                    const u = ctx.user() orelse return false;
                    return u.is_superuser;
                }
                return true; // other custom topics stay public
            }
        }.f,
    },
});
```

**Security guidance.** Because a custom topic's frame is delivered verbatim to every
subscriber (no per-record `viewRule`), keep private/per-subject state **signal-only**:
`signal(topic)` carries no data, so a subscriber learns only that *something* changed and
must re-fetch the actual state over an authenticated GET. Use the payload-carrying
`broadcast(topic, payload)` only for data that is safe for **every** subscriber of that
topic, and use `.canSubscribe` to restrict who may join a private channel.

### Test-mode capture — assert sent mail + mock outbound HTTP (`zigbase.testcapture`)

For deterministic e2e/integration tests, the framework can capture what it *sent* — an
in-memory mail **outbox** and a record of every outbound `ctx.http()` call — and inject
**canned HTTP responses** instead of hitting the network. It mirrors the determinism seam
(`ZIGBASE_FAKE_NOW`) and shares the **same comptime gate**: it is compiled in only on a
`dev_clock` build (on in `Debug`, off in any release build), so a production binary is
byte-for-byte unaffected — `zigbase.testcapture.enabled` is `comptime false` there, the
seams fold away, and there is no runtime branch or perf cost. Every API below is a no-op /
returns empty when the gate is off.

**Mail outbox.** `Mailer.send` (the single seam every backend — Log/SMTP/Command/your own
plugin — routes through) records each email when capture is on:

```zig
const tc = zigbase.testcapture;
tc.mail.enable(true);     // capture + SUPPRESS real delivery (deterministic e2e mode)
defer tc.mail.reset();    // clear + free

// ... trigger a flow that sends mail (signup verification, password reset, your route) ...

try expectEqual(@as(usize, 1), tc.mail.count());
const e = tc.mail.get(0).?;               // { from, to, subject, body }
try expectEqualStrings("user@example.com", e.to);
try expect(tc.mail.find("Verify") != null);
```

`mail.enable(suppress)`: `suppress = true` records and skips real delivery; `false` records
**and** still delivers (assert against a live MailHog/log run). `from` is the backend's
configured sender (empty for `LogMailer`, which has none). Beyond the indexed accessors,
`mail.entries()` returns the whole captured slice (`[]const MailEntry`), `mail.disable()`
stops capturing while keeping already-captured entries readable, and `mail.reset()` clears
+ frees.

**HTTP capture / mock.** `HttpClient.request` (what `ctx.http()` returns) consults the
capture before touching the network — recording the request and, if a mock matches the URL
substring, returning the canned response with **no network at all**:

```zig
tc.http.enable(true);     // capture; block_unmocked=true → un-mocked URLs error (no network)
defer tc.http.reset();
tc.http.mock("api.stripe.com", .{
    .status = 200,
    .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
    .body = "{\"id\":\"ch_123\",\"paid\":true}",
});

// ... trigger a route/hook that calls ctx.http().post("https://api.stripe.com/...") ...

try expectEqual(@as(usize, 1), tc.http.requestCount());
const rq = tc.http.requestAt(0).?;        // { method, url, headers, body }
try expectEqual(zigbase.HttpMethod.POST, rq.method);
```

`http.enable(block_unmocked)`: with `block_unmocked = true` (recommended) a request to an
un-mocked URL fails with `error.TransportFailed` rather than silently hitting the network;
`false` lets un-mocked URLs pass through to the real network. Mocked responses are matched
newest-registration-first on URL substring. Beyond the indexed accessors, `http.requests()`
returns the whole captured slice (`[]const HttpRequest`), `http.disable()` stops capturing
while keeping recorded requests + mocks readable, and `http.reset()` clears + frees.

### Error helpers (`ctx.fail`, `ctx.invalid`, `ctx.errorResponse`)

For untyped route handlers, use the Ctx helpers to produce standard error responses
rather than building raw HTTP error responses by hand:

```zig
fn confirmBooking(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    const req = ctx.request.?;

    const id = req.param("id") orelse
        return ctx.errorResponse(ctx.fail(400, "Missing booking id."));

    const booking = (try ctx.records().get("bookings", id, .{})) orelse
        return ctx.errorResponse(error.NotFound);

    if (!isOwner(ctx.user(), booking))
        return ctx.errorResponse(ctx.fail(403, "Not the owner."));

    // ... update booking ...
}
```

`ctx.fail(status, message)` stashes the error and returns `error.Handled`.
`ctx.errorResponse(err)` maps any error to a `{code, message, data}` JSON response:

| `anyerror` | HTTP status |
| --- | --- |
| `error.Handled` | renders the stashed `ctx.fail` / `ctx.invalid` error |
| `error.NotFound` | 404 |
| `error.Forbidden` | 403 |
| `error.Unauthorized` | 401 |
| `error.BadRequest` | 400 |
| `error.Conflict` | 409 |
| anything else | 500 (no detail leaked) |

`ctx.invalid(fields)` stashes a 400 validation error with per-field detail:

```zig
return ctx.errorResponse(ctx.invalid(&.{
    .{ .field = "email", .code = "invalid", .message = "Must be a valid email." },
}));
```

### `ctx.tx()` — multi-write transactions

To write several records atomically — all commit or all roll back — define a
file-scoped callback and pass it to `ctx.tx`:

```zig
fn transferCredits(t: *zigbase.Tx) anyerror!void {
    var debit: std.json.ObjectMap = .empty;
    try debit.put(t.arena(), "balance", .{ .integer = new_balance });
    _ = try t.records().update("accounts", from_id, .{ .object = debit });

    var credit: std.json.ObjectMap = .empty;
    try credit.put(t.arena(), "balance", .{ .integer = credited });
    _ = try t.records().update("accounts", to_id, .{ .object = credit });
}

// in a route / job / hook handler:
try ctx.tx(void, transferCredits);
```

The callback receives a `*Tx` — a thin wrapper whose `t.records()` returns the
same `Records` API as `ctx.records()`. All writes inside the callback reuse the
single in-transaction writer connection (no second acquire, no deadlock). If the
callback returns any error the transaction rolls back automatically; on success
it commits.

The first type parameter is the callback's return type (use `void` when you do
not need to surface a value from the transaction):

```zig
fn countAndTag(t: *zigbase.Tx) anyerror!u64 {
    _ = try t.records().create("tags", value);
    return 1;
}
const n = try ctx.tx(u64, countAndTag);
```

Attempting to call `ctx.tx` from a callback that is already running inside a
transaction returns `error.NestedTransaction` immediately (without beginning a
new transaction).

> **Do not perform long network calls (`ctx.http()`) inside a `tx` callback.**
> The writer connection is held for the entire duration of the callback. Long
> I/O stalls all other writes on the server — complete any external HTTP calls
> before or after the `ctx.tx` block.

> **In a `before*` hook**, `ctx.records()` is bound to the hook's in-transaction
> connection and never acquires from the pool, so side-writes commit atomically with the
> triggering write. In route and job handlers `ctx.records()` lazily checks out a pooled
> connection that the framework releases on ctx teardown.

### `ctx.kv()` — built-in key/value settings store

Not every piece of mutable server state deserves its own collection. For small,
server-managed values — a maintenance toggle, a cached external token, a counter, a JSON
settings blob — `ctx.kv()` is a built-in key→value store backed by an internal `_kv`
system table. No schema, no access rules, no ceremony:

```zig
try ctx.kv().set("welcome_banner", "Closed for maintenance");
const banner = try ctx.kv().get("welcome_banner"); // ?[]const u8 (null if unset)
_ = try ctx.kv().delete("welcome_banner");          // bool: did a row exist?
```

Values are opaque `TEXT`. To store structured data, stringify it yourself (e.g.
`std.json.Stringify.valueAlloc(ctx.arena, value, .{})`) and parse it back on read. `set`
is an upsert that preserves the original `created` timestamp and bumps `updated`.

Reads use the read connection; writes use the bound connection inside a `before`-hook or
`ctx.tx` (so they commit atomically with the surrounding transaction) and otherwise
acquire/release the pool writer for you — the same lifetime rules as `ctx.records()`.

The same primitive is on the curated `Data` facade as `data.kvGet` / `data.kvSet` /
`data.kvDelete` (and `data.kvList`) for internal/test consumers.

> **Security:** KV/settings are **superuser-managed and never public by default**. The
> `_kv` table is not a collection, so it is invisible to the record API, query engine, and
> access-rule system. To expose a value publicly, write a custom route that returns exactly
> what you intend (see feature flags below).

### Feature flags + experiments (declared)

> **Breaking in 0.8.0.** Flags are now **declared-only**: you list them in the `App(cfg)`
> literal and access them through a typed accessor whose `.name` is checked at compile time.
> The old runtime-string `ctx.flag("arbitrary")` (KV-or-false) API is **removed** — see the
> migration note at the end of this section.

Declare flags and experiments alongside the rest of your config:

```zig
pub const App = zigbase.App(.{
    .flags = .{
        .checkout_enabled = true,                                       // bare bool = default
        .new_dashboard    = .{ .default = false, .description = "Dark mode shell" },
    },
    .experiments = .{
        .checkout_layout = .{ .variants = .{ "control", "compact" }, .weights = .{ 50, 50 } },
    },
});
```

A flag is either a bare `bool` (its default) or `.{ .default = <bool>, .description = "…" }`.
An experiment is `.{ .variants = .{…}, .weights = .{…} }` (parallel tuples; weights need not
sum to 100) with optional `.sticky` and `.description`. Malformed declarations
(unknown sub-key, length mismatch, empty/duplicate variants, all-zero weights) are
**compile errors**.

**Typed accessors** live on the `App` type — a typo'd `.name` is a compile error, not a
silent miss:

```zig
if (App.flag(ctx, .checkout_enabled)) {        // bool; unset → declared default
    // ... new path
}
try App.setFlag(ctx, .checkout_enabled, false); // operator kill switch: writes the override
const variant = try App.experiment(ctx, .checkout_layout, user_id); // []const u8 ("control"/"compact")
```

`App.flag` returns the `flag:<name>` override from the KV store if one is set, otherwise the
declared default (so a default-ON kill switch stays on until an override sets `"false"`); it
swallows read errors back to the default so a check never fails the request. `App.experiment`
buckets `subject` deterministically over the weights (`FNV1a-64(name ++ 0x00 ++ subject)`), so the
same `(name, subject)` always lands on the same variant; an empty subject maps to the first
variant. A weight override in `_kv` under `exp:<name>:weights` (JSON, e.g. `[90,10]`) changes
the split without a redeploy.

**Sticky assignments (`.sticky = true`).** By default an experiment is a *pure* function of
`(name, subject, weights)` — change the weights and a subject can re-bucket to a different
variant. Declare `.sticky = true` to **persist a subject's first assignment** so it survives
later weight changes (#129):

```zig
.experiments = .{
    .checkout_layout = .{ .variants = .{ "control", "compact" }, .weights = .{ 50, 50 }, .sticky = true },
},
```

The first `App.experiment(ctx, .checkout_layout, subject)` for a non-empty `subject` buckets
it and writes the result to the internal `_experiment_assignments` table (keyed by
`(experiment, subject)`); every later resolve returns the stored variant, even after you
edit `exp:<name>:weights`. New subjects still follow the current weights. An empty subject is
never persisted (it always maps to the first variant). The sticky read/write needs the
writer, so sticky resolution costs one extra write only on the **first** sighting of a
subject; pure-hash experiments touch no table at all.

Stale assignments are reaped by a framework-internal `_experiment_gc` job that is installed
**only when at least one declared experiment is `.sticky`** (zero overhead otherwise) and runs
hourly, deleting rows older than `.experiment_assignment_ttl` (in **days**, default `90`) in
bounded batches on the writer:

```zig
zigbase.App(.{
    .experiments = .{ .checkout_layout = .{ .variants = .{ "control", "compact" }, .weights = .{ 50, 50 }, .sticky = true } },
    .experiment_assignment_ttl = 30, // reap sticky assignments older than 30 days
});
```

Setting `.experiment_assignment_ttl` without any `.sticky` experiment is a `@compileError`
(it would be a silent no-op).

**Dynamic names + batch resolution** on `ctx` (the runtime escape hatches):

```zig
const on = ctx.flagByName("checkout_enabled"); // ?bool — null when the name is undeclared
const all = try ctx.flags().resolveAll(user_id); // every declared flag + experiment, one _kv scan
// all.flags: []{ name, value: bool }   all.experiments: []{ name, variant: []const u8 }
```

**Public read plane (`GET /api/state`).** A built-in, **unauthenticated** projection
returns every declared flag + experiment resolved for a caller-supplied `subject`:

```json
// GET /api/state?subject=user-42   (no auth)
{ "flags": { "checkout_enabled": true }, "experiments": { "checkout_layout": "compact" } }
```

It serves **resolved values only** (never the `_kv` keys, defaults, weights, or the
superuser settings verbs). A `.sticky` experiment returns its persisted assignment here
too — resolved **reader-first**, so a repeat call for a known `subject` is read-only and
only a subject's first resolve briefly takes the writer (an unauthenticated caller can't
storm the writer lock). It auto-mounts at `/api/state`; the `.features` knob remaps or
disables it:

```zig
App(.{
    .features = .{ .public_route = "/state" },   // remap (default "/api/state")
    // .features = .{ .public_route = .disabled }, // turn off entirely (404)
});
```

The typed TypeScript SDK surfaces this as `zb.flags.resolveAll(subject)` (named-boolean
flags + variant string-unions) — see
[TypeScript SDK → Typed feature state](./typescript-sdk#typed-feature-state--zbflags).
For a bespoke shape you can still write your own custom route over `ctx.flagByName` /
`ctx.flags().resolveAll`.

**Migrating from 0.7:** declare each flag you used in `.flags`, then replace
`try ctx.flag("x")` with `App.flag(ctx, .x)` (compile-checked) or `ctx.flagByName("x")`
(dynamic), and `try ctx.setFlag("x", v)` with `try App.setFlag(ctx, .x, v)`.

#### Exposure events (`.onFeatureExposure`)

Register `.onFeatureExposure` to feed an analytics/exposure pipeline: it fires every time a
declared flag or experiment is **resolved** (the `App.flag`/`ctx.flagByName` and
`App.experiment` read paths).

```zig
fn onExposure(ev: *zigbase.ExposureEvent) void {
    switch (ev.kind) {                       // .flag | .experiment
        .flag => log.info("flag {s} = {}", .{ ev.name, ev.value }),
        .experiment => log.info("exp {s} [{s}] -> {s}", .{ ev.name, ev.subject, ev.variant }),
    }
}
// .onFeatureExposure = onExposure,
```

`ExposureEvent` is `{ app, kind: enum { flag, experiment }, name, subject, value (flag),
variant (experiment) }`. For a `.flag` exposure `value` is the resolved boolean and `subject`
is empty (flags are global); for an `.experiment` `variant` is the resolved variant and
`subject` is the bucketing subject. The handler is **notify-only** — it cannot abort or write.
It is **zero-cost when unregistered**: the resolver short-circuits before constructing the
event, so an app without `.onFeatureExposure` pays nothing on the read path.

#### Realtime signal (`__features`)

Any override change — `ctx.setFlag`/`App.setFlag`, or an admin `PUT`/`DELETE` of a
`flag:<name>` / `exp:<name>:weights` setting — broadcasts a single frame
`{"type":"features.changed"}` on the fixed **public** realtime channel `__features` (over the
existing WebSocket). It is **signal-only**: no per-subject state or experiment assignment is
ever pushed. Clients subscribe anonymously to `__features` and re-`GET /api/state` (or call
`ctx.flags().resolveAll`) on receipt to pull fresh resolved values:

```js
const ws = new WebSocket(`ws://${location.host}/api/realtime`);
ws.onopen = () => ws.send(JSON.stringify({ action: "subscribe", topic: "__features" }));
ws.onmessage = (e) => {
  if (JSON.parse(e.data).type === "features.changed") refetchState();
};
```

### Superuser settings HTTP API

For administrative management there is a built-in **superuser-only** HTTP surface over the
KV store (every endpoint requires a valid superuser token):

| Method & path | Effect |
|---|---|
| `GET /api/settings` | List all settings (`[{key,value,created,updated}, …]`). |
| `GET /api/settings/:key` | Fetch one (`{key,value}`); 404 if absent. |
| `PUT /api/settings/:key` | Upsert; body `{"value":"…"}`. |
| `DELETE /api/settings/:key` | Remove; 204, or 404 if absent. |

The embedded admin UI exposes these endpoints as a "Settings" section where superusers can view, create, edit, delete entries, and toggle boolean flags with a checkbox — no API client required.

This is the management plane; the public read plane is the built-in `GET /api/state`
endpoint (above), or a custom route if you need a bespoke shape.

### Admin UI

The embedded admin UI (`/_/`) has a dedicated **Feature Flags & Experiments** screen
(`/_/#/features`) that exposes the comptime-declared registry to superusers without
any API calls:

- **Declared flags table** — every declared flag with its name, default, description,
  current effective value, and source (override vs default). A checkbox sets or clears
  the `flag:<name>` override; a **Use default** button appears when an override is active
  and removes it on click.
- **Declared experiments panel** — one card per experiment showing variants and weight
  inputs. Edit the weights and click **Save weights** to write the `exp:<name>:weights`
  override; **Reset to declared** deletes it. When no override is active the inputs show
  the declared weights.

The screen reads the declared registry via `GET /api/features` (superuser-only) and
all mutations go through the existing `PUT`/`DELETE /api/settings/:key` verbs, so the
raw **Settings** screen (also in the sidebar) shows the same override rows if you need
lower-level inspection.

## 6. Auth / file / lifecycle events

One handler each, registered by the matching config key:

| Key | Signature | When |
| --- | --- | --- |
| `onAuth` | `fn (ev: *zigbase.events.AuthEvent) void` | Notify-only, **after** a session is issued (login / oauth2). |
| `beforeAuthSuccess` | `fn (ctx: *zigbase.Ctx, ev: *zigbase.events.AuthSuccessEvent) anyerror!void` | Writable + abortable, **before** the session is issued. See [Auth lifecycle](#auth-lifecycle-beforeauthsuccess). |
| `auth` | struct of `fn (ctx: *zigbase.Ctx, ev: *zigbase.events.AuthLifecycleEvent) anyerror!void` | before/after `register`/`logout`/`refresh`/`password-change`. See [Auth lifecycle hooks](#auth-lifecycle-hooks-register--logout--refresh--password-change). |
| `onFileServe` | `fn (ev: *zigbase.events.FileEvent) anyerror!void` | Before serving a download; **return an error to deny** (framework → `404`). |
| `onFileUpload` | `fn (ev: *zigbase.events.FileEvent) void` | After a successful upload. |
| `onBootstrap` | `fn (ctx: *zigbase.Ctx, ev: *zigbase.events.LifecycleEvent) void` | After bootstrap. |
| `onBeforeServe` | `fn (ctx: *zigbase.Ctx, ev: *zigbase.events.LifecycleEvent) void` | Just before serving starts. |
| `onBeforeTerminate` | `fn (ctx: *zigbase.Ctx, ev: *zigbase.events.LifecycleEvent) void` | Just before shutdown. |
| `onFeatureExposure` | `fn (ev: *zigbase.ExposureEvent) void` | Notify-only, each time a declared flag/experiment is resolved. Zero-cost when unset. See [Exposure events](#exposure-events-onfeatureexposure). |

`AuthEvent` carries `app`, `ctx`, `collection`, `record: ?std.json.Value`, and `method`
(`.password` | `.oauth2` | `.magic_link` | `.otp` | `.webauthn` | `.custom`). `FileEvent` carries `app`, `ctx`, `collection`,
`record_id`, and `filename`. `LifecycleEvent` carries `app`.

### Auth lifecycle (`beforeAuthSuccess`)

`onAuth` is notify-only and fires **after** a session exists — perfect for logging or
audit, useless for mutating state as part of the login. `beforeAuthSuccess` is the
writable, abortable counterpart: it runs **after** the credentials/token are verified
(and, for magic-link, the link token is consumed) but **before** the session JWT is
issued, with a `*Ctx` bound to the login's **in-transaction writer**.

```zig
fn claimGuestPosts(ctx: *zigbase.Ctx, ev: *zigbase.events.AuthSuccessEvent) anyerror!void {
    // ev.record is the just-authenticated record; ev.record_id / ev.method are also set.
    const email = ev.record.object.get("email").?.string;
    // ctx.records() reuses the login transaction — this write commits WITH the session.
    var patch: std.json.ObjectMap = .empty;
    try patch.put(ctx.arena, "author", .{ .string = ev.record_id });
    for (try guestPostIds(ctx, email)) |id| _ = try ctx.records().update("posts", id, .{ .object = patch });
}
// App(.{ .beforeAuthSuccess = claimGuestPosts, ... })
```

Guarantees:

- **Transactional & atomic.** The consume path runs in `BEGIN IMMEDIATE … COMMIT`. The
  hook's `ctx.records()` writes commit together with the login.
- **Abortable, fail-closed.** Return *any* error to block the login: the transaction rolls
  back (the hook's side-writes are discarded, and a magic-link token is **un-consumed** so
  the link still works) and **no session is issued**. Use `ctx.fail(status, msg)` for a
  chosen status, `error.Forbidden`/`error.Unauthorized` for 403/401; any other error → 500.
- **Bound connection.** Do **not** call `ctx.tx` inside the hook (you are already in a
  transaction → `error.NestedTransaction`); use `ctx.records()` directly. `ctx.user()`
  reflects the just-authenticated principal.

Where it fires: the unified `POST /api/collections/:col/auth/:method/complete` endpoint
(password / otp / webauthn / oauth2 / custom) and the magic-link
`GET …/auth/magic_link/consume` link. The legacy `/auth-with-password` and `/auth-refresh`
endpoints do not fire `beforeAuthSuccess`. `onAuth` still fires once, after issuance, as
before. The surrounding lifecycle phases (register / logout / refresh / password-change)
have their own before/after hooks — see below.

### Auth lifecycle hooks (register / logout / refresh / password-change)

The `.auth` config group adds **before/after** hooks for the surrounding auth lifecycle,
all following the `beforeAuthSuccess` discipline. Each handler is
`fn (ctx: *zigbase.Ctx, ev: *zigbase.events.AuthLifecycleEvent) anyerror!void`; the event
carries `.collection`, `.record_id`, `.phase`, and a writable `.record` where applicable.

```zig
zigbase.App(.{
    .auth = .{
        .beforeRegister       = gateSignup,    // validate / gate; abort blocks the account
        .afterRegister        = seedProfile,    // post-create side effects
        .beforeLogout         = onBeforeLogout,
        .afterLogout          = onAfterLogout,
        .beforeRefresh        = onBeforeRefresh,
        .afterRefresh         = onAfterRefresh,
        .beforePasswordChange = onBeforePwChange,
        .afterPasswordChange  = onAfterPwChange,
    },
});
```

A typo'd hook name (e.g. `.beforeRegsiter`) or a wrong-typed handler is a **compile
error**, never a silently-dead hook. `beforeAuthSuccess` and `onAuth` are separate keys
and unchanged.

| Phase | Fires on | before: writable | before: transactional | before: abortable (fail closed) |
| --- | --- | :-: | :-: | --- |
| `register` | record create for an **auth** collection (`POST /api/collections/:col/records`) | ✅ (mutate the new account) | ✅ (in the create txn) | abort rolls back → **no account created** |
| `logout` | `POST /api/collections/:col/auth-logout` | ✅ (bound writer) | — (no write txn) | abort → mapped response, **cookies not cleared** |
| `refresh` | `POST /api/collections/:col/auth-refresh` | ✅ | ✅ | abort rolls back → **no new session** |
| `password-change` | `POST /api/collections/:col/confirm-password-reset` | ✅ | ✅ | abort rolls back → **password unchanged, reset token un-consumed** |

Semantics, consistent across phases:

- **Before-hooks** run with a `*Ctx` bound to the action's connection (in-transaction for
  register/refresh/password-change). `ctx.records()` writes participate in the action's
  transaction. Returning any error **aborts** the action and fails closed, mapped via the
  `Ctx` error model (`ctx.fail(status, msg)`, `error.Forbidden`→403, else 500). Where a
  write transaction exists, the abort rolls it back. Do **not** call `ctx.tx` (you are
  already in a transaction).
- **After-hooks** run post-commit (post-action for logout) and are notify-only — an error
  is routed to the framework error backstop; it never fails the request.
- `register` fires only for **auth** collections; `before_register` has no `record_id` yet
  (the account isn't created), and `ev.record` is the writable to-be-created data (edits are
  persisted).
- **`ev.record` is read-only for `before_refresh` / `before_password_change`.** It is a
  snapshot for reading; mutating `ev.record.*` is unsupported — the change is not isolated
  (the same value backs `onAuth`, the after-hook, and the HTTP response body) and is not
  persisted. For mutations use a `before*` record hook or the writable register phase. (Only
  `before_register` exposes a writable record.)
- `logout` keeps a no-writer fast path: it only resolves the caller and acquires the writer
  when an `.auth` hook is actually registered (an empty `.auth = .{}` installs nothing).

```zig
// Seed a profile row atomically with the new account.
fn seedProfile(ctx: *zigbase.Ctx, ev: *zigbase.events.AuthLifecycleEvent) anyerror!void {
    if (ev.phase != .after_register) return;
    var p: std.json.ObjectMap = .empty;
    try p.put(ctx.arena, "user", .{ .string = ev.record_id });
    _ = try ctx.records().create("profiles", .{ .object = p });
}
```

**Deferred (designed, not wired):** self-service password change via `PATCH /records`
(use the record `beforeUpdate`/`afterUpdate` hooks on the auth collection), and firing
`beforeAuthSuccess` on the legacy `/auth-with-password` / `/auth-refresh` endpoints. (The
`ctx.auth()` refresh / rotate / revoke session verbs **are** wired — see [§6 Session
verbs](#ctxauth--session-management).) See the auth-lifecycle-hooks design spec.

### Auth methods overview

ZigBase ships with a **pluggable auth-method system** that lets every auth collection enable built-in or custom login methods via config, with no route code. The system is built around a two-phase contract:

1. **Initiate** — challenge delivery (email a link/code, return WebAuthn options, or a no-op for API-key flows).
2. **Complete** — proof verification. On success the method returns a `Resolution.record(record_id)` and the framework mints the session via the one seam (`issueSession`+`emitAuth`), firing `onAuth`. The method never mints sessions itself.

There are three tiers:

| Tier | How | When |
|---|---|---|
| Built-in | `magic_link`, `otp`, `password`, `webauthn` in `.auth.methods` | Most apps — no Zig code needed |
| Custom plugin | Register a TYPE in `.auth_methods`; reference by slug in `.auth.methods` | Non-standard verification (corp SSO, API keys, etc.) |
| Escape hatch | Custom routes + `ctx.issueSession` / `zigbase.auth` API (see below) | Exotic flows where the two-phase contract doesn't fit |

**Backward compatibility:** an auth collection with no `.auth.methods` config defaults to `password` — existing deployments are unaffected.

### Enabling auth methods per collection (`.auth.methods`)

Each auth collection in `.collections` can declare a `.auth.methods` struct enabling one or more built-in methods:

| Method | Key | Options | Notes |
|---|---|---|---|
| Password | `password` | (none beyond `rate_limit`) | Built-in default when no `.methods` specified |
| Magic link | `magic_link` | `ttl_s: i64` (default 900), `auto_create: bool` (default false) | when `auto_create=true`, provisions an account for unknown identities; initiate emails link; complete verifies+consumes |
| OTP | `otp` | `length: u8` (default 6), `ttl_s: i64` (default 300), `auto_create: bool` (default false) | when `auto_create=true`, provisions an account for unknown identities; initiate emails code; complete verifies code |
| WebAuthn | `webauthn` | `rp_id: []const u8`, `rp_name: []const u8`, `origin: []const u8`, `credentials_collection: []const u8`, `require_uv: bool` (default false) | all four string fields required; `require_uv` rejects assertions without user-verification (biometrics/PIN) |
| OAuth2 | (see below) | gated by `.auth.oauth2.enabled` + `.auth.oauth2.providers` | 5th built-in; uses the contract but is NOT listed in `.auth.methods` |

**Per-collection auth options** (set directly on `.auth`, independent of which methods are enabled):

- **`require_verified: bool`** (default `false`) — when `true`, any login attempt is rejected with `403` if the auth record's `verified` field is `false`. This gate applies to **all** auth methods, including WebAuthn passkeys and OAuth2 accounts created from providers that did not confirm the email address (those are created `verified=false`). Enable it only after ensuring existing users have verified accounts, or after setting up a verification flow.

> **`auto_create`** (on `magic_link` and `otp`, default `false`) — when `true`, `initiate` automatically provisions a passwordless auth record (`verified = false`) for email addresses not yet in the collection, then sends the link/code as usual. Enables "sign up or sign in" with a single step. **Note:** auto-created accounts have `verified = false`; if the collection also sets `require_verified = true`, those accounts cannot log in until verified. Consider whether to pair these settings. Works best with single-field `identityFields` (the default `email`).

Each method accepts a `rate_limit` field:
- `.default` — uses the global env-var rate-limiter (`ZIGBASE_RATE_LIMIT_MAX` / `ZIGBASE_RATE_LIMIT_WINDOW`).
- `.off` — disables rate-limiting for this method (logged at startup like a `@public` rule).
- `.{ .custom = .{ .max = 5, .window_s = 60 } }` — per-method override: the configured `max`/`window_s` are honored against a **dedicated bucket scoped by collection + method**, so different methods (and the same method on different collections) never share a budget. The bucket subject (client IP, else the submitted identity) matches the global limiter. A custom limit applies even when the global limiter is disabled (`ZIGBASE_RATE_LIMIT_MAX=0`).

Example — two collections, each with different methods:

```zig
.collections = .{
    .members = .{ .type = .auth, .auth = .{
        .methods = .{ .magic_link = .{ .ttl_s = 900 } },
    } },
    .staff = .{ .type = .auth, .auth = .{
        .methods = .{ .password = .{}, .webauthn = .{
            .rp_id = "app.example.com",
            .rp_name = "My App",
            .origin = "https://app.example.com",
            .credentials_collection = "webauthnCredentials",
        } },
    } },
},
```

This yields the following endpoints (no route code):

```
POST /api/collections/members/auth/magic_link/initiate
POST /api/collections/members/auth/magic_link/complete
POST /api/collections/staff/auth-with-password           (legacy alias)
POST /api/collections/staff/auth/webauthn/initiate
POST /api/collections/staff/auth/webauthn/complete
POST /api/collections/staff/auth/webauthn/register/begin  (authed)
POST /api/collections/staff/auth/webauthn/register/finish (authed)
```

The dispatch enforces enablement: a disabled or unknown method slug returns `404`.

**Typed TS client.** `zig build gen-client` emits a typed `client.auth.<collection>.<method>` surface for every enabled non-password method (camelCased, e.g. `client.auth.members.magicLink`). For the three **built-in** methods the generated `initiate`/`complete` carry precise input/result types (the server contracts are fixed):

| Method | `initiate(input)` | `initiate` result | `complete(input)` | `complete` result |
| --- | --- | --- | --- | --- |
| `magic_link` | `{ identity }` | `void` (204) | `{ token }` | `{ token }` |
| `otp` | `{ identity }` | `void` (204) | `{ identity, code }` | `{ token }` |
| `webauthn` | `{ identity? }` | `{ challenge, rpId, ceremonyId, timeout }` | `{ ceremonyId, credentialId, authenticatorData, clientDataJSON, signature }` | `{ token }` |

Every built-in `complete` resolves to `{ token }` (`AuthMethodResult`); the session cookies (`zb_auth`/`zb_csrf`) are also set on the response. **Custom methods** can be typed too: a bare-string slug (`.custom = .{"corp-sso"}`) stays on the untyped `Record<string, unknown>` / `unknown` stubs, while the **struct form** declares comptime I/O types the generator reflects into precise TS interfaces (named by the Zig type) — `.{ .slug = "corp-sso", .Initiate = .{ .Input = …, .Output = … }, .Complete = .{ .Input = …, .Output = … } }`. A `void` Input omits the input arg; a `void` Output maps to `Promise<void>`. See [typescript-sdk.md → Typed auth methods](typescript-sdk.md#typed-auth-methods--zbauth).

### Custom `AuthMethod` plugin (`.auth_methods`)

For verification logic that the built-ins don't cover, implement an `AuthMethod` plugin type and register it at the app level:

```zig
// App-level registration of custom method TYPES:
.auth_methods = .{ WebAuthnMethod, CorpSsoMethod },

// Then reference by slug in a collection's .methods:
.staff = .{ .type = .auth, .auth = .{
    .methods = .{ .password = .{}, .custom = &.{"corp-sso"} },
} },
```

**The contract** — every plugin type must implement three functions:

```zig
// Required on every AuthMethod plugin type:
pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: zigbase.Config) !Self;
pub fn method(self: *Self) zigbase.AuthMethod;  // returns the vtable view
pub fn deinit(self: *Self) void;
```

`zigbase.AuthMethod` vtable:

```zig
pub const AuthMethod = struct {
    slug: []const u8,   // URL slug → /auth/<slug>/initiate | /complete
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        initiate: *const fn (ctx: *anyopaque, ac: *AuthCtx) anyerror!InitiateResult,
        complete: *const fn (ctx: *anyopaque, ac: *AuthCtx) anyerror!Resolution,
    };
};
```

`AuthCtx` — what the framework passes to each phase:

```zig
pub const AuthCtx = struct {
    app: *Runtime,
    ctx: *http.RequestCtx,        // body / query / cookies / remote_ip
    collection: schema.Collection, // the :col auth collection (validated .type == .auth)
    // No ambient conn — each method acquires its own via writer()/reader().

    // Connection RAII handles:
    pub fn writer(ac: *AuthCtx) WriterData;               // acquires pool writer (mutex); call deinit()
    pub fn reader(ac: *AuthCtx) !ReaderData;              // checks out a pooled reader; call deinit()

    // Blessed helpers (each takes the conn you acquired):
    pub fn rateLimit(ac: *AuthCtx, scope: []const u8, ident: []const u8) !?http.Response;
    pub fn mintLinkToken(ac: *AuthCtx, conn: *db.Db, record_id: []const u8, ttl_s: i64) ![]const u8;
    pub fn verifyLinkToken(ac: *AuthCtx, conn: *db.Db, token: []const u8) !?Claims;
    pub fn consumeLinkToken(ac: *AuthCtx, conn: *db.Db, claims: Claims) !void;
    pub fn deliverMail(ac: *AuthCtx, to: []const u8, subject: []const u8, body: []const u8) !void;
    pub fn findByIdentity(ac: *AuthCtx, conn: *db.Db, identity: []const u8) !?[]const u8;
};

pub const InitiateResult = struct { status: u16 = 200, body: ?[]const u8 = null };

pub const Resolution = union(enum) {
    record: []const u8,  // record id → framework issues session + fires onAuth
    fail: struct { status: u16, message: []const u8 },
};
```

A plugin type missing `create`/`method`/`deinit` is a **compile error**. Built-in methods (`password`, `magic_link`, `otp`, `webauthn`) implement the exact same contract — no privileged private path.

### WebAuthn — login + passkey registration

**Login flow (via the two-phase contract):**

1. `initiate`: POST body `{ "identity": "user@example.com" }` (optional for discoverable credentials). Returns `{ "challenge": "...", "rpId": "...", "ceremonyId": "..." }`.
2. Browser calls `navigator.credentials.get()` with the options.
3. `complete`: POST body `{ "ceremonyId": "...", "credentialId": "...", "authenticatorData": "...", "clientDataJSON": "...", "signature": "..." }`. On success, the framework mints the session and fires `onAuth(.webauthn)`.

**Passkey registration (requires an existing session):**

1. `POST /api/collections/:col/auth/webauthn/register/begin` — returns `{ "challenge": "...", "rpId": "...", "rpName": "...", "ceremonyId": "..." }`.
2. Browser calls `navigator.credentials.create()` with those options.
3. `POST /api/collections/:col/auth/webauthn/register/finish` with `{ "ceremonyId": "...", "id": "...", "rawId": "...", "response": { "clientDataJSON": "...", "attestationObject": "..." } }`. Stores the credential in `_webauthnCredentials` bound to the authenticated user.

Notes:
- Supports ES256 (P-256, COSE -7) and Ed25519 (COSE -8) public keys; the COSE key curve is validated against the algorithm (ES256→P-256, EdDSA→Ed25519).
- Attestation format: `fmt:"none"` (v1; other formats are future work).
- `signCount` is tracked; a count regression (possible credential clone) fails authentication closed.
- Each credential is bound to the collection it was registered on; presenting it on a different collection returns `401`.
- `require_uv: true` rejects assertions where the authenticator did not perform user verification (biometrics or PIN). Default `false`.
- Requires `webauthn.credentials_collection` to name a collection that stores credentials.

### ChallengeStore

`ChallengeStore` is a TTL'd, GC'd server-side store backed by `_authChallenges`. It is used internally by `magic_link` (the link token), `otp` (the emailed code), and `webauthn` (ceremony challenges). Custom plugins may access it via `AuthCtx.challengeStore()`, which returns a handle with:
- `store(id, data, ttl_s)` — store a challenge under `id` with the given TTL.
- `consume(id) ![]const u8` — retrieve and delete in one atomic step (single-use).

### OAuth2 providers (`.auth.oauth2`)

Configure OAuth2 sign-in for an auth collection by adding `.auth.oauth2` to its `.auth` block:

```zig
.users = .{ .type = .auth, .fields = .{}, .auth = .{
    .oauth2 = .{
        .enabled = true,
        .providers = .{
            // Preset provider — endpoints come from ZigBase's built-in table.
            .{ .name = "google", .redirectUrls = .{"https://app.example/oauth/callback"} },
            // Generic provider — all three endpoint URLs are required (all https://).
            .{ .name = "myprovider",
               .authURL = "https://myprovider.example/oauth/authorize",
               .tokenURL = "https://myprovider.example/oauth/token",
               .userinfoURL = "https://myprovider.example/api/user",
               .redirectUrls = .{"https://app.example/oauth/callback"} },
        },
    },
} },
```

**Built-in presets** (endpoint URLs supplied automatically): `google`, `github`, `microsoft`, `discord`.
A generic provider requires `authURL`, `tokenURL`, and `userinfoURL` (all must be `https://`).

**Per-provider fields** (all optional except `.name`):

| Field | Default | Notes |
|---|---|---|
| `name` | — | **Required**. Valid identifier; becomes the slug and is uppercased into the env var name. |
| `enabled` | `true` | Set `false` to temporarily disable without removing the declaration. |
| `redirectUrls` | `&.{}` | Tuple of allowed OAuth2 redirect URLs. |
| `clientId` | `""` | Prefer env (see below); literal is accepted but bakes the value into the binary. |
| `clientSecret` | `""` | **Do not set in the literal.** Use env — the literal embeds the secret in the binary. |
| `authURL` | `null` | Generic provider only. |
| `tokenURL` | `null` | Generic provider only. |
| `userinfoURL` | `null` | Generic provider only. |
| `scopes` | `null` | Override default scopes for a preset, or supply scopes for a generic provider. |

#### Runtime secrets via environment variables

The `clientId` and `clientSecret` are **NOT** read from the comptime literal at runtime (a comptime literal cannot hold a secret safely). Instead, set environment variables at provisioning time:

```
ZIGBASE_OAUTH_<UPPER(NAME)>_CLIENT_ID=<your-client-id>
ZIGBASE_OAUTH_<UPPER(NAME)>_CLIENT_SECRET=<your-client-secret>
```

For example, for `name = "google"`:

```
ZIGBASE_OAUTH_GOOGLE_CLIENT_ID=123456789-abc.apps.googleusercontent.com
ZIGBASE_OAUTH_GOOGLE_CLIENT_SECRET=GOCSPX-...
```

The framework uppercases the provider name character-by-character to form the env var key. The `clientSecret` is encrypted (AES-256-GCM, HKDF key derived from the JWT secret) before being persisted in the database — the plaintext never reaches disk.

#### Provisioning caveat (applied on first creation only)

The env-secret injection and collection creation happen at startup, but only on the **first boot** (when the collection does not yet exist in the database). On subsequent boots the live database options are preserved — the env vars are ignored for an already-provisioned collection. This means:

- **Rotating a secret:** update the value via the admin API (PATCH `/api/collections/:col`) or the admin UI. The admin path re-encrypts under the new plaintext.
- **Changing a redirect URL or adding a provider:** update the comptime literal AND use an explicit `.migrations` entry to apply the change (provisioning is additive-only; it does not re-apply options on existing collections).

> **CI/e2e caveat:** this feature cannot be exercised in automated CI without real provider credentials. All verification is at the unit level (comptime lowering + encrypt-on-inject with a stub env getter and a fake app secret).

### OAuth2 — contract method

OAuth2 (Google, GitHub, etc.) is the **fifth built-in `AuthMethod`** (slug `oauth2`). It is gated by the existing `.auth.oauth2.enabled` + `.auth.oauth2.providers` config, **not** by `.auth.methods`. When OAuth2 is enabled for a collection the framework auto-mounts three endpoints:

| Method | Path | Description |
|---|---|---|
| GET | `/api/collections/:col/auth/oauth2/providers` | Discovery — list enabled providers (name, authURL, clientId, scopes). Secrets never returned. |
| POST | `/api/collections/:col/auth/oauth2/initiate` | Return provider metadata so the client can drive the authorization redirect. |
| POST | `/api/collections/:col/auth/oauth2/complete` | Exchange the authorization code for a session. |

**`oauth2` initiate** — body `{ "provider": "<name>" }`:
```json
// response (200)
{
  "authURL": "https://accounts.google.com/o/oauth2/v2/auth?...",
  "clientId": "my-client-id.apps.googleusercontent.com",
  "scopes": ["openid", "email", "profile"],
  "state": "<server-issued-state>"   // always present (ZIGBASE_OAUTH_STATE_SERVER defaults to true)
}
```

**`oauth2` complete** — body:
```json
{
  "provider": "google",
  "code": "<authorization-code>",
  "codeVerifier": "<pkce-verifier>",
  "redirectUrl": "https://app.example.com/callback",
  "state": "<server-issued-state>"   // required by default (ZIGBASE_OAUTH_STATE_SERVER defaults to true)
}
```
```json
// response (200) — sets zb_auth and zb_csrf cookies
{ "token": "<jwt>" }
```

On success the framework fires `onAuth(.oauth2)` through the shared session seam — identical to every other method. All paths share one implementation and enforce the same security: single-use TTL'd CSRF `state` consumed before the code exchange, PKCE required, redirect allow-list, and https-only provider URLs.

> **Connection model:** each auth method manages its own DB connection for the duration of its call. `complete` acquires a writer, consumes the CSRF `state` (single-use, before the provider exchange), then **releases the writer** before the outbound provider HTTP round-trip. A new writer acquisition completes the record lookup and session mint. This means `complete` does **not** hold the writer across blocking I/O — high OAuth2 concurrency does not stall writes. Password `complete` uses a reader (argon2 verification is read-only); the writer is acquired only at session-mint time.

### Tier 3: escape hatch for exotic flows

For flows where the built-in two-phase `AuthMethod` contract doesn't fit, ZigBase exposes
a `zigbase.auth` helper surface so you can build custom login flows while staying in the
same session-issuance seam that built-in logins use.

**The seam guarantee:** every login — including custom flows via `ctx.issueSession`
— fires your `onAuth` handler. There is no way to mint a session that bypasses it.
Built-in flows (password, OAuth2) and custom flows both go through the same
`issueSession`+`emitAuth` path, so the `onAuth` hook is the single, reliable
chokepoint for cross-cutting session logic (audit logging, account-state checks, etc.).

#### `zigbase.auth` API reference

```zig
// src/auth_helpers.zig  (imported as zigbase.auth.*)

pub const Issued    = struct { token: []const u8, cookies: [2]http.Cookie };
pub const LinkToken = struct { token: []const u8 };

// Issue a full session (sets cookies, fires onAuth).
// Prefer ctx.issueSession (below) from a route — it acquires the writer for you.
pub fn issueSession(
    ctx: *http.RequestCtx, conn: *db.Db,
    collection: []const u8, record_id: []const u8,
) !Issued

// Single-use magic-link token helpers.
// opts.payload (default "") binds a small opaque, signed, tamper-proof string into the
// token — returned by verifyLinkToken as claims.pl. Use it to carry e.g. a post-login
// redirect target in the one token instead of an unsigned &next= URL param. Signed, not
// encrypted: readable-but-tamper-proof; keep it small (base64url'd into the JWT payload).
pub const MintOptions = struct { payload: []const u8 = "" };
pub fn mintLinkToken(
    ctx: *http.RequestCtx, conn: *db.Db,
    collection: []const u8, record_id: []const u8, ttl_s: i64, opts: MintOptions,
) !LinkToken

// Returns null when the token is expired, wrong collection, or has a bad signature.
// claims.id is the record id stored in the token; claims.pl is the bound payload ("" if none).
pub fn verifyLinkToken(
    ctx: *http.RequestCtx, conn: *db.Db,
    collection: []const u8, token: []const u8,
) !?jwt.Claims

// Marks the token consumed. Returns error.AlreadyConsumed on replay.
pub fn consumeLinkToken(conn: *db.Db, claims: jwt.Claims) !void

// Clear the session cookies (logout), mirroring issueSession. Returns arena-owned
// zb_auth/zb_csrf cookies built from the framework's own cookie policy, so they match
// the built-in logout exactly. Equivalent to ctx.auth().clearSession() (below).
pub fn clearSession(ctx: *Ctx) ![]const http.Cookie

// Session revocation (#99). Equivalent to the ctx.auth() verbs below.
pub fn revokeAllSessions(ctx: *Ctx) !void   // "log out everywhere" (bump epoch)
pub fn refresh(ctx: *Ctx) !Issued           // re-mint, same epoch (sliding refresh)
pub fn rotate(ctx: *Ctx) !Issued            // bump epoch + re-mint (kill other sessions)

// Send auth email via the configured mailer (SMTP or log in dev).
pub fn deliverAuthMail(
    app: *App, alloc: std.mem.Allocator,
    to: []const u8, subject: []const u8, body: []const u8,
) !void

// Rate-limit helper — returns a ready-to-return 429 Response when the caller
// is over the limit, null otherwise. scope identifies the endpoint; ident is the
// key (e.g. email or raw request body).
pub fn rateLimit(
    ctx: *http.RequestCtx, scope: []const u8, ident: []const u8,
) !?http.Response
```

#### `ctx.issueSession` — the ergonomic route helper

From inside a route handler, use `ctx.issueSession` instead of calling
`zigbase.auth.issueSession` directly. It acquires and releases the DB writer for you (it is
only valid in a route — `ctx.request` must be non-null):

```zig
// src/ctx.zig
pub fn issueSession(
    ctx: *Ctx, collection: []const u8, record_id: []const u8,
) !Issued   // acquires+releases the writer, fires onAuth(.custom)
```

> **Warning:** `ctx.issueSession` acquires the pool writer for you internally. Do NOT call it while you are already holding the writer — inside `ctx.tx`, from a `before*` hook, or with a bound connection — it would deadlock on the single non-reentrant writer. In those cases call `zigbase.auth.issueSession(ctx.request.?, conn, collection, record_id)` directly with the connection you already hold.

Typical usage in a confirm handler that does NOT separately hold the writer:

```zig
fn myConfirm(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    // ... verify your token, resolve the record id ...
    const issued = try ctx.issueSession("members", record_id);
    return .{ .status = 200, .body = "{\"ok\":true}", .cookies = &issued.cookies };
}
```

When your handler already holds the writer (e.g. for `verifyLinkToken` and `consumeLinkToken`), reuse it:

```zig
fn myConfirm(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    const w = ctx.app.pool.acquireWriter();
    defer ctx.app.pool.releaseWriter();
    // ... verifyLinkToken, consumeLinkToken using w ...
    // Use zigbase.auth.issueSession, NOT ctx.issueSession, to avoid double-acquiring the writer.
    const issued = try zigbase.auth.issueSession(ctx.request.?, w, "members", record_id);
    return .{ .status = 200, .body = "{\"ok\":true}", .cookies = &issued.cookies };
}
```

`issued.cookies` is a `[2]http.Cookie` containing `zb_auth` (httpOnly) and
`zb_csrf` (readable). Pass `&issued.cookies` as the `cookies` field on the
`http.Response` and the framework writes both Set-Cookie headers.

For a complete, copy-pasteable example (two-route magic-link flow with rate
limiting, enumeration safety, and single-use token replay protection) see
[Recipes → magic-link login](./recipes#recipe-magic-link-passwordless-login).

#### `ctx.auth()` — session management

The `ctx.auth()` namespace is the session-management surface.

`clearSession` mirrors `issueSession` for logout: it returns the cleared session cookies
built from the framework's own cookie policy (the same one the built-in `authLogout` uses),
arena-owned so they slot straight into `Response.cookies`. A logout handler is one line:

```zig
fn logout(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    return .{ .status = 204, .body = "", .cookies = try ctx.auth().clearSession() };
}
```

`zigbase.auth.clearSession(ctx)` is the equivalent free-function form.

##### Revoking sessions (#99)

Sessions are stateless JWTs, but they are still **revocable** via a per-auth-record
**token epoch**. Each `.auth` token embeds the record's `token_epoch`; verification rejects
a token whose epoch no longer matches the record's current value (fail closed). This is the
**default** model (`App(.{ .session_store = .epoch })`) and costs **no extra query on either
the verify hot path or login** — the epoch is folded into the single `tokenKey` SELECT each
already performs (one extra column, not an extra round-trip).

| verb | effect |
|---|---|
| `ctx.auth().revokeAllSessions()` | bump the epoch → **every** outstanding token for the principal stops verifying ("log out everywhere"). Pair with `clearSession` to also drop this browser's cookie. |
| `ctx.auth().refresh()` | re-mint a token (new `exp`, **same** epoch) — a sliding refresh that leaves other sessions valid. Returns `Issued` (JWT + cookies). |
| `ctx.auth().rotate()` | bump the epoch **then** re-mint — keep this session, kill every other. Returns `Issued`. |

```zig
fn changePassword(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    // ... verify + update the password ...
    const issued = try ctx.auth().rotate();           // invalidate all old sessions, keep this one
    return .{ .status = 200, .body = body, .cookies = try ctx.arena.dupe(zigbase.http.Cookie, &issued.cookies) };
}
```

Free-function forms: `zigbase.auth.revokeAllSessions(ctx)` / `refresh(ctx)` / `rotate(ctx)`.

Back-compat is total: tokens minted before the epoch existed (no claim) and freshly created
records (NULL column) both read as epoch `0`, so all existing valid tokens keep working.

**Per-device sessions (Variant B, `.session_store = .table`).** Opting into the table model
maintains a server-side `_sessions` row per session, enabling a full per-device UI:

| verb (table mode only) | effect |
|---|---|
| `ctx.auth().listActiveSessions()` | the current principal's active sessions (`id`, `created`, `last_seen`, `user_agent`, `ip`, `is_current`), newest first. |
| `ctx.auth().revoke(sessionId)` | "log out THIS device" — delete one session row. Authorized: only the owning user (or a superuser) may revoke a given session; a non-owner gets `error.NotFound` (indistinguishable from an absent id, so revoke can't probe other users' session ids). |

In table mode, login/refresh/oauth issuance records a session row and embeds its id in the
token (`sid` claim); **verify checks the row exists and is unexpired** (one extra indexed read
per authenticated request — the accepted cost of this mode). Logout and `revoke` delete the
row; `revokeAllSessions` clears all of the principal's rows (and bumps the epoch). `refresh`/
`rotate` rotate the current device's row (no accumulation), carrying the original `created`
(session start) forward and stamping `last_seen = now`. **By design `last_seen` reflects the
last token *refresh*, not every request** — verify never writes the session table, so an
authenticated request stays one read (no per-request write amplification on the single writer).

**Expired-session GC.** Enabling `.table` auto-installs a framework-internal recurring job
(`_session_gc`) that deletes expired `_sessions` rows (those whose `expires` has passed; NULL =
never expires) in bounded batches on the writer — no opt-in needed, and **nothing is installed
in `.epoch` mode** (no job, no timer). The default cadence is **hourly** (`"0 * * * *"`);
override it with `.session_gc_cron` (UTC, minute-granularity cron syntax), e.g.
`App(.{ .session_store = .table, .session_gc_cron = "*/30 * * * *" })` for every 30 minutes.
(Expired rows are inert before collection — verify already rejects them — so GC is housekeeping,
not a correctness gate.)

> **Switching an existing app to `.table` is not retroactive.** Tokens already minted under
> `.epoch` carry no `sid`, so they skip the per-device session check and stay valid until they
> expire — `revoke(sessionId)` can't kill them (no row exists). Use `revokeAllSessions()` (an
> epoch bump) once after enabling `.table` to invalidate every pre-existing session.

**`.epoch` is the default and is unchanged: it issues ZERO session-table queries, and enabling
`.table` does not alter the `.epoch`-mode token shape** — the `sid` claim is simply omitted when
absent. In `.epoch` mode `listActiveSessions`/`revoke` return `error.SessionStoreNotEnabled`
(there is no per-session inventory); `revokeAllSessions`/`refresh`/`rotate` work in **both** modes.

## 7. Scheduled jobs (`.cron` + `.jobs`)

```zig
.jobs = .{ .pool_size = 2 }, // worker pool size; defaults to 2 when unset
.cron = .{
    .{ .name = "heartbeat", .schedule = zigbase.schedule.Schedule{ .interval = .hourly }, .handler = heartbeat },
},
```

> `.jobs` does double duty: the reserved `.pool_size` key sets the scheduler worker-pool
> size (above), and any OTHER key registers a queue **job-kind handler** — see
> [§7b Background jobs & queues](#7b-background-jobs--queues-queues--workers--jobs).

Each `cron` spec needs `.name`, `.schedule`, and `.handler` (missing/wrong-typed → compile
error). The three schedule modes (`zigbase.schedule.Schedule`):

```zig
.{ .cron = "0 3 * * *" }              // 5-field cron, UTC, numeric-only
.{ .interval = .hourly }              // also .daily / .weekly
.{ .interval = .{ .minutes = 15 } }   // every N minutes
.reactive                             // handler decides its own next fire
```

**Handler signatures depend on the mode.** Cron and interval jobs use a ctx-first handler:

```zig
fn (ctx: *zigbase.Ctx, ev: *zigbase.events.JobEvent) anyerror!void
```

```zig
fn heartbeat(ctx: *zigbase.Ctx, ev: *zigbase.events.JobEvent) anyerror!void {
    _ = ctx;
    std.log.info("blog heartbeat job '{s}' ran", .{ev.name});
}
```

A `.reactive` job's handler instead **returns its next schedule**:

```zig
fn (ctx: *zigbase.Ctx, ev: *zigbase.events.JobEvent) anyerror!zigbase.schedule.Reactive
```

It returns either `.{ .after = <Interval> }` (re-run after that interval, e.g. `.{ .after =
.{ .minutes = 5 } }` or `.{ .after = .daily }`) or `.stop` (retire the job). `JobEvent`
carries `app` and `name`. Touch the database from a job through `ctx.records()` (see
[DB access from a route](#db-access-from-a-route-ctxrecords)); for raw SQL on a
migration-owned table acquire the pooled writer via `ctx.app.pool.acquireWriter()` /
`ctx.app.pool.releaseWriter()`.

### Caveats

The scheduler is intentionally simple (see [Known limitations](./known-limitations)):

- **Single-process** — no distributed coordination.
- **UTC** — all cron/interval evaluation is in UTC.
- **Numeric-only cron** — no `JAN`/`MON` names; supports `*`, `a`, `a,b,c`, `a-b`, `*/n`. A
  malformed numeric sub-part is silently skipped rather than rejected, so a typo'd field may
  match unexpectedly.
- **Day-of-month and day-of-week are ANDed** (not Vixie cron's OR semantics).
- **Minute granularity** — the smallest schedule resolution is one minute.
- **Interval drift** — interval schedules measure the next fire from the previous run's
  *completion*, not a fixed wall clock, so long-running jobs drift.
- **Single-flight** — a job never overlaps itself.

The framework may also register **internal jobs** of its own alongside your
`.cron` table. Declaring a TTL collection (`.ttl_field`, see §8) registers a
5-minute interval job named `_ttl_gc` that reaps expired rows; it runs on the same
worker pool and starts the scheduler even when you have no `.cron` configured.

### Ad-hoc background work: `app.submit`

To offload one-off background work from a route or hook onto the worker pool:

```zig
try ctx.app.submit("reindex", reindexTask);
// reindexTask: fn (ctx: *zigbase.Ctx, ev: *zigbase.events.JobEvent) anyerror!void
```

`submit` returns `error.SchedulerUnavailable` if no scheduler is running (e.g.
CLI/tests/no jobs configured).

> **Caveat:** ad-hoc submitted tasks currently run on a **detached thread that is NOT
> joined at shutdown**. A task submitted near shutdown may outlive the scheduler's
> stop/deinit and must not assume `app` (or its pool/storage) outlives it indefinitely.
> Cron/interval jobs, by contrast, use the bounded, cleanly-joined worker pool.

## 7b. Background jobs & queues (`.queues` / `.workers` / `.jobs`)

`.cron`/`app.submit` (§7) are for *scheduled* and *fire-and-forget* work. For **enqueued
background jobs** with retries, priorities, and optional durability, ZigBase ships a generic
multi-queue / worker / job engine. The same engine backs the built-in `mail` and `webhook`
job kinds.

Three config keys lower at comptime:

```zig
App(.{
    // Named queues. `.default` (memory/normal) is ALWAYS synthesized if you don't declare it.
    .queues = .{
        .emails = .{
            .backend  = .durable,   // .memory (default) | .durable
            .priority = .high,      // .high | .normal (default) | .low
            .retry    = .{ .max_attempts = 5, .backoff = .exponential, .base_ms = 1000, .max_ms = 300_000, .jitter = true },
            // Durable-only reliability knobs (defaults shown). Set the visibility timeout
            // ABOVE this queue's longest job runtime so the reclaim sweep never
            // double-dispatches a still-running job:
            .visibility_timeout_s = 300,       // reclaim a claim older than this (>= 1)
            .done_ttl_s           = 604_800,   // GC done/failed rows older than this (7d)
        },
        .reports = .{ .backend = .durable, .priority = .low },
    },
    // Named workers, each draining a subset of queues in STRICT priority order.
    // OMIT `.workers` entirely → ONE implicit worker drains ALL queues, strict priority.
    // `concurrency` = per-poll-cycle BATCH SIZE processed SERIALLY (NOT parallel handler
    // threads); run handlers in parallel by declaring MULTIPLE workers.
    .workers = .{
        .mailer  = .{ .queues = .{"emails"}, .concurrency = 4 },
        .general = .{ .queues = .{ "reports", "default" } },
    },
    // Job-kind registry: kind name → handler `fn(*Ctx, payload: []const u8) anyerror!void`.
    // (`.pool_size` is reserved here for the scheduler pool size — see §7.)
    .jobs = .{
        .resize_image = resizeImage,
        .reindex      = reindex,
    },
})
```

A job handler receives the JSON payload as bytes and deserializes it:

```zig
fn resizeImage(ctx: *zigbase.Ctx, payload: []const u8) anyerror!void {
    const parsed = try std.json.parseFromSlice(struct { id: []const u8 }, ctx.arena, payload, .{});
    // …do the work; touch the DB via ctx.records() / ctx.app.pool.acquireWriter()…
}
```

### Enqueueing

From any route, hook, or job:

```zig
// Compile-checked (a typo'd queue or kind is a COMPILE ERROR), mirrors App.flag:
try App.enqueue(ctx, .emails, .resize_image, .{ .id = "abc123" });

// Runtime-validated escape hatch (errors UnknownQueue / UnknownJobKind):
try ctx.enqueue(.emails, .resize_image, .{ .id = "abc123" });
```

`payload` is JSON-serialized (a `[]const u8` is treated as raw JSON and passed through
unchanged), and the job is routed to the queue's backend.

The framework registers one **built-in job kind** on the same engine: `"mail"`, which backs
[`ctx.mail().enqueue`](#ctxmail--send-application-mail) (it deserializes a `MailMessage`
payload and delivers it). It is reached via that helper (or `ctx.enqueueByName(queue,
"mail", msg)`), not the compile-checked `Job` enum, which reflects only your declared
`.jobs`.

### Backends, priority, and reliability

- **Backend `memory`** (default): the job runs in-process on a detached thread with backoff
  retry. **At-most-once across restart** — an enqueued memory job lives only in RAM, so a
  crash/shutdown before it completes drops it. Zero schema; great for best-effort work.
- **Backend `durable`**: the job is persisted to the `_queue_jobs` table and drained by a
  per-worker poller. **At-least-once** — a crash after a side effect but before the row is
  marked done replays the job, so durable consumers must tolerate replays (idempotency keys
  are the antidote). A **reclaim sweep** resets jobs stranded by a crashed worker (claimed
  longer than that queue's `visibility_timeout_s`), and a GC sweep reaps done/failed rows
  older than its `done_ttl_s` — **both are per-queue** (set `visibility_timeout_s` above the
  queue's longest job runtime, or a long job gets reclaimed mid-flight and re-dispatched).
  The poller and GC jobs are installed **only when a durable queue is declared** —
  pure-memory and no-queue apps install nothing (zero overhead).
- **Priority** (`high`/`normal`/`low`) is a per-queue property. A worker bound to several
  queues drains them in strict priority order: all ready `high`-priority jobs first, then
  `normal`, then `low`. There is no weighted-fair scheduler — priority plus the
  worker/`concurrency` topology is the throughput and anti-starvation lever.
- **Throughput vs. parallelism:** a worker's `concurrency` is the per-poll-cycle **batch
  size** processed **serially** within that worker — it is NOT a count of parallel handler
  threads. To run handlers concurrently, declare **multiple workers** (each is its own
  scheduler job on its own pool thread).
- **Retry/backoff**: on a retryable failure the durable job's `attempts` is bumped and its
  next run is pushed out by the queue's backoff (`fixed` or `exponential`, with optional
  jitter, capped at `max_ms`); exhausting `max_attempts` marks it `failed` and fires your
  `.onError` handler (phase `.job`). Memory jobs retry in-process the same way.

### Caveats

- Durable workers **poll** (roughly every scheduler tick, ~0.5s), so durable jobs drain with
  low but non-zero latency. The scheduler is single-process (see §7 caveats).
- Memory jobs run on detached threads not joined at shutdown (like `app.submit`).

## 8. Define your schema in code (`.collections` + `.migrations`)

Instead of provisioning collections over the REST API (see
[Recipes → Provisioning your schema](./recipes#recipe-provisioning-your-schema)), you can
declare them at **comptime** and have ZigBase provision them at startup:

```zig
zigbase.App(.{
    .collections = .{
        .users = .{ .type = .auth, .fields = .{
            .{ .name = "display_name", .type = .text },
        } },
        .posts = .{ .fields = .{
            .{ .name = "title",  .type = .text, .required = true },
            .{ .name = "author", .type = .relation, .target = "users" }, // by NAME
            .{ .name = "status", .type = .select, .values = .{ "draft", "published" } },
        }, .rules = .{ .list = "status = \"published\"" } },
    },
}).runCli(init);
```

### The `.collections` shape

`.collections` is a struct literal whose **field name is the collection name**. Each value
is a struct with:

- `.type` — `.base` (default) / `.auth` / `.view` (a `schema.CollectionType`).
- `.fields` — a **tuple** of field literals (see below).
- `.rules` — optional `.{ .list, .view, .create, .update, .delete }` (any subset; each is a
  filter-expression string; full grammar in [API → Filter grammar](./api#filter-grammar) —
  comparisons, relation traversal, the `in` set-membership operator, and the
  `@request.auth.*` / `@request.account.*` macros).

Each field literal needs `.name` and `.type`, plus optional `.required`, `.unique`,
`.hidden`, and type-specific options:

```zig
.{ .name = "title",  .type = .text, .required = true, .min = 1, .max = 200 }
.{ .name = "price",  .type = .number, .mode = .fixed, .scale = 2 }   // .float (default) / .int / .fixed
.{ .name = "owner",  .type = .relation, .target = "users", .maxSelect = 1, .cascadeDelete = false }
.{ .name = "status", .type = .select, .values = .{ "draft", "published" }, .maxSelect = 1 }
.{ .name = "avatar", .type = .file, .maxSelect = 1, .mimeTypes = .{ "image/png" } }
.{ .name = "meta",   .type = .json }
```

The full field-type catalog (text / email / url / editor / date / autodate / bool / number
/ json / select / relation / file) and their options is in [Fields](./fields). A relation
field's `.target` is the **target collection name** — provisioning resolves it to the
target's id (no need to capture ids as you would over the REST API). Mistakes are caught at
compile time: an unknown field type, a `select` without `.values`, a `fixed` number without
a valid `.scale = 1..8`, or a relation without `.target` is a **compile error**.
Field names reserved by the engine (`id`, `created`, `updated`, `email`,
`username`, `passwordHash`, `tokenKey`, `verified`) are also rejected at compile
time with a clear error message. A malformed `text` field `.pattern` (invalid regex
syntax) or a malformed `date` field `.min`/`.max` bound in a comptime `.collections`
literal is likewise a `@compileError` at build time — consistent with the rest of the
comptime-validated surface.

### Indexes

A collection may declare `.indexes` — a tuple of index literals provisioned as
`CREATE INDEX` statements when the collection is created:

```zig
.indexes = .{
    // unique, case-sensitive (default collation)
    .{ .name = "idx_users_handle", .fields = .{"handle"}, .unique = true },
    // case-insensitive: SQLite emits ("email" COLLATE NOCASE); Postgres a lower("email") functional index
    .{ .name = "idx_users_email",  .fields = .{"email"}, .unique = true, .collation = .nocase },
    // partial / conditional-unique: emits ... WHERE deleted_at IS NULL
    .{ .name = "idx_active_slug",  .fields = .{"slug"}, .unique = true, .where = "deleted_at IS NULL" },
},
```

`.collation` (`.binary` default / `.nocase`) is applied to every indexed column;
`.where` is an optional partial-index predicate emitted verbatim as `WHERE <where>`.
The index `.name` and `.fields` are validated as identifiers; the `.where` predicate
is raw SQL authored in the schema. Index `.fields` reference fields by their declared name (not an internal id); `.name` and each field are validated as identifiers at compile time.

### Row expiry (TTL) — `.ttl_field`

A collection may name an existing `date`/`autodate` field as the row's **expiry
timestamp** via `.ttl_field`. A framework-internal garbage-collector then reaps
rows whose timestamp is in the past — automatically, with no cron of your own:

```zig
.sessions = .{
    .fields = .{
        .{ .name = "token",      .type = .text },
        .{ .name = "expires_at", .type = .date },   // ISO-8601 UTC, e.g. "2026-07-01T00:00:00Z"
    },
    .ttl_field = "expires_at",   // rows with expires_at <= now are deleted
},
```

Semantics:

- `.ttl_field` must name a field declared on the **same collection** and of type
  `.date` or `.autodate` — anything else is a **compile error** (those types hold an
  ISO-8601 instant). Both the read-exclusion predicate and the GC normalize both
  sides via SQLite `strftime(...)` before comparing, so non-canonical `.date` values
  (timezone offsets, space separator, date-only) are handled correctly — do not
  assume lexical comparison.
- A row is reaped when its ttl value is **non-null and at/before "now"**. A row
  whose ttl field is `null` never expires (so an optional, never-set expiry is a
  permanent row). A row with an unparseable ttl value is treated the same as `null`
  — fail-safe: it remains visible and is never reaped by the GC.
- **Read-time exclusion**: expired rows are **automatically hidden from every read**
  (list and get, via the HTTP API, `ctx.records()`, and relation expand). The
  predicate is ANDed with your filter, access rule, and keyset cursor, so it composes
  transparently. You do not need to add a manual `expires_at > @now` filter.
- The GC sweep still runs **once at startup** and then on a **5-minute interval**
  (framework-internal job `_ttl_gc`; see §7), deleting expired rows so the table does
  not grow unboundedly. Declaring a TTL collection starts the scheduler even if you
  have no `.cron` of your own.
- With an `.autodate` ttl field, prefer one whose value you set explicitly to the
  intended expiry (autodate defaults to write-on-create "now", which would expire
  the row immediately).

### Multi-tenancy — account-scoped collections (`.tenancy` + `.tenant_field`)

ZigBase has built-in **account-scoped multi-tenancy** (#156): a collection can be *tenant-owned*,
and every read/write of it is automatically narrowed to the request's **active account** — you do
not write `account = @request.account.id` on every rule, and a client can never read or write across
tenants.

Turn it on in `App(.{ ... })` and mark each owned collection's owning-account column with
`.tenant_field`:

```zig
zigbase.App(.{
    .tenancy = .{
        .enabled = true,
        .resolver = .header,          // read the active account from X-Account-Id / the zb_account cookie
        .auth_collection = "users",   // the auth collection whose records are members
        .roles = .{ "viewer", "editor", "admin", "owner" }, // optional; this is the default ladder
    },
    .collections = .{
        .projects = .{
            .fields = .{
                .{ .name = "title",   .type = .text },
                .{ .name = "account", .type = .text },   // holds the owning account id
            },
            .tenant_field = "account",                   // <- makes `projects` tenant-owned
            .rules = .{ .list = "@public", .view = "@public" },
        },
    },
});
```

**Data model.** Migration `0014_tenancy` creates three system collections (visible in
`_collections`, `system = 1`):

- `_accounts(id, created, updated, name, slug UNIQUE, owner_user, status)` — one row per tenant.
- `_memberships(id, …, account, user_collection, user, role, status)` — the principal↔account edge.
  `(account, user_collection, user)` is unique; `user_collection` is part of the key because several
  auth collections may exist. Indexed on `(user_collection, user, status)` ("my accounts") and
  `(account, status)`.
- `_invitations(id, …, account, email, role, token UNIQUE, invited_by, expires, accepted_at)` —
  pending invites. (Invite/accept/remove **lifecycle** is a later PR; PR2 ships the tables only.)

**Resolution (fail closed).** On each request the active account is resolved from `X-Account-Id`
(or the signed `zb_account` cookie) and verified against an **active** `_memberships` row for the
authenticated principal — one indexed `SELECT`, cached on the request. No/invalid/inactive
membership ⇒ **no account context**, and tenant-owned data is invisible. The resolution also fills
the rule macros `@request.account.id`, `@request.account.role`, and the list-valued
`@request.account.ids` (the `in` operator's membership-bounded source).

**Activation for browsers.** `POST /api/accounts/:id/activate` verifies membership and sets a
signed, HttpOnly `zb_account` cookie, so a browser SPA selects an account once instead of sending
`X-Account-Id` on every call. API clients can skip this and just send the header. 403 without an
active membership; 404 when tenancy is disabled.

**Scoping & the write path.** A tenant-owned collection is auto-scoped at all CRUD chokepoints and
realtime delivery via a bound `"<col>"."<tenant_field>" = ?` predicate composed into the guard
stack — `WHERE (filter) AND (rule) AND (tenant_field = ?) AND (ttl)`. A **locked** rule (`null`/`""`)
still denies first (the fail-closed floor is unchanged). On **create** the owning account is
*stamped* onto the row (clients can't spoof it); on **update** a cross-tenant move is rejected by the
in-transaction guard, and a cross-tenant *target* is rejected **before** the `before_update` hook
runs (so hooks never fire against another account's row). Creating in a tenant-owned collection with
no active account is denied.

**Realtime is scoped too.** A WebSocket connection resolves its active account at the handshake
(the signed `zb_account` cookie or `X-Account-Id` header) and verifies a membership at `auth`-frame
time; delivery of a tenant-owned collection's create/update/delete frames (including the delete
snapshot) is then filtered to the subscriber's account. With tenancy enabled, a connection with no
resolved account receives **nothing** from a tenant-owned collection — even one with a `@public`
viewRule — so realtime never leaks across accounts (fail closed).

**Roles** form a total order (`tenancy/roles.zig`), default `viewer < editor < admin < owner`,
configurable via `.tenancy.roles`. (PR3 consumes the ranking for ability checks.)

**Superuser & cross-tenant tooling.** Superusers bypass tenancy entirely (consistent with the
access-rule engine). For admin tooling that must legitimately span accounts (an ops dashboard,
a maintenance job), `zigbase.crossTenant(rctx)` returns a context with the override enabled — the
*explicit, never-silent* way to widen scope.

**Back-compat is byte-identical.** With `.tenancy` absent/`enabled = false`, or for any collection
without a `.tenant_field`, the composed SQL and authorization decisions are **identical** to the
pre-tenancy engine (pinned by tests in `policy.zig`). Enabling tenancy never changes a non-tenant
collection.

### Relationship-based row abilities (`.abilities`)

Tenancy scopes a collection to **one** active account. **Abilities** (#155) authorize a CRUD
action by the principal's **relationship** to the row — "you may edit a project if you are an
`editor` (or higher) of the account it belongs to" — without writing that membership join by hand in
every rule. Abilities are declared at the top level of `App(.{ … })`, keyed by collection name, with
a per-action **relationship** rule:

```zig
const App = zigbase.App(.{
    .tenancy = .{ .enabled = true, .auth_collection = "users",
                  .roles = .{ "viewer", "editor", "admin", "owner" } },
    .collections = .{
        .projects = .{
            .fields = .{
                .{ .name = "title",   .type = .text },
                .{ .name = "account", .type = .relation, .target = "accounts" }, // owning account
            },
            .rules = .{ .list = "@public", .view = "@public" },
        },
    },
    // A row of `projects` is authorized when the principal holds a membership (role ≥ floor) of the
    // account named by the `account` relation field.
    .abilities = .{
        .projects = .{
            .view   = .{ .relationship = .{ .via = "account" } },               // any active member
            .update = .{ .relationship = .{ .via = "account", .min_role = .editor } },
            .delete = .{ .relationship = .{ .via = "account", .min_role = .admin } },
            .create = .{ .relationship = .{ .via = "account", .min_role = .editor } },
        },
    },
});
```

**Lowering.** Each rule compiles to a bound `IN` predicate over the principal's **qualifying**
membership account-ids — `"projects"."account" IN (?,?,…)` — exactly the shape the `in` operator and
`@request.account.ids` macro already emit. `min_role` filters the membership set through the
configured role ladder (`.tenancy.roles`); `.via` **must name a relation field** (the field whose
column holds the owning account id). `list` reuses the `view` ability.

**Composition.** The ability predicate is AND-ed into the same guard stack as the access rule and the
tenant scope, on **every** chokepoint — view/create/update/delete, `expand`, realtime delivery, AND
the bulk **list** endpoint: `WHERE (filter) AND (rule) AND (ability) AND (tenant_field = ?) AND (ttl)`.
An ability forces a per-row check even when the access rule alone would `allow`, so a
`.rules.list = "@public"` collection with a view ability returns the **ability-narrowed** set (HTTP
200) — not every row, and not a 400.

**Fail closed.** No qualifying membership ⇒ the constant-false predicate `0` (the row is denied;
never SQLite's invalid `IN ()`). A **locked** rule (`null`/`""`) still denies first. Account-ids are
always **bound** parameters, never interpolated; superusers bypass abilities entirely.

**Comptime validation.** An ability naming an unknown collection, a `.via` that is not a relation
field, or a `.min_role` not in `.tenancy.roles` is a loud `@compileError`. `.abilities` also requires
`.tenancy.enabled = true` (abilities authorize by account membership, which only resolves under
tenancy) — configuring abilities with tenancy disabled is a `@compileError` rather than a silent
deny-all at runtime.

**Custom routes.** `try ctx.can(.update, "projects", id)` authorizes a specific record through the
**same** policy (rule + ability + tenant scope) the REST chokepoints use — use it instead of
re-implementing the check in a handler.

**Introspection.** `GET /api/collections/:col/records/:id/abilities` returns a JSON object of booleans
like `{"view": true, "update": false, "delete": false}` — the actions the current principal may
perform on that record. The endpoint itself requires view access (404 otherwise), so it never leaks a
record's existence (and `"view"` is therefore always `true` on a 200 response).

**Back-compat is byte-identical.** A collection with no `.abilities` entry composes a null predicate,
so its decisions and compiled SQL are **identical** to the pre-abilities engine (pinned in
`policy.zig`).

### Product analytics (`.analytics` + `ctx.track`)

Built-in event capture and declarative rollups. Two halves:

**1. Capture — `ctx.track(name, payload)`.** From any hook, route, or job, append one immutable
event to the built-in `_events` collection:

```zig
fn afterSignup(ctx: *zigbase.Ctx, ev: *zigbase.RecordEvent) anyerror!void {
    try ctx.track("user.signup", .{ .plan = "pro" });
}
```

The `actor` / `actor_collection` (the authenticated principal), the `account` (the request's active
tenant scope, `""` when tenancy is off), and the `occurred_at` timestamp are all resolved
**server-side** — a client cannot forge any of them. `payload` is any JSON-serializable value,
stored as opaque JSON text (a `[]const u8` is taken as raw JSON). It is a single cheap INSERT; inside
a hook / `ctx.tx` it reuses the in-transaction connection.

**2. Rollups — declarative, scheduled aggregation.** Declare named rollups; each registers one job on
the existing scheduler that aggregates `_events` into a `_rollup_<name>` summary table:

```zig
const App = zigbase.App(.{
    .analytics = .{
        .rollups = .{
            .signups_daily = .{
                .event = "user.signup",
                .every = .{ .interval = .hourly },          // a cron/interval Schedule
                .group_by = .{ .account = true, .time_bucket = .day },
                .metric = .count,
            },
        },
    },
});
```

`.group_by` keys: `.account` / `.actor` (bools) and `.time_bucket` (`.none` / `.day` / `.hour`).
`.metric` is `.count` (default). Aggregation is **incremental and idempotent**: a persisted watermark
(in `_kv`) tracks the monotonic `_events.rowid` already aggregated, and each run aggregates the
disjoint window `watermark < rowid <= max_rowid`. Because the watermark is the rowid (not the
timestamp) and the job holds the exclusive writer for the pass, a run **neither double-counts nor
drops** — even an event inserted in the same wall-clock second as a prior run still has a
strictly-greater rowid and is counted next pass. Summary-table / column identifiers are gated through
`schema.isValidIdentifier`. Misconfiguration fails **loudly at compile time** — an unknown
`.group_by`/`.metric`, a missing or empty `.event`, or a rollup name that is not a valid identifier is
a `@compileError`.

**Read API (tenant-scoped, fail-closed).** Both endpoints are authenticated and never leak across
accounts:

- `GET /api/analytics/events?name=&actor=&since=&limit=` — the raw activity feed.
- `GET /api/analytics/rollups/:name?from=&to=` — a rollup's summary rows (for charts).

A **superuser** sees everything; a **member** sees only their active account's data (resolved from a
verified `_memberships` row, the same path the records chokepoints use); with tenancy **disabled** the
feed is scoped to the caller's own events and a (global) rollup is superuser-only. A member can never
read another account's events or rollups.

> **Visibility is account-level, not role-level.** Any *active member* of an account — whatever their
> role — can read the **entire** account's event feed (including other members' events and payloads)
> and all of its rollup buckets. The trust boundary is the tenant, not the role; there is deliberately
> no intra-account role gating. Treat event payloads as readable by every member of the account.

**Back-compat.** With no `.analytics` config the `_events` table is still seeded (harmless) but no
rollup job is scheduled, and `ctx.track` works standalone.

### Field encryption at rest (`.encrypted`)

Mark a `text`, `editor`, or `json` field `.encrypted = true` to store it
encrypted at rest. The records layer encrypts on write and decrypts on read, so
your handlers, the records API, and the HTTP responses always see **plaintext** —
only the SQLite file holds ciphertext:

```zig
.fields = .{
    .{ .name = "ssn",   .type = .text, .encrypted = true },
    .{ .name = "notes", .type = .json, .encrypted = true },
},
```

**Envelope.** AES-256-GCM, versioned: each value is stored as
`v<N>:` + base64url(nonce ‖ ciphertext ‖ tag) with a fresh random nonce per
write, where `N` is the key generation (default `1` — see Key rotation below).

**Key (required).** The key comes **only** from the `ZIGBASE_FIELD_KEY`
environment variable (HKDF-derived; the raw value may be any length). Unlike the
JWT secret it is **never auto-generated, persisted, or logged** — losing or
rotating it determines whether the data is recoverable, so you must manage it.
If any collection declares an `.encrypted` field and `ZIGBASE_FIELD_KEY` is unset,
**the server refuses to start** (fail-closed — it never silently stores plaintext).
This holds for both comptime `.collections` and collections created at **runtime**
(via the admin/collections API): startup scans the live database schema after
provisioning, so a restart without the key is refused even for a runtime-added
encrypted field.

**Constraints (enforced).** Encrypted values are per-row-nonce ciphertext, so they
cannot be indexed, marked `.unique`, or used in a `?filter`/`?sort`:

- Indexing an encrypted field, marking it `.unique`, or setting `.encrypted` on a
  non-`text`/`editor`/`json` field is a **compile error**.
- A request that filters or sorts by an encrypted field gets a **400**.
- Access rules that compare an encrypted field will compare against ciphertext and
  effectively never match — don't reference encrypted fields in rules.

**Strict reads / enabling on existing data.** Reads are strict: a stored value
that is not a valid `v<N>:` envelope (e.g. legacy plaintext) or that fails
authentication (wrong key, tamper, or an unconfigured key generation) **fails
closed** — there is no plaintext passthrough. Therefore, turning `.encrypted` on
for a column that already holds plaintext rows requires running `zigbase rewrap`
first (see below); "encrypted means encrypted".

#### Key rotation

The `v<N>:` envelope prefix is the **key generation**: a `v<N>:` value is
decrypted with generation `N`'s key. Writes always use the **primary** generation
and stamp its version; reads dispatch on the prefix. This lets you write under a
new key while still reading old data, then migrate the old data forward.

Configuration (env only — keys are never auto-generated, persisted, or logged):

| Env var | Meaning |
| --- | --- |
| `ZIGBASE_FIELD_KEY` | The **primary** (current/write) key. Required if any field is encrypted. |
| `ZIGBASE_FIELD_KEY_GENERATION` | Integer `1..64`, **default `1`** — the generation of the primary key (= the `v<N>:` version written). |
| `ZIGBASE_FIELD_KEY_V<M>` | A read-only key for an **older** generation `M`, used to decrypt existing `v<M>:` data. |

The default (just `ZIGBASE_FIELD_KEY`, generation `1`) is identical to the
single-key build — it writes and reads `v1:`. Each generation derives an
independent key (HKDF, domain-separated by generation), so generations never
share key material. Setting `ZIGBASE_FIELD_KEY_V<M>` for the primary generation
`M` is a fatal config error (ambiguous — the primary key already comes from
`ZIGBASE_FIELD_KEY`).

**To rotate** from generation 1 (key `oldkey`) to generation 2 (key `newkey`):

1. Restart with `ZIGBASE_FIELD_KEY=newkey`, `ZIGBASE_FIELD_KEY_GENERATION=2`,
   `ZIGBASE_FIELD_KEY_V1=oldkey`. New writes are `v2:`; old `v1:` rows still read.
2. Run the rewrap command to re-encrypt every `v1:` cell as `v2:`:

   ```sh
   ZIGBASE_FIELD_KEY=newkey ZIGBASE_FIELD_KEY_GENERATION=2 ZIGBASE_FIELD_KEY_V1=oldkey \
     zigbase rewrap --data-dir ./zb_data
   ```
3. Once rewrap completes, drop `ZIGBASE_FIELD_KEY_V1` — no `v1:` data remains.

**`zigbase rewrap`** walks every `.encrypted` field of every collection, decrypts
each cell with whichever generation matches its envelope version (or, for legacy
plaintext, takes it as-is), and re-encrypts it under the primary key. It is the
supported path both to finish a rotation and to migrate existing plaintext into
ciphertext when first enabling `.encrypted`. It is **idempotent** (cells already
at the primary version are skipped), transactional per collection, and
**fail-closed**: a cell it cannot decrypt (missing generation key, wrong key,
tamper) aborts the run with the offending row reported and that collection's
transaction rolled back — no data is lost. `--dry-run` reports counts without
writing. Run it with the primary key plus every older generation present in your
data configured.

> Memory note: rewrap buffers a collection's rewritten cells in memory before
> writing them back, so peak memory is O(rows) in the collection being processed.
> This is fine for a one-off maintenance command on typical tables; chunked
> rewrapping for very large encrypted tables is a possible future option.

> Note: the envelope hides a value's *contents* but not its *length* — ciphertext
> length is proportional to plaintext length. A single long-lived key suits typical
> volumes; for very high write volumes, periodic key rotation is recommended.

### Startup provisioning + additive auto-migration

On every startup, ZigBase diffs each declared collection against the live database and
applies the **minimal safe change set** (running it twice is a clean no-op):

- A collection that doesn't exist yet is **created**.
- A field present in the spec but missing from the live collection is **added**, rebuilding
  the table while **preserving existing data** (the new column is null for old rows).
- A **non-additive** change — a field rename, drop, or type/storage-class change — is
  **detected, logged, and SKIPPED** (never applied, so no data loss). Relation targets must
  reference a known collection (a comptime collection or a pre-existing live one such as
  `_superusers`); an unknown target is a startup error.

For the changes auto-migration won't do, use the `.migrations` escape hatch.

### Explicit migrations (`.migrations`)

`.migrations` is a **typed slice** of `zigbase.Migration` records, each run **once**
(recorded in `_migrations` under a `prov:` prefix) **before** provisioning. The field is
`[]const zigbase.Migration`, so it must be a typed slice (`&[_]zigbase.Migration{ ... }`) —
a bare anonymous tuple does **not** coerce:

```zig
.migrations = &[_]zigbase.Migration{
    .{ .id = "0001_rename_title", .up = renameTitle },
},
// .up signature: fn (m: *zigbase.Migrator) anyerror!void
//   `m` carries the active SQL dialect, the writer connection (`m.db`), a scratch
//   arena (`m.arena`), and `m.io`. It exposes exec/execLowered/prepare/rawFor.
fn renameTitle(m: *zigbase.Migrator) anyerror!void {
    // RENAME COLUMN is identical on SQLite and Postgres, so plain raw SQL is fine here.
    try m.exec("ALTER TABLE \"posts\" RENAME COLUMN \"headline\" TO \"title\";");
}
```

Each migration has an `.id` (used for the once-only record) and an `.up` function `fn
(m: *zigbase.Migrator) anyerror!void` run inside a transaction (rolled back on error).
Use migrations for renames, drops, type changes, and data backfills.

#### Cross-backend migrations (SQLite **and** Postgres)

The same migration runs on whichever backend the server was started with (SQLite by
default, or PostgreSQL when built with `-Dpostgres` and pointed at a `postgres://` URL).
`*zigbase.Migrator` makes that explicit — it is **pass-the-dialect**, not an SQL
transpiler:

- **`m.execLowered(sql)`** — run a curated statement written in the SQLite flavor; the
  dialect lowers the portable migration-level SQLite-isms (`INTEGER`→`BIGINT`,
  `datetime('now')`→a text now, `INSERT OR IGNORE`→`ON CONFLICT DO NOTHING`) on Postgres
  while leaving SQLite **byte-identical**. Covers most additive DDL + seeds.
- **`m.exec(sql)`** — run **raw, backend-specific** SQL verbatim. *You* own dialect
  correctness: SQLite-only SQL run on Postgres **fails loud** at startup (the database
  rejects it and the migration aborts — migrations are fail-fast).
- **`m.dialect.kind`** (`.sqlite` / `.postgres`), **`m.rawFor(.postgres, sql)`** /
  **`m.rawFor(.sqlite, sql)`** (run only on the matching backend), and
  **`m.requireBackend(.sqlite)`** (assert + fail loudly on the wrong backend) let a
  migration branch when a statement genuinely differs per backend.

ZigBase deliberately does **not** transpile SQL between dialects. A SQLite-only consumer
that never builds with `-Dpostgres` keeps working unchanged. The framework's own
comptime-schema provisioning is fully cross-backend, so most apps need no raw migrations.

**Postgres collation.** Provisioned TEXT columns are pinned to `COLLATE "C"` so text
ordering / keyset pagination matches SQLite's BINARY byte order across backends. A comptime
index marked `.collation = .nocase` is case-INSENSITIVE on **both** backends: SQLite uses
`COLLATE NOCASE`, while Postgres (which has no built-in NOCASE collation) provisions a
`lower("col")` **functional index** — a built-in, no `citext`/extension dependency. So a
`.nocase` UNIQUE index rejects case-variant duplicates (`Bob@x.com` vs `bob@x.com`) on
Postgres exactly as on SQLite (#159). **Lookups and comparisons are case-insensitive on
BOTH backends**, so a `.nocase` column behaves identically everywhere: identity/email
lookups (`findByIdentity`/`findByEmail`) and filter/rule equality (`=`/`!=`/`in`) against a
`.nocase` column emit `lower("col") = lower($1)` on Postgres (the `lower()` functional
index) and `"col" COLLATE NOCASE = ?1 COLLATE NOCASE` on SQLite (the COLLATE NOCASE index) —
so a user registered as `Bob@x.com` can log in as `bob@x.com` on either backend (the
uniqueness ⇔ lookup consistency holds). The built-in auth identity uniqueness (the partial
unique index auto-created for each `identityFields` entry) is a plain CASE-SENSITIVE index
on both backends; case-insensitive identity is opt-in by declaring a `.nocase` index on the
field (the pattern the example apps use). One nuance: Postgres `lower()` is locale-aware
(folds non-ASCII, e.g. `É`→`é`), whereas SQLite `NOCASE` folds ASCII A–Z only.

## 9. Pluggable storage & mailer backends (`.storage` / `.mailer`)

`.storage` and `.mailer` each select a comptime **plugin type**. The defaults reproduce the
built-in wiring:

- `.storage` defaults to **`zigbase`'s `DefaultStoragePlugin`** — local-disk storage rooted
  at `<data_dir>/storage`.
- `.mailer` defaults to **`DefaultMailerPlugin`** — config-driven with a fixed precedence: a
  `CommandMailer` (pipes the message to a local MTA's stdin) when `ZIGBASE_SENDMAIL_COMMAND`
  is set, else an `SmtpMailer` (STARTTLS / implicit TLS / plaintext) when `ZIGBASE_SMTP_HOST`
  is set, else a `LogMailer` (logs the email). Switching is config-driven; no code change is
  needed to upgrade from logging to a local sendmail/msmtp relay or real SMTP.

A plugin is a type with this uniform contract (built from the runtime `zigbase.Config`):

```zig
pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: zigbase.Config) !Self;
pub fn interface(self: *Self) zigbase.Storage; // or zigbase.Mailer — the type-erased vtable view
pub fn deinit(self: *Self) void;               // release owned resources
```

`create` builds the backend from config; `interface` returns the type-erased vtable handle
stored on the app; `deinit` tears it down (the instance outlives the server). Supply your
own to back storage or mail with a different system. A custom mailer hands back a
`zigbase.Mailer` view built from a static `VTable` whose `send` receives a `zigbase.Email`:

```zig
const AuditMailer = struct {
    sent: usize = 0,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: zigbase.Config) !AuditMailer {
        _ = gpa; _ = io; _ = cfg;
        return .{};
    }
    pub fn interface(self: *AuditMailer) zigbase.Mailer {
        return .{ .ptr = self, .vtable = &vtable };
    }
    pub fn deinit(self: *AuditMailer) void { _ = self; }

    const vtable = zigbase.Mailer.VTable{ .send = send };

    fn send(ptr: *anyopaque, io: std.Io, alloc: std.mem.Allocator, email: zigbase.Email) anyerror!void {
        _ = io; _ = alloc;
        const self: *AuditMailer = @ptrCast(@alignCast(ptr));
        self.sent += 1;
        std.log.info("to={s} subject={s}", .{ email.to, email.subject });
    }
};

zigbase.App(.{ .mailer = AuditMailer }).runCli(init);
```

A custom storage plugin follows the same shape, returning a `zigbase.Storage` view from
`interface()`. The `zigbase.Storage` vtable backs file storage (the default
`zigbase.DefaultStoragePlugin` wraps `zigbase.LocalStorage`); the `zigbase.Mailer` vtable —
a single `send(io, alloc, zigbase.Email)` — backs mail (the default
`zigbase.DefaultMailerPlugin` selects `zigbase.LogMailer` or `zigbase.SmtpMailer` from
config). See the [plugins example](../examples/plugins) for the full, compiling
custom-mailer plugin.

## 10. Footprint levers (`.pools`)

`.pools` tunes ZigBase's memory/connection footprint at comptime. All fields are optional;
each defaults to the historical value:

| Field | Default | Meaning |
| --- | --- | --- |
| `.readers` | `16` | warm reader-connection pool cap — shrink to reduce the connection footprint. |
| `.jobs` | `2` | scheduler worker-pool size (same as `.jobs.pool_size`). |
| `.stack_size` | `1 MiB` | per-thread stack for scheduler/job/`submit` threads (vs `std.Thread`'s 16 MiB default). **Clamped up** to a safe floor — the lever can only *raise* the stack, e.g. for unusually deep job handlers. |
| `.cache_kib` | `1024` | SQLite per-connection page cache (KiB), across the writer + warm readers — shrink to save memory, raise for large working sets. |

```zig
zigbase.App(.{
    .pools = .{ .readers = 4, .jobs = 2, .stack_size = 2 << 20, .cache_kib = 256 },
}).runCli(init);
```

`.pools.jobs` is the unified job-pool lever; the legacy `.jobs = .{ .pool_size = N }` still
works (and `.pools.jobs` takes precedence when both are set).

## 10b. Pagination (`.pagination`)

`.pagination` chooses, at comptime, which list-pagination modes the records list endpoint
exposes and which **cursor token format** it mints. All fields are optional; the stock binary
behaves as `.{ .offset = true, .cursor = true, .cursor_token = .stateless }`.

```zig
zigbase.App(.{
    .pagination = .{
        .offset = true,             // page/perPage offset paging (default true)
        .cursor = true,             // cursor (keyset) paging      (default true)
        .cursor_token = .stateless, // .stateless | .signed | .stateful (default .stateless)
    },
}).runCli(init);
```

- **`.offset = false`** — requests with `page`/`perPage` get a 400; clients must walk `cursor`.
- **`.cursor = false`** — requests with `cursor` get a 400; only offset paging is allowed.
- **Both `false`** — a `@compileError` (a list endpoint must have at least one mode).

The `.cursor_token` selector (security/statefulness tradeoffs):

| Value | Token | Tamper-evident | State | Use when |
| --- | --- | --- | --- | --- |
| `.stateless` (default) | base64url JSON payload, validated against the request's sort/filter | No (rules + parameterized binding secure it) | None | Default; CDN-friendly; SDK-byte-compatible. |
| `.signed` | stateless payload + HMAC-SHA256 keyed by the **server JWT secret** | Yes (400 on bad MAC) | None | You want tamper-evidence with no extra storage. |
| `.stateful` | random opaque id; payload stored in `_cursorStates` with a TTL (GC'd) | N/A | A row per cursor | You want server-controlled validity/expiry (410 on expired). |

See the [API reference](api#cursor-keyset-pagination) for the request/response shape. The
blog example uses `.cursor_token = .signed`; golfsim shows the explicit stateless default.

## 11. Errors + Sentry

```zig
.onError = handleError, // fn (ev: *zigbase.ErrorEvent) void
```

When the framework catches an error, your `onError` handler (if any) runs **first**, then a
built-in backstop reports the error to Sentry when `ZIGBASE_SENTRY_DSN` is set, otherwise
logs it. `ErrorEvent` carries `app`, `ctx` (optional), `err`, `phase` (`request` /
`before_hook` / `after_hook` / `cron` / `job` / `file_serve`), and `message`. The backstop
never propagates.

## 12. The worked example

Three buildable examples form a ladder: the [blog example](../examples/blog) is the basic
packaging proof (hooks + route + cron + Astro/React frontend served via `--serve-static`),
the [golfsim example](../examples/golfsim) is a realistic app (hooks, routes, cron, a
comptime-hardcoded `.dir` static mode, and a **generated TypeScript typed client** at
`clients/typescript/zbase.gen.ts` — regenerate with `zig build gen-client`), and the
[plugins example](../examples/plugins) is
the advanced framework-feature reference (custom mailer plugin + `.collections` schema +
typed `.migrations` + `.pools` levers + fully embedded static assets via `embedStaticDir`).

The blog `App(.{...})` block is the canonical basics reference (hooks + route + job):

```zig
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .hooks = .{ .posts = .{ .beforeCreate = slugify } },
        .routes = .{
            .{ .method = .GET, .path = "/api/blog/ping", .handler = ping, .auth = .public },
        },
        .jobs = .{ .pool_size = 2 },
        .cron = .{
            .{ .name = "heartbeat", .schedule = zigbase.schedule.Schedule{ .interval = .hourly }, .handler = heartbeat },
        },
    }).runCli(init);
}
```

## 13. Serve a frontend: static files

Anything that misses `/_/`, the built-in API, and your custom routes falls through to the
static-file server (GET/HEAD only; `/api/*` misses keep the JSON 404 envelope; static
misses return a plain-text 404). `/` and directory paths resolve to `index.html`. In
**embedded** mode, each asset carries a precomputed CRC32 content `ETag` and zigbase
handles `If-None-Match`/304 itself. In **dir** mode (`--serve-static` or comptime `.dir`),
caching is delegated to facil.io's `sendFile`, which emits its own `ETag`, `Last-Modified`,
`Cache-Control: max-age=3600`, and handles `If-None-Match`/304. All modes add
`X-Content-Type-Options: nosniff`.

Pick a mode at comptime with `.static_files`:

| Mode | Config | `--serve-static` flag |
|---|---|---|
| runtime flag (default) | *(field absent)* | enabled |
| disabled | `.static_files = .disabled` | rejected |
| hardcoded dir | `.static_files = .{ .dir = "frontend/dist" }` | rejected |
| embedded | `.static_files = .{ .embedded = &@import("static_assets").files }` | rejected |

In **embedded** mode, assets are compiled into the binary. Generate the manifest from your
`build.zig` using the helper exported by zigbase's `build.zig`:

```zig
// build.zig
const zigbase_build = @import("zigbase");
const assets = zigbase_build.embedStaticDir(b, "frontend/dist");
exe_mod.addImport("static_assets", assets);

// main.zig
.static_files = .{ .embedded = &@import("static_assets").files }
```

The build fails with a clear error when `frontend/dist` is missing — build the frontend
first (e.g. `npm run build`). A hardcoded or `--serve-static` directory that is missing or
unreadable at startup is a **fatal startup error** naming the path.

See the [blog example](../examples/blog) (runtime flag), [golfsim example](../examples/golfsim)
(hardcoded dir), and [plugins example](../examples/plugins) (embedded).

## 14. Test / dev-mode determinism seams

Two env vars (dev builds only) make a test suite reproducible. Both are compiled out
entirely in production — a release binary never reads either var.

### Freezing time: `ZIGBASE_FAKE_NOW`

Set `ZIGBASE_FAKE_NOW` to an ISO-8601 UTC instant (e.g. `2029-03-07T16:00:00Z`) to
freeze the framework's clock for the lifetime of the process. Every framework-controlled
timestamp routes through the seam:

- Token `iat` / `exp` (JWT auth tokens).
- The scheduler's next-fire math (cron / interval jobs).
- Auth rate-limiter wall clock.
- Auth-challenge and keyset-cursor TTL/expiry checks.
- A consumer's own `datetime('now')` / `unixepoch('now')` / `strftime(…, 'now')` /
  `date('now')` / `time('now')` / `julianday('now')` in raw SQL — those date/time
  functions are shadowed on every connection and resolve to the frozen instant when a
  freeze is active, **including their zero-argument implicit-`'now'` forms** (e.g.
  `date()`). Every other input passes through to genuine SQLite unfrozen: explicit
  datetimes, `'+1 day'` / `'start of month'` modifiers, and the `strftime` format string.
- The SQL keywords `CURRENT_TIMESTAMP` / `CURRENT_TIME` / `CURRENT_DATE` and column
  `DEFAULT CURRENT_TIMESTAMP` timestamps. These read SQLite's clock through the VFS, not
  the SQL-function layer, so (dev builds only) connections open against the `zigbase_frozen`
  wrapping VFS — a byte-for-byte copy of the default VFS with only its current-time hooks
  overridden to the frozen instant; all file I/O still delegates to the genuine OS VFS
  unchanged (`src/clock_vfs.zig`). There are no remaining unfrozen `'now'` paths.

On the **Postgres backend** (`-Dpostgres`, opt-in), the same freeze is achieved with one
portable mechanism instead of the two SQLite shims (there is no in-process function
registration or VFS on a remote server): when a freeze is active, every connection installs a
session-level `now()` override — a `zigbase_frozen.now()` wrapper returning the frozen instant,
placed on the connection's `search_path` ahead of `pg_catalog` (`src/backend/postgres/clock.zig`).
Because the framework and any consumer raw SQL both call `now()`, this freezes record autodate
stamps, KV/metadata timestamps, and a consumer's own `now()` alike. Same comptime `dev_clock`
gate, so a production Postgres binary is unaffected.

```sh
ZIGBASE_FAKE_NOW="2029-03-07T16:00:00Z" ./zigbase serve ...
```

### Seeding entropy: `ZIGBASE_FAKE_SEED`

Set `ZIGBASE_FAKE_SEED` to a decimal `u64` (e.g. `12345`) to plant a deterministic
Xoshiro256++ PRNG as the entropy source for ID/token generation. Every record ID,
field ID, and token key generated in the process comes from that seeded PRNG instead of
the OS CSPRNG, so two runs with the same seed produce byte-for-byte identical IDs and
tokens — useful for snapshot tests.

```sh
ZIGBASE_FAKE_SEED=12345 ./zigbase serve ...
```

The seam routes through `src/id.generate`, covering:
- Collection IDs and field IDs (provisioning, record creates).
- `tokenKey` per auth record and the OAuth2 CSRF state value.

Other randomness (AEAD nonces, OTP digits, WebAuthn challenges) is **not** routed
through this seam — those are security-critical at runtime and seeding them is unsafe.

### Production gate

Both seams are compiled in ONLY when the `dev_clock` build option is `true` (the
default in `Debug` builds). The release script forces `-Ddev-clock=false` for all
shipped binaries, so a production binary has the override code comptime-eliminated:

- `ZIGBASE_FAKE_NOW` is never read; the clock always returns wall time.
- `ZIGBASE_FAKE_SEED` is never read; ID/token generation always uses the OS CSPRNG.

You can also force the prod-safe behavior explicitly: `zig build -Ddev-clock=false`.

CI runs both passes: the default `Debug` pass (dev features on, prod-gate assertions skipped) and a `-Ddev-clock=false` prod-gate pass (dev features off, prod-gate assertions executed) to verify the compiled-out guarantee.

## Exported names reference

The public surface (from `src/root.zig`):

- `zigbase.App` — the comptime application builder.
- `zigbase.Runtime` — the runtime app context type (the `*App` you receive on events).
- `zigbase.Config`, `zigbase.Server`.
- `zigbase.http` — HTTP types (`http.Response`, `http.Method`, ...).
- `zigbase.Ctx` — the per-request capability object passed as the first parameter to every
  route / hook / job / lifecycle handler (`ctx.records()`, `ctx.http()`, `ctx.user()`,
  `ctx.tx()`, `ctx.issueSession()`, `ctx.fail`/`ctx.invalid`/`ctx.errorResponse`).
- `zigbase.events` — all event/handler types (`events.AuthEvent`, `events.FileEvent`,
  `events.LifecycleEvent`, `events.JobEvent`, ...).
- `zigbase.schedule` — `schedule.Schedule`, `schedule.Interval`, `schedule.Reactive`.
- `zigbase.RecordEvent`, `zigbase.ErrorEvent`, `zigbase.JobEvent` — re-exported directly
  for convenience (the same types as `zigbase.events.*`); they are the second parameter of
  hook / job handlers.
- `zigbase.Req`, `zigbase.RouteError` — the typed-route handler input wrapper and error set.
- `zigbase.Tx` — the transaction scope passed to a `ctx.tx(T, fn(*Tx) ...)` callback
  (`t.records()`, `t.arena()`).
- `zigbase.Migration` — the `.migrations` slice element type; `zigbase.Db` — the writer
  connection passed to a migration's `.up`.
- `zigbase.StaticFile` — the embedded manifest entry type (path, bytes, etag); used by
  `.static_files = .{ .embedded = ... }`.
- `zigbase.Storage` / `zigbase.Mailer` / `zigbase.Email` — the storage & mailer plugin
  vtable types; `zigbase.DefaultStoragePlugin` / `zigbase.DefaultMailerPlugin` — the
  built-in defaults; `zigbase.LocalStorage`, `zigbase.LogMailer`, `zigbase.SmtpMailer`,
  `zigbase.CommandMailer`, `zigbase.SmtpTls` — the concrete backends.
- `zigbase.MailMessage` — the `{ to, subject, text?, html?, reply_to? }` message type taken
  by [`ctx.mail().send` / `.enqueue`](#ctxmail--send-application-mail).
- `zigbase.QueueDef` / `zigbase.WorkerDef` / `zigbase.RetryPolicy` / `zigbase.Backend` /
  `zigbase.Priority` / `zigbase.Backoff` / `zigbase.QueueRegistry` — the background-jobs
  config types named when declaring `.queues` / `.workers`. The compile-checked enqueue
  accessor (`App.enqueue(ctx, .queue, .kind, payload)`) and the generated `Queue`/`Job`
  enums live on the `App(cfg)` type; the runtime escape hatch is `ctx.enqueue` /
  `ctx.enqueueByName`.
- `zigbase.AuthMethod` — the auth plugin vtable type.
- `zigbase.AuthCtx` — the per-request auth context passed to plugin phases.
- `zigbase.auth.Resolution` / `zigbase.auth.InitiateResult` — the phase return types.

## See also

- [Tutorial](./tutorial) — build an app on ZigBase, end to end.
- [Recipes](./recipes) — copy-pasteable hook / route / job patterns (computed fields, owner
  rules, path-param routes, DB access in cron).
- [Fields](./fields) — the field-type & options catalog.
- [API](./api) — the HTTP REST + WebSocket reference.
