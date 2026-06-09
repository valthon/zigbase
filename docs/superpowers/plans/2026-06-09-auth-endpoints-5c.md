# Auth Endpoints & Middleware (Plan 5c) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make ZigBase auth collections usable end-to-end — issue and verify JWTs over both bearer header and httpOnly cookie (with double-submit CSRF), log users in/out/refresh, generate email-verification & password-reset tokens, force `verified=false` on signup, enforce identity uniqueness, and gate collection management behind superusers.

**Architecture:** A pure header/cookie layer is added to `RequestCtx`/`Response` (Task 1) and translated to/from zap in `server.zig`. The record handlers' `buildContext` becomes auth-aware via a new `auth.authenticate` middleware (Task 6) that finds the record from unverified claims, derives its per-record signing key (`crypto.deriveKey(jwt_secret, tokenKey)`), and verifies the JWT (Task 6 also enforces CSRF on the cookie+unsafe-method path). Auth-collection record create/update route through `auth.applyCreate`/`applyUpdate` (Task 5). Login/refresh/logout/verify/reset live in a new `api/auth.zig` (Tasks 7–8). Collection-management handlers gain a superuser gate (Task 9).

**Tech Stack:** Zig 0.16.0 (run via `mise exec zig@0.16.0 -- zig <args>` from the repo root — bare `zig` is 0.15.2). zap (facil.io) for HTTP, vendored SQLite. Existing modules: `crypto.zig` (argon2id, `deriveKey`, `genToken`), `jwt.zig` (HS256 `sign`/`verify`), `auth.zig` (`applyCreate`/`applyUpdate`), `schema.zig` (auth system fields, `CollectionOptions`), `records.zig`, `collections.zig`, `ddl.zig`, `request.zig` (`RequestContext`).

**Build/test command (run from repo root):** `mise exec zig@0.16.0 -- zig build test`

**Branch:** all work continues on `auth` (do NOT branch or merge; SP5 merges as a unit after this plan + a holistic review).

---

## File Structure

- **Modify** `src/http.zig` — add request headers (`authorization`, `cookie_header`, `csrf_token`) + accessor helpers (`bearerToken`, `cookie`) to `RequestCtx`; add `Cookie` struct + `cookies` field to `Response`.
- **Modify** `src/server.zig` — read `authorization`/`cookie`/`x-csrf-token` headers into the ctx; write `resp.cookies` out via `r.setCookie`.
- **Modify** `src/jwt.zig` — add `peekClaims` (decode payload without verifying, to locate the record).
- **Modify** `src/auth.zig` — force `verified=false` in `applyCreate`; add the `authenticate` middleware + `Authed` type + identity/record/tokenKey lookup helpers.
- **Modify** `src/ddl.zig` — add `where: ?[]const u8` to partial-index support; add `authIdentityIndexSql` for `... WHERE "<field>" != ''` partial unique indexes.
- **Modify** `src/schema.zig` — drop the column-level `UNIQUE` on the `email` auth system field (identity uniqueness now comes from partial unique indexes).
- **Modify** `src/collections.zig` — emit partial unique identity indexes on create and on rebuild.
- **Modify** `src/config.zig` — add `cookie_secure`, `auth_token_ttl_s`, `verification_ttl_s`, `password_reset_ttl_s`.
- **Modify** `src/app.zig` — carry `jwt_secret`, `cookie_secure`, and the three TTLs (all defaulted so existing test constructors still compile).
- **Modify** `src/main.zig` — populate the new `App` fields from `Config` at startup.
- **Modify** `src/api/records.zig` — make `buildContext` auth-aware; route auth-collection create/update through `auth.applyCreate`/`applyUpdate`.
- **Create** `src/api/auth.zig` — `authWithPassword`, `authRefresh`, `authLogout`, `requestVerification`, `confirmVerification`, `requestPasswordReset`, `confirmPasswordReset`; cookie issuance/clearing helpers.
- **Modify** `src/api/collections.zig` — superuser gate on list/create/get/update/delete.

---

## Conventions (read before starting)

- **`server.zig` is the ONLY module importing zap.** Handlers stay pure `(*RequestCtx) -> Response`. Cookies are expressed as the engine-local `http.Cookie` and translated in `server.zig`.
- **All SQL identifiers come from validated schema names** (`schema.isValidIdentifier`); **every value is bound**. No string interpolation of user values.
- **Header names passed to `zap.getHeader` must be lowercase** (`"authorization"`, `"cookie"`, `"x-csrf-token"`) — facil.io stores header keys lowercased.
- **Time is never read from the wall clock in pure code.** The middleware/endpoints read "now" from SQLite via `unixepoch('now')` (a helper added in Task 6) and pass it to `jwt.verify`/into claims.
- **Cookie names:** `zb_auth` (the JWT; httpOnly, Secure-gated, `SameSite=Strict`) and `zb_csrf` (the CSRF token; readable by JS, NOT httpOnly, Secure-gated, `SameSite=Strict`).

---

### Task 1: Request headers + response cookies (`http.zig`, `server.zig`)

**Files:**
- Modify: `src/http.zig`
- Modify: `src/server.zig`

- [ ] **Step 1: Write the failing tests** (append to the test block at the bottom of `src/http.zig`)

```zig
test "bearerToken extracts the token after 'Bearer '" {
    var ctx = RequestCtx{ .method = .GET, .path = "/", .allocator = std.testing.allocator, .authorization = "Bearer abc.def.ghi" };
    try std.testing.expectEqualStrings("abc.def.ghi", ctx.bearerToken().?);
    var none = RequestCtx{ .method = .GET, .path = "/", .allocator = std.testing.allocator, .authorization = "" };
    try std.testing.expect(none.bearerToken() == null);
    var basic = RequestCtx{ .method = .GET, .path = "/", .allocator = std.testing.allocator, .authorization = "Basic xyz" };
    try std.testing.expect(basic.bearerToken() == null);
}

test "cookie parses a named value out of the Cookie header" {
    var ctx = RequestCtx{ .method = .GET, .path = "/", .allocator = std.testing.allocator, .cookie_header = "a=1; zb_auth=tok123; b=2" };
    try std.testing.expectEqualStrings("tok123", ctx.cookie("zb_auth").?);
    try std.testing.expectEqualStrings("1", ctx.cookie("a").?);
    try std.testing.expect(ctx.cookie("missing") == null);
    var empty = RequestCtx{ .method = .GET, .path = "/", .allocator = std.testing.allocator, .cookie_header = "" };
    try std.testing.expect(empty.cookie("zb_auth") == null);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mise exec zig@0.16.0 -- zig build test`
Expected: compile error — `RequestCtx` has no field `authorization`/`cookie_header`, no `bearerToken`/`cookie` method.

- [ ] **Step 3: Add the fields, accessors, and `Cookie`/`Response.cookies` to `src/http.zig`**

Add three fields to `RequestCtx` (after `params`):

```zig
    /// Raw request headers (filled by server.zig; "" when absent). Names are lowercase.
    authorization: []const u8 = "",
    cookie_header: []const u8 = "",
    csrf_token: []const u8 = "", // X-CSRF-Token header value
```

Add two methods inside `RequestCtx` (after `param`):

```zig
    /// The bearer token from `Authorization: Bearer <token>`, or null.
    pub fn bearerToken(self: *const RequestCtx) ?[]const u8 {
        const prefix = "Bearer ";
        if (!std.mem.startsWith(u8, self.authorization, prefix)) return null;
        const t = self.authorization[prefix.len..];
        return if (t.len == 0) null else t;
    }

    /// The value of cookie `name` from the Cookie header, or null. Trims surrounding spaces.
    pub fn cookie(self: *const RequestCtx, name: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, self.cookie_header, ';');
        while (it.next()) |raw| {
            const pair = std.mem.trim(u8, raw, " ");
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
        }
        return null;
    }
```

Add the `Cookie` type (above `Response`) and a `cookies` field to `Response`:

