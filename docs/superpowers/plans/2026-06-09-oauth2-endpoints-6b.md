# OAuth2 Endpoints & Wiring (Plan 6b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete ZigBase OAuth2 — the client-driven (PKCE) endpoints (`oauth2-providers`, `auth-with-oauth2`, unlink), the real `std.http.Client` transport, the create/link/login decision tree, `_externalAuths` cleanup on auth-record delete, and encrypt-on-input/https-validation for provider config — then a holistic security review and merge of SP6 (6a+6b) to `main`.

**Architecture:** `src/api/oauth.zig` holds the endpoints and the decision tree, reusing the shared session issuance from `api/auth.zig` and the 6a foundation (`oauth/secrets.zig`, `oauth/providers.zig`, `oauth/client.zig`, `_externalAuths`, per-collection `oauth2` options). The core handler is dependency-injected with a `Transport` so the whole flow is unit-tested with a stub; the production handler wires a real `std.http.Client`-backed transport. Account linking is explicit-only.

**Tech Stack:** Zig 0.16.0 (`mise exec zig@0.16.0 -- zig <args>` from repo root; bare `zig` is 0.15.2). `std.http.Client` + `std.crypto.tls` for outbound HTTPS. Vendored SQLite. Builds on Plan 6a (branch `oauth2`).

**Build/test command:** `mise exec zig@0.16.0 -- zig build test --summary all`

**Branch:** Continue on `oauth2` (created in 6a). SP6 merges as a unit to `main` at the end of this plan (Task 7), after the holistic review.

**Spec:** `docs/superpowers/specs/2026-06-09-oauth2-design.md`. **Prereq:** Plan 6a complete (it is — 157 tests green on `oauth2`).

---

## Verified facts (Zig 0.16.0 + current code — do not re-derive)

- **`std.http.Client.fetch`** (compiles; verified):
  ```zig
  var client = std.http.Client{ .allocator = alloc, .io = io };
  defer client.deinit();
  var aw = std.Io.Writer.Allocating.init(alloc);
  const extra = [_]std.http.Header{ .{ .name = "accept", .value = "application/json" } };
  const res = try client.fetch(.{
      .location = .{ .url = url },           // url: []const u8
      .method = if (body != null) .POST else .GET,
      .payload = body,                       // ?[]const u8
      .extra_headers = &extra,               // []const std.http.Header
      .response_writer = &aw.writer,
  });
  const status: u16 = @intFromEnum(res.status); // res.status: std.http.Status
  const resp_body: []u8 = aw.written();
  ```
  `std.http.Header = struct { name: []const u8, value: []const u8 }`. The client auto-loads the system CA bundle for HTTPS on Linux. If a TLS/CA error appears in the live smoke (Task 7), the fix is to load the bundle explicitly (`client.ca_bundle` / `try client.initDefaultProxies(...)`) — handle only if the smoke surfaces it.
- **6a foundation (branch `oauth2`):**
  - `src/oauth/secrets.zig`: `encryptSecret(io, alloc, app_secret, plaintext) ![]u8`, `decryptSecret(alloc, app_secret, blob) SecretError![]u8` (`SecretError=error{BadSecret}||Allocator.Error`), `isEncrypted(blob) bool`.
  - `src/oauth/providers.zig`: `Provider{ name, authURL, tokenURL, userinfoURL, scopes, mapping }`, `ProviderMapping{ id, email?, emailVerified?, name?, avatar? }`, `Identity{ providerUserId, email?, emailVerified, name?, avatarUrl? }`, `lookup(name) ?Provider`, `extractIdentity(alloc, provider, json) ExtractError!Identity`.
  - `src/oauth/client.zig`: `Method{GET,POST}`, `Header{name,value}`, `Response{status:u16, body:[]const u8}`, `TransportError`, `Transport{ ctx:*anyopaque, call:*const fn(...)TransportError!Response }`, `ClientError`, `exchangeCode(transport, alloc, provider, client_id, client_secret, code, code_verifier, redirect_uri) ClientError![]const u8`, `fetchIdentity(transport, alloc, provider, access_token) ClientError!providers.Identity`.
  - `src/schema.zig`: `OAuth2Provider{ name, clientId, clientSecret, enabled, redirectUrls, authURL?, tokenURL?, userinfoURL?, scopes? }`, `OAuth2Options{ enabled, providers }`, `AuthOptions.oauth2`.
  - `_externalAuths(id, collectionRef, recordRef, provider, providerId, created, updated)` with unique `(provider,providerId)` and `(collectionRef,recordRef,provider)`.
- **`src/api/auth.zig`** (private today — Task 1 makes some `pub`): `nowUnix(conn) DbError!i64`, `tokenKeyFor(alloc, conn, table, rid) !?[]const u8`, `Issued{ token:[]const u8, cookies:[2]http.Cookie }`, `issue(ctx, conn, collection, rid, token_key) !Issued`. Also `auth.authenticate(io, alloc, app, ctx:*const http.RequestCtx, conn) !?Authed` (in `src/auth.zig`; `Authed{ record:json.Value, collection:[]const u8, is_superuser:bool }`).
- **`src/records.zig`:** `create(alloc, io, w, col, data) RecordError!json.Value`, `get(alloc, conn, col, id) RecordError!?json.Value` (strips hidden), `delete(alloc, w, col, id) RecordError!bool`.
- **`src/api/collections.zig`** `create`/`update` handlers parse via `schema.parseCollectionInput`, then `collections.create`/`update`, then `schema.collectionToJson`. They already gate on `requireSuperuser`.
- **`src/api/records.zig`** `delete` handler: rule check → `records.delete(...)` → 204.
- **id:** `@import("id.zig").generate(io, buf)` fills base36; `collectionId(io) [15]u8`.
- **Routing:** `server.zig` `routes` array; pattern segments literal except `:param`. Handlers `*const fn(*http.RequestCtx) anyerror!http.Response`.

---

## File Structure

