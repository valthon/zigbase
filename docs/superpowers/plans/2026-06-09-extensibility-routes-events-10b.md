# Extensibility — Custom Routes & Events (10b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let consumers register custom HTTP routes (`fn(*RouteEvent) !Response`, comptime, with declarative `.public`/`.authed`/`.superuser` gating) and subscribe to auth/file/lifecycle events — extending the 10a event bus to request-time extensibility — without changing default behavior.

**Architecture:** `App(cfg)` gains `.routes`, `.onAuth`, `.onFileServe`, `.onFileUpload`, `.onBootstrap`/`.onBeforeServe`/`.onBeforeTerminate`. The comptime builder assembles a runtime route table (`[]const RuntimeRoute`) and single event handlers onto `events.Dispatch`. `server.zig` dispatches custom routes AFTER the built-in router (built-ins win) and AFTER resolving auth, enforcing the route's auth level before the handler runs. Auth/file/lifecycle emit points are added at the existing success sites.

**Tech Stack:** Zig 0.16 (`mise exec zig@0.16.0 -- zig …`), zap (HTTP), `std.json`. Browser tests via `mise exec python@3.13 -- python -m pytest` (Playwright). The example app's `build.zig` (path dep) is the consumer-side integration proof.

**Build/test rule (every task):** Run BOTH `mise exec zig@0.16.0 -- zig build` AND `mise exec zig@0.16.0 -- zig build test --summary all`. Current baseline on branch `extensibility-framework`: **220 Zig tests**, binary EXIT 0, **10 Playwright tests**, `examples/blog` builds. All must stay green; default behavior (no routes/handlers configured) must be byte-for-byte unchanged.

**Prerequisite:** Plan 10a (Framework Core) is complete on this branch. Key existing surfaces (verbatim):
- `events.Dispatch = struct { record: ?RecordHandler = null, on_error: ?ErrorHandler = null }` — extended here.
- `framework.App(comptime cfg)` builds `dispatch` and validates top-level cfg keys (`hooks`/`onError`) via `@compileError` — extended here.
- `server.zig onRequest`: after the `/_/` admin check, calls `router.dispatch(&routes, &ctx)` which returns a 404 envelope when nothing matches. `routes` is a static built-in table.
- `router.zig`: `matchPath(alloc, pattern, path) !?[]http.Param` and `dispatch(routes, ctx) !Response` (404 on no match).
- `http.RequestCtx { method, path, query, body, allocator, app, params, authorization, cookie_header, csrf_token, content_type, form_fields, files }`; `http.Response`; `http.Handler = *const fn(*RequestCtx) anyerror!Response`.
- `auth.authenticate(io, alloc, app, ctx, conn) !?Authed` where `Authed { record: std.json.Value, collection: []const u8, is_superuser: bool }`.
- `request.RequestContext { auth: ?std.json.Value, is_superuser: bool, data: ?std.json.Value, method: []const u8 }`.
- Auth success sites: `api/auth.zig` `authWithPassword` (`col.name`, `rid`, `rec`) and `authRefresh` (`col_name`, `rid`, `authed.record`); `api/oauth.zig` `respondSession(ctx, conn, col, rid, is_new)`.
- File sites: `api/files.zig` `serve(ctx)` (params `col`/`rec`/`name`); `api/records.zig` `writeUploads(ctx, col, record_id, writes, deletes)`.
- Lifecycle site: `framework.zig serveImpl` (migrations run, then `srv.listen()`).

---

## File Structure

| File | Responsibility |
|---|---|
| `src/events.zig` (MOD) | Add `RouteEvent`, `AuthEvent`, `FileEvent`, `LifecycleEvent`, the `AuthLevel` enum, `RuntimeRoute`, handler typedefs, and the extended `Dispatch` (routes + auth/file/lifecycle handlers). Add `buildRoutes(comptime routes)` comptime assembler. |
| `src/framework.zig` (MOD) | `App(cfg)`: build routes + auth/file/lifecycle handlers onto `dispatch`; extend the top-level cfg-key whitelist; emit lifecycle events in `serveImpl`. |
| `src/router.zig` (MOD) | Add `tryDispatch(routes, ctx) !?Response` (null on no-match) so built-ins can be tried first, then custom routes, then a single 404. |
| `src/server.zig` (MOD) | `onRequest`: built-in `tryDispatch` → custom-route dispatch (auth-gated) → 404. Add `dispatchCustom`. |
| `src/api/auth.zig` (MOD) | Emit `auth.afterAuthSuccess` at the password + refresh success sites. |
| `src/api/oauth.zig` (MOD) | Emit `auth.afterAuthSuccess` in `respondSession`. |
| `src/api/files.zig` (MOD) | Emit `file.beforeServe` (can deny → 404) in `serve`. |
| `src/api/records.zig` (MOD) | Emit `file.afterUpload` after `writeUploads` succeeds. |
| `examples/blog/src/main.zig` (MOD) | Add a custom `GET /api/blog/stats` route + an `onAuth` handler. |
| `tests/admin/test_custom_route.py` (NEW) | Playwright e2e: the example's custom route responds end-to-end. |