```zig
pub const SameSite = enum { default, lax, strict, none };

/// A cookie the handler wants set on the response. `server.zig` translates this to zap.
pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    max_age_s: i32 = 0, // 0 = session cookie; negative clears
    http_only: bool = true,
    secure: bool = true,
    same_site: SameSite = .strict,
    path: []const u8 = "/",
};
```

In `Response`, add (after `body`):

```zig
    cookies: []const Cookie = &.{},
```

- [ ] **Step 4: Wire the headers/cookies through `src/server.zig`**

In `onRequest`, after constructing `ctx` (before `router.dispatch`), fill the header fields:

```zig
    ctx.authorization = r.getHeader("authorization") orelse "";
    ctx.cookie_header = r.getHeader("cookie") orelse "";
    ctx.csrf_token = r.getHeader("x-csrf-token") orelse "";
```

After `setZapStatus(r, resp.status);` (and before/after `setContentType` is fine), emit cookies:

```zig
    for (resp.cookies) |c| {
        r.setCookie(.{
            .name = c.name,
            .value = c.value,
            .path = c.path,
            .max_age_s = @intCast(c.max_age_s),
            .secure = c.secure,
            .http_only = c.http_only,
            .same_site = switch (c.same_site) {
                .default => .Default,
                .lax => .Lax,
                .strict => .Strict,
                .none => .None,
            },
        }) catch {};
    }
```

Note: `ctx` must be declared `var` (it already is). `zap.CookieArgs.max_age_s` is `c_int`; `@intCast` from `i32` is safe.

- [ ] **Step 5: Run the tests**

Run: `mise exec zig@0.16.0 -- zig build test`
Expected: PASS (all existing tests + the two new ones).

- [ ] **Step 6: Commit**

```bash
git add src/http.zig src/server.zig
git commit -m "feat(http): request headers + response cookies"
```

---

### Task 2: `jwt.peekClaims` + force `verified=false` on signup

**Files:**
- Modify: `src/jwt.zig`
- Modify: `src/auth.zig`

- [ ] **Step 1: Write the failing tests**

Append to `src/jwt.zig` tests:

```zig
test "peekClaims decodes the payload without checking the signature" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = crypto.deriveKey("secret", "tk1");
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 2000 };
    const token = try sign(a, claims, &key);
    // Tamper the signature: peekClaims must still return the claims.
    const buf = try a.dupe(u8, token);
    buf[buf.len - 1] = if (buf[buf.len - 1] == 'A') 'B' else 'A';
    const peeked = try peekClaims(a, buf);
    try std.testing.expectEqualStrings("u1", peeked.id);
    try std.testing.expectEqualStrings("users", peeked.collection);
    try std.testing.expectError(error.Malformed, peekClaims(a, "nope"));
}
```

Append to `src/auth.zig` tests:

```zig
test "applyCreate forces verified=false even if the client sends verified=true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "email", .{ .string = "a@b.c" });
    try data.put(a, "password", .{ .string = "longenough" });
    try data.put(a, "verified", .{ .bool = true });
    const out = try applyCreate(std.testing.io, a, .{ .object = data }, 8);
    try std.testing.expectEqual(false, out.object.get("verified").?.bool);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test`
Expected: compile error (`peekClaims` undefined) and/or the `applyCreate` assertion fails (currently honors client `verified:true`).

- [ ] **Step 3: Implement `peekClaims` in `src/jwt.zig`**

Add after `verify`:

```zig
/// Decode the payload of a compact JWS WITHOUT verifying the signature or expiry.
/// Used to locate the record (id/collection) before its signing key is known.
/// The returned claims MUST then be confirmed with `verify` using the record's key.
pub fn peekClaims(alloc: std.mem.Allocator, token: []const u8) JwtError!Claims {
    var it = std.mem.splitScalar(u8, token, '.');
    _ = it.next() orelse return error.Malformed; // header
    const p = it.next() orelse return error.Malformed; // payload
    _ = it.next() orelse return error.Malformed; // signature
    const payload_json = b64dec(alloc, p) catch return error.Malformed;
    const parsed = std.json.parseFromSlice(Claims, alloc, payload_json, .{}) catch return error.Malformed;
    return parsed.value;
}
```

- [ ] **Step 4: Force `verified=false` in `src/auth.zig` `applyCreate`**

Replace this line in `applyCreate`:

```zig
    if (out.get("verified") == null) try out.put(alloc, "verified", .{ .bool = false });
```

with (note: `put` overwrites an existing key, so this drops any client-sent value):

```zig
    try out.put(alloc, "verified", .{ .bool = false }); // never trust a client-supplied verified flag
```

- [ ] **Step 5: Run the tests**

Run: `mise exec zig@0.16.0 -- zig build test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/jwt.zig src/auth.zig
git commit -m "feat(jwt): peekClaims; auth: force verified=false on create"
```

---

### Task 3: Partial unique identity indexes (`ddl.zig`, `schema.zig`, `collections.zig`)

**Why:** Two empty-string emails must not collide, and `username` (and any configured identity field) must be unique when non-empty. Column-level `UNIQUE` on `email` can't express "unique only when non-empty", so we replace it with partial unique indexes generated from `options.auth.identityFields`.

**Files:**
- Modify: `src/schema.zig` (drop email column UNIQUE)
- Modify: `src/ddl.zig` (partial unique index SQL)
- Modify: `src/collections.zig` (emit them on create + rebuild)

- [ ] **Step 1: Write the failing tests**

Append to `src/ddl.zig` tests:

```zig
test "authIdentityIndexSql builds a partial unique index over non-empty values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sql = try authIdentityIndexSql(a, "users", "email");
    try std.testing.expectEqualStrings(
        "CREATE UNIQUE INDEX IF NOT EXISTS \"idx_auth_users_email\" ON \"users\" (\"email\") WHERE \"email\" != '';",
        sql,
    );
}
```

Add an integration test to `src/collections.zig` (append near the other engine tests; adapt the in-file `Db`/helpers used there — model it on an existing create test):

```zig
test "auth collection enforces identity uniqueness via partial unique index, allows multiple empty" {
    var d = try db.Db.openMemory();
    defer d.close();
    try @import("migrations.zig").run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try create(a, std.testing.io, &d, .{
        .id = "", .name = "members", .type = .auth,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
    });
    // two distinct emails ok
    try d.exec("INSERT INTO \"members\" (\"id\",\"created\",\"updated\",\"email\") VALUES ('a','','','x@y.z');");
    try d.exec("INSERT INTO \"members\" (\"id\",\"created\",\"updated\",\"email\") VALUES ('b','','','q@y.z');");
    // duplicate non-empty email rejected (exec maps the SQLite constraint error to ExecFailed)
    try std.testing.expectError(error.ExecFailed, d.exec("INSERT INTO \"members\" (\"id\",\"created\",\"updated\",\"email\") VALUES ('c','','','x@y.z');"));
    // two empty emails allowed (partial index excludes them)
    try d.exec("INSERT INTO \"members\" (\"id\",\"created\",\"updated\",\"email\") VALUES ('d','','','');");
    try d.exec("INSERT INTO \"members\" (\"id\",\"created\",\"updated\",\"email\") VALUES ('e','','','');");
}
```

Note: `db.exec` returns `error.ExecFailed` (from `db.DbError`) on a constraint violation. If the build reports a different tag, update the `expectError` to match — do NOT widen it to `anyerror`.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test`
Expected: compile error (`authIdentityIndexSql` undefined); the collections test fails because no partial index is created yet (the duplicate insert would succeed, or the empty-email inserts would be blocked by the old column UNIQUE).

- [ ] **Step 3: Drop the column-level UNIQUE on `email` in `src/schema.zig`**

In `authSystemFields()`, change the email field from:

```zig
            .{ .id = "_email", .name = "email", .unique = true, .options = .{ .email = .{} } },
```

to:

```zig
            .{ .id = "_email", .name = "email", .options = .{ .email = .{} } }, // uniqueness via partial unique index (see ddl.authIdentityIndexSql)
