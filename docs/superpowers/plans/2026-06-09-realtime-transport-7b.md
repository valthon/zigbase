# Realtime WebSocket Transport & Wiring (Plan 7b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete ZigBase realtime — the live WebSocket transport (upgrade + zap callbacks), a shared `auth.verifyToken`, facil.io pub/sub subscribe/publish wired to the 7a `shouldDeliver`, the `broadcast` hook on record create/update/delete, an Origin check, route wiring — then a holistic security review and merge of SP7 (7a+7b) to `main`.

**Architecture:** A new `src/realtime/ws.zig` is the second (and only other) zap-importing module; it owns the WebSocket glue (Handler instantiation, on_open/on_message/on_close, facil.io `subscribe`/`publish`) and wraps the pure 7a `Conn` in a `LiveConn`. The HTTP→WS upgrade is the listener's `on_upgrade` hook. Events fan out via facil.io channels; each per-connection delivery runs the 7a `shouldDeliver` and writes only on a pass. Auth is an explicit JWT message (never the cookie).

**Tech Stack:** Zig 0.16.0 (`mise exec zig@0.16.0 -- zig <args>` from repo root; bare `zig` is 0.15.2). zap WebSockets (`zap.WebSockets.Handler`) + facil.io pub/sub. Builds on Plan 7a (branch `realtime`).

**Build/test command:** `mise exec zig@0.16.0 -- zig build test --summary all`

**Branch:** Continue on `realtime`. SP7 merges as a unit to `main` at the end of this plan (Task 4), after the holistic review.

**Spec:** `docs/superpowers/specs/2026-06-09-realtime-design.md`. **Prereq:** Plan 7a complete (186 tests green on `realtime`).

---

## Verified facts (zap v0.10.6 + current code — do not re-derive)

- **WS handler:** `const WS = zap.WebSockets.Handler(LiveConn);`. Types:
  - `WS.WebSocketSettings{ on_open: ?fn(?*LiveConn, zap.WebSockets.WsHandle), on_message: ?fn(?*LiveConn, zap.WebSockets.WsHandle, []const u8, bool), on_close: ?fn(?*LiveConn, isize), context: ?*LiveConn }` — **must outlive the connection** (facil.io stores `udata = &settings`).
  - `WS.upgrade(h: [*c]fio.http_s, settings: *WS.WebSocketSettings) WS.WebSocketError!void`.
  - `WS.write(handle, message: []const u8, is_text: bool) !void` — safe on the connection's own thread (inside callbacks).
  - `WS.publish(.{ channel: []const u8, message: []const u8, is_json: bool = false })` — `fio_publish`; **callable from any thread** (the record-writer thread uses it). Non-blocking enqueue.
  - `WS.subscribe(handle, args: *WS.SubscribeArgs) !usize` — `SubscribeArgs{ channel, on_message: ?fn(?*LiveConn, zap.WebSockets.WsHandle, []const u8 channel, []const u8 message), context: ?*LiveConn }`; **each args must outlive the subscription** (facil.io holds the pointer).