---

## Task 1: Event payloads, route types, and the extended `Dispatch`

Define the new event payloads + route runtime type + handler typedefs, extend `Dispatch`, and add `buildRoutes`. Pure types + a comptime assembler with unit tests.

**Files:** Modify `src/events.zig`; Test: in `src/events.zig`.

- [ ] **Step 1: Write failing tests for `buildRoutes` and the AuthLevel mapping**

Add to `src/events.zig` (tests section):
```zig
test "buildRoutes assembles a runtime route table preserving order, method, pattern, auth" {
    const H = struct {
        fn a(ev: *RouteEvent) anyerror!@import("http.zig").Response { _ = ev; return .{ .status = 200, .body = "a" }; }
        fn b(ev: *RouteEvent) anyerror!@import("http.zig").Response { _ = ev; return .{ .status = 200, .body = "b" }; }
    };
    const table = buildRoutes(.{
        .{ .method = .GET, .path = "/api/x", .handler = H.a, .auth = .public },
        .{ .method = .POST, .path = "/api/y", .handler = H.b, .auth = .superuser },
    });
    try std.testing.expectEqual(@as(usize, 2), table.len);
    try std.testing.expect(table[0].method == .GET);
    try std.testing.expectEqualStrings("/api/x", table[0].pattern);
    try std.testing.expect(table[0].auth == .public);
    try std.testing.expect(table[1].method == .POST);
    try std.testing.expect(table[1].auth == .superuser);
}

test "buildRoutes defaults auth to .superuser when omitted" {
    const H = struct {
        fn a(ev: *RouteEvent) anyerror!@import("http.zig").Response { _ = ev; return .{ .status = 200, .body = "a" }; }
    };
    const table = buildRoutes(.{
        .{ .method = .GET, .path = "/api/secret", .handler = H.a },
    });
    try std.testing.expect(table[0].auth == .superuser);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | head -20`
Expected: FAIL — `buildRoutes`/`RouteEvent` undefined.

- [ ] **Step 3: Implement the types + `buildRoutes`**

Add to `src/events.zig` (near the other public decls; `http` import at top: `const http = @import("http.zig");`):
```zig
pub const AuthLevel = enum { public, authed, superuser };

pub const RouteEvent = struct {
    app: *App,
    ctx: *http.RequestCtx,
    /// Resolved request/auth context (auth identity, is_superuser, method). Built by
    /// the framework before the handler runs; `.public` routes still get it (anonymous).
    rctx: request.RequestContext,
};

pub const RouteHandler = *const fn (ev: *RouteEvent) anyerror!http.Response;

/// A custom route after comptime assembly. The framework matches `method`+`pattern`
/// (reusing router.matchPath), enforces `auth`, then calls `handler`.
pub const RuntimeRoute = struct {
    method: http.Method,
    pattern: []const u8,
    handler: RouteHandler,
    auth: AuthLevel,
};

pub const AuthEvent = struct {
    app: *App,
    ctx: *const request.RequestContext,
    collection: []const u8,
    record: ?std.json.Value,
    method: enum { password, oauth2 },
};
pub const AuthHandler = *const fn (ev: *AuthEvent) void;

pub const FileEvent = struct {
    app: *App,
    ctx: *const request.RequestContext,
    collection: []const u8,
    record_id: []const u8,
    filename: []const u8,
};
/// beforeServe handlers may return error to deny (framework maps to 404); afterUpload errors route to the backstop.
pub const FileServeHandler = *const fn (ev: *FileEvent) anyerror!void;
pub const FileUploadHandler = *const fn (ev: *FileEvent) void;

pub const LifecycleEvent = struct { app: *App };
pub const LifecycleHandler = *const fn (ev: *LifecycleEvent) void;

/// Assemble a comptime tuple of route specs into a runtime route table. Each spec is
/// `.{ .method, .path, .handler, .auth = .public|.authed|.superuser }`; `.auth` defaults
/// to `.superuser` (safe default) when omitted.
pub fn buildRoutes(comptime specs: anytype) []const RuntimeRoute {
    comptime {
        var table: [std.meta.fields(@TypeOf(specs)).len]RuntimeRoute = undefined;
        for (std.meta.fields(@TypeOf(specs)), 0..) |f, i| {
            const s = @field(specs, f.name);
            const auth: AuthLevel = if (@hasField(@TypeOf(s), "auth")) s.auth else .superuser;
            table[i] = .{ .method = s.method, .pattern = s.path, .handler = s.handler, .auth = auth };
        }
        const final = table;
        return &final;
    }
}
```