- **Modify** `src/api/auth.zig` — make `issue`, `Issued`, `tokenKeyFor`, `nowUnix` `pub` (no behavior change).
- **Modify** `src/oauth/client.zig` — add `httpTransport(io, alloc) Transport` (production transport over `std.http.Client`).
- **Create** `src/api/oauth.zig` — `resolveProvider`, https validation, `oauth2Providers` (GET), `authWithOAuth2Impl`/`authWithOAuth2` (decision tree), `unlinkProvider` (DELETE), `_externalAuths` helpers.
- **Modify** `src/api/records.zig` — delete `_externalAuths` rows when an auth-collection record is deleted.
- **Modify** `src/api/collections.zig` — encrypt plaintext `clientSecret` on save, https-validate provider endpoints, preserve secret on empty-update.
- **Modify** `src/server.zig` — register the OAuth2 routes.
- **Modify** `src/main.zig` — add `_ = @import("api/oauth.zig");` to the test root.

---

### Task 1: Expose shared session issuance (`api/auth.zig`)

**Files:** Modify `src/api/auth.zig`.

- [ ] **Step 1: Make the helpers `pub`** — change four declarations (no body changes):
  - `fn nowUnix(` → `pub fn nowUnix(`
  - `fn tokenKeyFor(` → `pub fn tokenKeyFor(`
  - `const Issued = struct` → `pub const Issued = struct`
  - `fn issue(` → `pub fn issue(`

- [ ] **Step 2: Run the suite**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS (no behavior change; 157 tests still green).

- [ ] **Step 3: Commit**

```bash
git add src/api/auth.zig
git commit -m "refactor(auth): expose issue/tokenKeyFor/nowUnix for reuse"
```

---

### Task 2: Production HTTP transport (`oauth/client.zig`)

**Files:** Modify `src/oauth/client.zig`.

The production `Transport` wraps `std.http.Client`. It can't be unit-tested without a network; it's covered by the live smoke in Task 7. Add a compile-checked implementation plus a small structural test.

- [ ] **Step 1: Add the production transport** — append to `src/oauth/client.zig` (after `fetchIdentity`, before the tests):

```zig
const HttpCtx = struct { io: std.Io, alloc: std.mem.Allocator };

fn httpCall(ctx: *anyopaque, alloc: std.mem.Allocator, method: Method, url: []const u8, headers: []const Header, body: ?[]const u8) TransportError!Response {
    const hc: *HttpCtx = @ptrCast(@alignCast(ctx));
    var client = std.http.Client{ .allocator = alloc, .io = hc.io };
    defer client.deinit();

    // Translate our headers into std.http.Header.
    const extra = alloc.alloc(std.http.Header, headers.len) catch return error.TransportFailed;
    for (headers, 0..) |h, i| extra[i] = .{ .name = h.name, .value = h.value };

    var aw = std.Io.Writer.Allocating.init(alloc);
    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = if (method == .POST) .POST else .GET,
        .payload = body,
        .extra_headers = extra,
        .response_writer = &aw.writer,
    }) catch return error.TransportFailed;

    return .{ .status = @intFromEnum(res.status), .body = aw.written() };
}

/// A production transport backed by std.http.Client (TLS via std.crypto.tls). `hc` must outlive use.
pub fn httpTransport(hc: *HttpCtx) Transport {
    return .{ .ctx = hc, .call = httpCall };
}

/// Allocate an HttpCtx bound to (io, alloc) for httpTransport. Caller owns it (arena-friendly).
pub fn httpContext(alloc: std.mem.Allocator, io: std.Io) !*HttpCtx {
    const hc = try alloc.create(HttpCtx);
    hc.* = .{ .io = io, .alloc = alloc };
    return hc;
}
```

- [ ] **Step 2: Add a structural test** (append to the `src/oauth/client.zig` tests)

```zig
test "httpTransport builds a Transport bound to its context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hc = try httpContext(a, std.testing.io);
    const t = httpTransport(hc);
    try std.testing.expect(t.ctx == @as(*anyopaque, @ptrCast(hc)));
    // We do NOT call out to the network in unit tests; the real path is exercised by the Task 7 smoke.
}
```

- [ ] **Step 3: Run the suite**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/oauth/client.zig
git commit -m "feat(oauth): production std.http.Client transport"
```

---

### Task 3: Provider resolution + `GET oauth2-providers` (`api/oauth.zig`)

**Files:** Create `src/api/oauth.zig`; Modify `src/main.zig` (test root).

- [ ] **Step 1: Create `src/api/oauth.zig` with imports, `resolveProvider`, https check, and `oauth2Providers`, plus the tests for this task** (the decision-tree handler is Task 4 — leave a stub-free file that compiles with just these):

```zig
const std = @import("std");
const http = @import("../http.zig");
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const collections = @import("../collections.zig");
const providers = @import("../oauth/providers.zig");
const ApiError = @import("error.zig").ApiError;

/// Build the effective provider endpoints for a configured provider:
/// presets supply endpoints (optionally overridden); generic providers must supply all three.
/// Returns null if a generic provider is missing an endpoint, or any effective URL is not https.
pub fn resolveProvider(cfg: schema.OAuth2Provider) ?providers.Provider {
    var p: providers.Provider = undefined;
    if (providers.lookup(cfg.name)) |preset| {
        p = preset;
        if (cfg.authURL) |u| p.authURL = u;
        if (cfg.tokenURL) |u| p.tokenURL = u;
        if (cfg.userinfoURL) |u| p.userinfoURL = u;
        if (cfg.scopes) |s| p.scopes = s;
    } else {
        const au = cfg.authURL orelse return null;
        const tu = cfg.tokenURL orelse return null;
        const uu = cfg.userinfoURL orelse return null;
        p = .{
            .name = cfg.name, .authURL = au, .tokenURL = tu, .userinfoURL = uu,
            .scopes = cfg.scopes orelse &.{ "openid", "email", "profile" },
            // generic providers are assumed OIDC-shaped (standard claims).
            .mapping = .{ .id = "sub", .email = "email", .emailVerified = "email_verified", .name = "name", .avatar = "picture" },
        };
    }
    if (!isHttps(p.authURL) or !isHttps(p.tokenURL) or !isHttps(p.userinfoURL)) return null;
    return p;
}

fn isHttps(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://");
}