- **`zap.WebSockets.WsHandle = ?*fio.ws_s`**; `zap.fio` is `@import("zap").fio` (the C bindings). Use `zap.WebSockets.Handler` for the namespace; `fio.http_s` is reachable as the param type of `upgrade`. In `ws.zig`, `const fio = zap.fio;`.
- **Upgrade entry:** `zap.HttpListenerSettings.on_upgrade: ?*const fn(r: zap.Request, target_protocol: []const u8) anyerror!void`. facil.io calls it for upgrade requests; `target_protocol` is `"websocket"` for WS. `zap.Request.h` is the `[*c]fio.http_s` to pass to `WS.upgrade`. `r.getHeader("origin")` / `r.path`.
- **`src/server.zig`** builds the listener as `zap.HttpListener.init(.{ .port = self.port, .on_request = onRequest, .log = false })` and uses a `Server.instance` global (`Server.instance.?.app`) inside `onRequest`. The same global gives `on_upgrade` access to `*App`.
- **`src/auth.zig`** `authenticate(io, alloc, app, ctx, conn)`: after resolving the token + CSRF gate, it does claims→record. The token→record core (peek claims → `type==.auth` → load tokenKey → `deriveKey` → `jwt.verify` against `nowUnix` → load record) is extracted into `verifyToken` (Task 1). `jwt.peekClaims(alloc, token)` yields `Claims{ id, collection, type, csrf, iat, exp }`. `tokenKeyFor`/`nowUnix`/`superuserRecord` are file-local in auth.zig.
- **7a:** `realtime/protocol.zig` (`parseClient`, `Action`, `parseTopic`, `serializeEvent`, `connectFrame`/`ackFrame`/`authFrame`/`errorFrame`); `realtime/connection.zig` (`Conn`, `AuthIdentity`, `addSub`/`removeSub`/`hasSub`/`subFilter`/`setAuth`/`clearAuth`/`requestContext`); `realtime/hub.zig` (`shouldDeliver`, `buildEventFrames`, `EventFrames`).
- **`src/api/records.zig`** handlers `create`/`update`/`delete` produce the result record (`rec`) / have `col` + `rid` in scope.
- **`src/id.zig`** `collectionId(io) [15]u8`. **`src/db.zig`** `Pool.openReader() DbError!Db`.

---

## File Structure

- **Modify** `src/auth.zig` — extract `pub const Verified` + `pub fn verifyToken(alloc, app, conn, token) ?Verified`; `authenticate` delegates.
- **Create** `src/realtime/ws.zig` — `LiveConn`, the `WS` handler, `handleUpgrade`, on_open/on_message/on_close, the subscription delivery callback, and `broadcast`. (Second zap-importing module — a deliberate, scoped exception to "only server.zig imports zap"; the WS transport fundamentally needs zap primitives, while the pure logic stays in protocol/connection/hub.)
- **Modify** `src/config.zig` / `src/app.zig` — `realtime_allowed_origins` (CSV; empty = allow any, dev default).
- **Modify** `src/server.zig` — set `.on_upgrade = realtime_ws.handleUpgrade` on the listener.
- **Modify** `src/api/records.zig` — call `realtime_ws.broadcast(...)` after each successful create/update/delete.
- **Modify** `src/main.zig` — add `_ = @import("realtime/ws.zig");` to the test root.

---

### Task 1: `auth.verifyToken` refactor (`auth.zig`)

**Files:** Modify `src/auth.zig`.