```

Update the existing schema test that asserts on this field if it checks `.unique` (search `authSystemFields`/`_email` in `src/schema.zig` tests; if none asserts `.unique`, no change needed).

- [ ] **Step 4: Add `authIdentityIndexSql` to `src/ddl.zig`**

```zig
/// A partial UNIQUE index enforcing identity uniqueness only over non-empty values:
///   CREATE UNIQUE INDEX IF NOT EXISTS "idx_auth_<table>_<field>" ON "<table>" ("<field>") WHERE "<field>" != '';
/// `table` and `field` are validated schema identifiers (injection-safe), but we quote them anyway.
pub fn authIdentityIndexSql(alloc: std.mem.Allocator, table: []const u8, field: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "CREATE UNIQUE INDEX IF NOT EXISTS \"idx_auth_{s}_{s}\" ON \"{s}\" (\"{s}\") WHERE \"{s}\" != '';",
        .{ table, field, table, field, field },
    );
}
```

- [ ] **Step 5: Emit identity indexes on create in `src/collections.zig`**

In `create`, after the user-index loop (`for (col.indexes) |idx| ...`) and before/after `insertRow` but inside the transaction, add:

```zig
    if (col.type == .auth) {
        for (col.options.auth.identityFields) |idf| {
            try w.exec(try alloc.dupeZ(u8, try ddl.authIdentityIndexSql(alloc, col.name, idf)));
        }
    }
```

- [ ] **Step 6: Emit identity indexes on rebuild in `src/collections.zig` `update`**

Find where `update` executes the `rebuildPlan` statements (the loop over `plan`). After that loop (still inside the transaction), re-create the identity indexes for the new collection (the rebuild dropped/renamed the table, so old indexes are gone):

```zig
    if (newc.type == .auth) {
        for (newc.options.auth.identityFields) |idf| {
            try w.exec(try alloc.dupeZ(u8, try ddl.authIdentityIndexSql(alloc, newc.name, idf)));
        }
    }
```

Use whatever the in-scope new-collection variable is named in `update` (the plan/grounding shows `newc` and `newc_full`; use the user-facing `newc` for `.options`/`.name`/`.type`). If `newc` is not in scope at that point, use the equivalent variable holding the post-validation collection.

- [ ] **Step 7: Run the tests**

Run: `mise exec zig@0.16.0 -- zig build test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add src/schema.zig src/ddl.zig src/collections.zig
git commit -m "feat(auth): partial unique identity indexes; drop email column UNIQUE"
```

---

### Task 4: Auth config + App settings (`config.zig`, `app.zig`, `main.zig`)

**Files:**
- Modify: `src/config.zig`
- Modify: `src/app.zig`
- Modify: `src/main.zig`

- [ ] **Step 1: Write the failing test** (append to `src/config.zig` tests)

```zig
test "auth defaults and overrides" {
    const G0 = struct {
        fn get(_: []const u8) ?[]const u8 { return null; }
    };
    const d = try Config.load(&G0.get);
    try std.testing.expectEqual(false, d.cookie_secure);
    try std.testing.expectEqual(@as(i64, 14 * 24 * 3600), d.auth_token_ttl_s);

    const G1 = struct {
        fn get(key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_COOKIE_SECURE")) return "true";
            if (std.mem.eql(u8, key, "ZIGBASE_AUTH_TOKEN_TTL")) return "3600";
            return null;
        }
    };
    const c = try Config.load(&G1.get);
    try std.testing.expectEqual(true, c.cookie_secure);
    try std.testing.expectEqual(@as(i64, 3600), c.auth_token_ttl_s);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test`
Expected: compile error — no `cookie_secure`/`auth_token_ttl_s` on `Config`.

- [ ] **Step 3: Extend `Config` in `src/config.zig`**

Add fields (after `jwt_secret`):

```zig
    cookie_secure: bool = false, // dev default; set true behind HTTPS
    auth_token_ttl_s: i64 = 14 * 24 * 3600, // 14 days
    verification_ttl_s: i64 = 7 * 24 * 3600, // 7 days
    password_reset_ttl_s: i64 = 3600, // 1 hour
```

In `load`, after the `jwt_secret` line, add:

```zig
        if (getter("ZIGBASE_COOKIE_SECURE")) |v| cfg.cookie_secure = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
        if (getter("ZIGBASE_AUTH_TOKEN_TTL")) |v| cfg.auth_token_ttl_s = try std.fmt.parseInt(i64, v, 10);
        if (getter("ZIGBASE_VERIFICATION_TTL")) |v| cfg.verification_ttl_s = try std.fmt.parseInt(i64, v, 10);
        if (getter("ZIGBASE_PASSWORD_RESET_TTL")) |v| cfg.password_reset_ttl_s = try std.fmt.parseInt(i64, v, 10);
```

- [ ] **Step 4: Extend `App` in `src/app.zig`** (defaults so existing `.{ .allocator, .io, .pool }` constructors still compile)

```zig
pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    pool: *db.Pool,
    jwt_secret: []const u8 = "dev-insecure-secret-change-me",
    cookie_secure: bool = false,
    auth_token_ttl_s: i64 = 14 * 24 * 3600,
    verification_ttl_s: i64 = 7 * 24 * 3600,
    password_reset_ttl_s: i64 = 3600,
};
```

- [ ] **Step 5: Populate the new fields at startup in `src/main.zig`**

Find where `App` is constructed for `serve` (search `app_mod.App{` or `.{ .allocator = ..., .io = ..., .pool = ...`). Add the config-derived fields:

```zig
        .jwt_secret = cfg.jwt_secret,
        .cookie_secure = cfg.cookie_secure,
        .auth_token_ttl_s = cfg.auth_token_ttl_s,
        .verification_ttl_s = cfg.verification_ttl_s,
        .password_reset_ttl_s = cfg.password_reset_ttl_s,
```

(Use the actual local `Config` variable name in `main.zig`; grounding shows it as `cfg`.)

- [ ] **Step 6: Run the tests**

Run: `mise exec zig@0.16.0 -- zig build test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/config.zig src/app.zig src/main.zig
git commit -m "feat(config): auth cookie/ttl settings on Config and App"
```

---

### Task 5: Route auth-collection record create/update through `auth.applyCreate`/`applyUpdate` (`api/records.zig`)

**Why:** Creating a user must hash the password, generate a tokenKey, strip plaintext, and force `verified=false`; updating must rotate the tokenKey on password change.

**Files:**
- Modify: `src/api/records.zig`

- [ ] **Step 1: Write the failing test** (append to `src/api/records.zig` tests)

Add a helper that seeds an auth collection, then a test:

```zig
fn seedAuth(env: *TestEnv, name: []const u8, createR: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    _ = try collections.create(a, std.testing.io, w, .{
        .id = "", .name = name, .type = .auth,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
        .listRule = "", .viewRule = "", .createRule = createR, .updateRule = "", .deleteRule = "",
    });
}

test "creating an auth record hashes the password, hides secrets, forces verified=false" {
    var env = try TestEnv.init();
    defer env.deinit();
    try seedAuth(env, "users", "");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var cctx = ctxFor(env, a, .POST, "{\"email\":\"u@x.io\",\"password\":\"longenough\",\"verified\":true}", &p);
    const res = try create(&cctx);
    try std.testing.expectEqual(@as(u16, 201), res.status);
    // secrets never serialized
    try std.testing.expect(std.mem.indexOf(u8, res.body, "passwordHash") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "tokenKey") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "password") == null);
    // verified forced false despite client sending true
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"verified\":false") != null);
}