/// Find an enabled provider config by name in a collection's oauth2 options.
fn findProviderConfig(col: schema.Collection, name: []const u8) ?schema.OAuth2Provider {
    if (!col.options.auth.oauth2.enabled) return null;
    for (col.options.auth.oauth2.providers) |p| {
        if (p.enabled and std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

fn redirectAllowed(cfg: schema.OAuth2Provider, redirect_url: []const u8) bool {
    for (cfg.redirectUrls) |u| if (std.mem.eql(u8, u, redirect_url)) return true;
    return false;
}

/// GET /api/collections/:col/oauth2-providers — public redirect-building info (no secret).
pub fn oauth2Providers(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col_name = ctx.param("col") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const col = (try collections.get(ctx.allocator, w, col_name)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    if (col.type != .auth or !col.options.auth.oauth2.enabled) return ApiError.notFound().toResponse(ctx.allocator);

    var arr = std.json.Array.init(ctx.allocator);
    for (col.options.auth.oauth2.providers) |cfg| {
        if (!cfg.enabled) continue;
        const prov = resolveProvider(cfg) orelse continue;
        var o: std.json.ObjectMap = .empty;
        try o.put(ctx.allocator, "name", .{ .string = cfg.name });
        try o.put(ctx.allocator, "authURL", .{ .string = prov.authURL });
        try o.put(ctx.allocator, "clientId", .{ .string = cfg.clientId });
        var scopes = std.json.Array.init(ctx.allocator);
        for (prov.scopes) |s| try scopes.append(.{ .string = s });
        try o.put(ctx.allocator, "scopes", .{ .array = scopes });
        try arr.append(.{ .object = o });
    }
    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator, "providers", .{ .array = arr });
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .object = root }, .{}) };
}
```

Register the module in `src/main.zig` test root: add `_ = @import("api/oauth.zig");`.

- [ ] **Step 2: Append the Task-3 tests to `src/api/oauth.zig`**

```zig
const app_mod = @import("../app.zig");
const migrations = @import("../migrations.zig");

test "resolveProvider: preset, generic, and https rejection" {
    // preset
    const g = resolveProvider(.{ .name = "google", .clientId = "c", .clientSecret = "" }).?;
    try std.testing.expectEqualStrings("https://oauth2.googleapis.com/token", g.tokenURL);
    // generic with all endpoints
    const gen = resolveProvider(.{ .name = "acme", .authURL = "https://a/auth", .tokenURL = "https://a/tok", .userinfoURL = "https://a/ui" }).?;
    try std.testing.expectEqualStrings("https://a/tok", gen.tokenURL);
    // generic missing an endpoint -> null
    try std.testing.expect(resolveProvider(.{ .name = "acme", .authURL = "https://a/auth" }) == null);
    // non-https override -> null
    try std.testing.expect(resolveProvider(.{ .name = "google", .tokenURL = "http://evil/tok" }) == null);
}

// Shared test harness for the oauth endpoints (reused by Task 4).
const TestEnv = struct {
    tmp: std.testing.TmpDir,
    pool: db.Pool,
    app: app_mod.App,

    fn init() !*TestEnv {
        const env = try std.testing.allocator.create(TestEnv);
        env.tmp = std.testing.tmpDir(.{});
        const dir = try env.tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(dir);
        const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/t.db", .{dir}, 0);
        defer std.testing.allocator.free(path);
        env.pool = try db.Pool.init(std.testing.allocator, path);
        {
            const w = env.pool.acquireWriter();
            defer env.pool.releaseWriter();
            try migrations.run(w);
        }
        env.app = .{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = &env.pool };
        return env;
    }
    fn deinit(env: *TestEnv) void {
        env.pool.deinit();
        env.tmp.cleanup();
        std.testing.allocator.destroy(env);
    }

    /// Seed an auth collection with one enabled oauth2 provider (clientSecret already encrypted).
    fn seedOAuthCollection(env: *TestEnv, a: std.mem.Allocator, name: []const u8) !void {
        const secrets = @import("../oauth/secrets.zig");
        const blob = try secrets.encryptSecret(std.testing.io, a, env.app.jwt_secret, "stub-secret");
        const provs = [_]schema.OAuth2Provider{.{
            .name = "google", .clientId = "cid", .clientSecret = blob, .enabled = true,
            .redirectUrls = &.{"https://app/cb"},
        }};
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        _ = try collections.create(a, std.testing.io, w, .{
            .id = "", .name = name, .type = .auth,
            .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
            .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "",
            .options = .{ .auth = .{ .oauth2 = .{ .enabled = true, .providers = &provs } } },
        });
    }

    fn ctx(env: *TestEnv, a: std.mem.Allocator, m: http.Method, body: []const u8, params: []const http.Param) http.RequestCtx {
        return .{ .method = m, .path = "/", .body = body, .allocator = a, .app = &env.app, .params = params };
    }
};

test "oauth2-providers lists enabled providers without secrets" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.seedOAuthCollection(a, "users");
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var c = env.ctx(a, .GET, "", &p);
    const res = try oauth2Providers(&c);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"name\":\"google\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"clientId\":\"cid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "stub-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "clientSecret") == null);
}

test "oauth2-providers 404 when oauth2 disabled" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = env.pool.acquireWriter();
    {
        defer env.pool.releaseWriter();
        _ = try collections.create(a, std.testing.io, w, .{ .id = "", .name = "plain", .type = .auth, .fields = &.{}, .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "" });
    }
    const p = [_]http.Param{.{ .key = "col", .value = "plain" }};
    var c = env.ctx(a, .GET, "", &p);
    try std.testing.expectEqual(@as(u16, 404), (try oauth2Providers(&c)).status);
}
```

- [ ] **Step 2b: Run to verify failure then implementation passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: after writing both the impl (Step 1) and tests (Step 2), PASS. (If you wrote tests first per strict TDD, they fail to compile until Step 1 code exists — that's fine; land them together in this task.)

- [ ] **Step 3: Commit**

```bash
git add src/api/oauth.zig src/main.zig
git commit -m "feat(oauth): provider resolution + oauth2-providers endpoint"
```

---

### Task 4: `auth-with-oauth2` decision tree (`api/oauth.zig`)

**Files:** Modify `src/api/oauth.zig`.

The handler is split into `authWithOAuth2Impl(ctx, transport)` (testable with a stub) and `authWithOAuth2(ctx)` (wires the real transport). Linking is explicit-only.

- [ ] **Step 1: Add imports + helpers + the decision tree** — add these imports at the top of `src/api/oauth.zig` (alongside the existing ones): 

```zig
const records = @import("../records.zig");
const crypto = @import("../crypto.zig");
const auth = @import("../auth.zig");
const auth_api = @import("auth.zig");
const oauth_client = @import("../oauth/client.zig");
const secrets = @import("../oauth/secrets.zig");
const id = @import("../id.zig");
```

Then add the link helpers and the handler:

```zig
const Link = struct { collectionRef: []const u8, recordRef: []const u8 };

