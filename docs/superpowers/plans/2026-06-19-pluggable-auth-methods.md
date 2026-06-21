# Pluggable Auth Methods — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish ZigBase's pluggable-auth foundation — one audited session-issuance seam, a hardened consumer-facing `issueSession`, and a blessed helper surface — so passwordless / magic-link login (the motivating use case) is buildable safely, and so future built-in/custom auth methods plug into the same machinery.

**Architecture:** Every session mint funnels through a single `issueSession()` that signs the native `.auth` JWT (`issue()`) and then fires `emitAuth()` — making it structurally impossible to log a user in without the `onAuth` hook firing (the concrete defect in PR #46). That seam is exposed three ways: a top-level `zigbase.auth.issueSession`, a `RouteEvent.issueSession` convenience, and a curated `zigbase.auth.*` of the token/mail/rate-limit helpers currently private to `api/auth.zig`. This PR (Milestone 1) ships that foundation + magic-link; later milestones add the `AuthMethod` plugin contract, config-driven built-in methods, rpc-client generation, and the OAuth2 refactor.

**Tech Stack:** Zig 0.16.0 (via `mise exec zig@0.16.0`), vendored SQLite amalgamation, `zap`/facil.io HTTP, embedded Preact admin SPA, Python 3.13 + Playwright browser suite.

## Global Constraints

- **Zig version is exact:** build/test only with `mise exec zig@0.16.0 -- zig build ...`. Another 0.16.x is not guaranteed to work.
- **Authoritative test signal:** `zig build test --summary all` prints a spurious `failed command: …` line even on success; the real signal is the `Build Summary: N/N tests passed` line.
- **A new `src/*.zig` file's tests do not run until the file is added to the `test { _ = @import("…"); }` block in `src/root.zig`.**
- **`root.zig` is the public API surface:** any type/function a framework consumer must NAME is re-exported there.
- **Hook record mutations use `ev.arena`, never `ev.app.allocator`** (arena owns the JSON map; mixing allocators is UB). Not central to this PR but holds wherever a hook touches `ev.record`.
- **Safe-by-default is the house style:** new gates fail closed; opt-outs (e.g. disabling a rate limit) are logged like `@public` rules.
- **Docs sync is mandatory:** `docs/*.md` has a published mirror under `site/src/content/`. Any doc change updates both. Build the site with `cd site && npm run build` when docs change. The PR template carries the checklist.
- **`docs/superpowers/` is a historical archive** — the spec and this plan live there but do **not** rewrite sibling archived files.
- **`gh pr edit` is broken on this repo** — use `gh api -X PATCH` to edit a PR.
- **Local plain-HTTP dev needs `--insecure-cookies`** or the auth cookie isn't stored (cookies are `Secure` by default).

**Reference spec:** `docs/superpowers/specs/2026-06-19-pluggable-auth-methods-design.md` (Approach A, three tiers on one seam). This plan implements **Milestone 1** in full; Milestones 2–4 are roadmapped at the end for follow-up plans.

---

## File map (Milestone 1)

- **Modify `src/api/auth.zig`** — make `issueSession` the single mint+emit seam (currently `emitAuth` is called by each endpoint separately); have the existing `authWithPassword`/`authRefresh` route session minting through it; add a `method`-tagged emit.
- **Modify `src/events.zig`** — generalize `AuthMethod` enum (`password`, `oauth2` → add `magic_link`, `custom`) and the `AuthEvent` it tags; keep `password`/`oauth2` variants stable.
- **Create `src/auth_helpers.zig`** — the consumer-facing `zigbase.auth` namespace: `issueSession`, `mintLinkToken`, `verifyLinkToken`, `consumeLinkToken`, `deliverAuthMail`, `rateLimit`, the `RateLimitFn` type, and `Issued`/`LinkToken` result types. Thin wrappers over the now-not-private `api/auth.zig` internals, each taking an explicit connection.
- **Modify `src/events.zig` (RouteEvent)** — add `RouteEvent.issueSession(collection, record_id) !Issued` convenience that acquires/uses the writer and routes through the seam + emit.
- **Modify `src/root.zig`** — re-export `pub const auth = @import("auth_helpers.zig")`; add `auth_helpers` to the test-root `@import` block.
- **Modify `src/api/oauth.zig`** — route its session mint through the same `issueSession` seam (so OAuth2 keeps emitting `onAuth` after the refactor; no behavior change).
- **Create `examples/.../magic_link` recipe** (smallest viable: a doc recipe + a Zig snippet in `docs/recipes.md`, no new example app unless trivial).
- **Modify docs:** `docs/framework.md` (§6 auth events + a new "custom auth flows" subsection), `docs/recipes.md` (magic-link recipe), `docs/api.md` (note the seam guarantee), and the `site/src/content/` mirrors of each. `CHANGELOG.md` + `site/src/content/docs/changelog.md` `[Unreleased]`.

---

## Task 1: Make `issueSession` the single mint+emit seam

**Files:**
- Modify: `src/api/auth.zig` (the `issue`/`emitAuth` region ~92–172, and `authWithPassword`/`authRefresh`)
- Test: `src/api/auth.zig` (in-file `test {}` block)

**Interfaces:**
- Consumes: existing `issue(ctx, conn, collection, rid, token_key) !Issued`, `tokenKeyFor`, `collections.get`, `emitAuth(ctx, collection, record, method)`, `records.get`.
- Produces: `issueSession(ctx, conn, collection, record_id, method: events.AuthMethod) !Issued` — resolves table + tokenKey, calls `issue()`, loads the record, calls `emitAuth(...)` with the given `method`, returns `Issued`. **This is the only function that mints + emits.** `authWithPassword`/`authRefresh` call it instead of calling `issue()` + `emitAuth()` separately.

- [ ] **Step 1: Write the failing test** — a successful password login still emits `onAuth` exactly once, now via the seam. Add to the test block in `src/api/auth.zig`:

```zig
test "issueSession is the mint+emit seam: emits onAuth once with the method tag" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "seam@x.io", "longenough");

    // Install a counting onAuth handler on the test app's dispatch.
    const Counter = struct {
        var seen: usize = 0;
        var last_method: events.AuthMethod = .oauth2;
        fn onAuth(ev: *events.AuthEvent) void { seen += 1; last_method = ev.method; }
    };
    Counter.seen = 0;
    var disp = events.Dispatch{ .on_auth = Counter.onAuth };
    env.app.dispatch = &disp;

    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var login = env.ctx(a, .POST, "{\"identity\":\"seam@x.io\",\"password\":\"longenough\"}", &p);
    const res = try authWithPassword(&login);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqual(@as(usize, 1), Counter.seen);
    try std.testing.expectEqual(events.AuthMethod.password, Counter.last_method);
}
```

> Note for the implementer: confirm the real field/handler names by reading `src/events.zig` (`Dispatch`, `on_auth`, `AuthEvent`, `AuthHandler`) and `src/app.zig` (`App.dispatch` type — it is `?*Dispatch` or similar). Adjust the handler installation to match. The behavior under test (one emit, correct tag) is the invariant.

- [ ] **Step 2: Run the test, verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -8`
Expected: FAIL — `issueSession` arity/signature mismatch (it currently takes no `method`) or emit-count assertion fails. Confirm via the `Build Summary` line showing a failure.

- [ ] **Step 3: Implement the seam.** Replace the PR #46-style `issueSession` (if present) and refactor:

```zig
/// THE session seam: resolve a collection's table + the record's tokenKey, sign a
/// native `.auth` session via `issue()`, then fire `emitAuth(method)`. Every login —
/// password, refresh, magic-link, custom route — mints through here, so `onAuth`
/// ALWAYS fires. `conn` is the caller's already-acquired connection.
pub fn issueSession(
    ctx: *http.RequestCtx,
    conn: *db.Db,
    collection: []const u8,
    record_id: []const u8,
    method: events.AuthMethod,
) !Issued {
    const col = (try collections.get(ctx.allocator, conn, collection)) orelse return error.NotFound;
    if (col.type != .auth) return error.NotFound;
    const tk = (try tokenKeyFor(ctx.allocator, conn, col.name, record_id)) orelse return error.NotFound;
    const issued = try issue(ctx, conn, col.name, record_id, tk);
    const rec = try records.get(ctx.allocator, conn, col, record_id); // ?std.json.Value
    emitAuth(ctx, col.name, rec, method);
    return issued;
}
```

Then in `authWithPassword`, replace the `issue(...)` + `records.get(...)` + `emitAuth(...)` trio (lines ~159–165) with a single `issueSession(ctx, &r, col.name, rid, .password)` call, building the JSON response from `issued` + a re-read record. In `authRefresh`, replace its `issue(...)` + `emitAuth(...)` (lines ~187–188) with `issueSession(ctx, w, col_name, rid, .password)`.

> Keep `issue()` `pub` and unchanged (it is the pure signer). The seam wraps it.

- [ ] **Step 4: Run tests, verify pass**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -8`
Expected: PASS — `Build Summary: N/N tests passed`. The pre-existing auth tests (`auth-with-password issues a token…`, `…round-trips…`) still pass.

- [ ] **Step 5: Commit**

```bash
git add src/api/auth.zig
git commit -m "refactor(auth): funnel session minting through a single issueSession+emitAuth seam"
```

---

## Task 2: Generalize the `onAuth` method tag

**Files:**
- Modify: `src/events.zig` (the `AuthMethod` enum + any exhaustive switches on it)
- Test: `src/events.zig` (in-file `test {}` block) or `src/api/auth.zig`

**Interfaces:**
- Consumes: existing `events.AuthMethod` enum `{ password, oauth2 }`.
- Produces: `events.AuthMethod = enum { password, oauth2, magic_link, custom }`. Existing variants keep their names/positions. Any `switch` over `AuthMethod` in the codebase gains the new prongs (search first).

- [ ] **Step 1: Find every switch on `AuthMethod`**

Run: `grep -rn "AuthMethod\|\.password\b\|\.oauth2\b" src/ | grep -i "switch\|method" | head -30`
Read each hit; note which need new prongs. (Expected: serialization of the method tag, if any, e.g. in `emitAuth` callers or a `@tagName` use — `@tagName` needs no change.)

- [ ] **Step 2: Write the failing test** — the enum carries the new tags:

```zig
test "AuthMethod enumerates magic_link and custom" {
    try std.testing.expectEqualStrings("magic_link", @tagName(AuthMethod.magic_link));
    try std.testing.expectEqualStrings("custom", @tagName(AuthMethod.custom));
}
```

- [ ] **Step 3: Run the test, verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -8`
Expected: FAIL — `magic_link`/`custom` are not members of `AuthMethod`.

- [ ] **Step 4: Add the variants** and patch any non-exhaustive switch found in Step 1:

```zig
pub const AuthMethod = enum { password, oauth2, magic_link, custom };
```

- [ ] **Step 5: Run tests, verify pass**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -8`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/events.zig
git commit -m "feat(events): add magic_link and custom AuthMethod tags for onAuth"
```

---

## Task 3: Curated consumer-facing `zigbase.auth` helper surface

**Files:**
- Create: `src/auth_helpers.zig`
- Modify: `src/root.zig` (re-export + test-root import)
- Test: `src/auth_helpers.zig` (in-file `test {}` block)

**Interfaces:**
- Consumes: `api/auth.zig`'s now-reachable `issueSession`, `mintToken`, `consumeToken`, `verifyTyped`, `deliverToken` (make these `pub` if not already), `Issued`, and `jwt.TokenType`/`jwt.Claims`. `db.Db`, `http.RequestCtx`.
- Produces, under `zigbase.auth`:
  - `pub const Issued = api_auth.Issued;`
  - `pub fn issueSession(ctx, conn, collection, record_id) !Issued` — magic-link/custom default tag `.custom`. (Thin wrapper calling `api_auth.issueSession(..., .custom)`.)
  - `pub const LinkToken = struct { token: []const u8 };`
  - `pub fn mintLinkToken(ctx, conn, collection, record_id, ttl_s: i64) !LinkToken` — wraps `mintToken(..., .verification, ttl)` semantics with a fresh `jti` (single-use). (A magic-link is a verification-class single-use token.)
  - `pub fn verifyLinkToken(ctx, conn, collection, token) !?jwt.Claims` — wraps `verifyTyped(..., .verification)`.
  - `pub fn consumeLinkToken(conn, claims) !void` — wraps `consumeToken` (records `jti` in `_consumedTokens`; `error.AlreadyConsumed` on replay).
  - `pub fn deliverAuthMail(app, alloc, to, subject, body) !void` — wraps `deliverToken`.
  - `pub const RateLimitFn = *const fn (ctx: *http.RequestCtx, scope: []const u8, ident: []const u8) bool;`
  - `pub fn rateLimit(ctx, scope, ident) !?http.Response` — wraps the existing `rateLimited` (returns a 429 Response when limited, else null).

- [ ] **Step 1: Make the `api/auth.zig` internals reachable.** In `src/api/auth.zig`, change `fn mintToken` → `pub fn mintToken`, `fn consumeToken` → `pub fn consumeToken`, `fn verifyTyped` → `pub fn verifyTyped`, `fn deliverToken` → `pub fn deliverToken`, `fn rateLimited` → `pub fn rateLimited`. (`issueSession`, `issue`, `tokenKeyFor`, `Issued` are already `pub` after Task 1.) Build to confirm no breakage:

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -6`
Expected: PASS (visibility widening only).

- [ ] **Step 2: Write the failing test** — a consumer can mint, deliver-free, verify, consume, and a replay is rejected; then issueSession mints a session. Put in `src/auth_helpers.zig`:

```zig
const std = @import("std");
const auth = @import("auth_helpers.zig");
// Reuse the api/auth.zig TestEnv via a thin local harness OR a memory DB.
// Minimal end-to-end: mint a link token for a user, verify it, consume it, replay fails.

test "magic-link helpers: mint → verify → consume; replay rejected" {
    var h = try @import("api/auth.zig").TestEnv.initAuth("members"); // requires TestEnv be pub
    defer h.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try h.createUser(a, "members", "m@x.io", "longenough");

    const w = h.pool.acquireWriter();
    defer h.pool.releaseWriter();
    const col = (try @import("collections.zig").get(a, w, "members")).?;
    const rid = (try @import("api/auth.zig").findByIdentity(a, w, col, "m@x.io")).?; // make findByIdentity pub

    var ctx = h.ctx(a, .POST, "", &[_]@import("http.zig").Param{});
    const lt = try auth.mintLinkToken(&ctx, w, "members", rid, 900);
    const claims = (try auth.verifyLinkToken(&ctx, w, "members", lt.token)).?;
    try auth.consumeLinkToken(w, claims);
    try std.testing.expectError(error.AlreadyConsumed, auth.consumeLinkToken(w, claims));

    const issued = try auth.issueSession(&ctx, w, "members", rid);
    try std.testing.expect(issued.cookies.len == 2);
}
```

> Implementer: this test reaches into `api/auth.zig`'s `TestEnv`, `findByIdentity`, `createUser`. Make `TestEnv`, `findByIdentity` `pub` (or build a small local harness in `auth_helpers.zig` if you prefer not to widen test scaffolding visibility — either is acceptable; prefer the smaller surface). Confirm exact import paths (`@import("collections.zig")` resolves relative to `src/`).

- [ ] **Step 3: Run the test, verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -8`
Expected: FAIL — `auth_helpers.zig` not yet imported by root / functions undefined.

- [ ] **Step 4: Implement `src/auth_helpers.zig`** with the wrappers from Interfaces above. Each is 2–6 lines delegating to `api/auth.zig`. Example:

```zig
const std = @import("std");
const http = @import("http.zig");
const db = @import("db.zig");
const jwt = @import("jwt.zig");
const api_auth = @import("api/auth.zig");
const events = @import("events.zig");

pub const Issued = api_auth.Issued;
pub const RateLimitFn = *const fn (ctx: *http.RequestCtx, scope: []const u8, ident: []const u8) bool;
pub const LinkToken = struct { token: []const u8 };

pub fn issueSession(ctx: *http.RequestCtx, conn: *db.Db, collection: []const u8, record_id: []const u8) !Issued {
    return api_auth.issueSession(ctx, conn, collection, record_id, .custom);
}

pub fn mintLinkToken(ctx: *http.RequestCtx, conn: *db.Db, collection: []const u8, record_id: []const u8, ttl_s: i64) !LinkToken {
    const tk = (try api_auth.tokenKeyFor(ctx.allocator, conn, collection, record_id)) orelse return error.NotFound;
    const token = try api_auth.mintToken(ctx, conn, collection, record_id, tk, .verification, ttl_s);
    return .{ .token = token };
}

pub fn verifyLinkToken(ctx: *http.RequestCtx, conn: *db.Db, collection: []const u8, token: []const u8) !?jwt.Claims {
    const col = (try @import("collections.zig").get(ctx.allocator, conn, collection)) orelse return null;
    return api_auth.verifyTyped(ctx, conn, col, token, .verification);
}

pub fn consumeLinkToken(conn: *db.Db, claims: jwt.Claims) !void {
    return api_auth.consumeToken(conn, claims);
}

pub fn deliverAuthMail(app: anytype, alloc: std.mem.Allocator, to: []const u8, subject: []const u8, body: []const u8) !void {
    return api_auth.deliverToken(app, alloc, to, subject, body);
}

pub fn rateLimit(ctx: *http.RequestCtx, scope: []const u8, ident: []const u8) !?http.Response {
    return api_auth.rateLimited(ctx, scope, ident);
}
```

> `verifyTyped`/`mintToken` take a `schema.Collection` vs a name in places — read their exact signatures in `api/auth.zig` and match. `deliverToken`'s first param is `*app.App`; keep `anytype` or import the concrete type.

- [ ] **Step 5: Wire into `root.zig`** — add the re-export and the test import:

```zig
// public surface
pub const auth = @import("auth_helpers.zig");
// inside the test { } block:
test { _ = @import("auth_helpers.zig"); }
```

- [ ] **Step 6: Run tests, verify pass**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -8`
Expected: PASS — including the new `auth_helpers` test.

- [ ] **Step 7: Commit**

```bash
git add src/auth_helpers.zig src/root.zig src/api/auth.zig
git commit -m "feat(auth): expose curated zigbase.auth helper surface (issueSession, link tokens, rate-limit)"
```

---

## Task 4: `RouteEvent.issueSession` convenience + two-layer rate-limit override type

**Files:**
- Modify: `src/events.zig` (`RouteEvent` struct — add `issueSession` method; it already has `writer()`/`reader()`)
- Test: `src/events.zig` or `src/api/auth.zig` (needs a `RouteEvent` + app; reuse `TestEnv`)

**Interfaces:**
- Consumes: `RouteEvent.app`, `RouteEvent.ctx`, `auth_helpers.issueSession`, the writer accessor.
- Produces: `pub fn issueSession(ev: *RouteEvent, collection: []const u8, record_id: []const u8) !auth_helpers.Issued` — acquires the writer, mints through the seam (tag `.custom`), releases the writer, returns `Issued` (caller sets the cookies on its `http.Response`). Also `pub const RateLimitFn = auth_helpers.RateLimitFn;` re-exported on the events namespace for config use.

- [ ] **Step 1: Write the failing test** — a route can mint a session for a known record and the returned `Issued` carries both cookies + fires onAuth:

```zig
test "RouteEvent.issueSession mints a session and fires onAuth(custom)" {
    var env = try TestEnv.initAuth("members");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "members", "r@x.io", "longenough");
    // resolve rid
    const w0 = env.pool.acquireWriter();
    const col = (try @import("../collections.zig").get(a, w0, "members")).?;
    const rid = (try findByIdentity(a, w0, col, "r@x.io")).?;
    env.pool.releaseWriter();

    const Counter = struct { var seen: usize = 0; var m: events.AuthMethod = .password;
        fn h(ev: *events.AuthEvent) void { seen += 1; m = ev.method; } };
    Counter.seen = 0;
    var disp = events.Dispatch{ .on_auth = Counter.h };
    env.app.dispatch = &disp;

    var rctx = ...; // build a RouteEvent over env.app + a RequestCtx (see events.zig RouteEvent fields)
    const issued = try rctx.issueSession("members", rid);
    try std.testing.expectEqual(@as(usize, 2), issued.cookies.len);
    try std.testing.expectEqual(@as(usize, 1), Counter.seen);
    try std.testing.expectEqual(events.AuthMethod.custom, Counter.m);
}
```

> Implementer: read `RouteEvent`'s real fields in `src/events.zig` to construct one in the test (it carries `app`, `ctx`, `rctx`). Mirror how existing `events.zig`/route tests build a `RouteEvent`, if any; otherwise construct the struct literal directly. The asserted invariant (2 cookies, 1 emit, `.custom` tag) is what matters.

- [ ] **Step 2: Run, verify fail**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -8`
Expected: FAIL — `issueSession` not a member of `RouteEvent`.

- [ ] **Step 3: Implement** on `RouteEvent`:

```zig
pub fn issueSession(ev: *RouteEvent, collection: []const u8, record_id: []const u8) !@import("auth_helpers.zig").Issued {
    var w = ev.writer();
    defer w.deinit();
    return @import("auth_helpers.zig").issueSession(ev.ctx, w.conn(), collection, record_id);
}
pub const RateLimitFn = @import("auth_helpers.zig").RateLimitFn;
```

> Match `WriterData`'s accessor for the underlying `*db.Db` (read `events.zig`: it may be `w.db` / `w.conn()` / `w.data()` internals). The wrapper exists so a consumer never hand-acquires the writer for the common case.

- [ ] **Step 4: Run tests, verify pass**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -8`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/events.zig
git commit -m "feat(events): RouteEvent.issueSession convenience for custom auth flows"
```

---

## Task 5: OAuth2 routes through the seam (no behavior change, preserves the invariant)

**Files:**
- Modify: `src/api/oauth.zig` (`authWithOAuth2` — replace its `issue()`+`emitAuth(.oauth2)` with `issueSession(..., .oauth2)`)
- Test: existing oauth tests must still pass; add an emit-count assertion if oauth has a unit test harness.

**Interfaces:**
- Consumes: `api_auth.issueSession(ctx, conn, collection, rid, .oauth2)`.
- Produces: no new public surface; OAuth2 logins keep emitting `onAuth(.oauth2)` — now via the one seam, so the guarantee holds uniformly.

- [ ] **Step 1: Read `src/api/oauth.zig`** and locate where it currently calls `auth.issue(...)` and `auth.emitAuth(..., .oauth2)`. Note the connection it holds (writer).

- [ ] **Step 2: If oauth.zig has a unit-test harness, add a failing emit-count test** mirroring Task 1's counter (one emit, `.oauth2`). If oauth is covered only by the Playwright suite, skip the unit test and rely on Step 4's behavior assertion + the browser suite.

- [ ] **Step 3: Replace** the mint+emit pair in `authWithOAuth2` with a single `issueSession(ctx, w, col.name, rid, .oauth2)` call; build response from the returned `Issued`.

- [ ] **Step 4: Run unit tests + the oauth browser test**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -8`
Then (if present): `mise exec python@3.13 -- python -m pytest tests/admin -k oauth -q 2>&1 | tail -15`
Expected: PASS both. (No behavior change intended.)

- [ ] **Step 5: Commit**

```bash
git add src/api/oauth.zig
git commit -m "refactor(oauth): mint sessions through the shared issueSession seam"
```

---

## Task 6: Docs — magic-link recipe + custom-auth-flow section + seam guarantee

**Files:**
- Modify: `docs/framework.md` (§6 region — add a "Custom auth flows" subsection documenting `zigbase.auth.issueSession`, `ev.issueSession`, the link-token helpers, and the seam/`onAuth` guarantee)
- Modify: `docs/recipes.md` (add a complete magic-link recipe: a request route that mints+mails a link token, a confirm route that verifies+consumes+`issueSession`)
- Modify: `docs/api.md` (note that all logins fire `onAuth`)
- Mirror each into `site/src/content/...` (the published copies)
- Modify: `CHANGELOG.md` + `site/src/content/docs/changelog.md` `[Unreleased]`

**Interfaces:** none (docs only). The recipe code must compile-match the APIs from Tasks 3–4.

- [ ] **Step 1: Write the magic-link recipe** in `docs/recipes.md` — two custom routes (`.auth = .public`), e.g.:

```zig
// POST /api/members/magic/request  { "email": "..." }  → 204 (always, no enumeration)
fn magicRequest(ev: *zigbase.RouteEvent) anyerror!zigbase.http.Response {
    const email = /* parse ev.ctx.body */;
    if (try ev.app... rate-limit via zigbase.auth.rateLimit) |resp| return resp;
    var w = ev.writer(); defer w.deinit();
    // resolve record by email; if found, mint + mail a link token:
    //   const lt = try zigbase.auth.mintLinkToken(ev.ctx, w.conn(), "members", rid, 900);
    //   try zigbase.auth.deliverAuthMail(ev.app, ev.ctx.allocator, email, "Your sign-in link", body);
    return .{ .status = 204, .body = "" };
}
// POST /api/members/magic/confirm  { "token": "..." } → 200 + cookies
fn magicConfirm(ev: *zigbase.RouteEvent) anyerror!zigbase.http.Response {
    const token = /* parse */;
    var w = ev.writer(); defer w.deinit();
    const claims = (try zigbase.auth.verifyLinkToken(ev.ctx, w.conn(), "members", token))
        orelse return .{ .status = 400, .body = "{\"message\":\"Invalid or expired link.\"}" };
    zigbase.auth.consumeLinkToken(w.conn(), claims) catch
        return .{ .status = 400, .body = "{\"message\":\"Link already used.\"}" };
    const issued = try ev.issueSession("members", claims.id);
    return .{ .status = 200, .body = "{\"ok\":true}", .cookies = &issued.cookies };
}
```

Flesh out the body parsing to real, compiling code (mirror the body-parse pattern from existing recipes). The recipe MUST state: link is single-use (replay → 400), `onAuth` fires on confirm, and the request route is enumeration-safe (always 204).

- [ ] **Step 2: Add the framework.md "Custom auth flows" subsection** documenting the `zigbase.auth` surface and the seam guarantee ("every login, including custom flows via `ev.issueSession`, fires your `onAuth` handler — there is no way to mint a session that bypasses it").

- [ ] **Step 3: Mirror to `site/src/content/`** (find the corresponding files: `site/src/content/docs/framework.*`, `recipes.*`, `api.*`) and update them identically.

- [ ] **Step 4: Add a CHANGELOG `[Unreleased]` entry** in both `CHANGELOG.md` and `site/src/content/docs/changelog.md`:

```
### Added
- `zigbase.auth` consumer surface for custom auth flows: `issueSession` (also `RouteEvent.issueSession`), single-use magic-link tokens (`mintLinkToken`/`verifyLinkToken`/`consumeLinkToken`), `deliverAuthMail`, and `rateLimit`. All session minting now funnels through one seam that always fires `onAuth`.
### Changed
- Session issuance (password, refresh, OAuth2) routes through a single `issueSession`+`emitAuth` seam — custom routes can no longer mint a session that skips the `onAuth` hook.
```

- [ ] **Step 5: Build the site to verify docs compile**

Run: `cd site && /home/valthon/.local/bin/mise exec node@24 -- npm run build 2>&1 | tail -15`
Expected: build succeeds (no broken-link/frontmatter errors).

- [ ] **Step 6: Commit**

```bash
git add docs/ site/ CHANGELOG.md
git commit -m "docs(auth): magic-link recipe + custom-auth-flow surface + onAuth seam guarantee"
```

---

## Task 7: Full-suite verification + PR

**Files:** none (verification + PR).

- [ ] **Step 1: Run the full Zig unit suite**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -10`
Expected: `Build Summary: N/N tests passed` (no failures).

- [ ] **Step 2: Build the binary + run the relevant browser tests** (auth + any login-touching flows):

```bash
mise exec zig@0.16.0 -- zig build 2>&1 | tail -5
mise exec python@3.13 -- python -m pytest tests/admin -k "auth or login" -q 2>&1 | tail -20
```
Expected: binary builds; selected browser tests pass. (Unit-green ≠ browser-green — this step is mandatory per CLAUDE.md.)

- [ ] **Step 3: Build the example apps** that CI builds (they are consumers of the public surface):

```bash
for ex in examples/blog examples/golfsim examples/plugins; do
  echo "== $ex =="; (cd "$ex" && /home/valthon/.local/bin/mise exec zig@0.16.0 -- zig build 2>&1 | tail -3)
done
```
Expected: all build (golfsim/plugins may need their frontend `dist` — follow each example's README if a frontend build is required first).

- [ ] **Step 4: Push the branch and open the PR**

```bash
git push -u origin worktree-pluggable-auth-design
gh pr create --title "feat(auth): pluggable-auth foundation — one session seam + magic-link helpers (supersedes #46)" \
  --body "$(cat <<'EOF'
## What
Milestone 1 of the pluggable-auth design (spec: docs/superpowers/specs/2026-06-19-pluggable-auth-methods-design.md). Funnels all session minting through one `issueSession`+`emitAuth` seam, exposes a curated `zigbase.auth` surface (`issueSession`, single-use magic-link tokens, mailer + rate-limit helpers) and `RouteEvent.issueSession`, and ships a magic-link recipe.

## Why
PR #46 exported a bare `issueSession` that silently bypassed the `onAuth` hook and forced consumers to re-implement token/replay/mailer/rate-limit machinery the framework already had privately. This makes the safe machinery reachable and makes bypassing `onAuth` structurally impossible.

## Supersedes
#46 — credited; its mechanism is replaced by `ev.issueSession` (routes through the seam + emits `onAuth`).

## Follow-ups (later milestones, per the spec §15)
- `AuthMethod` plugin contract + config-driven built-in methods + auto-mounted `auth/<slug>/...` endpoints
- rpc-client generation for auth endpoints
- OAuth2 fully refactored onto the contract; OTP; WebAuthn

## Testing
- `zig build test` — green
- `tests/admin` auth/login browser tests — green
- example apps build
EOF
)"
```

- [ ] **Step 5: Link/close PR #46 relationship** — add a comment on #46 noting supersession (do not auto-close; leave for the maintainer):

```bash
gh pr comment 46 --body "Superseded by the pluggable-auth foundation PR (one session seam + \`ev.issueSession\` that, unlike this PR's bare export, routes through \`emitAuth\` so \`onAuth\` always fires). Crediting this PR in the design (docs/superpowers/specs/2026-06-19-pluggable-auth-methods-design.md §13)."
```

---

## Roadmap — Milestones 2–4 (separate follow-up plans, NOT executed in this PR)

These are the remaining spec phases. Each warrants its own `writing-plans` pass + PR.

- **Milestone 2 — `AuthMethod` plugin contract.** The comptime `AuthMethod` struct (`initiate`/`complete` vtable), `AuthCtx` (blessed helpers bound to a connection), comptime plugin-contract validation (mirroring `assertPluginContract` for storage/mailer), and **route auto-mounting** at `/api/collections/:col/auth/<slug>/{initiate,complete}` for every collection that enables a method. Re-express **password** as the first built-in `AuthMethod` to prove the contract. Two-layer rate-limit applied around each phase (simple `.rate_limit` config + `RateLimitFn` override). Config: `.auth.methods` struct-literal per collection; `.auth_methods` App-level custom types.
- **Milestone 3 — built-in `magic_link` + `otp` methods on the contract**, plus **rpc-client generation** so `zb.auth.<method>.initiate/complete(...)` appear in the typed TS client (typed `Initiate`/`Complete` I/O structs; extend the comptime generator that today only sees `.routes`).
- **Milestone 4 — OAuth2 refactored onto the contract** (the proof obligation; `state` moves into a TTL'd `ChallengeStore` table) and **WebAuthn** as a separate effort (needs `ChallengeStore` + consumer-owned credential collection). Add twitter/linkedin presets to `oauth/providers.zig`.

---

## Self-Review

**Spec coverage (Milestone 1 scope):**
- Spec §4 core seam (`issueSession`=`issue`+`emitAuth`) → Task 1. ✓
- Spec §10 `onAuth` method tagging → Task 2. ✓
- Spec §4 Tier 3 hardened escape hatch (`ev.issueSession`, `zigbase.auth.issueSession`) → Tasks 3, 4. ✓
- Spec §1/§11 blessed helpers (mint/consume/verify/mail/rate-limit no longer private) → Task 3. ✓
- Spec §14 rate-limit override function type (`RateLimitFn`) → Task 3 (type) + Task 4 (re-export); full around-the-endpoint application deferred to Milestone 2 (no auto-mounted endpoints exist yet in M1). ✓ (scoped)
- Spec §9 OAuth2 keeps emitting via the seam → Task 5. ✓
- Spec §13 PR #46 disposition → Task 7 Step 5. ✓
- Docs sync (CLAUDE.md) → Task 6. ✓
- **Deferred by design (roadmap):** §4 Tier 1 config methods, §4 Tier 2 contract, §6 auto-mount, §8 WebAuthn/ChallengeStore, §14 rpc inclusion. Clearly roadmapped, not silently dropped.

**Placeholder scan:** Task code steps carry real Zig; the few `/* parse */` markers in Task 6's recipe are flagged as "flesh out to compiling code" with a named pattern to mirror — acceptable for a docs recipe, not a build-blocking task. No `TODO`/`TBD` in executable tasks.

**Type consistency:** `Issued` (from `api/auth.zig`, re-exported via `auth_helpers`) used consistently across Tasks 1/3/4. `events.AuthMethod` variants (`password`/`oauth2`/`magic_link`/`custom`) consistent across Tasks 1/2/4/5. `issueSession` arity: `api_auth.issueSession(ctx, conn, collection, record_id, method)` (5 args) vs the consumer `auth_helpers.issueSession(ctx, conn, collection, record_id)` (4 args, hardcodes `.custom`) and `RouteEvent.issueSession(collection, record_id)` (2 args, hardcodes writer + `.custom`) — intentional and documented in each task's Interfaces.

**Known soft spots the executing subagents must resolve against the compiler (ground truth):** exact `Dispatch`/`on_auth`/`App.dispatch` field names (Task 1/4 tests), exact signatures of `mintToken`/`verifyTyped`/`deliverToken` (name vs `schema.Collection` args — Task 3), and `WriterData`'s `*db.Db` accessor (Task 4). Each task instructs the implementer to read the real source first.