test "creating an auth record without a password is a 400" {
    var env = try TestEnv.init();
    defer env.deinit();
    try seedAuth(env, "users2", "");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = [_]http.Param{.{ .key = "col", .value = "users2" }};
    var cctx = ctxFor(env, a, .POST, "{\"email\":\"u@x.io\"}", &p);
    const res = try create(&cctx);
    try std.testing.expectEqual(@as(u16, 400), res.status);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test`
Expected: FAIL — the create handler stores the raw object (no hash; `passwordHash` absent so insert may even error, and `verified:true` leaks through).

- [ ] **Step 3: Add an import + a password-preprocessing helper in `src/api/records.zig`**

Add the import near the top:

```zig
const auth = @import("../auth.zig");
```

Add a helper (after `forbidden`):

```zig
/// For auth collections, transform the request data through auth.applyCreate/applyUpdate
/// (hash password, gen/rotate tokenKey, strip plaintext, force verified=false on create).
/// For non-auth collections, returns `data` unchanged. Maps PasswordTooShort -> a 400 sentinel.
const AuthPrepError = error{BadPassword} || std.mem.Allocator.Error;

fn prepAuthData(ctx: *http.RequestCtx, col: schema.Collection, data: std.json.Value, comptime is_create: bool) AuthPrepError!std.json.Value {
    if (col.type != .auth) return data;
    const app = ctx.app.?;
    const min_len = col.options.auth.minPasswordLength;
    const out = if (is_create)
        auth.applyCreate(app.io, ctx.allocator, data, min_len)
    else
        auth.applyUpdate(app.io, ctx.allocator, data, min_len);
    return out catch |e| switch (e) {
        error.PasswordTooShort => return error.BadPassword,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadPassword, // hashing/token errors -> treat as bad request (rare; OS entropy/argon failure)
    };
}
```

- [ ] **Step 4: Use it in `create`**

In `create`, immediately after `data` is parsed and `col` is resolved (after the `resolveCollection` line, before `buildContext`), insert:

```zig
    const data2 = prepAuthData(ctx, col, data, true) catch |e| switch (e) {
        error.BadPassword => return ApiError.badRequest("A password of the required length is required.").toResponse(ctx.allocator),
        error.OutOfMemory => return e,
    };
```

Then replace the two `data` references in the `rules.decide` switch arms (`records.create(... col, data)` and `records.createGuarded(... col, data, ...)`) with `data2`. Leave the `rctx` built from the ORIGINAL `data` (rules should see the client's intent, e.g. `@request.data.email`), i.e. keep `const rctx = buildContext(ctx, data);` referencing `data`.

- [ ] **Step 5: Use it in `update`**

In `update`, after `col` is resolved and the existence check passes, before the `rules.decide` switch, insert:

```zig
    const data2 = prepAuthData(ctx, col, data, false) catch |e| switch (e) {
        error.BadPassword => return ApiError.badRequest("A password of the required length is required.").toResponse(ctx.allocator),
        error.OutOfMemory => return e,
    };
```

Replace the `data` argument in `records.update(... rid, data)` and `records.updateGuarded(... rid, data, ...)` with `data2`. Keep `rctx` built from the original `data`.

- [ ] **Step 6: Run the tests**

Run: `mise exec zig@0.16.0 -- zig build test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/api/records.zig
git commit -m "feat(records): hash passwords / rotate tokenKey for auth collections"
```

---

### Task 6: `auth.authenticate` middleware + auth-aware `buildContext` (`auth.zig`, `api/records.zig`)

**Why:** Populate `RequestContext.auth`/`is_superuser` from a verified token (bearer OR `zb_auth` cookie), enforcing CSRF on the cookie + unsafe-method path so `@request.auth.*` rules and superuser bypass work.

**Files:**
- Modify: `src/auth.zig`
- Modify: `src/api/records.zig`

- [ ] **Step 1: Write the failing tests** (append to `src/auth.zig` tests)

These build a real in-memory DB, seed an auth collection + record, mint a token, and assert the middleware resolves it. Model the DB/collection setup on `src/api/records.zig`'s `TestEnv` pattern, but here use `db.Db.openMemory()` directly:

```zig
const db_ = @import("db.zig");
const collections_ = @import("collections.zig");
const migrations_ = @import("migrations.zig");
const jwt_ = @import("jwt.zig");
const crypto_ = @import("crypto.zig");
const http_ = @import("http.zig");

test "authenticate resolves a valid bearer token to its record" {
    var d = try db_.Db.openMemory();
    defer d.close();
    try migrations_.run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try collections_.create(a, std.testing.io, &d, .{
        .id = "", .name = "users", .type = .auth,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
        .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "",
    });
    // insert a record with a known tokenKey
    try d.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('rec1','','','u@x.io','tk-secret',1);");

    var app = TestApp.make(&d); // see helper below
    const key = crypto_.deriveKey(app.jwt_secret, "tk-secret");
    const token = try jwt_.sign(a, .{ .id = "rec1", .collection = "users", .type = .auth, .iat = 0, .exp = 9999999999 }, &key);

    var ctx = http_.RequestCtx{ .method = .GET, .path = "/", .allocator = a, .authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token}) };
    const authed = (try authenticate(app.io, a, &app, &ctx, &d)) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("users", authed.collection);
    try std.testing.expectEqual(false, authed.is_superuser);
    try std.testing.expectEqualStrings("rec1", authed.record.object.get("id").?.string);
    // tokenKey must NOT be exposed on the authed record
    try std.testing.expect(authed.record.object.get("tokenKey") == null);
}

test "authenticate rejects a token signed with the wrong key (returns null)" {
    var d = try db_.Db.openMemory();
    defer d.close();
    try migrations_.run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try collections_.create(a, std.testing.io, &d, .{
        .id = "", .name = "users", .type = .auth,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
    });
    try d.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('rec1','','','u@x.io','tk-secret',1);");
    var app = TestApp.make(&d);
    const wrong = crypto_.deriveKey(app.jwt_secret, "different-key");
    const token = try jwt_.sign(a, .{ .id = "rec1", .collection = "users", .type = .auth, .iat = 0, .exp = 9999999999 }, &wrong);
    var ctx = http_.RequestCtx{ .method = .GET, .path = "/", .allocator = a, .authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token}) };
    try std.testing.expect((try authenticate(app.io, a, &app, &ctx, &d)) == null);
}

test "authenticate requires CSRF on the cookie + unsafe-method path" {
    var d = try db_.Db.openMemory();
    defer d.close();
    try migrations_.run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try collections_.create(a, std.testing.io, &d, .{
        .id = "", .name = "users", .type = .auth,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
    });
    try d.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('rec1','','','u@x.io','tk-secret',1);");
    var app = TestApp.make(&d);
    const key = crypto_.deriveKey(app.jwt_secret, "tk-secret");
    const token = try jwt_.sign(a, .{ .id = "rec1", .collection = "users", .type = .auth, .csrf = "csrf-abc", .iat = 0, .exp = 9999999999 }, &key);
    const cookie_hdr = try std.fmt.allocPrint(a, "zb_auth={s}", .{token});

    // POST via cookie without the matching CSRF header -> null
    var bad = http_.RequestCtx{ .method = .POST, .path = "/", .allocator = a, .cookie_header = cookie_hdr };
    try std.testing.expect((try authenticate(app.io, a, &app, &bad, &d)) == null);
    // POST via cookie WITH the matching CSRF header -> resolves
    var ok = http_.RequestCtx{ .method = .POST, .path = "/", .allocator = a, .cookie_header = cookie_hdr, .csrf_token = "csrf-abc" };
    try std.testing.expect((try authenticate(app.io, a, &app, &ok, &d)) != null);
    // GET via cookie needs no CSRF
    var get = http_.RequestCtx{ .method = .GET, .path = "/", .allocator = a, .cookie_header = cookie_hdr };
    try std.testing.expect((try authenticate(app.io, a, &app, &get, &d)) != null);
}
```

Add this test-only helper near the top of the `src/auth.zig` test region (App is defined in `app.zig`; construct it with defaults + the pool-less direct-conn shape the middleware needs — see Step 3 for the `authenticate` signature, which takes the `*db.Db` directly, so `App` here only supplies settings):

```zig
const App_ = @import("app.zig").App;
const TestApp = struct {
    fn make(d: *db_.Db) App_ {
        _ = d;
        // pool is unused by authenticate (it takes the conn explicitly); supply a dummy via undefined is unsafe,
        // so authenticate must NOT touch app.pool. Construct with the real fields it reads:
        return App_{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined };
    }
};
```

IMPORTANT for the implementer: `authenticate` MUST take the DB connection explicitly and MUST NOT read `app.pool` (so the test's `undefined` pool is never dereferenced). It reads only `app.jwt_secret` (and `app.io`/`app.allocator` if needed). If you find this constraint awkward, instead pass `jwt_secret: []const u8` directly rather than `*App`; update the signature and the records.zig caller accordingly. Pick one and keep it consistent.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test`
Expected: compile error — `authenticate`/`Authed` undefined.