fn findLink(alloc: std.mem.Allocator, conn: *db.Db, provider: []const u8, provider_id: []const u8) !?Link {
    var st = try conn.prepare("SELECT \"collectionRef\",\"recordRef\" FROM \"_externalAuths\" WHERE \"provider\"=?1 AND \"providerId\"=?2;");
    defer st.finalize();
    try st.bindText(1, provider);
    try st.bindText(2, provider_id);
    if (!try st.step()) return null;
    return .{ .collectionRef = try alloc.dupe(u8, st.columnText(0)), .recordRef = try alloc.dupe(u8, st.columnText(1)) };
}

fn insertLink(io_unused: std.Io, alloc: std.mem.Allocator, conn: *db.Db, collection_ref: []const u8, record_ref: []const u8, provider: []const u8, provider_id: []const u8) !void {
    var rid = id.collectionId(io_unused);
    var st = try conn.prepare(
        \\INSERT INTO "_externalAuths" ("id","collectionRef","recordRef","provider","providerId","created","updated")
        \\ VALUES (?1,?2,?3,?4,?5,datetime('now'),datetime('now'));
    );
    defer st.finalize();
    try st.bindText(1, &rid);
    try st.bindText(2, collection_ref);
    try st.bindText(3, record_ref);
    try st.bindText(4, provider);
    try st.bindText(5, provider_id);
    _ = try st.step();
}

fn parseBody(ctx: *http.RequestCtx) ?std.json.Value {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.body, .{}) catch return null;
    if (parsed.value != .object) return null;
    return parsed.value;
}
fn strField(obj: std.json.Value, key: []const u8) ?[]const u8 {
    const v = obj.object.get(key) orelse return null;
    return switch (v) { .string => |s| s, else => null };
}

fn respondSession(ctx: *http.RequestCtx, conn: *db.Db, col: schema.Collection, rid: []const u8, is_new: bool) !http.Response {
    const tk = (try auth_api.tokenKeyFor(ctx.allocator, conn, col.name, rid)) orelse return ApiError.internal().toResponse(ctx.allocator);
    const issued = try auth_api.issue(ctx, conn, col.name, rid, tk);
    const rec = (try records.get(ctx.allocator, conn, col, rid)) orelse return ApiError.internal().toResponse(ctx.allocator);
    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator, "token", .{ .string = issued.token });
    try root.put(ctx.allocator, "record", rec);
    var meta: std.json.ObjectMap = .empty;
    try meta.put(ctx.allocator, "isNew", .{ .bool = is_new });
    try root.put(ctx.allocator, "meta", .{ .object = meta });
    const cookies = try ctx.allocator.dupe(http.Cookie, &issued.cookies);
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .object = root }, .{}), .cookies = cookies };
}

/// Create a new password-less auth record from a provider identity. Returns its id, or an error.
fn createOAuthRecord(ctx: *http.RequestCtx, conn: *db.Db, col: schema.Collection, identity: providers.Identity) ![]const u8 {
    const app = ctx.app.?;
    const tk = try crypto.genToken(app.io, ctx.allocator, 32);
    var data: std.json.ObjectMap = .empty;
    if (identity.email) |e| try data.put(ctx.allocator, "email", .{ .string = e });
    if (identity.name) |n| try data.put(ctx.allocator, "username", .{ .string = n });
    try data.put(ctx.allocator, "passwordHash", .{ .string = "" });
    try data.put(ctx.allocator, "tokenKey", .{ .string = tk });
    try data.put(ctx.allocator, "verified", .{ .bool = identity.emailVerified });
    const rec = try records.create(ctx.allocator, app.io, conn, col, .{ .object = data });
    return rec.object.get("id").?.string;
}

/// Testable core. `transport` performs the provider HTTP calls.
pub fn authWithOAuth2Impl(ctx: *http.RequestCtx, transport: oauth_client.Transport) anyerror!http.Response {
    const app = ctx.app.?;
    const body = parseBody(ctx) orelse return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator);
    const provider_name = strField(body, "provider") orelse return ApiError.badRequest("provider is required.").toResponse(ctx.allocator);
    const code = strField(body, "code") orelse return ApiError.badRequest("code is required.").toResponse(ctx.allocator);
    const verifier = strField(body, "codeVerifier") orelse return ApiError.badRequest("codeVerifier is required.").toResponse(ctx.allocator);
    const redirect_url = strField(body, "redirectUrl") orelse return ApiError.badRequest("redirectUrl is required.").toResponse(ctx.allocator);

    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col_name = ctx.param("col") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const col = (try collections.get(ctx.allocator, w, col_name)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    if (col.type != .auth) return ApiError.notFound().toResponse(ctx.allocator);

    const cfg = findProviderConfig(col, provider_name) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const provider = resolveProvider(cfg) orelse return ApiError.badRequest("Provider misconfigured.").toResponse(ctx.allocator);
    if (!redirectAllowed(cfg, redirect_url)) return ApiError.badRequest("redirectUrl not allowed.").toResponse(ctx.allocator);

    const secret = secrets.decryptSecret(ctx.allocator, app.jwt_secret, cfg.clientSecret) catch
        return ApiError.internal().toResponse(ctx.allocator);

    const access_token = oauth_client.exchangeCode(transport, ctx.allocator, provider, cfg.clientId, secret, code, verifier, redirect_url) catch
        return ApiError.badRequest("OAuth exchange failed.").toResponse(ctx.allocator);
    const identity = oauth_client.fetchIdentity(transport, ctx.allocator, provider, access_token) catch
        return ApiError.badRequest("OAuth identity fetch failed.").toResponse(ctx.allocator);

    // Who, if anyone, is the request already authenticated as (in this collection)?
    const authed = (auth.authenticate(app.io, ctx.allocator, app, ctx, w) catch null);
    const authed_rid: ?[]const u8 = if (authed) |x|
        (if (std.mem.eql(u8, x.collection, col.name)) x.record.object.get("id").?.string else null)
    else
        null;

    if (try findLink(ctx.allocator, w, provider_name, identity.providerUserId)) |link| {
        // Existing link.
        if (authed_rid) |arid| {
            if (!std.mem.eql(u8, arid, link.recordRef))
                return (ApiError{ .status = 409, .message = "Provider already linked to another account." }).toResponse(ctx.allocator);
        }
        return respondSession(ctx, w, col, link.recordRef, false);
    }

    // No link yet.
    if (authed_rid) |arid| {
        // Explicit link to the already-authenticated record.
        insertLink(app.io, ctx.allocator, w, col.name, arid, provider_name, identity.providerUserId) catch
            return (ApiError{ .status = 409, .message = "Provider already linked." }).toResponse(ctx.allocator);
        return respondSession(ctx, w, col, arid, false);
    }

    // Anonymous: create a new record, then link.
    const new_rid = createOAuthRecord(ctx, w, col, identity) catch
        return (ApiError{ .status = 409, .message = "Email already registered; sign in and link instead." }).toResponse(ctx.allocator);
    insertLink(app.io, ctx.allocator, w, col.name, new_rid, provider_name, identity.providerUserId) catch
        return (ApiError{ .status = 409, .message = "Provider already linked." }).toResponse(ctx.allocator);
    return respondSession(ctx, w, col, new_rid, true);
}