Extend `Dispatch`:
```zig
pub const Dispatch = struct {
    record: ?RecordHandler = null,
    on_error: ?ErrorHandler = null,
    routes: []const RuntimeRoute = &.{},
    on_auth: ?AuthHandler = null,
    on_file_serve: ?FileServeHandler = null,
    on_file_upload: ?FileUploadHandler = null,
    on_bootstrap: ?LifecycleHandler = null,
    on_before_serve: ?LifecycleHandler = null,
    on_before_terminate: ?LifecycleHandler = null,
};
```

- [ ] **Step 4: Run tests → pass; count up from 220.**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -6`
Expected: PASS.

- [ ] **Step 5: Build binary + commit**

```sh
mise exec zig@0.16.0 -- zig build
git add src/events.zig
git commit -m "feat(framework): route/auth/file/lifecycle event types + buildRoutes

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `router.tryDispatch` (no-404 variant)

So `onRequest` can try built-ins first, then custom routes, then a single 404.

**Files:** Modify `src/router.zig`; Test: in `src/router.zig`.

- [ ] **Step 1: Write the failing test**

Add to `src/router.zig`:
```zig
test "tryDispatch returns null when nothing matches, Response when it does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const routes = [_]Route{.{ .method = .GET, .pattern = "/api/collections/:idOrName", .handler = dummyHandler }};
    var ctx = http.RequestCtx{ .method = .GET, .path = "/api/collections/posts", .allocator = arena.allocator() };
    const hit = try tryDispatch(&routes, &ctx);
    try std.testing.expect(hit != null);
    try std.testing.expectEqualStrings("posts", hit.?.body);
    var ctx2 = http.RequestCtx{ .method = .GET, .path = "/nope", .allocator = arena.allocator() };
    try std.testing.expect((try tryDispatch(&routes, &ctx2)) == null);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | head -20`
Expected: FAIL — `tryDispatch` undefined.

- [ ] **Step 3: Implement `tryDispatch` and refactor `dispatch` to use it**

In `src/router.zig`, add `tryDispatch` and make `dispatch` delegate (DRY):
```zig
/// Like `dispatch`, but returns null instead of a 404 envelope when nothing matches.
/// Lets the caller try multiple route tables (built-in, then custom) before 404ing.
pub fn tryDispatch(routes: []const Route, ctx: *http.RequestCtx) anyerror!?http.Response {
    for (routes) |rt| {
        if (rt.method != ctx.method) continue;
        if (try matchPath(ctx.allocator, rt.pattern, ctx.path)) |params| {
            ctx.params = params;
            return try rt.handler(ctx);
        }
    }
    return null;
}

/// Find the first matching route (method + path), fill ctx.params, invoke handler.
/// Returns a 404 envelope when nothing matches.
pub fn dispatch(routes: []const Route, ctx: *http.RequestCtx) anyerror!http.Response {
    const ApiError = @import("api/error.zig").ApiError;
    return (try tryDispatch(routes, ctx)) orelse ApiError.notFound().toResponse(ctx.allocator);
}
```

- [ ] **Step 4: Run tests → pass (existing dispatch tests still pass + new one).**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -6`

- [ ] **Step 5: Build + commit**

```sh
mise exec zig@0.16.0 -- zig build
git add src/router.zig
git commit -m "feat(framework): router.tryDispatch (null on no-match) for layered routing

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Custom-route dispatch in `server.zig` (auth-gated, built-ins win)

Wire custom routes into `onRequest`: built-ins first; then custom routes with auth enforcement; then 404. Default (no custom routes) path unchanged.