- [ ] **Step 3: Implement the middleware in `src/auth.zig`**

Add imports at the top (if not present): `jwt`, `http`, `crypto` (already imported), `collections`, `request`. Then:

```zig
const jwt = @import("jwt.zig");
const http = @import("http.zig");
const collections = @import("collections.zig");

pub const Authed = struct {
    record: std.json.Value, // the auth record with hidden fields stripped
    collection: []const u8,
    is_superuser: bool,
};

/// Read the current unix time from SQLite (keeps pure code clock-free).
fn nowUnix(conn: *db.Db) db.DbError!i64 {
    var st = try conn.prepare("SELECT unixepoch('now');");
    defer st.finalize();
    _ = try st.step();
    return st.columnInt(0);
}

/// Fetch a single auth record's tokenKey by id from `table`. Returns null if absent.
fn tokenKeyFor(alloc: std.mem.Allocator, conn: *db.Db, table: []const u8, rid: []const u8) !?[]const u8 {
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT \"tokenKey\" FROM \"{s}\" WHERE \"id\" = ?1;", .{table}, 0);
    var st = try conn.prepare(sql);
    defer st.finalize();
    try st.bindText(1, rid);
    if (!try st.step()) return null;
    return try alloc.dupe(u8, st.columnText(0));
}

fn isUnsafe(m: http.Method) bool {
    return switch (m) {
        .POST, .PUT, .PATCH, .DELETE => true,
        else => false,
    };
}

/// Resolve the request's auth token (bearer or zb_auth cookie) to a record, or null if
/// absent/invalid. Enforces double-submit CSRF on the cookie + unsafe-method path.
/// `conn` is any open connection (reader or writer); `app` supplies jwt_secret/io.
pub fn authenticate(io: std.Io, alloc: std.mem.Allocator, app: anytype, ctx: *const http.RequestCtx, conn: *db.Db) !?Authed {
    _ = io;
    const bearer = ctx.bearerToken();
    const from_cookie = bearer == null;
    const token = bearer orelse (ctx.cookie("zb_auth") orelse return null);

    const claims = jwt.peekClaims(alloc, token) catch return null;
    if (claims.type != .auth) return null;

    // CSRF: cookie transport on an unsafe method requires the header to match the signed csrf claim.
    if (from_cookie and isUnsafe(ctx.method)) {
        if (ctx.csrf_token.len == 0 or claims.csrf.len == 0) return null;
        if (!std.crypto.timing_safe.eql([0]u8, undefined, undefined)) {} // (no-op placeholder; see note)
        if (claims.csrf.len != ctx.csrf_token.len or
            !std.crypto.timing_safe.eql(u8, claims.csrf, ctx.csrf_token)) return null;
    }

    const is_super = std.mem.eql(u8, claims.collection, "_superusers");

    // The physical table for the record: superusers live in "_superusers"; otherwise the collection name.
    const table = if (is_super) "_superusers" else blk: {
        const col = (collections.get(alloc, conn, claims.collection) catch return null) orelse return null;
        break :blk col.name;
    };

    const tk = (tokenKeyFor(alloc, conn, table, claims.id) catch return null) orelse return null;
    const key = crypto.deriveKey(app.jwt_secret, tk);
    const now = nowUnix(conn) catch return null;
    _ = jwt.verify(alloc, token, &key, now) catch return null;

    // Load the record object (hidden fields stripped) for @request.auth.* and responses.
    const rec = if (is_super)
        (superuserRecord(alloc, conn, claims.id) catch return null) orelse return null
    else blk: {
        const col = (collections.get(alloc, conn, claims.collection) catch return null) orelse return null;
        const records = @import("records.zig");
        break :blk (records.get(alloc, conn, col, claims.id) catch return null) orelse return null;
    };

    return Authed{ .record = rec, .collection = claims.collection, .is_superuser = is_super };
}

/// Build a record object for a _superusers row (id/email/verified; secrets excluded).
fn superuserRecord(alloc: std.mem.Allocator, conn: *db.Db, rid: []const u8) !?std.json.Value {
    var st = try conn.prepare("SELECT \"id\",\"email\",\"verified\" FROM \"_superusers\" WHERE \"id\" = ?1;");
    defer st.finalize();
    try st.bindText(1, rid);
    if (!try st.step()) return null;
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "id", .{ .string = try alloc.dupe(u8, st.columnText(0)) });
    try obj.put(alloc, "email", .{ .string = try alloc.dupe(u8, st.columnText(1)) });
    try obj.put(alloc, "verified", .{ .bool = st.columnInt(2) != 0 });
    return .{ .object = obj };
}
```

NOTE on the CSRF compare: delete the placeholder no-op line. Use a constant-time comparison. `std.crypto.timing_safe.eql` requires equal-length arrays at comptime; for runtime-length slices, compare lengths first (non-secret) then do a byte-accumulating constant-time compare. Implement this small helper instead:

```zig
fn ctEqlSlices(a_: []const u8, b_: []const u8) bool {
    if (a_.len != b_.len) return false;
    var diff: u8 = 0;
    for (a_, b_) |x, y| diff |= x ^ y;
    return diff == 0;
}
```

and use `if (!ctEqlSlices(claims.csrf, ctx.csrf_token)) return null;` (drop the timing_safe lines entirely).

Also: `app: anytype` lets the test pass a value `*App` without importing pool internals; the records.zig caller passes `ctx.app.?`. If you prefer an explicit type, change the signature to take `jwt_secret: []const u8` instead of `app` and pass `app.jwt_secret` at the call site — either is acceptable, keep it consistent with the Step-1 test (which calls `authenticate(app.io, a, &app, &ctx, &d)`).

- [ ] **Step 4: Make `buildContext` auth-aware in `src/api/records.zig`**

Replace the current `buildContext` with a version that authenticates against the supplied connection:

```zig
fn buildContext(ctx: *http.RequestCtx, conn: *db.Db, data: ?std.json.Value) request.RequestContext {
    if (ctx.app) |app| {
        if (auth.authenticate(app.io, ctx.allocator, app, ctx, conn) catch null) |a| {
            return .{ .auth = a.record, .is_superuser = a.is_superuser, .data = data, .method = @tagName(ctx.method) };
        }
    }
    return .{ .auth = null, .is_superuser = false, .data = data, .method = @tagName(ctx.method) };
}
```

Update every caller to pass the connection in scope:
- `view`: `const rctx = buildContext(ctx, &r, null);`
- `create`: `const rctx = buildContext(ctx, w, data);`
- `update`: `const rctx = buildContext(ctx, w, data);`
- `delete`: `const rctx = buildContext(ctx, w, null);`
- `list`: `const rctx = buildContext(ctx, &r, null);`

(`r` is the reader `db.Db`, `w` is the writer `*db.Db`; pass `&r` for readers, `w` for the writer pointer.)

- [ ] **Step 5: Run the tests**

Run: `mise exec zig@0.16.0 -- zig build test`
Expected: PASS (all existing record/rule tests still green — anonymous requests resolve to `auth=null` exactly as before).

- [ ] **Step 6: Commit**

```bash
git add src/auth.zig src/api/records.zig
git commit -m "feat(auth): bearer/cookie authentication middleware with CSRF"
```

---

### Task 7: Login / refresh / logout endpoints (`api/auth.zig`, `server.zig`)

**Files:**
- Create: `src/api/auth.zig`
- Modify: `src/server.zig` (routes)

- [ ] **Step 1: Write the failing test** (in the new `src/api/auth.zig`, mirroring the `TestEnv` pattern from `api/records.zig` — copy that `TestEnv`/`ctxFor` scaffolding, adapted to seed an auth collection)