/// POST /api/collections/:col/auth-with-oauth2 — production handler (real HTTP transport).
pub fn authWithOAuth2(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const hc = try oauth_client.httpContext(ctx.allocator, app.io);
    return authWithOAuth2Impl(ctx, oauth_client.httpTransport(hc));
}
```

- [ ] **Step 2: Add the decision-tree tests** (append to `src/api/oauth.zig` tests). These reuse `TestEnv` from Task 3 and inject a stub transport.

```zig
// Stub transport returning a fixed provider identity.
const OAuthStub = struct {
    pid: []const u8 = "P1",
    email: []const u8 = "u@x.io",
    verified: bool = true,
    fn call(c: *anyopaque, alloc: std.mem.Allocator, m: oauth_client.Method, url: []const u8, h: []const oauth_client.Header, b: ?[]const u8) oauth_client.TransportError!oauth_client.Response {
        _ = m; _ = h; _ = b;
        const self: *OAuthStub = @ptrCast(@alignCast(c));
        if (std.mem.indexOf(u8, url, "token") != null)
            return .{ .status = 200, .body = try alloc.dupe(u8, "{\"access_token\":\"AT\"}") };
        const j = try std.fmt.allocPrint(alloc, "{{\"sub\":\"{s}\",\"email\":\"{s}\",\"email_verified\":{s}}}", .{ self.pid, self.email, if (self.verified) "true" else "false" });
        return .{ .status = 200, .body = j };
    }
    fn transport(self: *OAuthStub) oauth_client.Transport { return .{ .ctx = self, .call = call }; }
};

fn oauthBody(a: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"provider\":\"google\",\"code\":\"c\",\"codeVerifier\":\"v\",\"redirectUrl\":\"https://app/cb\"}}", .{});
}

test "anonymous oauth login creates a verified, password-less record (isNew)" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.seedOAuthCollection(a, "users");
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var stub = OAuthStub{};
    var c = env.ctx(a, .POST, try oauthBody(a), &p);
    const res = try authWithOAuth2Impl(&c, stub.transport());
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"isNew\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"token\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "passwordHash") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "tokenKey") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"verified\":true") != null);
}

test "second oauth login with same identity logs in the same record (not new)" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.seedOAuthCollection(a, "users");
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var stub = OAuthStub{};
    var c1 = env.ctx(a, .POST, try oauthBody(a), &p);
    const r1 = try authWithOAuth2Impl(&c1, stub.transport());
    const id1 = (try std.json.parseFromSlice(std.json.Value, a, r1.body, .{})).value.object.get("record").?.object.get("id").?.string;
    var c2 = env.ctx(a, .POST, try oauthBody(a), &p);
    const r2 = try authWithOAuth2Impl(&c2, stub.transport());
    try std.testing.expect(std.mem.indexOf(u8, r2.body, "\"isNew\":false") != null);
    const id2 = (try std.json.parseFromSlice(std.json.Value, a, r2.body, .{})).value.object.get("record").?.object.get("id").?.string;
    try std.testing.expectEqualStrings(id1, id2);
}

test "provider not enabled -> 404; redirect not allowlisted -> 400" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.seedOAuthCollection(a, "users");
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var stub = OAuthStub{};
    // unknown provider
    var cbad = env.ctx(a, .POST, "{\"provider\":\"github\",\"code\":\"c\",\"codeVerifier\":\"v\",\"redirectUrl\":\"https://app/cb\"}", &p);
    try std.testing.expectEqual(@as(u16, 404), (try authWithOAuth2Impl(&cbad, stub.transport())).status);
    // bad redirect
    var crd = env.ctx(a, .POST, "{\"provider\":\"google\",\"code\":\"c\",\"codeVerifier\":\"v\",\"redirectUrl\":\"https://evil/cb\"}", &p);
    try std.testing.expectEqual(@as(u16, 400), (try authWithOAuth2Impl(&crd, stub.transport())).status);
}

test "anonymous oauth create colliding email -> 409" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.seedOAuthCollection(a, "users");
    // pre-create a record with the same email the stub will report
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try w.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('pre','','','u@x.io','tk',1);");
    }
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var stub = OAuthStub{ .pid = "P9", .email = "u@x.io" }; // new provider id, existing email
    var c = env.ctx(a, .POST, try oauthBody(a), &p);
    try std.testing.expectEqual(@as(u16, 409), (try authWithOAuth2Impl(&c, stub.transport())).status);
}
```

- [ ] **Step 3: Run the suite**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS (all new decision-tree tests + everything prior).

- [ ] **Step 4: Commit**

```bash
git add src/api/oauth.zig
git commit -m "feat(oauth): auth-with-oauth2 decision tree (create/link/login)"
```

---

### Task 5: Unlink endpoint + `_externalAuths` cleanup on delete

**Files:** Modify `src/api/oauth.zig`, `src/api/records.zig`.

- [ ] **Step 1: Add `_externalAuths` cleanup to the record delete handler** (`src/api/records.zig`). After a successful `records.delete` of an auth-collection record, delete its external-auth links. Find the `delete` handler's success path (`if (!try records.delete(...)) return ...notFound; return .{ .status = 204, ... };`) and insert before the `204` return:

```zig
    if (col.type == .auth) {
        var st = try w.prepare("DELETE FROM \"_externalAuths\" WHERE \"collectionRef\"=?1 AND \"recordRef\"=?2;");
        defer st.finalize();
        try st.bindText(1, col.name);
        try st.bindText(2, rid);
        _ = try st.step();
    }
