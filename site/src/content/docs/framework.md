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
| `onAuth` | Fires after a successful login / oauth2. |
| `onFileServe` | Fires before serving a file download (may deny). |
| `onFileUpload` | Fires after a file upload. |
| `onBootstrap` | Lifecycle: after bootstrap. |
| `onBeforeServe` | Lifecycle: just before the server starts serving. |
| `onBeforeTerminate` | Lifecycle: just before shutdown. |
| `cron` | Scheduled job table. |
| `jobs` | Scheduler settings (e.g. `.pool_size`). |
| `collections` | Comptime schema: collections provisioned at startup (additive auto-migration). |
| `migrations` | Explicit migrations (the escape hatch for non-additive schema changes). |
| `static_files` | Comptime static-file mode: absent (default flag), `.disabled`, `.{ .dir = "..." }`, `.{ .embedded = ... }`. |
| `storage` | Storage plugin TYPE (defaults to local-disk storage). |
| `mailer` | Mailer plugin TYPE (defaults to log/SMTP mailer). |
| `auth_methods` | Register custom `AuthMethod` plugin TYPES (comptime, like `.storage`/`.mailer`). |
| `pools` | Footprint levers: reader pool, job pool, thread stack size, SQLite page cache. |
| `pagination` | Enable/disable offset & cursor list paging and pick the cursor token format. |
| `enable_typegen` | Enable the `typegen` CLI subcommand (default `false`). Set `true` only for client-generation builds. |

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
fn (ev: *zigbase.RecordEvent) anyerror!void
```

`zigbase.RecordEvent` fields:

- `app: *Runtime` — the runtime app context.
- `ctx` — the request context.
- `data` — the `Data` facade for DB access (see below).
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
fn slugify(ev: *zigbase.RecordEvent) anyerror!void {
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

### The `ev.data` facade

`ev.data` (a `zigbase.Data`) gives a hook curated DB access:

- `findById(collection, id) !?std.json.Value` — returns `null` for both an unknown
  collection and a missing record.
- `create(collection, value) !std.json.Value`
- `update(collection, id, value) !?std.json.Value`
- `delete(collection, id) !bool`
- `list(collection, query) !ListResult`

`create`/`update`/`delete`/`list` return `error.UnknownCollection` when the collection name
does not resolve.

> **Atomicity caveat:** a `before*` hook's `ev.data` writes are **NOT** atomic with the
> triggering write. The triggering write opens its transaction *after* the before-hook
> returns, so side-writes a hook issues via `ev.data` commit independently of (and before)
> the triggering write. See [Known limitations](./known-limitations).

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
fn (ev: *zigbase.RouteEvent) anyerror!zigbase.http.Response
```

```zig
fn ping(ev: *zigbase.RouteEvent) anyerror!zigbase.http.Response {
    _ = ev;
    return .{ .status = 200, .body = "{\"pong\":true}" };
}
```

`RouteEvent` carries `app`, `ctx` (the `http.RequestCtx`), and `rctx` — the resolved
request/auth identity (auth identity, `is_superuser`, method), built by the framework
before your handler runs. The framework **enforces `.auth` before** calling the handler.
**Built-in routes always win** over custom routes that would match the same method + path.

### DB access from a route (`ev.writer()` / `ev.reader()`)

Unlike `RecordEvent` (whose `ev.data` is already bound to the in-transaction writer), a
`RouteEvent` has no ambient connection. Use the RAII accessors to check a connection out of
the pool and hand it back — both `RouteEvent` and `JobEvent` / `LifecycleEvent` expose
them:

```zig
// writes — acquires the shared, mutex-guarded pool writer
var w = ev.writer();
defer w.deinit();                 // releases the writer back to the pool (no leak)
const created = try w.data().create("posts", value);

// reads — checks out a warm pooled read-only connection
var r = try ev.reader();
defer r.deinit();                 // returns the connection to the warm pool
const rec = try r.data().findById("posts", id);
```

`ev.writer()` returns a `WriterData` and `ev.reader()` returns `!ReaderData`; each handle's
`data()` yields a `zigbase.Data` bound to that connection (same facade as `RecordEvent.data`:
`findById` / `create` / `update` / `delete` / `list`). **Always `defer <handle>.deinit()`**
— the writer is a single shared connection, so hold it no longer than necessary.

> **Auth collections:** `data().create(collection, fields)` on an auth collection runs
> the same credential transforms as the HTTP layer (generates the per-record `tokenKey`,
> forces `verified=false`, and hashes `password` if one is supplied). A `password` is
> **optional**, so a passwordless flow can provision a credential-less account that
> `zigbase.auth.issueSession` / `mintLinkToken` can immediately operate on. Non-auth
> collections take the plain insert path. (The lower-level engine `records.create` does
> *not* provision — reach for it directly only for raw import/migration.)