```zig
test "auth-with-password issues a token + cookies, wrong password 400" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // create a user via the records handler
    try env.createUser(a, "users", "u@x.io", "longenough");

    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var ok = env.ctx(a, .POST, "{\"identity\":\"u@x.io\",\"password\":\"longenough\"}", &p);
    const res = try authWithPassword(&ok);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"token\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"record\":") != null);
    // sets zb_auth (httpOnly) and zb_csrf cookies
    var saw_auth = false;
    var saw_csrf = false;
    for (res.cookies) |c| {
        if (std.mem.eql(u8, c.name, "zb_auth")) { saw_auth = true; try std.testing.expect(c.http_only); }
        if (std.mem.eql(u8, c.name, "zb_csrf")) { saw_csrf = true; try std.testing.expect(!c.http_only); }
    }
    try std.testing.expect(saw_auth and saw_csrf);

    var bad = env.ctx(a, .POST, "{\"identity\":\"u@x.io\",\"password\":\"wrongwrong\"}", &p);
    try std.testing.expectEqual(@as(u16, 400), (try authWithPassword(&bad)).status);
}

test "auth-logout clears the cookies" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var ctx = env.ctx(a, .POST, "", &p);
    const res = try authLogout(&ctx);
    try std.testing.expectEqual(@as(u16, 204), res.status);
    var cleared: usize = 0;
    for (res.cookies) |c| if (c.max_age_s < 0) { cleared += 1; };
    try std.testing.expectEqual(@as(usize, 2), cleared);
}
```

Build a `TestEnv` with `initAuth(name)` (open pool, run migrations, create an auth collection with public rules), `createUser(a, col, email, pw)` (call `records_api.create` with a `{email,password}` body), and `ctx(a, method, body, params)` (returns a `RequestCtx` with `.app = &env.app`). Reuse the exact shape from `src/api/records.zig`'s `TestEnv`.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test`
Expected: compile error — `api/auth.zig` functions undefined.

- [ ] **Step 3: Implement `src/api/auth.zig`**

```zig
const std = @import("std");
const http = @import("../http.zig");
const db = @import("../db.zig");
const collections = @import("../collections.zig");
const records = @import("../records.zig");
const schema = @import("../schema.zig");
const crypto = @import("../crypto.zig");
const jwt = @import("../jwt.zig");
const auth = @import("../auth.zig");
const ApiError = @import("error.zig").ApiError;

fn jsonResponse(ctx: *http.RequestCtx, status: u16, v: std.json.Value, cookies: []const http.Cookie) !http.Response {
    return .{ .status = status, .body = try std.json.Stringify.valueAlloc(ctx.allocator, v, .{}), .cookies = cookies };
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

fn nowUnix(conn: *db.Db) db.DbError!i64 {
    var st = try conn.prepare("SELECT unixepoch('now');");
    defer st.finalize();
    _ = try st.step();
    return st.columnInt(0);
}

/// Look up an auth record id by trying each identity field in order. Returns the row id, or null.
fn findByIdentity(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, identity: []const u8) !?[]const u8 {
    for (col.options.auth.identityFields) |idf| {
        // idf is a validated schema identifier
        const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT \"id\" FROM \"{s}\" WHERE \"{s}\" = ?1 AND \"{s}\" != '' LIMIT 1;", .{ col.name, idf, idf }, 0);
        var st = try conn.prepare(sql);
        defer st.finalize();
        try st.bindText(1, identity);
        if (try st.step()) return try alloc.dupe(u8, st.columnText(0));
    }
    return null;
}

fn passwordHashFor(alloc: std.mem.Allocator, conn: *db.Db, table: []const u8, rid: []const u8) !?[]const u8 {
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT \"passwordHash\",\"tokenKey\" FROM \"{s}\" WHERE \"id\" = ?1;", .{table}, 0);
    var st = try conn.prepare(sql);
    defer st.finalize();
    try st.bindText(1, rid);
    if (!try st.step()) return null;
    return try alloc.dupe(u8, st.columnText(0));
}

fn tokenKeyFor(alloc: std.mem.Allocator, conn: *db.Db, table: []const u8, rid: []const u8) !?[]const u8 {
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT \"tokenKey\" FROM \"{s}\" WHERE \"id\" = ?1;", .{table}, 0);
    var st = try conn.prepare(sql);
    defer st.finalize();
    try st.bindText(1, rid);
    if (!try st.step()) return null;
    return try alloc.dupe(u8, st.columnText(0));
}

/// Mint an auth JWT for (collection, id) and the matching cookie pair. Returns {token, cookies}.
const Issued = struct { token: []const u8, cookies: [2]http.Cookie };

fn issue(ctx: *http.RequestCtx, conn: *db.Db, collection: []const u8, rid: []const u8, token_key: []const u8) !Issued {
    const app = ctx.app.?;
    const csrf = try crypto.genToken(app.io, ctx.allocator, 32);
    const now = try nowUnix(conn);
    const claims = jwt.Claims{
        .id = rid, .collection = collection, .type = .auth, .csrf = csrf,
        .iat = now, .exp = now + app.auth_token_ttl_s,
    };
    const key = crypto.deriveKey(app.jwt_secret, token_key);
    const token = try jwt.sign(ctx.allocator, claims, &key);
    const max_age: i32 = @intCast(app.auth_token_ttl_s);
    return .{
        .token = token,
        .cookies = .{
            .{ .name = "zb_auth", .value = token, .max_age_s = max_age, .http_only = true, .secure = app.cookie_secure, .same_site = .strict },
            .{ .name = "zb_csrf", .value = csrf, .max_age_s = max_age, .http_only = false, .secure = app.cookie_secure, .same_site = .strict },
        },
    };
}

pub fn authWithPassword(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const body = parseBody(ctx) orelse return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator);
    const identity = strField(body, "identity") orelse return ApiError.badRequest("identity is required.").toResponse(ctx.allocator);
    const password = strField(body, "password") orelse return ApiError.badRequest("password is required.").toResponse(ctx.allocator);

    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col_name = ctx.param("col") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const col = (try collections.get(ctx.allocator, w, col_name)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    if (col.type != .auth) return ApiError.notFound().toResponse(ctx.allocator);

    const rid = (try findByIdentity(ctx.allocator, w, col, identity)) orelse
        return ApiError.badRequest("Invalid credentials.").toResponse(ctx.allocator);
    const phc = (try passwordHashFor(ctx.allocator, w, col.name, rid)) orelse
        return ApiError.badRequest("Invalid credentials.").toResponse(ctx.allocator);
    if (!crypto.verifyPassword(app.io, ctx.allocator, phc, password))
        return ApiError.badRequest("Invalid credentials.").toResponse(ctx.allocator);

    const tk = (try tokenKeyFor(ctx.allocator, w, col.name, rid)) orelse
        return ApiError.badRequest("Invalid credentials.").toResponse(ctx.allocator);
    const issued = try issue(ctx, w, col.name, rid, tk);
    const rec = (try records.get(ctx.allocator, w, col, rid)) orelse
        return ApiError.notFound().toResponse(ctx.allocator);

    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator, "token", .{ .string = issued.token });
    try root.put(ctx.allocator, "record", rec);
    const cookies = try ctx.allocator.dupe(http.Cookie, &issued.cookies);
    return jsonResponse(ctx, 200, .{ .object = root }, cookies);
}

pub fn authRefresh(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const authed = (try auth.authenticate(app.io, ctx.allocator, app, ctx, w)) orelse
        return (ApiError{ .status = 401, .message = "Not authenticated." }).toResponse(ctx.allocator);
    const col_name = ctx.param("col") orelse return ApiError.notFound().toResponse(ctx.allocator);
    if (!std.mem.eql(u8, authed.collection, col_name))
        return (ApiError{ .status = 401, .message = "Not authenticated." }).toResponse(ctx.allocator);

    const rid = authed.record.object.get("id").?.string;
    const tk = (try tokenKeyFor(ctx.allocator, w, col_name, rid)) orelse
        return (ApiError{ .status = 401, .message = "Not authenticated." }).toResponse(ctx.allocator);
    const issued = try issue(ctx, w, col_name, rid, tk);
    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator, "token", .{ .string = issued.token });
    try root.put(ctx.allocator, "record", authed.record);
    const cookies = try ctx.allocator.dupe(http.Cookie, &issued.cookies);
    return jsonResponse(ctx, 200, .{ .object = root }, cookies);
}

pub fn authLogout(ctx: *http.RequestCtx) anyerror!http.Response {
    const cleared = [_]http.Cookie{
        .{ .name = "zb_auth", .value = "", .max_age_s = -1, .http_only = true, .secure = ctx.app.?.cookie_secure, .same_site = .strict },
        .{ .name = "zb_csrf", .value = "", .max_age_s = -1, .http_only = false, .secure = ctx.app.?.cookie_secure, .same_site = .strict },
    };
    const cookies = try ctx.allocator.dupe(http.Cookie, &cleared);
    return .{ .status = 204, .body = "", .cookies = cookies };
}
```