```

(`col`, `rid`, `w` are all in scope in the delete handler. The SQL is a constant string literal — it coerces directly to the `[:0]const u8` that `prepare` expects; `col.name`/`rid` are bound, not interpolated. Confirm the exact local names in the `delete` handler — the record id may be `rid` or `id`; use whatever is in scope.)

- [ ] **Step 2: Add the unlink handler to `src/api/oauth.zig`**

```zig
fn linkCount(alloc: std.mem.Allocator, conn: *db.Db, collection_ref: []const u8, record_ref: []const u8) !i64 {
    _ = alloc;
    var st = try conn.prepare("SELECT COUNT(*) FROM \"_externalAuths\" WHERE \"collectionRef\"=?1 AND \"recordRef\"=?2;");
    defer st.finalize();
    try st.bindText(1, collection_ref);
    try st.bindText(2, record_ref);
    _ = try st.step();
    return st.columnInt(0);
}

fn passwordIsSet(alloc: std.mem.Allocator, conn: *db.Db, table: []const u8, rid: []const u8) !bool {
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT \"passwordHash\" FROM \"{s}\" WHERE \"id\"=?1;", .{table}, 0);
    var st = try conn.prepare(sql);
    defer st.finalize();
    try st.bindText(1, rid);
    if (!try st.step()) return false;
    return st.columnText(0).len > 0;
}

/// DELETE /api/collections/:col/records/:id/external-auths/:provider — self or superuser.
pub fn unlinkProvider(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col_name = ctx.param("col") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rid = ctx.param("id") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const provider = ctx.param("provider") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const col = (try collections.get(ctx.allocator, w, col_name)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    if (col.type != .auth) return ApiError.notFound().toResponse(ctx.allocator);

    // Authorization: superuser, or authenticated as this exact record.
    const authed = (auth.authenticate(app.io, ctx.allocator, app, ctx, w) catch null) orelse
        return (ApiError{ .status = 403, .message = "Forbidden." }).toResponse(ctx.allocator);
    const is_self = std.mem.eql(u8, authed.collection, col.name) and std.mem.eql(u8, authed.record.object.get("id").?.string, rid);
    if (!authed.is_superuser and !is_self) return (ApiError{ .status = 403, .message = "Forbidden." }).toResponse(ctx.allocator);

    // Lockout guard: refuse to remove the last credential of a password-less account.
    if ((try linkCount(ctx.allocator, w, col.name, rid)) <= 1 and !(try passwordIsSet(ctx.allocator, w, col.name, rid)))
        return (ApiError{ .status = 400, .message = "Cannot remove the last credential." }).toResponse(ctx.allocator);

    var st = try w.prepare("DELETE FROM \"_externalAuths\" WHERE \"collectionRef\"=?1 AND \"recordRef\"=?2 AND \"provider\"=?3 RETURNING \"id\";");
    defer st.finalize();
    try st.bindText(1, col.name);
    try st.bindText(2, rid);
    try st.bindText(3, provider);
    if (!try st.step()) return ApiError.notFound().toResponse(ctx.allocator);
    return .{ .status = 204, .body = "" };
}
```

- [ ] **Step 3: Add tests** (append to `src/api/oauth.zig` tests). These build on `TestEnv` + link a provider, then unlink.

```zig
fn linkOne(env: *TestEnv, a: std.mem.Allocator, col: []const u8, rid: []const u8, provider: []const u8, pid: []const u8) !void {
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    try insertLink(std.testing.io, a, w, col, rid, provider, pid);
}

test "unlink refuses the last credential of a password-less account" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.seedOAuthCollection(a, "users");
    // create a password-less record + one link
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try w.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"passwordHash\",\"tokenKey\",\"verified\") VALUES ('r1','','','u@x.io','','tk',1);");
    }
    try linkOne(env, a, "users", "r1", "google", "P1");
    // authenticate as r1 (mint a bearer)
    const jwt = @import("../jwt.zig");
    const crypto2 = @import("../crypto.zig");
    const key = crypto2.deriveKey(env.app.jwt_secret, "tk");
    const token = try jwt.sign(a, .{ .id = "r1", .collection = "users", .type = .auth, .iat = 0, .exp = 9999999999 }, &key);
    const p = [_]http.Param{ .{ .key = "col", .value = "users" }, .{ .key = "id", .value = "r1" }, .{ .key = "provider", .value = "google" } };
    var c = env.ctx(a, .DELETE, "", &p);
    c.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    try std.testing.expectEqual(@as(u16, 400), (try unlinkProvider(&c)).status);
}

test "unlink succeeds when another credential remains (password set)" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.seedOAuthCollection(a, "users");
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try w.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"passwordHash\",\"tokenKey\",\"verified\") VALUES ('r2','','','u2@x.io','$argon2id$x','tk2',1);");
    }
    try linkOne(env, a, "users", "r2", "google", "P2");
    const jwt = @import("../jwt.zig");
    const crypto2 = @import("../crypto.zig");
    const key = crypto2.deriveKey(env.app.jwt_secret, "tk2");
    const token = try jwt.sign(a, .{ .id = "r2", .collection = "users", .type = .auth, .iat = 0, .exp = 9999999999 }, &key);
    const p = [_]http.Param{ .{ .key = "col", .value = "users" }, .{ .key = "id", .value = "r2" }, .{ .key = "provider", .value = "google" } };
    var c = env.ctx(a, .DELETE, "", &p);
    c.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    try std.testing.expectEqual(@as(u16, 204), (try unlinkProvider(&c)).status);
}