### Typed routes and the generated `rpc` surface

For routes that carry a structured input or output, ZigBase supports **typed routes** declared with a `Req(Input)` / `Output` handler signature instead of the raw `RouteEvent` form. A typed route handler looks like:

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

Untyped routes (the raw `fn(*zigbase.RouteEvent) anyerror!zigbase.http.Response` form) own their full response — status, cookies, redirect, content-type — and carry no typed `Input`/`Output`, so the generator deliberately **skips** them: they do not appear in `zb.rpc.*`. Call them with your own `fetch`/HTTP client. This is what lets an untyped handler set a session cookie, return a `307` redirect, or serve a non-JSON body (e.g. `text/calendar`) that a typed `zb.rpc.*` method could not express.

See the [TypeScript SDK docs](./typescript-sdk#typed-rpc--zbrpc) and `examples/golfsim/` for the full worked example.

## 6. Auth / file / lifecycle events

One handler each, registered by the matching config key:

| Key | Signature | When |
| --- | --- | --- |
| `onAuth` | `fn (ev: *zigbase.events.AuthEvent) void` | After a successful login / oauth2. |
| `onFileServe` | `fn (ev: *zigbase.events.FileEvent) anyerror!void` | Before serving a download; **return an error to deny** (framework → `404`). |
| `onFileUpload` | `fn (ev: *zigbase.events.FileEvent) void` | After a successful upload. |
| `onBootstrap` | `fn (ev: *zigbase.events.LifecycleEvent) void` | After bootstrap. |
| `onBeforeServe` | `fn (ev: *zigbase.events.LifecycleEvent) void` | Just before serving starts. |
| `onBeforeTerminate` | `fn (ev: *zigbase.events.LifecycleEvent) void` | Just before shutdown. |

`AuthEvent` carries `app`, `ctx`, `collection`, `record: ?std.json.Value`, and `method`
(`.password` | `.oauth2` | `.magic_link` | `.otp` | `.webauthn` | `.custom`). `FileEvent` carries `app`, `ctx`, `collection`,
`record_id`, and `filename`. `LifecycleEvent` carries `app`.

### Auth methods overview

ZigBase ships with a **pluggable auth-method system** that lets every auth collection enable built-in or custom login methods via config, with no route code. The system is built around a two-phase contract:

1. **Initiate** — challenge delivery (email a link/code, return WebAuthn options, or a no-op for API-key flows).
2. **Complete** — proof verification. On success the method returns a `Resolution.record(record_id)` and the framework mints the session via the one seam (`issueSession`+`emitAuth`), firing `onAuth`. The method never mints sessions itself.

There are three tiers:

| Tier | How | When |
|---|---|---|
| Built-in | `magic_link`, `otp`, `password`, `webauthn` in `.auth.methods` | Most apps — no Zig code needed |
| Custom plugin | Register a TYPE in `.auth_methods`; reference by slug in `.auth.methods` | Non-standard verification (corp SSO, API keys, etc.) |
| Escape hatch | Custom routes + `ev.issueSession` / `zigbase.auth` API (see below) | Exotic flows where the two-phase contract doesn't fit |

**Backward compatibility:** an auth collection with no `.auth.methods` config defaults to `password` — existing deployments are unaffected.

### Enabling auth methods per collection (`.auth.methods`)

Each auth collection in `.collections` can declare a `.auth.methods` struct enabling one or more built-in methods:

| Method | Key | Options | Notes |
|---|---|---|---|
| Password | `password` | (none beyond `rate_limit`) | Built-in default when no `.methods` specified |
| Magic link | `magic_link` | `ttl_s: i64` (default 900), `auto_create: bool` (default false) | initiate emails link; complete verifies+consumes |
| OTP | `otp` | `length: u8` (default 6), `ttl_s: i64` (default 300) | initiate emails code; complete verifies code |
| WebAuthn | `webauthn` | `rp_id: []const u8`, `rp_name: []const u8`, `origin: []const u8`, `credentials_collection: []const u8`, `require_uv: bool` (default false) | all four string fields required; `require_uv` rejects assertions without user-verification (biometrics/PIN) |
| OAuth2 | (see below) | gated by `.auth.oauth2.enabled` + `.auth.oauth2.providers` | 5th built-in; uses the contract but is NOT listed in `.auth.methods` |

**Per-collection auth options** (set directly on `.auth`, independent of which methods are enabled):

- **`require_verified: bool`** (default `false`) — when `true`, any login attempt is rejected with `403` if the auth record's `verified` field is `false`. This gate applies to **all** auth methods, including WebAuthn passkeys and OAuth2 accounts created from providers that did not confirm the email address (those are created `verified=false`). Enable it only after ensuring existing users have verified accounts, or after setting up a verification flow.

Each method accepts a `rate_limit` field:
- `.default` — uses the global env-var rate-limiter (`ZIGBASE_RATE_LIMIT_MAX` / `ZIGBASE_RATE_LIMIT_WINDOW`).
- `.off` — disables rate-limiting for this method (logged at startup like a `@public` rule).
- `.{ .custom = .{ .max = 5, .window_s = 60 } }` — per-method override.

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

**The seam guarantee:** every login — including custom flows via `ev.issueSession`
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
// Prefer ev.issueSession (below) from a route — it acquires the writer for you.
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

#### `RouteEvent.issueSession` — the ergonomic route helper

From inside a `RouteEvent` handler, use `ev.issueSession` instead of calling
`zigbase.auth.issueSession` directly. It acquires and releases the DB writer for you:

```zig
// src/events.zig  (re-exported on RouteEvent)
pub fn issueSession(
    ev: *RouteEvent, collection: []const u8, record_id: []const u8,
) !Issued   // acquires+releases the writer, fires onAuth(.custom)
```

> **Warning:** `ev.issueSession` acquires the pool writer for you. If your handler already holds the writer (`var w = ev.writer()`), do NOT call `ev.issueSession` — it would deadlock on the single non-reentrant writer. Instead call `zigbase.auth.issueSession(ev.ctx, w.conn, collection, record_id)` with the connection you already hold.

Typical usage in a confirm handler that does NOT separately hold the writer:

```zig
fn myConfirm(ev: *zigbase.RouteEvent) anyerror!zigbase.http.Response {
    // ... verify your token, resolve the record id ...
    const issued = try ev.issueSession("members", record_id);
    return .{ .status = 200, .body = "{\"ok\":true}", .cookies = &issued.cookies };
}
```

When your handler already holds the writer (e.g. for `verifyLinkToken` and `consumeLinkToken`), reuse it:

```zig
fn myConfirm(ev: *zigbase.RouteEvent) anyerror!zigbase.http.Response {
    var w = ev.writer();
    defer w.deinit();
    // ... verifyLinkToken, consumeLinkToken using w.conn ...
    // Use zigbase.auth.issueSession, NOT ev.issueSession, to avoid double-acquiring the writer.
    const issued = try zigbase.auth.issueSession(ev.ctx, w.conn, "members", record_id);
    return .{ .status = 200, .body = "{\"ok\":true}", .cookies = &issued.cookies };
}
```

`issued.cookies` is a `[2]http.Cookie` containing `zb_auth` (httpOnly) and
`zb_csrf` (readable). Pass `&issued.cookies` as the `cookies` field on the
`http.Response` and the framework writes both Set-Cookie headers.

For a complete, copy-pasteable example (two-route magic-link flow with rate
limiting, enumeration safety, and single-use token replay protection) see
[Recipes → magic-link login](./recipes#recipe-magic-link-passwordless-login).

## 7. Scheduled jobs (`.cron` + `.jobs`)

```zig
.jobs = .{ .pool_size = 2 }, // worker pool size; defaults to 2 when unset
.cron = .{
    .{ .name = "heartbeat", .schedule = zigbase.schedule.Schedule{ .interval = .hourly }, .handler = heartbeat },
},
```

Each `cron` spec needs `.name`, `.schedule`, and `.handler` (missing/wrong-typed → compile
error). The three schedule modes (`zigbase.schedule.Schedule`):

```zig
.{ .cron = "0 3 * * *" }              // 5-field cron, UTC, numeric-only
.{ .interval = .hourly }              // also .daily / .weekly
.{ .interval = .{ .minutes = 15 } }   // every N minutes
.reactive                             // handler decides its own next fire
```

**Handler signatures depend on the mode.** Cron and interval jobs use:

```zig
fn (ev: *zigbase.events.JobEvent) anyerror!void
```

```zig
fn heartbeat(ev: *zigbase.events.JobEvent) anyerror!void {
    std.log.info("blog heartbeat job '{s}' ran", .{ev.name});
}
```

A `.reactive` job's handler instead **returns its next schedule**:

```zig
fn (ev: *zigbase.events.JobEvent) anyerror!zigbase.schedule.Reactive
```

It returns either `.{ .after = <Interval> }` (re-run after that interval, e.g. `.{ .after =
.{ .minutes = 5 } }` or `.{ .after = .daily }`) or `.stop` (retire the job). `JobEvent`
carries `app` and `name`, and exposes the same `ev.writer()` / `ev.reader()` DB accessors
as `RouteEvent` (see
[DB access from a route](#db-access-from-a-route-evwriter--evreader)) — use them to touch
the database from a job rather than hand-building a `Data` from the pool.

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

### Ad-hoc background work: `app.submit`

To offload one-off background work from a route or hook onto the worker pool:

```zig
try ev.app.submit("reindex", reindexTask);
// reindexTask: fn (ev: *zigbase.events.JobEvent) anyerror!void
```

`submit` returns `error.SchedulerUnavailable` if no scheduler is running (e.g.
CLI/tests/no jobs configured).

> **Caveat:** ad-hoc submitted tasks currently run on a **detached thread that is NOT
> joined at shutdown**. A task submitted near shutdown may outlive the scheduler's
> stop/deinit and must not assume `app` (or its pool/storage) outlives it indefinitely.
> Cron/interval jobs, by contrast, use the bounded, cleanly-joined worker pool.

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
  filter-expression string).

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
.indexes = &.{
    .{ .name = "idx_posts_status", .fields = &.{"status"} },
    .{ .name = "idx_posts_slug",   .fields = &.{"slug"}, .unique = true },
    // case-insensitive: emits ("email" COLLATE NOCASE)
    .{ .name = "idx_users_email",  .fields = &.{"email"}, .unique = true, .collation = .nocase },
    // partial / conditional-unique: emits ... WHERE deleted_at IS NULL
    .{ .name = "idx_active_slug",  .fields = &.{"slug"}, .unique = true, .where = "deleted_at IS NULL" },
}
```

`.collation` (`.binary` default / `.nocase`) is applied to every indexed column;
`.where` is an optional partial-index predicate emitted verbatim as `WHERE <where>`.
The index `.name` and `.fields` are validated as identifiers; the `.where` predicate
is raw SQL authored in the schema.

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
// .up signature: fn (alloc: std.mem.Allocator, io: std.Io, w: *zigbase.Db) anyerror!void
//   (zigbase.Db is the writer connection; it exposes exec/prepare/begin/commit/rollback.)
fn renameTitle(alloc: std.mem.Allocator, io: std.Io, w: *zigbase.Db) anyerror!void {
    _ = alloc; _ = io;
    try w.exec("ALTER TABLE \"posts\" RENAME COLUMN \"headline\" TO \"title\";");
}
```

Each migration has an `.id` (used for the once-only record) and an `.up` function `fn
(alloc: std.mem.Allocator, io: std.Io, w: *zigbase.Db) anyerror!void` run inside a
transaction (rolled back on error). Use migrations for renames, drops, type changes, and
data backfills.

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

## Exported names reference

The public surface (from `src/root.zig`):

- `zigbase.App` — the comptime application builder.
- `zigbase.Runtime` — the runtime app context type (the `*App` you receive on events).
- `zigbase.Config`, `zigbase.Server`.
- `zigbase.http` — HTTP types (`http.Response`, `http.Method`, ...).
- `zigbase.Data` — the DB facade.
- `zigbase.events` — all event/handler types (`events.AuthEvent`, `events.FileEvent`,
  `events.LifecycleEvent`, `events.JobEvent`, ...).
- `zigbase.schedule` — `schedule.Schedule`, `schedule.Interval`, `schedule.Reactive`.
- `zigbase.RecordEvent`, `zigbase.ErrorEvent`, `zigbase.RouteEvent` — re-exported directly
  for convenience.
- `zigbase.Migration` — the `.migrations` slice element type; `zigbase.Db` — the writer
  connection passed to a migration's `.up`.
- `zigbase.StaticFile` — the embedded manifest entry type (path, bytes, etag); used by
  `.static_files = .{ .embedded = ... }`.
- `zigbase.Storage` / `zigbase.Mailer` / `zigbase.Email` — the storage & mailer plugin
  vtable types; `zigbase.DefaultStoragePlugin` / `zigbase.DefaultMailerPlugin` — the
  built-in defaults; `zigbase.LocalStorage`, `zigbase.LogMailer`, `zigbase.SmtpMailer`,
  `zigbase.CommandMailer`, `zigbase.SmtpTls` — the concrete backends.
- `zigbase.AuthMethod` — the auth plugin vtable type.
- `zigbase.AuthCtx` — the per-request auth context passed to plugin phases.
- `zigbase.auth.Resolution` / `zigbase.auth.InitiateResult` — the phase return types.

## See also

- [Tutorial](./tutorial) — build an app on ZigBase, end to end.
- [Recipes](./recipes) — copy-pasteable hook / route / job patterns (computed fields, owner
  rules, path-param routes, DB access in cron).
- [Fields](./fields) — the field-type & options catalog.
- [API](./api) — the HTTP REST + WebSocket reference.