Note: `passwordHashFor` over-selects (also reads tokenKey) but only returns the hash; that's fine. If `db.Stmt.columnText` over a NULL passwordHash returns "", `verifyPassword` will simply fail → 400, which is correct.

- [ ] **Step 4: Register routes in `src/server.zig`**

Add the import and routes:

```zig
const auth_api = @import("api/auth.zig");
```

In the `routes` array, add:

```zig
    .{ .method = .POST, .pattern = "/api/collections/:col/auth-with-password", .handler = auth_api.authWithPassword },
    .{ .method = .POST, .pattern = "/api/collections/:col/auth-refresh", .handler = auth_api.authRefresh },
    .{ .method = .POST, .pattern = "/api/collections/:col/auth-logout", .handler = auth_api.authLogout },
```

- [ ] **Step 5: Run the tests**

Run: `mise exec zig@0.16.0 -- zig build test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/api/auth.zig src/server.zig
git commit -m "feat(auth): auth-with-password / refresh / logout endpoints"
```

---

### Task 8: Email-verification + password-reset endpoints (`api/auth.zig`, `server.zig`)

**Behavior:** `request-*` endpoints always return 204 (no account enumeration) and log the generated token at info level (no mailer yet). `confirm-*` endpoints verify the token against the record's derived key and apply the change. Verification/reset tokens are typed (`jwt.TokenType.verification` / `.password_reset`) and short-lived.

**Files:**
- Modify: `src/api/auth.zig`
- Modify: `src/server.zig` (routes)

- [ ] **Step 1: Write the failing test** (append to `src/api/auth.zig` tests)

```zig
test "verification: request always 204; confirm sets verified=true" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "v@x.io", "longenough");
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};

    var req = env.ctx(a, .POST, "{\"email\":\"v@x.io\"}", &p);
    try std.testing.expectEqual(@as(u16, 204), (try requestVerification(&req)).status);
    var req_missing = env.ctx(a, .POST, "{\"email\":\"nobody@x.io\"}", &p);
    try std.testing.expectEqual(@as(u16, 204), (try requestVerification(&req_missing)).status); // no enumeration

    // mint a verification token directly (the endpoint only logs it) and confirm
    const token = try env.mintTyped(a, "users", "v@x.io", .verification);
    const body = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\"}}", .{token});
    var conf = env.ctx(a, .POST, body, &p);
    try std.testing.expectEqual(@as(u16, 200), (try confirmVerification(&conf)).status);
    try std.testing.expect(env.recordVerified(a, "users", "v@x.io"));
}

test "password reset: confirm changes the password and rotates the token" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "r@x.io", "oldpassword");
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    const token = try env.mintTyped(a, "users", "r@x.io", .password_reset);
    const body = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\",\"password\":\"newpassword\"}}", .{token});
    var conf = env.ctx(a, .POST, body, &p);
    try std.testing.expectEqual(@as(u16, 200), (try confirmPasswordReset(&conf)).status);
    // old reset token no longer verifies (tokenKey rotated): a second confirm fails
    var conf2 = env.ctx(a, .POST, body, &p);
    try std.testing.expectEqual(@as(u16, 400), (try confirmPasswordReset(&conf2)).status);
}
```