test "deleting an auth record removes its external-auth links" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.seedOAuthCollection(a, "users");
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try w.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('r3','','','u3@x.io','tk3',1);");
    }
    try linkOne(env, a, "users", "r3", "google", "P3");
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const col = (try collections.get(a, w, "users")).?;
        _ = try records.delete(a, w, col, "r3");
        // emulate the handler cleanup
        var st = try w.prepare("DELETE FROM \"_externalAuths\" WHERE \"collectionRef\"=?1 AND \"recordRef\"=?2;");
        defer st.finalize();
        try st.bindText(1, "users");
        try st.bindText(2, "r3");
        _ = try st.step();
        try std.testing.expectEqual(@as(i64, 0), try linkCount(a, w, "users", "r3"));
    }
}
```

(The last test emulates the handler's cleanup SQL directly; the handler wiring itself is exercised by the Task 7 live smoke. The records.zig `records` import is already present in `api/oauth.zig` from Task 4.)

- [ ] **Step 4: Run the suite**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/api/oauth.zig src/api/records.zig
git commit -m "feat(oauth): unlink endpoint + _externalAuths cleanup on record delete"
```

---

### Task 6: Encrypt-on-save + https-validate provider config (`api/collections.zig`)

**Files:** Modify `src/api/collections.zig`.

When a superuser saves a collection, any plaintext `clientSecret` must be encrypted (the app secret lives on `App`), provider endpoints must be https, and an empty `clientSecret` on update must preserve the stored blob.

- [ ] **Step 1: Add the import + a transform helper** to `src/api/collections.zig`:

```zig
const secrets = @import("../oauth/secrets.zig");
const oauth_api = @import("oauth.zig");
```

```zig
/// Encrypt any plaintext clientSecret, validate provider endpoints are https/resolvable, and
/// (on update) preserve a stored secret when the incoming one is empty. Mutates `def.options`.
/// Returns error.BadOAuthConfig if a provider can't be resolved (missing endpoint / non-https).
fn prepareOAuthConfig(ctx: *http.RequestCtx, def: *schema.Collection, existing: ?schema.Collection) !void {
    const app = ctx.app.?;
    if (def.type != .auth) return;
    const provs = def.options.auth.oauth2.providers;
    if (provs.len == 0) return;
    const out = try ctx.allocator.alloc(schema.OAuth2Provider, provs.len);
    for (provs, 0..) |p, i| {
        var np = p;
        // resolvable + https (resolveProvider enforces both)
        if (oauth_api.resolveProvider(np) == null) return error.BadOAuthConfig;
        if (np.clientSecret.len == 0) {
            // preserve a previously stored secret for this provider, if any
            if (existing) |ex| {
                for (ex.options.auth.oauth2.providers) |xp| {
                    if (std.mem.eql(u8, xp.name, np.name)) { np.clientSecret = xp.clientSecret; break; }
                }
            }
        } else if (!secrets.isEncrypted(np.clientSecret)) {
            np.clientSecret = try secrets.encryptSecret(app.io, ctx.allocator, app.jwt_secret, np.clientSecret);
        }
        out[i] = np;
    }
    def.options.auth.oauth2.providers = out;
}
```

- [ ] **Step 2: Wire it into `create`** — in `src/api/collections.zig` `create`, after `const def = ... parseCollectionInput ...` and before `collections.create`:

```zig
    var def_mut = def;
    prepareOAuthConfig(ctx, &def_mut, null) catch
        return ApiError.badRequest("Invalid OAuth2 provider config (endpoints must be https).").toResponse(ctx.allocator);
```

and change the `collections.create(ctx.allocator, app.io, w, def)` call to use `def_mut`.

- [ ] **Step 3: Wire it into `update`** — in `update`, after parsing `def` and acquiring `w`, load the existing collection and prepare:

```zig
    const existing = collections.get(ctx.allocator, w, key) catch null;
    var def_mut = def;
    prepareOAuthConfig(ctx, &def_mut, existing) catch
        return ApiError.badRequest("Invalid OAuth2 provider config (endpoints must be https).").toResponse(ctx.allocator);
```

and change the `collections.update(ctx.allocator, app.io, w, key, def)` call to use `def_mut`.

- [ ] **Step 4: Add tests** (append to `src/api/collections.zig` tests; reuse its `TestEnv`/`ctxFor`/`superuserToken`). The body sends a plaintext secret; after create, reading the persisted collection must show an encrypted (`v1:`) secret and the API response must redact it.

```zig
test "creating an oauth2 collection encrypts the clientSecret and redacts it in output" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const token = try env.superuserToken(a);
    const body =
        \\{"name":"members","type":"auth","fields":[],
        \\ "options":{"auth":{"oauth2":{"enabled":true,"providers":[
        \\   {"name":"google","clientId":"cid","clientSecret":"PLAINTEXT","enabled":true,"redirectUrls":["https://app/cb"]}
        \\ ]}}}}
    ;
    var c = ctxFor(env, a, .POST, body, &.{});
    c.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    const res = try create(&c);
    try std.testing.expectEqual(@as(u16, 201), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "PLAINTEXT") == null); // redacted in output
    // persisted secret is encrypted
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    const col = (try collections.get(a, w, "members")).?;
    const stored = col.options.auth.oauth2.providers[0].clientSecret;
    try std.testing.expect(std.mem.startsWith(u8, stored, "v1:"));
    try std.testing.expect(std.mem.indexOf(u8, stored, "PLAINTEXT") == null);
}

test "non-https generic provider endpoint is rejected at save" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const token = try env.superuserToken(a);
    const body =
        \\{"name":"m2","type":"auth","fields":[],
        \\ "options":{"auth":{"oauth2":{"enabled":true,"providers":[
        \\   {"name":"acme","clientId":"c","clientSecret":"s","redirectUrls":[],
        \\    "authURL":"http://a/auth","tokenURL":"http://a/tok","userinfoURL":"http://a/ui"}
        \\ ]}}}}
    ;
    var c = ctxFor(env, a, .POST, body, &.{});
    c.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    try std.testing.expectEqual(@as(u16, 400), (try create(&c)).status);
}
```

Note: confirm `error.BadOAuthConfig` is reachable — add it to nothing global; it's an ad-hoc error returned by `prepareOAuthConfig` and caught at the call site, so no error-set declaration is needed (Zig infers it). If `parseCollectionInput` strips `options` you don't expect, re-check Task 4 of Plan 6a (`optionsFromJson` parses `oauth2`).