**Files:** Modify `src/server.zig`; Test: Playwright (deferred to Task 7's example) + a Zig unit test for the gating helper.

- [ ] **Step 1: Add a `dispatchCustom` helper + a unit test for auth gating**

Add to `src/server.zig` (after imports add `const auth = @import("auth.zig"); const events = @import("events.zig"); const request = @import("request.zig");` if not present):
```zig
/// Try the consumer's custom routes (after built-ins). Resolves auth, enforces the route's
/// AuthLevel, then calls the handler. Returns null if no custom route matches the path+method.
fn dispatchCustom(ctx: *http.RequestCtx) anyerror!?http.Response {
    const app = ctx.app orelse return null;
    const d = app.dispatch orelse return null;
    if (d.routes.len == 0) return null;
    for (d.routes) |rt| {
        if (rt.method != ctx.method) continue;
        if (try router.matchPath(ctx.allocator, rt.pattern, ctx.path)) |params| {
            ctx.params = params;
            // Resolve auth on a fresh reader (read-only; never touches the writer lock).
            var reader = app.pool.openReader() catch return ApiError.internal().toResponse(ctx.allocator);
            defer reader.close();
            const authed = auth.authenticate(app.io, ctx.allocator, app, ctx, &reader) catch null;
            switch (rt.auth) {
                .public => {},
                .authed => if (authed == null) return (ApiError{ .status = 401, .message = "Not authenticated." }).toResponse(ctx.allocator),
                .superuser => if (authed == null or !authed.?.is_superuser) return ApiError.forbidden().toResponse(ctx.allocator),
            }
            var rctx = request.RequestContext{
                .auth = if (authed) |a| a.record else null,
                .is_superuser = if (authed) |a| a.is_superuser else false,
                .method = @tagName(ctx.method),
            };
            var ev = events.RouteEvent{ .app = app, .ctx = ctx, .rctx = rctx };
            return rt.handler(&ev) catch |e| {
                var err_ev = events.ErrorEvent{ .app = app, .ctx = &rctx, .err = e, .phase = .request, .message = @errorName(e) };
                events.dispatchError(app, app.dispatch, &err_ev);
                return ApiError.internal().toResponse(ctx.allocator);
            };
        }
    }
    return null;
}
```
> Confirm `ApiError.forbidden()` exists (grep `pub fn forbidden` in `src/api/error.zig`); if it's named differently, use the real constructor (e.g. `(ApiError{ .status = 403, .message = "Forbidden." })`). Confirm `auth.authenticate`'s exact signature and that `Authed.is_superuser`/`.record` are the field names (per 10a map they are).

No standalone Zig unit test here (auth needs a DB + HTTP); the gating is proven end-to-end by Task 7's Playwright test. (If you want a pure check, add a unit test that `dispatchCustom` returns null when `app.dispatch` is null or `routes.len == 0` — constructing a minimal ctx with `app = null`.)

- [ ] **Step 2: Wire `dispatchCustom` into `onRequest` (built-ins first, then custom, then 404)**

In `src/server.zig` `onRequest`, replace the `const resp = if (admin) admin.serve else router.dispatch(...) catch ...` block with a layered version:
```zig
    const resp = blk: {
        if (std.mem.startsWith(u8, ctx.path, "/_/") or std.mem.eql(u8, ctx.path, "/_"))
            break :blk admin.serve(&ctx);
        // Built-in API routes win over custom routes.
        if (router.tryDispatch(&routes, &ctx) catch null) |r| break :blk r;
        if (dispatchCustom(&ctx) catch null) |r| break :blk r;
        break :blk ApiError.notFound().toResponse(arena.allocator()) catch {
            setZapStatus(r, 500);
            r.setContentType(.JSON) catch {};
            r.sendBody("{\"code\":500,\"message\":\"Something went wrong.\",\"data\":{}}") catch {};
            return;
        };
    };
```
> Preserve the existing 500-fallback behavior for the allocation-failure path. The built-in `tryDispatch ... catch null` preserves the previous "internal error on handler failure" semantics by falling through to custom→404; if you'd rather keep the explicit 500 on a built-in handler error, branch on the error instead of `catch null`. Keep behavior for built-ins as close to current as possible — the simplest faithful form: `const builtin = router.tryDispatch(&routes, &ctx) catch |e| { ... map to 500 envelope ... }; if (builtin) |r| break :blk r;`. Choose the form that keeps the existing 10 Playwright tests green.

- [ ] **Step 3: Verify default behavior unchanged**

Run:
```sh
mise exec zig@0.16.0 -- zig build
mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -6
mise exec python@3.13 -- python -m pytest tests/admin -q
```
Expected: binary EXIT 0; Zig all pass; **10 Playwright passed** (no custom routes configured ⇒ `dispatchCustom` returns null immediately ⇒ identical behavior).

- [ ] **Step 4: Commit**

```sh
git add src/server.zig
git commit -m "feat(framework): dispatch auth-gated custom routes after built-ins

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Wire routes + handlers into `App(cfg)` + lifecycle emits

Build the route table + auth/file/lifecycle handlers onto `dispatch`, extend the cfg-key whitelist, and emit lifecycle events in `serveImpl`.

**Files:** Modify `src/framework.zig`; Test: in `src/framework.zig`.

- [ ] **Step 1: Write failing tests**

Add to `src/framework.zig`:
```zig
test "App(cfg) assembles custom routes onto dispatch" {
    const H = struct {
        fn h(ev: *@import("events.zig").RouteEvent) anyerror!@import("http.zig").Response { _ = ev; return .{ .status = 200, .body = "ok" }; }
    };
    const A = App(.{ .routes = .{ .{ .method = .GET, .path = "/api/x", .handler = H.h, .auth = .public } } });
    try std.testing.expectEqual(@as(usize, 1), A.dispatch.routes.len);
    try std.testing.expectEqualStrings("/api/x", A.dispatch.routes[0].pattern);
}

test "App(.{}) has no routes and null lifecycle/auth/file handlers" {
    const A = App(.{});
    try std.testing.expectEqual(@as(usize, 0), A.dispatch.routes.len);
    try std.testing.expect(A.dispatch.on_auth == null);
    try std.testing.expect(A.dispatch.on_bootstrap == null);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | head -20`
Expected: FAIL (routes not assembled).

- [ ] **Step 3: Extend the comptime `dispatch` block + cfg-key whitelist**

In `src/framework.zig` `App(cfg)`, replace the `dispatch` comptime block's whitelist + builder with:
```zig
        pub const dispatch: events.Dispatch = blk: {
            const allowed = .{ "hooks", "onError", "routes", "onAuth", "onFileServe", "onFileUpload", "onBootstrap", "onBeforeServe", "onBeforeTerminate" };
            for (std.meta.fields(@TypeOf(cfg))) |f| {
                var ok = false;
                for (allowed) |name| if (std.mem.eql(u8, f.name, name)) { ok = true; };
                if (!ok) @compileError("unknown App cfg field '" ++ f.name ++ "'; expected one of hooks/onError/routes/onAuth/onFileServe/onFileUpload/onBootstrap/onBeforeServe/onBeforeTerminate");
            }
            var d = events.Dispatch{};
            if (@hasField(@TypeOf(cfg), "hooks")) d.record = events.buildRecordDispatcher(cfg.hooks);
            if (@hasField(@TypeOf(cfg), "onError")) d.on_error = cfg.onError;
            if (@hasField(@TypeOf(cfg), "routes")) d.routes = events.buildRoutes(cfg.routes);
            if (@hasField(@TypeOf(cfg), "onAuth")) d.on_auth = cfg.onAuth;
            if (@hasField(@TypeOf(cfg), "onFileServe")) d.on_file_serve = cfg.onFileServe;
            if (@hasField(@TypeOf(cfg), "onFileUpload")) d.on_file_upload = cfg.onFileUpload;
            if (@hasField(@TypeOf(cfg), "onBootstrap")) d.on_bootstrap = cfg.onBootstrap;
            if (@hasField(@TypeOf(cfg), "onBeforeServe")) d.on_before_serve = cfg.onBeforeServe;
            if (@hasField(@TypeOf(cfg), "onBeforeTerminate")) d.on_before_terminate = cfg.onBeforeTerminate;
            break :blk d;
        };
```

- [ ] **Step 4: Emit lifecycle events in `serveImpl`**

In `src/framework.zig` `serveImpl`, after `app` is constructed (it has `.dispatch = dispatch`), and after migrations have run, add bootstrap + before-serve emits, and a before-terminate emit. Insert right before `try srv.listen();`:
```zig
    if (dispatch.on_bootstrap) |h| {
        var ev = events.LifecycleEvent{ .app = &app };
        h(&ev);
    }
    if (dispatch.on_before_serve) |h| {
        var ev = events.LifecycleEvent{ .app = &app };
        h(&ev);
    }
    // before_terminate fires when listen() returns (graceful shutdown / error).
    defer if (dispatch.on_before_terminate) |h| {
        var ev = events.LifecycleEvent{ .app = &app };
        h(&ev);
    };
    try srv.listen();
```
> Note: `srv.listen()` calls `zap.start(...)` which blocks until the reactor stops; the `defer` fires on return. Migrations already ran above, so `on_bootstrap` correctly sees a migrated DB.

- [ ] **Step 5: Run tests + build + Playwright**

```sh
mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -6
mise exec zig@0.16.0 -- zig build
mise exec python@3.13 -- python -m pytest tests/admin -q
```
Expected: new tests pass; 10 Playwright pass (App(.{}) ⇒ all handlers null/empty ⇒ unchanged).

- [ ] **Step 6: Commit**

```sh
git add src/framework.zig
git commit -m "feat(framework): assemble routes + auth/file/lifecycle handlers in App(cfg)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Emit `auth.afterAuthSuccess`

Fire the auth event at the password, refresh, and oauth2 success sites. After-style: errors swallowed (auth already succeeded).

**Files:** Modify `src/api/auth.zig`, `src/api/oauth.zig`; Test: behavioral via example/Playwright (the emit is a side-effect; a Zig unit test for the helper is optional).

- [ ] **Step 1: Add an `emitAuth` helper to `src/api/auth.zig`**

Add (reuse existing imports; add `const events = @import("../events.zig");` and `const request = @import("../request.zig");` if absent):
```zig
/// Fire auth.afterAuthSuccess. After-style: errors routed to the backstop and swallowed.
pub fn emitAuth(ctx: *http.RequestCtx, collection: []const u8, record: ?std.json.Value, method: anytype) void {
    const app = ctx.app orelse return;
    const d = app.dispatch orelse return;
    const h = d.on_auth orelse return;
    var rctx = request.RequestContext{ .method = @tagName(ctx.method) };
    var ev = events.AuthEvent{ .app = app, .ctx = &rctx, .collection = collection, .record = record, .method = method };
    h(&ev);
}
```
> `method` is `events.AuthEvent`'s `method` enum value (`.password` or `.oauth2`); pass it literally at each call site.

- [ ] **Step 2: Call it at the success sites**

In `api/auth.zig` `authWithPassword`, after `const rec = (try records.get(...)) orelse ...;` and before returning the response, add:
```zig
    emitAuth(ctx, col.name, rec, .password);
```
In `authRefresh`, after `authed.record` is known and the response is assembled, add:
```zig
    emitAuth(ctx, col_name, authed.record, .password);
```
In `api/oauth.zig` `respondSession`, after `const rec = (try records.get(...)) orelse ...;`, add:
```zig
    auth_api.emitAuth(ctx, col.name, rec, .oauth2);
```
> Confirm `auth_api` is the import alias for `api/auth.zig` in `oauth.zig` (grep). Use the real alias.

- [ ] **Step 3: Verify**

```sh
mise exec zig@0.16.0 -- zig build
mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -6
mise exec python@3.13 -- python -m pytest tests/admin -q
```
Expected: all green (no on_auth handler by default ⇒ emitAuth is a no-op).

- [ ] **Step 4: Commit**

```sh
git add src/api/auth.zig src/api/oauth.zig
git commit -m "feat(framework): emit auth.afterAuthSuccess (password + oauth2)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Emit `file.beforeServe` (deny → 404) and `file.afterUpload`

**Files:** Modify `src/api/files.zig`, `src/api/records.zig`.

- [ ] **Step 1: `file.beforeServe` in `api/files.zig` serve**

In `serve(ctx)`, after `col_name`/`rid`/`name` are resolved and AFTER the existing access-rule check passes (so beforeServe runs only on otherwise-servable files) but BEFORE building the file response, add:
```zig
    if (app.dispatch) |d| if (d.on_file_serve) |h| {
        var rctx = request.RequestContext{ .method = "GET" };
        var fev = events.FileEvent{ .app = app, .ctx = &rctx, .collection = col_name, .record_id = rid, .filename = name };
        h(&fev) catch return ApiError.notFound().toResponse(ctx.allocator);
    };
```
> Add `const events = @import("../events.zig"); const request = @import("../request.zig");` if absent. A beforeServe handler returning an error denies the download (404), matching the existing 404-hides-existence policy.

- [ ] **Step 2: `file.afterUpload` in `api/records.zig`**

After a successful `writeUploads(...)` call (both create and update paths), emit one `file.afterUpload` per written file. Add a small helper near `emitRecord`:
```zig
fn emitFileUploads(app: *app_mod.App, rctx: *const request.RequestContext, col_name: []const u8, record_id: []const u8, writes: []const file_plan.FieldWrite) void {
    const d = app.dispatch orelse return;
    const h = d.on_file_upload orelse return;
    for (writes) |wr| {
        var ev = events.FileEvent{ .app = app, .ctx = rctx, .collection = col_name, .record_id = record_id, .filename = wr.filename };
        h(&ev);
    }
}
```
Call it after `writeUploads(...) catch { ... }` succeeds in create and update, passing `&rctx`, `col.name`, the record id, and `all.writes` (the `AllPlan.writes` slice). (Use the actual local names from 10a's create/update — `all.writes`, the captured `rid`.)

- [ ] **Step 3: Verify**

```sh
mise exec zig@0.16.0 -- zig build
mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -6
mise exec python@3.13 -- python -m pytest tests/admin -q
```
Expected: all green (no file handlers by default ⇒ no-ops; the existing file upload Playwright test still passes).

- [ ] **Step 4: Commit**

```sh
git add src/api/files.zig src/api/records.zig
git commit -m "feat(framework): emit file.beforeServe (deny->404) and file.afterUpload

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Example custom route + Playwright e2e

Add a custom route (and an `onAuth` handler) to `examples/blog`, and a browser test that drives the route end-to-end — the consumer-side integration proof for routes.

**Files:** Modify `examples/blog/src/main.zig`; Create `tests/admin/test_custom_route.py`; (the example is built/run by the test harness — confirm `conftest.py`'s `binary` fixture can target the example, else the test builds it directly).

- [ ] **Step 1: Add a public custom route to the example**

In `examples/blog/src/main.zig`, add a handler and register it:
```zig
/// GET /api/blog/ping — a public custom route returning a small JSON body.
fn ping(ev: *zigbase.RouteEvent) anyerror!zigbase.http.Response {
    _ = ev;
    return .{ .status = 200, .body = "{\"pong\":true}" };
}

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .hooks = .{ .posts = .{ .beforeCreate = slugify } },
        .routes = .{
            .{ .method = .GET, .path = "/api/blog/ping", .handler = ping, .auth = .public },
        },
    }).runCli(init);
}
```
> Confirm `zigbase.http` and `zigbase.RouteEvent` and `zigbase.events`-ish exports are public (`src/root.zig`). If `http`/`RouteEvent` aren't re-exported, add the re-exports to `src/root.zig` (`pub const RouteEvent = events.RouteEvent;` — `http` is already exported) as part of this task and rebuild. The route returns a literal JSON string (no allocation needed). For `.method = .GET`, `zigbase.http.Method.GET` — confirm `Method` is reachable (it's in `zigbase.http`).

- [ ] **Step 2: Build the example (packaging proof for routes)**

```sh
cd /home/valthon/nothlav/zigbase/examples/blog && mise exec zig@0.16.0 -- zig build && ls zig-out/bin/blog && cd ../..
```
Expected: EXIT 0.

- [ ] **Step 3: Add a Playwright test driving the route**

Create `tests/admin/test_custom_route.py`. Mirror the existing `conftest.py` fixtures (read `tests/admin/conftest.py` for the `binary`/`server`/`page` fixture shapes). The test must run the EXAMPLE binary (not the main `zigbase` binary), so either: (a) parametrize/extend the `server` fixture to accept a binary path and point it at `examples/blog/zig-out/bin/blog`, or (b) write a self-contained fixture in this test file that builds + serves the example on a free port with a temp data dir + a superuser, then HTTP-GETs `/api/blog/ping` via `page.request` and asserts `{"pong": true}` with status 200.
```python
# tests/admin/test_custom_route.py
import json, socket, subprocess, time, urllib.request, os, signal, tempfile, pathlib

REPO = pathlib.Path(__file__).resolve().parents[2]
BLOG = REPO / "examples" / "blog"

def _free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

def test_custom_public_route_responds():
    # build the example
    subprocess.run(["mise", "exec", "zig@0.16.0", "--", "zig", "build"], cwd=BLOG, check=True)
    blog = BLOG / "zig-out" / "bin" / "blog"
    assert blog.exists()
    with tempfile.TemporaryDirectory() as data:
        port = _free_port()
        proc = subprocess.Popen([str(blog), "serve", "--http-port", str(port), "--data-dir", data],
                                env={**os.environ, "ZIGBASE_JWT_SECRET": "test-secret-not-default"})
        try:
            url = f"http://127.0.0.1:{port}/api/blog/ping"
            deadline = time.time() + 15
            body = None
            while time.time() < deadline:
                try:
                    with urllib.request.urlopen(url, timeout=1) as r:
                        body = r.read().decode(); status = r.status; break
                except Exception:
                    time.sleep(0.2)
            assert body is not None, "server did not come up"
            assert status == 200
            assert json.loads(body) == {"pong": True}
        finally:
            proc.send_signal(signal.SIGINT); proc.terminate(); proc.wait(timeout=10)
```
> This test is self-contained (doesn't need the Playwright `page` fixture since it's a plain HTTP GET). If the repo prefers all browser tests go through `page.request`, adapt to the existing fixtures — but a urllib GET is sufficient and avoids coupling the example to the admin conftest. Use `mise exec python@3.13 -- python -m pytest tests/admin/test_custom_route.py -q` to run it.

- [ ] **Step 4: Run the new test + the full suite**

```sh
cd /home/valthon/nothlav/zigbase
mise exec python@3.13 -- python -m pytest tests/admin -q
```
Expected: 11 passed (10 existing + the new custom-route test).

- [ ] **Step 5: Commit**

```sh
git add examples/blog/src/main.zig tests/admin/test_custom_route.py src/root.zig
git commit -m "test(framework): example custom route + e2e proves request-time extensibility

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Final review pass

- [ ] **Step 1: Full green gate**

```sh
cd /home/valthon/nothlav/zigbase
mise exec zig@0.16.0 -- zig build
mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -6
mise exec python@3.13 -- python -m pytest tests/admin -q
cd examples/blog && mise exec zig@0.16.0 -- zig build && cd ../..
```
Expected: binary green; all Zig pass; 11 Playwright pass; example builds.

- [ ] **Step 2: Holistic review (dispatch a fresh code-review subagent)**

Review `git diff <task1-base>..HEAD` for: the null-dispatch invariant (no custom routes/handlers ⇒ behavior identical, the 10+existing tests prove it); route precedence (built-ins always win over custom — a custom `/api/collections/...` cannot shadow built-ins); auth gating correctness (`.authed`→401, `.superuser`→403, `.public`→anonymous; auth resolved on a reader, never the writer lock); that custom-route handler errors route to the error backstop and 500 (no panic); the file.beforeServe deny path returns 404 (hides existence, consistent with existing policy) and runs only after the access rule passes; auth/file emits are after-style and swallow; lifecycle emit ordering (bootstrap after migrations, before_terminate on shutdown). Confirm no secret/PII leak through the new event payloads.

- [ ] **Step 3: Address findings, re-run the gate, then stop**

10b ends here. The scheduler/job pool is **Plan 10c**; release engineering is **Plan 10d**. Do NOT merge to `main` until the framework + release are complete on this branch.

---

## Self-Review (plan author)

**Spec coverage (spec §3 custom routes, §2 auth/file/lifecycle events):**
- §3 routes: comptime registration + `fn(*RouteEvent) !Response` + post-auth/post-builtin precedence + declarative `.auth` gating → Tasks 1, 2, 3, 4, 7. ✓
- §2 auth events (`auth.afterAuthSuccess` password + oauth2) → Task 5. ✓
- §2 file events (`file.beforeServe` deny, `file.afterUpload`) → Task 6. ✓
- §2 lifecycle events (`afterBootstrap`/`beforeServe`/`beforeTerminate`) → Task 4. ✓
- Scheduler/job pool (§4) → **deferred to Plan 10c** (explicitly). ✓
- Release (§6) → **Plan 10d**. ✓

**Placeholder scan:** No "TBD"/"handle edge cases". Flagged adaptation points (the `ApiError.forbidden` constructor name in Task 3; `auth_api` alias in Task 5; `zigbase.http`/`RouteEvent` re-exports in Task 7) name the authoritative source to confirm and the invariant; not vague placeholders.

**Type consistency:** `events.Dispatch{ record, on_error, routes, on_auth, on_file_serve, on_file_upload, on_bootstrap, on_before_serve, on_before_terminate }`, `RouteEvent{ app, ctx, rctx }`, `RuntimeRoute{ method, pattern, handler, auth }`, `AuthLevel{ public, authed, superuser }`, `AuthEvent{ app, ctx, collection, record, method }`, `FileEvent{ app, ctx, collection, record_id, filename }`, `LifecycleEvent{ app }`, `buildRoutes(specs) []const RuntimeRoute`, `router.tryDispatch(...) !?Response`, `dispatchCustom(ctx) !?Response`, `emitAuth`, `emitFileUploads` — used consistently across Tasks 1–7. The route handler returns `http.Response` (distinct from record hooks' `!void`).