Extend `TestEnv` with `mintTyped(a, col, email, token_type)` (find the record's tokenKey, derive the key, sign a `Claims{ .type = token_type, .exp = now+big }`) and `recordVerified(a, col, email)` (query `verified`). Use `std.testing.io` and a fixed `now` via `unixepoch` on the writer.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test`
Expected: compile error — the four functions are undefined.

- [ ] **Step 3: Implement the endpoints in `src/api/auth.zig`**

```zig
/// Find a record id by email (the canonical verification/reset identity), or null.
fn findByEmail(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, email: []const u8) !?[]const u8 {
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT \"id\" FROM \"{s}\" WHERE \"email\" = ?1 AND \"email\" != '' LIMIT 1;", .{col.name}, 0);
    var st = try conn.prepare(sql);
    defer st.finalize();
    try st.bindText(1, email);
    if (try st.step()) return try alloc.dupe(u8, st.columnText(0));
    return null;
}

fn mintTyped(ctx: *http.RequestCtx, conn: *db.Db, col_name: []const u8, rid: []const u8, token_key: []const u8, tt: jwt.TokenType, ttl: i64) ![]const u8 {
    const app = ctx.app.?;
    const now = try nowUnix(conn);
    const key = crypto.deriveKey(app.jwt_secret, token_key);
    return jwt.sign(ctx.allocator, .{ .id = rid, .collection = col_name, .type = tt, .iat = now, .exp = now + ttl }, &key);
}

fn loadAuthCollection(ctx: *http.RequestCtx, conn: *db.Db) !?schema.Collection {
    const col_name = ctx.param("col") orelse return null;
    const col = (try collections.get(ctx.allocator, conn, col_name)) orelse return null;
    if (col.type != .auth) return null;
    return col;
}

/// Verify a typed token against the record's derived key. Returns the claims on success.
fn verifyTyped(ctx: *http.RequestCtx, conn: *db.Db, col: schema.Collection, token: []const u8, want: jwt.TokenType) !?jwt.Claims {
    const app = ctx.app.?;
    const claims = jwt.peekClaims(ctx.allocator, token) catch return null;
    if (claims.type != want) return null;
    if (!std.mem.eql(u8, claims.collection, col.name)) return null;
    const tk = (try tokenKeyFor(ctx.allocator, conn, col.name, claims.id)) orelse return null;
    const key = crypto.deriveKey(app.jwt_secret, tk);
    const now = try nowUnix(conn);
    const verified = jwt.verify(ctx.allocator, token, &key, now) catch return null;
    return verified;
}

pub fn requestVerification(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col = (try loadAuthCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const body = parseBody(ctx) orelse return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator);
    if (strField(body, "email")) |email| {
        if (try findByEmail(ctx.allocator, w, col, email)) |rid| {
            if (try tokenKeyFor(ctx.allocator, w, col.name, rid)) |tk| {
                const token = try mintTyped(ctx, w, col.name, rid, tk, .verification, app.verification_ttl_s);
                std.log.info("verification token for {s}/{s}: {s}", .{ col.name, email, token });
            }
        }
    }
    return .{ .status = 204, .body = "" };
}

pub fn confirmVerification(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col = (try loadAuthCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const body = parseBody(ctx) orelse return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator);
    const token = strField(body, "token") orelse return ApiError.badRequest("token is required.").toResponse(ctx.allocator);
    const claims = (try verifyTyped(ctx, w, col, token, .verification)) orelse
        return ApiError.badRequest("Invalid or expired token.").toResponse(ctx.allocator);
    const sql = try std.fmt.allocPrintSentinel(ctx.allocator, "UPDATE \"{s}\" SET \"verified\" = 1 WHERE \"id\" = ?1;", .{col.name}, 0);
    var st = try w.prepare(sql);
    defer st.finalize();
    try st.bindText(1, claims.id);
    _ = try st.step();
    return .{ .status = 200, .body = "{\"verified\":true}" };
}

pub fn requestPasswordReset(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col = (try loadAuthCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const body = parseBody(ctx) orelse return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator);
    if (strField(body, "email")) |email| {
        if (try findByEmail(ctx.allocator, w, col, email)) |rid| {
            if (try tokenKeyFor(ctx.allocator, w, col.name, rid)) |tk| {
                const token = try mintTyped(ctx, w, col.name, rid, tk, .password_reset, app.password_reset_ttl_s);
                std.log.info("password-reset token for {s}/{s}: {s}", .{ col.name, email, token });
            }
        }
    }
    return .{ .status = 204, .body = "" };
}

pub fn confirmPasswordReset(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col = (try loadAuthCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const body = parseBody(ctx) orelse return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator);
    const token = strField(body, "token") orelse return ApiError.badRequest("token is required.").toResponse(ctx.allocator);
    const password = strField(body, "password") orelse return ApiError.badRequest("password is required.").toResponse(ctx.allocator);
    const claims = (try verifyTyped(ctx, w, col, token, .password_reset)) orelse
        return ApiError.badRequest("Invalid or expired token.").toResponse(ctx.allocator);
    if (password.len < col.options.auth.minPasswordLength)
        return ApiError.badRequest("Password too short.").toResponse(ctx.allocator);

    // Rotate credentials via auth.applyUpdate + records.update so tokenKey rotates (invalidating the reset token).
    var data: std.json.ObjectMap = .empty;
    try data.put(ctx.allocator, "password", .{ .string = password });
    const updated = auth.applyUpdate(app.io, ctx.allocator, .{ .object = data }, col.options.auth.minPasswordLength) catch
        return ApiError.badRequest("Invalid password.").toResponse(ctx.allocator);
    _ = records.update(ctx.allocator, w, col, claims.id, updated) catch
        return ApiError.internal().toResponse(ctx.allocator);
    return .{ .status = 200, .body = "{\"success\":true}" };
}
```

- [ ] **Step 4: Register routes in `src/server.zig`**

```zig
    .{ .method = .POST, .pattern = "/api/collections/:col/request-verification", .handler = auth_api.requestVerification },
    .{ .method = .POST, .pattern = "/api/collections/:col/confirm-verification", .handler = auth_api.confirmVerification },
    .{ .method = .POST, .pattern = "/api/collections/:col/request-password-reset", .handler = auth_api.requestPasswordReset },
    .{ .method = .POST, .pattern = "/api/collections/:col/confirm-password-reset", .handler = auth_api.confirmPasswordReset },
```

- [ ] **Step 5: Run the tests**

Run: `mise exec zig@0.16.0 -- zig build test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/api/auth.zig src/server.zig
git commit -m "feat(auth): email-verification and password-reset endpoints"
```

---

### Task 9: Superuser-gate collection management + full integration smoke (`api/collections.zig`)

**Files:**
- Modify: `src/api/collections.zig`

- [ ] **Step 1: Write the failing test** (append to `src/api/collections.zig` tests; reuse its existing `TestEnv`/`ctxFor` helpers)

```zig
test "collection management requires a superuser" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // anonymous list -> 403
    var anon = ctxFor(env, a, .GET, "", &.{});
    try std.testing.expectEqual(@as(u16, 403), (try list(&anon)).status);

    // superuser token -> 200
    const token = try env.superuserToken(a); // seeds a _superusers row + signs an auth JWT for it
    var su = ctxFor(env, a, .GET, "", &.{});
    su.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    try std.testing.expectEqual(@as(u16, 200), (try list(&su)).status);
}
```

Add a `superuserToken(a)` helper to this file's `TestEnv`: insert a `_superusers` row (`id`, `email`, `tokenKey`, `verified=1`), derive its key with `env.app.jwt_secret`, and sign a `Claims{ .id = ..., .collection = "_superusers", .type = .auth, .exp = now+big }`.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test`
Expected: FAIL — anonymous `list` currently returns 200.

- [ ] **Step 3: Add a superuser gate to `src/api/collections.zig`**

Add imports:

```zig
const auth = @import("../auth.zig");
```

Add a helper:

```zig
/// Returns true if the request carries a valid superuser token. Uses a reader connection.
fn isSuperuser(ctx: *http.RequestCtx) bool {
    const app = ctx.app orelse return false;
    var r = app.pool.openReader() catch return false;
    defer r.close();
    const authed = (auth.authenticate(app.io, ctx.allocator, app, ctx, &r) catch null) orelse return false;
    return authed.is_superuser;
}

fn requireSuperuser(ctx: *http.RequestCtx) ?http.Response {
    if (isSuperuser(ctx)) return null;
    return (ApiError{ .status = 403, .message = "Forbidden." }).toResponse(ctx.allocator) catch
        ApiError.internal().toResponse(ctx.allocator) catch unreachable;
}
```

At the top of each of `list`, `create`, `get`, `update`, `delete`, add:

```zig
    if (requireSuperuser(ctx)) |resp| return resp;
```

- [ ] **Step 4: Run the tests**

Run: `mise exec zig@0.16.0 -- zig build test`
Expected: PASS.

- [ ] **Step 5: Manual end-to-end smoke (live server)**

Build and run, then exercise the full auth flow with curl. Document the commands and outputs in the commit message body.

```bash
mise exec zig@0.16.0 -- zig build
# create a superuser
./zig-out/bin/zigbase superuser create --email admin@x.io --password adminpassword --data-dir ./zb_smoke
# serve in the background
ZIGBASE_DATA_DIR=./zb_smoke ./zig-out/bin/zigbase serve &
SRV=$!
sleep 1
# log in as superuser
curl -s -X POST localhost:8090/api/collections/_superusers/auth-with-password \
  -H 'content-type: application/json' \
  -d '{"identity":"admin@x.io","password":"adminpassword"}'
# use the returned token to create an auth collection (expect 200), then create a user,
# log in as the user, hit a rule-protected record endpoint, refresh, logout.
kill $SRV
rm -rf ./zb_smoke
```

Expected: superuser login returns `{"token":...,"record":...}`; collection creation with the bearer token returns the new collection; anonymous collection creation returns 403; user login returns a token + sets `zb_auth`/`zb_csrf` cookies (inspect with `-i`); logout clears them.

- [ ] **Step 6: Commit**

```bash
git add src/api/collections.zig
git commit -m "feat(collections): gate management endpoints behind superuser; SP5 smoke"
```

---

## Post-plan: holistic review + merge

After all nine tasks pass, run a holistic review over the whole SP5 diff (`5a`+`5b`+`5c`) on the `auth` branch — trace the auth path for: token-forgery / alg-confusion, CSRF bypass (cookie path on unsafe methods), secret leakage (`passwordHash`/`tokenKey` in any response or log other than the dev token logs), SQL injection through identity/email lookups, and the superuser gate covering every management endpoint. Confirm `verified` cannot be set by a client on create/update. Then merge SP5 to `main` as a unit and update the project-status memory.

---

## Self-Review Notes (author)

- **Spec coverage:** transport (bearer+cookie) → Tasks 1,6; CSRF double-submit → Tasks 6,7; identity uniqueness partial indexes → Task 3; force `verified=false` → Task 2 + Task 5; login/refresh/logout → Task 7; verify/reset generated-not-sent → Task 8; superuser gate → Task 9; config (`cookie_secure`, TTLs) → Task 4.
- **Type consistency:** `http.Cookie` fields used identically in `server.zig`, `api/auth.zig`; `auth.authenticate(io, alloc, app, ctx, conn)` signature used in `api/records.zig`, `api/auth.zig` (`authRefresh`), and `api/collections.zig`; `jwt.Claims` field names (`csrf`, `type`, `exp`) match `jwt.zig`.
- **Known follow-ups (out of scope for 5c):** rate-limiting on login/reset; real mailer for verify/reset; reader-connection pooling; `onlyVerified` collection auth option.