- [ ] **Step 5: Run the suite**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/api/collections.zig
git commit -m "feat(oauth): encrypt clientSecret on save + https-validate provider config"
```

---

### Task 7: Routes, live smoke, holistic review, merge

**Files:** Modify `src/server.zig`.

- [ ] **Step 1: Register routes in `src/server.zig`** — add the import and routes:

```zig
const oauth_api = @import("api/oauth.zig");
```

In the `routes` array:

```zig
    .{ .method = .GET, .pattern = "/api/collections/:col/oauth2-providers", .handler = oauth_api.oauth2Providers },
    .{ .method = .POST, .pattern = "/api/collections/:col/auth-with-oauth2", .handler = oauth_api.authWithOAuth2 },
    .{ .method = .DELETE, .pattern = "/api/collections/:col/records/:id/external-auths/:provider", .handler = oauth_api.unlinkProvider },
```

- [ ] **Step 2: Build + run the suite**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS (full suite green).

- [ ] **Step 3: Live smoke (no real provider needed)** — verify routing + gating + redaction end-to-end over HTTP. Build, create a superuser, serve on a custom port.

```bash
mise exec zig@0.16.0 -- zig build
SMOKE=/home/valthon/.claude/jobs/fc85a1ad/tmp/zb_oauth_smoke
rm -rf "$SMOKE"; mkdir -p "$SMOKE"
./zig-out/bin/zigbase superuser create --email admin@x.io --password adminpassword --data-dir "$SMOKE"
ZIGBASE_DATA_DIR="$SMOKE" ZIGBASE_HTTP_PORT=8097 ./zig-out/bin/zigbase serve >"$SMOKE/server.log" 2>&1 &
SRV=$!; sleep 1.5
```
Then with curl, using the superuser bearer token (from `POST /api/collections/_superusers/auth-with-password`):
1. Create an auth collection `users` with `options.auth.oauth2.enabled=true` and a google provider (`clientId`, `clientSecret` plaintext, `redirectUrls:["https://app/cb"]`). Expect 201 and the response must NOT echo the plaintext secret.
2. `GET /api/collections/users/oauth2-providers` → 200, lists `google` with `clientId` but no `clientSecret`/secret material.
3. `POST /api/collections/users/auth-with-oauth2` with `{"provider":"google","code":"x","codeVerifier":"y","redirectUrl":"https://evil/cb"}` → 400 (redirect not allowlisted) — this exercises the handler up to the allowlist check without a real provider.
4. `GET /api/collections/users/oauth2-providers` on a non-existent/disabled collection → 404.
5. Clean up: `kill $SRV; rm -rf "$SMOKE"`.

Record the observed status codes. (A full real-provider exchange is out of scope for CI; the production transport is covered structurally + by manual provider testing.)

- [ ] **Step 4: Commit the routes**

```bash
git add src/server.zig
git commit -m "feat(oauth): register oauth2 routes; SP6 smoke"
```

- [ ] **Step 5: Holistic security review** — dispatch a review over the whole SP6 diff (`git diff main..oauth2 -- 'src/*'`). Trace, with concrete scenarios: token/secret leakage (no `clientSecret`/`passwordHash`/`tokenKey`/access-token in any response or log); SQL injection through provider/table/identity values (all bound; table names validated); SSRF via generic `tokenURL`/`userinfoURL` (https-only + superuser-only); the linking decision tree (explicit-only; cross-account 409; email-collision 409; no email auto-link); unlink authorization (self/superuser) + last-credential lockout guard; `_externalAuths` cleanup on delete; encrypt-on-save + preserve-on-empty-update; redirect allowlist enforcement; PKCE verifier forwarded; provider-token discarded. Fix any CRITICAL/IMPORTANT findings (new commits) and re-run the suite.

- [ ] **Step 6: Merge SP6 to `main`**

```bash
git checkout main
git merge --no-ff oauth2 -m "merge: SP6 OAuth2 (foundation + endpoints)

Client-driven PKCE OAuth2 for ZigBase auth collections: provider preset
registry + userinfo identity, AES-256-GCM-encrypted per-collection client
secrets, _externalAuths linking, explicit-only account linking, oauth2-providers
/ auth-with-oauth2 / unlink endpoints, real std.http.Client transport, and
holistic-review fixes.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
mise exec zig@0.16.0 -- zig build test --summary all
```
Expected: full suite green on `main`. Then update the project-status memory (SP6 complete; SP7 Realtime next).

---

## Done criteria for 6b / SP6

- Full suite green on `main` after merge.
- `oauth2-providers` (no secrets), `auth-with-oauth2` (create/link/login, explicit-only linking, 409s), and unlink (self/superuser, last-credential guard) all work; secrets encrypted at rest and never serialized; `_externalAuths` cleaned on delete; provider endpoints https-only; PKCE verifier forwarded; provider tokens discarded.
- Live smoke confirmed routing + gating + redaction.

---

## Self-Review (author)

- **Spec coverage:** `oauth2-providers` (§4.1 → Task 3); `auth-with-oauth2` decision tree incl. explicit-only linking + 409s + no-password create (§4.2, §6 → Task 4); unlink + last-credential guard + delete cleanup (§4.3, §3.1 → Task 5); production transport (§5.2 → Task 2); shared issuance reuse (§2 → Task 1); encrypt-on-save + https-validate + preserve-on-empty (§3.2, §6 → Task 6); routes + smoke + review + merge (§9 → Task 7).
- **Type consistency:** `Transport`/`Method`/`Header`/`Response`/`exchangeCode`/`fetchIdentity` (6a) consumed unchanged; `resolveProvider(schema.OAuth2Provider) ?providers.Provider` used by both the endpoint (Task 3) and config validation (Task 6); `auth_api.issue/tokenKeyFor/nowUnix` made pub in Task 1 and used in Task 4; `auth.authenticate` signature matches SP5.
- **Placeholder scan:** none — every code step has complete code. The one constant-SQL `allocPrintSentinel(..., .{}, 0)` in Task 5 Step 1 is intentional (uniform sentinel-terminated string; no interpolation).
- **Deferred/known:** real end-to-end provider exchange is manual/out-of-CI (production transport is structurally tested + smoke-routed); generic providers assume OIDC-standard userinfo claims (documented); a host-allowlist for SSRF beyond https-only is a future hardening.