- [ ] **Step 1: Write the failing test** (append to `src/auth.zig` tests; mirrors the existing `authenticate` tests' setup)

```zig
test "verifyToken resolves a valid token string to a record + exp" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try collections.create(a, std.testing.io, &d, .{
        .id = "", .name = "users", .type = .auth,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
    });
    try d.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('rec1','','','u@x.io','tk-secret',1);");
    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined };
    const key = crypto.deriveKey(app.jwt_secret, "tk-secret");
    const token = try jwt.sign(a, .{ .id = "rec1", .collection = "users", .type = .auth, .iat = 0, .exp = 9999999999 }, &key);
    const v = verifyToken(a, &app, &d, token) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("users", v.collection);
    try std.testing.expectEqual(false, v.is_superuser);
    try std.testing.expectEqual(@as(i64, 9999999999), v.exp);
    try std.testing.expectEqualStrings("rec1", v.record.object.get("id").?.string);
    // wrong-key token -> null
    const wrong = crypto.deriveKey(app.jwt_secret, "other");
    const bad = try jwt.sign(a, .{ .id = "rec1", .collection = "users", .type = .auth, .iat = 0, .exp = 9999999999 }, &wrong);
    try std.testing.expect(verifyToken(a, &app, &d, bad) == null);
}
```

(The existing test imports `db`, `collections`, `migrations`, `jwt`, `crypto`, `App` as `db_`/etc. aliases or module names — reuse whatever the existing `authenticate` tests in this file already import; do not add duplicate imports.)

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `verifyToken`/`Verified` undefined.

- [ ] **Step 3: Add `Verified` + `verifyToken`, and delegate from `authenticate`**

Add (near `Authed`):

```zig
pub const Verified = struct {
    record: std.json.Value,
    collection: []const u8,
    is_superuser: bool,
    exp: i64,
};

/// Resolve a JWT string to a verified identity (no HTTP ctx, no CSRF — the caller owns transport
/// concerns). peek claims → require type==.auth → load the record's tokenKey → derive key →
/// jwt.verify against SQLite now → load the record (hidden fields stripped). null on any failure.
pub fn verifyToken(alloc: std.mem.Allocator, app: anytype, conn: *db.Db, token: []const u8) ?Verified {
    const claims = jwt.peekClaims(alloc, token) catch return null;
    if (claims.type != .auth) return null;
    const is_super = std.mem.eql(u8, claims.collection, "_superusers");
    const table = if (is_super) "_superusers" else blk: {
        const col = (collections.get(alloc, conn, claims.collection) catch return null) orelse return null;
        break :blk col.name;
    };
    const tk = (tokenKeyFor(alloc, conn, table, claims.id) catch return null) orelse return null;
    const key = crypto.deriveKey(app.jwt_secret, tk);
    const now = nowUnix(conn) catch return null;
    _ = jwt.verify(alloc, token, &key, now) catch return null;
    const rec = if (is_super)
        (superuserRecord(alloc, conn, claims.id) catch return null) orelse return null
    else blk: {
        const col = (collections.get(alloc, conn, claims.collection) catch return null) orelse return null;
        const records = @import("records.zig");
        break :blk (records.get(alloc, conn, col, claims.id) catch return null) orelse return null;
    };
    return .{ .record = rec, .collection = claims.collection, .is_superuser = is_super, .exp = claims.exp };
}
```

Then **replace the body of `authenticate`** from `const claims = jwt.peekClaims(...)` onward (keeping the bearer/cookie + CSRF gate intact) so it delegates:

```zig
    // (keep the existing top of authenticate: bearer/from_cookie/token resolution + CSRF gate)
    // CSRF gate stays, but it needs claims.csrf — peek once here for the gate:
    const claims = jwt.peekClaims(alloc, token) catch return null;
    if (claims.type != .auth) return null;
    if (from_cookie and isUnsafe(ctx.method)) {
        if (ctx.csrf_token.len == 0 or claims.csrf.len == 0) return null;
        if (!ctEqlSlices(claims.csrf, ctx.csrf_token)) return null;
    }
    const v = verifyToken(alloc, app, conn, token) orelse return null;
    return Authed{ .record = v.record, .collection = v.collection, .is_superuser = v.is_superuser };
```

(Net effect: `authenticate` keeps its CSRF gate and now reuses `verifyToken` for the verify+load. `peekClaims` runs twice — once for the CSRF gate, once inside `verifyToken` — a negligible cost for a clean split. All existing `authenticate` tests must stay green.)

- [ ] **Step 4: Run to verify pass**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS (new verifyToken test + all existing auth tests green).

- [ ] **Step 5: Commit**

```bash
git add src/auth.zig
git commit -m "refactor(auth): extract verifyToken (token-string -> identity)"
```

---

### Task 2: Realtime config (`config.zig`, `app.zig`)

**Files:** Modify `src/config.zig`, `src/app.zig`.

- [ ] **Step 1: Write the failing test** (append to `src/config.zig` tests)

```zig
test "realtime origins default empty, overridable" {
    const G0 = struct {
        fn get(_: []const u8) ?[]const u8 { return null; }
    };
    try std.testing.expectEqualStrings("", (try Config.load(&G0.get)).realtime_allowed_origins);
    const G1 = struct {
        fn get(key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_REALTIME_ORIGINS")) return "https://app.example";
            return null;
        }
    };
    try std.testing.expectEqualStrings("https://app.example", (try Config.load(&G1.get)).realtime_allowed_origins);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — no `realtime_allowed_origins`.

- [ ] **Step 3: Add the field + getter + App field**

In `src/config.zig` `Config`, add (after the auth fields):

```zig
    realtime_allowed_origins: []const u8 = "", // CSV of allowed WS Origins; "" = allow any (dev)
```

In `Config.load`, add:

```zig
        if (getter("ZIGBASE_REALTIME_ORIGINS")) |v| cfg.realtime_allowed_origins = v;
```

In `src/app.zig` `App`, add (defaulted so existing constructors compile):

```zig
    realtime_allowed_origins: []const u8 = "",
```

In `src/main.zig` `runServe`, where `App{…}` is built, add `.realtime_allowed_origins = cfg.realtime_allowed_origins,`.

- [ ] **Step 4: Run to verify pass + commit**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS.

```bash
git add src/config.zig src/app.zig src/main.zig
git commit -m "feat(realtime): allowed-origins config"
```

---

### Task 3: The WebSocket module (`realtime/ws.zig`)

**Files:** Create `src/realtime/ws.zig`; Modify `src/main.zig`.

This is the zap glue — Handler, upgrade, callbacks, delivery, broadcast. It is **compile-checked + smoke-validated** (the live socket path isn't unit-testable); the security logic it calls (`shouldDeliver`, `verifyToken`, the protocol codec) is already unit-tested in 7a/Task 1. Add one pure unit test for the Origin check.

- [ ] **Step 1: Create `src/realtime/ws.zig`**

```zig
const std = @import("std");
const zap = @import("zap");
const fio = zap.fio;
const App = @import("../app.zig").App;
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const collections = @import("../collections.zig");
const auth = @import("../auth.zig");
const id = @import("../id.zig");
const protocol = @import("protocol.zig");
const connection = @import("connection.zig");
const hub = @import("hub.zig");

/// Live per-connection state: the pure 7a `Conn` plus the zap handle / settings / app.
pub const LiveConn = struct {
    conn: connection.Conn = .{},
    handle: zap.WebSockets.WsHandle = null,
    settings: WS.WebSocketSettings = undefined, // facil.io holds &settings; must outlive the conn
    app: *App,
    arena: std.heap.ArenaAllocator, // per-connection allocations (subs, sub-args, frames)
    client_id: [15]u8 = undefined,
    /// Stable storage for SubscribeArgs (facil.io holds pointers) — one per active channel.
    sub_args: std.ArrayList(*WS.SubscribeArgs) = .empty,
};

pub const WS = zap.WebSockets.Handler(LiveConn);

/// Is `origin` allowed by the CSV allowlist? Empty allowlist allows any (dev default).
pub fn originAllowed(allowlist: []const u8, origin: ?[]const u8) bool {
    if (allowlist.len == 0) return true;
    const o = origin orelse return false;
    var it = std.mem.splitScalar(u8, allowlist, ',');
    while (it.next()) |allowed| {
        if (std.mem.eql(u8, std.mem.trim(u8, allowed, " "), o)) return true;
    }
    return false;
}

/// Listener on_upgrade hook: validate Origin, allocate a LiveConn, upgrade. Path-gated to /api/realtime.
pub fn handleUpgrade(r: zap.Request, target_protocol: []const u8) anyerror!void {
    const Server = @import("../server.zig").Server;
    const app = Server.instance.?.app;
    if (!std.mem.eql(u8, target_protocol, "websocket")) return; // not a WS upgrade
    if (!std.mem.eql(u8, r.path orelse "", "/api/realtime")) {
        r.setStatus(.not_found);
        r.markAsFinished(true);
        return;
    }
    if (!originAllowed(app.realtime_allowed_origins, r.getHeader("origin"))) {
        r.setStatus(.forbidden);
        r.markAsFinished(true);
        return;
    }
    const lc = try app.allocator.create(LiveConn);
    lc.* = .{ .app = app, .arena = std.heap.ArenaAllocator.init(app.allocator) };
    var cid = id.collectionId(app.io);
    @memcpy(&lc.client_id, &cid);
    lc.settings = .{
        .on_open = onOpen,
        .on_message = onMessage,
        .on_close = onClose,
        .context = lc,
    };
    WS.upgrade(r.h, &lc.settings) catch {
        lc.arena.deinit();
        app.allocator.destroy(lc);
        return;
    };
}

fn onOpen(context: ?*LiveConn, handle: zap.WebSockets.WsHandle) anyerror!void {
    const lc = context orelse return;
    lc.handle = handle;
    const a = lc.arena.allocator();
    const frame = try protocol.connectFrame(a, &lc.client_id);
    WS.write(handle, frame, true) catch {};
}

fn onMessage(context: ?*LiveConn, handle: zap.WebSockets.WsHandle, message: []const u8, is_text: bool) anyerror!void {
    _ = is_text;
    const lc = context orelse return;
    const a = lc.arena.allocator();
    const msg = protocol.parseClient(a, message) catch {
        WS.write(handle, try protocol.errorFrame(a, "bad message"), true) catch {};
        return;
    };
    switch (msg) {
        .auth => |m| {
            var r = lc.app.pool.openReader() catch {
                WS.write(handle, try protocol.authFrame(a, false), true) catch {};
                return;
            };
            defer r.close();
            if (auth.verifyToken(a, lc.app, &r, m.token)) |v| {
                lc.conn.setAuth(.{ .record = v.record, .is_superuser = v.is_superuser, .exp = v.exp });
                WS.write(handle, try protocol.authFrame(a, true), true) catch {};
            } else {
                lc.conn.clearAuth();
                WS.write(handle, try protocol.authFrame(a, false), true) catch {};
            }
        },
        .subscribe => |m| {
            // validate the collection exists
            var r = lc.app.pool.openReader() catch return;
            const ok = blk: {
                defer r.close();
                const t = protocol.parseTopic(m.topic);
                const col = (collections.get(a, &r, t.collection) catch break :blk false) orelse break :blk false;
                _ = col;
                break :blk true;
            };
            if (!ok) {
                WS.write(handle, try protocol.errorFrame(a, "unknown collection"), true) catch {};
                return;
            }
            // (filter validity is re-checked at delivery by shouldDeliver; a malformed filter simply
            // never matches. Optional: pre-parse here for an early error — deferred.)
            lc.conn.addSub(a, m.topic, m.filter) catch return;
            const args = a.create(WS.SubscribeArgs) catch return;
            args.* = .{ .channel = m.topic, .on_message = onChannelMessage, .context = lc };
            _ = WS.subscribe(handle, args) catch {};
            lc.sub_args.append(a, args) catch {};
            WS.write(handle, try protocol.ackFrame(a, "subscribe", m.topic), true) catch {};
        },
        .unsubscribe => |m| {
            _ = lc.conn.removeSub(m.topic); // delivery callback skips channels not in conn.subs
            WS.write(handle, try protocol.ackFrame(a, "unsubscribe", m.topic), true) catch {};
        },
    }
}

/// facil.io delivers a channel message to this connection (on its own thread). Re-check the live
/// subscription (it may have been unsubscribed), then run shouldDeliver and write on a pass.
fn onChannelMessage(context: ?*LiveConn, handle: zap.WebSockets.WsHandle, channel: []const u8, message: []const u8) anyerror!void {
    const lc = context orelse return;
    if (!lc.conn.hasSub(channel)) return; // unsubscribed: facil.io subscription lingers; we skip
    const a = lc.arena.allocator();

    // The published message is the full event frame already shaped for `channel` (topic == channel).
    // Parse out action + record id to feed shouldDeliver.
    const parsed = std.json.parseFromSlice(std.json.Value, a, message, .{}) catch return;
    if (parsed.value != .object) return;
    const obj = parsed.value.object;
    const action_str = (obj.get("action") orelse return).string;
    const action: protocol.Action = if (std.mem.eql(u8, action_str, "create")) .create
        else if (std.mem.eql(u8, action_str, "update")) .update
        else if (std.mem.eql(u8, action_str, "delete")) .delete
        else return;
    const record_id = ((obj.get("record") orelse return).object.get("id") orelse return).string;

    const t = protocol.parseTopic(channel);
    var r = lc.app.pool.openReader() catch return;
    defer r.close();
    const col = (collections.get(a, &r, t.collection) catch return) orelse return;
    const now = auth.nowUnixPub(&r) catch return;
    const filter_ptr = lc.conn.subFilter(channel);
    const sub_filter: ?[]const u8 = if (filter_ptr) |p| p.* else null;

    const deliver = hub.shouldDeliver(a, &r, col, &lc.conn, now, action, record_id, sub_filter) catch return;
    if (deliver) WS.write(handle, message, true) catch {};
}

fn onClose(context: ?*LiveConn, uuid: isize) anyerror!void {
    _ = uuid;
    const lc = context orelse return;
    const app = lc.app;
    lc.arena.deinit();
    app.allocator.destroy(lc);
}

/// Publish a record event to its collection + record channels. Called from the record-writer path
/// (any thread); `fio_publish` is a non-blocking enqueue. `record` is the full record for
/// create/update (hidden fields already stripped) and is ignored for delete (id-only).
pub fn broadcast(app: *App, col: schema.Collection, action: protocol.Action, record_id: []const u8, record: ?std.json.Value) void {
    _ = app;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ef = hub.buildEventFrames(a, col.name, action, record_id, record) catch return;
    WS.publish(.{ .channel = ef.collection_channel, .message = ef.frame_collection });
    WS.publish(.{ .channel = ef.record_channel, .message = ef.frame_record });
}
```

Add a `pub` wrapper for `nowUnix` in `src/auth.zig` (the delivery callback needs current time): add

```zig
pub fn nowUnixPub(conn: *db.Db) db.DbError!i64 {
    return nowUnix(conn);
}
```

- [ ] **Step 2: Add the Origin unit test** (append to `src/realtime/ws.zig`)

```zig
test "originAllowed: empty allowlist allows any; CSV matches exactly" {
    try std.testing.expect(originAllowed("", null));
    try std.testing.expect(originAllowed("", "https://anything"));
    try std.testing.expect(originAllowed("https://a.com, https://b.com", "https://b.com"));
    try std.testing.expect(!originAllowed("https://a.com", "https://evil.com"));
    try std.testing.expect(!originAllowed("https://a.com", null));
}
```

Register `_ = @import("realtime/ws.zig");` in `src/main.zig` test root.

- [ ] **Step 3: Build + run**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS (the Origin test + everything prior; the file compiles against zap). If a zap WS type/signature differs from the snippet (e.g. `WsHandle` namespacing, `SubscribeArgs` field names, `upgrade` arg type), READ `zig-pkg/zap-*/src/websockets.zig` and adapt MINIMALLY to compile — the verified facts above are the starting point. Do NOT change the security logic. If you cannot make it compile after reasonable effort, report BLOCKED with the exact error.

- [ ] **Step 4: Commit**

```bash
git add src/realtime/ws.zig src/auth.zig src/main.zig
git commit -m "feat(realtime): WebSocket transport (upgrade, subscribe, delivery, broadcast)"
```

---

### Task 4: Wire upgrade + broadcast hook (`server.zig`, `api/records.zig`)

**Files:** Modify `src/server.zig`, `src/api/records.zig`.

- [ ] **Step 1: Set `on_upgrade` in `src/server.zig`**

Add the import:

```zig
const realtime_ws = @import("realtime/ws.zig");
```

Change the listener init to add the upgrade hook:

```zig
        var listener = zap.HttpListener.init(.{ .port = self.port, .on_request = onRequest, .on_upgrade = realtime_ws.handleUpgrade, .log = false });
```

- [ ] **Step 2: Add the broadcast hook to `src/api/records.zig`**

Add the import:

```zig
const realtime_ws = @import("../realtime/ws.zig");
```

In `create` — after `const rec = switch (...) … ;` succeeds and before `return jsonResponse(ctx, 201, rec);`:

```zig
    realtime_ws.broadcast(app, col, .create, rec.object.get("id").?.string, rec);
```

In `update` — after the update succeeds, before returning the updated record (`updated orelse …`). Bind the unwrapped value first:

```zig
    const ur = updated orelse return ApiError.notFound().toResponse(ctx.allocator);
    realtime_ws.broadcast(app, col, .update, ur.object.get("id").?.string, ur);
    return jsonResponse(ctx, 200, ur);
```

(Replace the existing `return jsonResponse(ctx, 200, updated orelse …);` line with the three lines above.)

In `delete` — after `if (!try records.delete(...)) return …notFound;` and the (Task: SP6) `_externalAuths` cleanup, before `return .{ .status = 204, .body = "" };`:

```zig
    realtime_ws.broadcast(app, col, .delete, rid, null);
```

Note: `realtime_ws.broadcast` takes `app: *App` — `app` is the local `ctx.app.?` already bound in each handler. `protocol.Action` is referenced via `realtime_ws`? No — `broadcast`'s `action` param is `protocol.Action`; pass `.create`/`.update`/`.delete` (the enum literal coerces). If the compiler needs the type, it's `@import("../realtime/protocol.zig").Action` — but the enum-literal form should infer.

- [ ] **Step 3: Build + run the suite**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS (full suite; the broadcast calls compile — they're no-ops in unit tests since no WS server is running, and `fio_publish` with no subscribers is harmless).

- [ ] **Step 4: Commit**

```bash
git add src/server.zig src/api/records.zig
git commit -m "feat(realtime): wire WS upgrade + broadcast on record mutations"
```

---

### Task 5: Live smoke, holistic review, merge

**Files:** none (validation + merge).

- [ ] **Step 1: Live WebSocket smoke**

Build and run; drive a real WS client. Prefer Python `websockets` if available (`python3 -c "import websockets"` to check); else `websocat`; else report which tool is missing.

```bash
mise exec zig@0.16.0 -- zig build
SMOKE=/home/valthon/.claude/jobs/fc85a1ad/tmp/zb_rt_smoke
rm -rf "$SMOKE"; mkdir -p "$SMOKE"
./zig-out/bin/zigbase superuser create --email admin@x.io --password adminpassword --data-dir "$SMOKE"
ZIGBASE_DATA_DIR="$SMOKE" ZIGBASE_HTTP_PORT=8095 ./zig-out/bin/zigbase serve >"$SMOKE/server.log" 2>&1 &
SRV=$!; sleep 1.5
```

Then:
1. Superuser-login via REST (`POST /api/collections/_superusers/auth-with-password`) → capture token.
2. Create a **public** base collection `msgs` with one text field `body` and `listRule/viewRule/createRule = ""` (bearer the superuser token).
3. With a Python script (write it to `$SMOKE/client.py`): open `ws://localhost:8095/api/realtime`; expect a `{"type":"connect",…}` frame; send `{"action":"subscribe","topic":"msgs"}`; expect an `ack`; then (from the script, via a second thread or after a short delay) `POST /api/collections/msgs/records` with `{"body":"hello"}`; assert the client receives an `{"type":"event","topic":"msgs","action":"create","record":{…"body":"hello"…}}` within a couple of seconds.
4. Negative check: create a collection `secret` with `viewRule = "owner = @request.auth.id"` and a text field `owner`; an **anonymous** WS subscriber to `secret` must receive **nothing** when a `secret` record is created.
5. Cleanup: `kill $SRV; rm -rf "$SMOKE"`.

Record the observed frames. If the smoke reveals a zap WS integration bug (e.g. upgrade not firing, no delivery), fix it (new commit) and re-run. If no WS client tool is available in the environment, report that and provide the `client.py` you wrote so the user can run it.

- [ ] **Step 2: Commit any smoke fixes**

```bash
git add -A && git commit -m "fix(realtime): <smoke finding>"   # only if changes were needed
```

- [ ] **Step 3: Holistic security review** — dispatch a review over the whole SP7 diff (`git diff main..realtime -- 'src/*'`). Trace, with concrete scenarios: **CSWSH** (auth is the JWT message only — never the cookie; Origin check); **leakage** (delivery reuses `shouldDeliver` = viewRule guard + filter; delete is id-only; full-record events strip hidden fields via the same `records.get`); **expiry** (delivery downgrades a past-`exp` connection to anonymous); **SQLi** (channel/topic strings → `parseTopic` → validated collection identifiers; record ids bound; filter compiled, not interpolated); **thread-safety** (writes only on the connection thread via callbacks; cross-thread only via `WS.publish`/`fio_publish`; the writer holds its lock only across a non-blocking publish enqueue); **lifetime** (`LiveConn.settings` and each `SubscribeArgs` outlive the connection; `onClose` frees the arena+LiveConn with no use-after-free; facil.io has stopped delivering before `onClose`); **DoS** (per-event guard cost — known/accepted; inbound frame-size bounds — note facil.io's default max message size; unbounded subscriptions per connection — note as a follow-up). Fix any CRITICAL/IMPORTANT findings (new commits) and re-run the suite.

- [ ] **Step 4: Merge SP7 to `main`**

```bash
git checkout main
git merge --no-ff realtime -m "merge: SP7 Realtime (WebSocket subscriptions)

WebSocket realtime for ZigBase: clients auth via a JWT message (never the
cookie), subscribe to collection/record topics with optional filters, and
receive rule-filtered create/update/delete events. Pure protocol + the
shouldDeliver gate (viewRule + filter, reusing the access-rules engine) are
unit-tested across the leakage matrix; the live transport rides facil.io
pub/sub with per-connection filtering. Delete events are id-only. Includes
holistic-review fixes.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
mise exec zig@0.16.0 -- zig build test --summary all
```
Expected: full suite green on `main`. Then update the project-status memory (SP7 complete; SP8 Files next).

---

## Done criteria for 7b / SP7

- Full suite green on `main` after merge.
- A real WS client can connect, auth (JWT message), subscribe, and receive rule-filtered create/update/delete events; an unauthorized/anonymous subscriber receives nothing it couldn't `GET`; delete events are id-only.
- Holistic review clean (CSWSH, leakage, expiry, SQLi, thread-safety, lifetime).

---

## Self-Review (author)

- **Spec coverage:** `verifyToken` shared core (§2 → Task 1); allowed-origins (§5 → Task 2); WS upgrade + on_open/message/close + subscribe + delivery (`shouldDeliver`) + `broadcast` (§2,§3,§4 → Task 3); on_upgrade wiring + broadcast hook on create/update/delete (§4 → Task 4); Origin/CSWSH + live smoke + holistic review + merge (§5,§7 → Tasks 3–5). The pure protocol/`Conn`/`shouldDeliver`/`buildEventFrames` are Plan 7a (done).
- **Type consistency:** `Verified` (Task 1) consumed by `ws.onMessage`; `WS = zap.WebSockets.Handler(LiveConn)` types used consistently; `protocol.Action`/`hub.shouldDeliver`/`hub.buildEventFrames`/`connection.Conn` (7a) used as defined; `broadcast(app, col, action, record_id, record)` signature matches the three call sites in Task 4; `auth.nowUnixPub` added for the delivery callback.
- **Placeholder scan:** none — full code in every step. Task 3 explicitly flags that exact zap WS field/namespace names may need minimal adaptation (with the source path to check), which is honest about an FFI boundary, not a placeholder for logic.
- **Known/accepted (documented):** lingering facil.io subscription after `unsubscribe` (delivery-skipped via `conn.hasSub`); per-event DB guard cost (post-MVP perf, per the spec); unbounded subscriptions per connection (review follow-up); the second zap-importing module (`realtime/ws.zig`) is a deliberate, scoped exception.
