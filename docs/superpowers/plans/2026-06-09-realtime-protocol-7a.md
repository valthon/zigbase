# Realtime Protocol & Delivery Logic (Plan 7a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure, unit-testable core of ZigBase realtime — the WebSocket wire protocol (parse client messages, serialize server events), the per-connection subscription/auth data model, and the security-critical `shouldDeliver` decision (viewRule + filter against the DB) — with no facil.io WebSocket glue yet.

**Architecture:** A new `src/realtime/` package: `protocol.zig` (pure JSON message/event codec), `connection.zig` (the `Conn` context — auth identity + subscriptions, builds a `RequestContext`), and `hub.zig` (`shouldDeliver` reusing the SP4 access-rules guard + SP3 filter compiler, plus pure event-frame building). The live WebSocket transport, facil.io pub/sub, and the broadcast hook are Plan 7b.

**Tech Stack:** Zig 0.16.0 (`mise exec zig@0.16.0 -- zig <args>` from repo root; bare `zig` is 0.15.2). std.json, vendored SQLite. Reuses `rules.zig` (`decide`/`matches`), `request.zig` (`RequestContext`), `schema.zig`, `db.zig`.

**Build/test command:** `mise exec zig@0.16.0 -- zig build test --summary all`

**Branch:** Create and work on branch `realtime`. SP7 merges as a unit (7a+7b) after the holistic review at the end of 7b. Do NOT merge to `main` in this plan.

**Spec:** `docs/superpowers/specs/2026-06-09-realtime-design.md`.

---

## Verified facts (current code — do not re-derive)

- **`src/rules.zig`:** `Decision = enum { allow, deny_locked, check }`. `decide(rule: ?[]const u8, rctx: *const request.RequestContext) Decision` — superuser→allow; `null`→deny_locked; `""`→allow; else→check. `matches(alloc, conn: *db.Db, col: schema.Collection, id: []const u8, rule: []const u8, rctx: *const request.RequestContext) RuleError!bool` — runs the guarded `SELECT 1 … WHERE id=? AND (rule)` with `@request.*` macros bound.
- **`src/request.zig`:** `RequestContext{ auth: ?std.json.Value = null, is_superuser: bool = false, data: ?std.json.Value = null, method: []const u8 = "" }`.
- **Filter language:** conjunction is `&&` (lexer token `l_and`), disjunction `||`; parenthesized grouping is supported. So multiple rule/filter clauses combine as `(clauseA) && (clauseB)`.
- **`src/collections.zig`:** `get(alloc, conn: *db.Db, idOrName) EngineError!?schema.Collection`. **`src/migrations.zig`:** `run(w: *db.Db) DbError!void`. **`src/records.zig`:** `create(alloc, io, w, col, data) RecordError!std.json.Value`.
- **`src/db.zig`:** `Db.openMemory() DbError!Db`, `Db.exec(sql:[:0]const u8)`, `Db.prepare`. `Pool` not needed in 7a (tests use a single `Db`).
- **0.16 idioms:** `var l: std.ArrayList(T) = .empty; try l.append(alloc, x); try l.toOwnedSlice(alloc);`. `var m: std.StringHashMapUnmanaged(V) = .empty; try m.put(alloc, k, v); m.get(k); _ = m.remove(k); m.contains(k);`. `var o: std.json.ObjectMap = .empty; try o.put(alloc, k, v);`. Serialize: `std.json.Stringify.valueAlloc(alloc, std.json.Value{ … }, .{})` — **always pass a typed `std.json.Value`**, never a bare `.{ … }` (the anytype reflective path fails to compile). Parse: `std.json.parseFromSlice(std.json.Value, alloc, s, .{})`.
- **Test root:** `src/main.zig` has a `test { _ = @import("…"); }` block — every new module must be added there.

---

## File Structure

- **Create** `src/realtime/protocol.zig` — `ClientMsg` + `parseClient`; `Action`; `parseTopic`; `serializeEvent` + control-frame serializers (`connectFrame`/`ackFrame`/`authFrame`/`errorFrame`). Pure.
- **Create** `src/realtime/connection.zig` — `AuthIdentity`, `Conn` (auth + `subs` map), `requestContext(now)`. Pure (no DB).
- **Create** `src/realtime/hub.zig` — `shouldDeliver` (viewRule + filter against a DB) + `combineClauses`; `EventFrames` + `buildEventFrames` (pure event building, id-only delete). Reuses protocol.
- **Modify** `src/main.zig` — add the three modules to the test root.

---

### Task 0: Branch setup

- [ ] **Step 1: Create the branch**

```bash
cd /home/valthon/nothlav/zigbase
git checkout main
git checkout -b realtime
git status
```
Expected: on branch `realtime`, clean tree.

---

### Task 1: Wire protocol (`realtime/protocol.zig`)

**Files:** Create `src/realtime/protocol.zig`; Modify `src/main.zig`.

- [ ] **Step 1: Create `src/realtime/protocol.zig` with the tests first**

```zig
const std = @import("std");

test "parseClient: auth / subscribe (with+without filter) / unsubscribe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m1 = try parseClient(a, "{\"action\":\"auth\",\"token\":\"jwt123\"}");
    try std.testing.expectEqualStrings("jwt123", m1.auth.token);
    const m2 = try parseClient(a, "{\"action\":\"subscribe\",\"topic\":\"posts\",\"filter\":\"status='x'\"}");
    try std.testing.expectEqualStrings("posts", m2.subscribe.topic);
    try std.testing.expectEqualStrings("status='x'", m2.subscribe.filter.?);
    const m3 = try parseClient(a, "{\"action\":\"subscribe\",\"topic\":\"posts\"}");
    try std.testing.expect(m3.subscribe.filter == null);
    const m4 = try parseClient(a, "{\"action\":\"unsubscribe\",\"topic\":\"posts\"}");
    try std.testing.expectEqualStrings("posts", m4.unsubscribe.topic);
}

test "parseClient: malformed and unknown -> BadMessage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.BadMessage, parseClient(a, "not json"));
    try std.testing.expectError(error.BadMessage, parseClient(a, "{\"action\":\"bogus\"}"));
    try std.testing.expectError(error.BadMessage, parseClient(a, "{\"action\":\"auth\"}")); // missing token
    try std.testing.expectError(error.BadMessage, parseClient(a, "[]")); // not an object
}

test "parseTopic splits collection and optional record id" {
    const t1 = parseTopic("posts");
    try std.testing.expectEqualStrings("posts", t1.collection);
    try std.testing.expect(t1.record_id == null);
    const t2 = parseTopic("posts/REC123");
    try std.testing.expectEqualStrings("posts", t2.collection);
    try std.testing.expectEqualStrings("REC123", t2.record_id.?);
}

test "serializeEvent emits type/topic/action/record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rec: std.json.ObjectMap = .empty;
    try rec.put(a, "id", .{ .string = "REC1" });
    try rec.put(a, "title", .{ .string = "hi" });
    const s = try serializeEvent(a, "posts", .create, .{ .object = rec });
    try std.testing.expect(std.mem.indexOf(u8, s, "\"type\":\"event\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"topic\":\"posts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"action\":\"create\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"title\":\"hi\"") != null);
}

test "control frames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(std.mem.indexOf(u8, try connectFrame(a, "cid9"), "\"clientId\":\"cid9\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, try ackFrame(a, "subscribe", "posts"), "\"action\":\"subscribe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, try authFrame(a, true), "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, try authFrame(a, false), "\"status\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, try errorFrame(a, "nope"), "\"message\":\"nope\"") != null);
}
```

Register in `src/main.zig` test root: add `_ = @import("realtime/protocol.zig");`.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `parseClient`/`Action`/`parseTopic`/serializers undefined.

- [ ] **Step 3: Implement — insert above the tests in `src/realtime/protocol.zig`**

```zig
pub const Action = enum { create, update, delete };

pub const ClientMsg = union(enum) {
    auth: struct { token: []const u8 },
    subscribe: struct { topic: []const u8, filter: ?[]const u8 },
    unsubscribe: struct { topic: []const u8 },
};

pub const Topic = struct { collection: []const u8, record_id: ?[]const u8 };

pub const ParseError = error{BadMessage} || std.mem.Allocator.Error;

fn objStr(obj: std.json.Value, key: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    const v = obj.object.get(key) orelse return null;
    return switch (v) { .string => |s| s, else => null };
}

/// Parse a client message frame. Strings borrow from `alloc` (parse tree must outlive use; with an
/// arena that's automatic). Unknown action / missing field / non-object / bad JSON -> BadMessage.
pub fn parseClient(alloc: std.mem.Allocator, frame: []const u8) ParseError!ClientMsg {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, frame, .{}) catch return error.BadMessage;
    const root = parsed.value;
    if (root != .object) return error.BadMessage;
    const action = objStr(root, "action") orelse return error.BadMessage;
    if (std.mem.eql(u8, action, "auth")) {
        const token = objStr(root, "token") orelse return error.BadMessage;
        return .{ .auth = .{ .token = token } };
    } else if (std.mem.eql(u8, action, "subscribe")) {
        const topic = objStr(root, "topic") orelse return error.BadMessage;
        return .{ .subscribe = .{ .topic = topic, .filter = objStr(root, "filter") } };
    } else if (std.mem.eql(u8, action, "unsubscribe")) {
        const topic = objStr(root, "topic") orelse return error.BadMessage;
        return .{ .unsubscribe = .{ .topic = topic } };
    }
    return error.BadMessage;
}

/// Split a topic into `<collection>` or `<collection>/<recordId>`.
pub fn parseTopic(topic: []const u8) Topic {
    if (std.mem.indexOfScalar(u8, topic, '/')) |i| {
        return .{ .collection = topic[0..i], .record_id = topic[i + 1 ..] };
    }
    return .{ .collection = topic, .record_id = null };
}

/// {"type":"event","topic":..,"action":..,"record":record}
pub fn serializeEvent(alloc: std.mem.Allocator, topic: []const u8, action: Action, record: std.json.Value) ![]u8 {
    var o: std.json.ObjectMap = .empty;
    try o.put(alloc, "type", .{ .string = "event" });
    try o.put(alloc, "topic", .{ .string = topic });
    try o.put(alloc, "action", .{ .string = @tagName(action) });
    try o.put(alloc, "record", record);
    return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = o }, .{});
}

pub fn connectFrame(alloc: std.mem.Allocator, client_id: []const u8) ![]u8 {
    var o: std.json.ObjectMap = .empty;
    try o.put(alloc, "type", .{ .string = "connect" });
    try o.put(alloc, "clientId", .{ .string = client_id });
    return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = o }, .{});
}

pub fn ackFrame(alloc: std.mem.Allocator, action: []const u8, topic: []const u8) ![]u8 {
    var o: std.json.ObjectMap = .empty;
    try o.put(alloc, "type", .{ .string = "ack" });
    try o.put(alloc, "action", .{ .string = action });
    try o.put(alloc, "topic", .{ .string = topic });
    return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = o }, .{});
}

pub fn authFrame(alloc: std.mem.Allocator, ok: bool) ![]u8 {
    var o: std.json.ObjectMap = .empty;
    try o.put(alloc, "type", .{ .string = "auth" });
    try o.put(alloc, "status", .{ .string = if (ok) "ok" else "error" });
    return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = o }, .{});
}

pub fn errorFrame(alloc: std.mem.Allocator, message: []const u8) ![]u8 {
    var o: std.json.ObjectMap = .empty;
    try o.put(alloc, "type", .{ .string = "error" });
    try o.put(alloc, "message", .{ .string = message });
    return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = o }, .{});
}
```

- [ ] **Step 4: Run to verify pass**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS (5 new tests).

- [ ] **Step 5: Commit**

```bash
git add src/realtime/protocol.zig src/main.zig
git commit -m "feat(realtime): WebSocket wire protocol codec"
```

---

### Task 2: Connection model (`realtime/connection.zig`)

**Files:** Create `src/realtime/connection.zig`; Modify `src/main.zig`.

- [ ] **Step 1: Create `src/realtime/connection.zig` with the tests first**

```zig
const std = @import("std");
const request = @import("../request.zig");

test "subscriptions add/remove/get filter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var conn = Conn{};
    try conn.addSub(a, "posts", "status='x'");
    try conn.addSub(a, "users/REC1", null);
    try std.testing.expect(conn.hasSub("posts"));
    try std.testing.expectEqualStrings("status='x'", conn.subFilter("posts").?.*.?);
    try std.testing.expect(conn.subFilter("users/REC1").?.* == null);
    try std.testing.expect(conn.removeSub("posts"));
    try std.testing.expect(!conn.hasSub("posts"));
    try std.testing.expect(!conn.removeSub("missing"));
}

test "requestContext: anonymous, authed, expired" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var conn = Conn{};
    // anonymous
    try std.testing.expect(conn.requestContext(1000).auth == null);
    // authed, not expired
    var rec: std.json.ObjectMap = .empty;
    try rec.put(a, "id", .{ .string = "u1" });
    conn.setAuth(.{ .record = .{ .object = rec }, .is_superuser = false, .exp = 2000 });
    const c1 = conn.requestContext(1500);
    try std.testing.expect(c1.auth != null);
    try std.testing.expectEqualStrings("u1", c1.auth.?.object.get("id").?.string);
    // expired -> anonymous
    try std.testing.expect(conn.requestContext(2000).auth == null);
    try std.testing.expect(conn.requestContext(2001).auth == null);
    // superuser flag flows through when not expired
    conn.setAuth(.{ .record = .{ .object = rec }, .is_superuser = true, .exp = 2000 });
    try std.testing.expect(conn.requestContext(1500).is_superuser);
}
```

Register in `src/main.zig` test root: add `_ = @import("realtime/connection.zig");`.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `Conn`/`AuthIdentity` undefined.

- [ ] **Step 3: Implement — insert above the tests**

```zig
/// A verified connection identity. `exp` is the token's unix expiry; past it the connection is
/// treated as anonymous until a fresh `auth` message.
pub const AuthIdentity = struct {
    record: std.json.Value,
    is_superuser: bool,
    exp: i64,
};

/// Per-connection realtime state. In 7a this is the pure data model; 7b adds the live WS handle,
/// settings, clientId, and allocator. `subs` maps topic -> optional filter expression.
pub const Conn = struct {
    auth: ?AuthIdentity = null,
    subs: std.StringHashMapUnmanaged(?[]const u8) = .empty,

    pub fn setAuth(self: *Conn, ident: AuthIdentity) void {
        self.auth = ident;
    }
    pub fn clearAuth(self: *Conn) void {
        self.auth = null;
    }

    pub fn addSub(self: *Conn, alloc: std.mem.Allocator, topic: []const u8, filter: ?[]const u8) !void {
        const k = try alloc.dupe(u8, topic);
        const f: ?[]const u8 = if (filter) |x| try alloc.dupe(u8, x) else null;
        try self.subs.put(alloc, k, f);
    }
    pub fn removeSub(self: *Conn, topic: []const u8) bool {
        return self.subs.remove(topic);
    }
    pub fn hasSub(self: *const Conn, topic: []const u8) bool {
        return self.subs.contains(topic);
    }
    /// Returns a pointer to the stored optional filter for `topic`, or null if not subscribed.
    pub fn subFilter(self: *const Conn, topic: []const u8) ?*const ?[]const u8 {
        return self.subs.getPtr(topic);
    }

    /// Build the access-rules context for an event at unix time `now`. An absent or expired
    /// identity yields an anonymous context.
    pub fn requestContext(self: *const Conn, now: i64) request.RequestContext {
        if (self.auth) |ident| {
            if (ident.exp > now)
                return .{ .auth = ident.record, .is_superuser = ident.is_superuser, .method = "" };
        }
        return .{ .auth = null, .is_superuser = false, .method = "" };
    }
};
```

Note: `std.StringHashMapUnmanaged(V)` has `.getPtr(key) ?*V`, so `subFilter` returns `?*const ?[]const u8`. The test derefs as `subFilter("posts").?.*.?` (unwrap the optional pointer, deref `.*` to the stored `?[]const u8`, unwrap that). If a 0.16 std signature differs (e.g. `getPtr` returns a non-const pointer), adjust the `const`-ness only — the deref shape stands.

- [ ] **Step 4: Run to verify pass**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS. If the `subFilter` deref in the test doesn't compile, apply the explicit-deref form noted above, then re-run.

- [ ] **Step 5: Commit**

```bash
git add src/realtime/connection.zig src/main.zig
git commit -m "feat(realtime): per-connection auth + subscription model"
```

---

### Task 3: `shouldDeliver` decision (`realtime/hub.zig`)

**Files:** Create `src/realtime/hub.zig`; Modify `src/main.zig`.

This is the security-critical piece: it decides, per subscriber per event, whether to deliver — reusing the SP4 viewRule guard + SP3 filter compiler against a real DB.

- [ ] **Step 1: Create `src/realtime/hub.zig` with the tests first**

```zig
const std = @import("std");
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const rules = @import("../rules.zig");
const collections = @import("../collections.zig");
const records = @import("../records.zig");
const migrations = @import("../migrations.zig");
const protocol = @import("protocol.zig");
const connection = @import("connection.zig");
const Conn = connection.Conn;

const TestDb = struct {
    d: db.Db,
    fn init() !TestDb {
        var d = try db.Db.openMemory();
        try migrations.run(&d);
        return .{ .d = d };
    }
    fn deinit(self: *TestDb) void {
        self.d.close();
    }
    /// Create a collection with the given viewRule and one text field "owner"; returns it.
    fn mkColl(self: *TestDb, a: std.mem.Allocator, name: []const u8, view_rule: ?[]const u8) !schema.Collection {
        return collections.create(a, std.testing.io, &self.d, .{
            .id = "", .name = name,
            .fields = &[_]schema.Field{.{ .id = "f1", .name = "owner", .options = .{ .text = .{} } }},
            .listRule = "", .viewRule = view_rule, .createRule = "", .updateRule = "", .deleteRule = "",
        });
    }
    fn mkRec(self: *TestDb, a: std.mem.Allocator, col: schema.Collection, owner: []const u8) ![]const u8 {
        var data: std.json.ObjectMap = .empty;
        try data.put(a, "owner", .{ .string = owner });
        const rec = try records.create(a, std.testing.io, &self.d, col, .{ .object = data });
        return rec.object.get("id").?.string;
    }
};

fn authedConn(a: std.mem.Allocator, id: []const u8, is_super: bool) !Conn {
    var rec: std.json.ObjectMap = .empty;
    try rec.put(a, "id", .{ .string = id });
    var c = Conn{};
    c.setAuth(.{ .record = .{ .object = rec }, .is_superuser = is_super, .exp = 9999999999 });
    return c;
}

test "public viewRule (\"\"): create delivered to anyone, no filter" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try tdb.mkColl(a, "posts", "");
    const rid = try tdb.mkRec(a, col, "u1");
    var anon = Conn{};
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &anon, 0, .create, rid, null));
}

test "null viewRule: superuser-only" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try tdb.mkColl(a, "locked", null);
    const rid = try tdb.mkRec(a, col, "u1");
    var anon = Conn{};
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &anon, 0, .create, rid, null));
    var su = try authedConn(a, "admin", true);
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &su, 0, .create, rid, null));
}

test "macro viewRule: only the owner receives the record" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try tdb.mkColl(a, "notes", "owner = @request.auth.id");
    const rid = try tdb.mkRec(a, col, "u1");
    var owner = try authedConn(a, "u1", false);
    var other = try authedConn(a, "u2", false);
    var anon = Conn{};
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &owner, 0, .update, rid, null));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &other, 0, .update, rid, null));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &anon, 0, .update, rid, null));
}

test "subscription filter narrows within an authorized viewRule" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try tdb.mkColl(a, "items", ""); // public
    const rid = try tdb.mkRec(a, col, "alice");
    var anon = Conn{};
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &anon, 0, .create, rid, "owner = \"alice\""));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &anon, 0, .create, rid, "owner = \"bob\""));
}

test "delete is id-only/coarse: delivered unless locked" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pub_col = try tdb.mkColl(a, "p", "owner = @request.auth.id"); // check rule
    const locked = try tdb.mkColl(a, "l", null);
    var anon = Conn{};
    // delete on a check-rule collection: coarse -> delivered (id-only) even to a non-owner
    try std.testing.expect(try shouldDeliver(a, &tdb.d, pub_col, &anon, 0, .delete, "GONE", null));
    // delete on a locked collection: superuser-only
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, locked, &anon, 0, .delete, "GONE", null));
    var su = try authedConn(a, "admin", true);
    try std.testing.expect(try shouldDeliver(a, &tdb.d, locked, &su, 0, .delete, "GONE", null));
}

test "expired identity is treated as anonymous" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try tdb.mkColl(a, "notes", "owner = @request.auth.id");
    const rid = try tdb.mkRec(a, col, "u1");
    var rec: std.json.ObjectMap = .empty;
    try rec.put(a, "id", .{ .string = "u1" });
    var c = Conn{};
    c.setAuth(.{ .record = .{ .object = rec }, .is_superuser = false, .exp = 100 });
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &c, 50, .update, rid, null)); // before exp
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &c, 200, .update, rid, null)); // after exp -> anon
}
```

Register in `src/main.zig` test root: add `_ = @import("realtime/hub.zig");`.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `shouldDeliver` undefined.

- [ ] **Step 3: Implement — insert above the tests**

```zig
pub const DeliverError = rules.RuleError;

/// Combine clauses with `&&`, each parenthesized: `(c1) && (c2)`.
fn combineClauses(alloc: std.mem.Allocator, clauses: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (clauses, 0..) |c, i| {
        if (i > 0) try out.appendSlice(alloc, " && ");
        try out.append(alloc, '(');
        try out.appendSlice(alloc, c);
        try out.append(alloc, ')');
    }
    return out.toOwnedSlice(alloc);
}

/// Decide whether `conn` should receive an event for record `record_id` in `col` at unix time `now`.
/// create/update: authorize via viewRule AND the optional subscription filter, in one guarded query.
/// delete: id-only/coarse — delivered unless the viewRule is locked (null) and the conn isn't superuser
/// (the row is gone, so per-record re-authorization isn't possible; no record body is sent on delete).
pub fn shouldDeliver(
    alloc: std.mem.Allocator,
    reader: *db.Db,
    col: schema.Collection,
    conn: *const Conn,
    now: i64,
    action: protocol.Action,
    record_id: []const u8,
    sub_filter: ?[]const u8,
) DeliverError!bool {
    const rctx = conn.requestContext(now);

    if (action == .delete) {
        return rules.decide(col.viewRule, &rctx) != .deny_locked;
    }

    // create/update: assemble the clauses that must hold over the (existing) row.
    var clauses: std.ArrayList([]const u8) = .empty;
    defer clauses.deinit(alloc);
    switch (rules.decide(col.viewRule, &rctx)) {
        .deny_locked => return false,
        .allow => {},
        .check => try clauses.append(alloc, col.viewRule.?),
    }
    if (sub_filter) |f| if (f.len > 0) try clauses.append(alloc, f);
    if (clauses.items.len == 0) return true; // authorized and unfiltered

    const combined = try combineClauses(alloc, clauses.items);
    return rules.matches(alloc, reader, col, record_id, combined, &rctx);
}
```

- [ ] **Step 4: Run to verify pass**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS (7 new tests).

- [ ] **Step 5: Commit**

```bash
git add src/realtime/hub.zig src/main.zig
git commit -m "feat(realtime): rule-filtered shouldDeliver decision"
```

---

### Task 4: Event-frame building (`realtime/hub.zig`)

**Files:** Modify `src/realtime/hub.zig`.

Pure construction of the channels + frames that `broadcast` (Plan 7b) will publish: full record for create/update, **id-only** for delete.

- [ ] **Step 1: Add the failing tests** (append to `src/realtime/hub.zig` tests)

```zig
test "buildEventFrames: create carries the full record on both channels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rec: std.json.ObjectMap = .empty;
    try rec.put(a, "id", .{ .string = "REC1" });
    try rec.put(a, "title", .{ .string = "hi" });
    const ef = try buildEventFrames(a, "posts", .create, "REC1", .{ .object = rec });
    try std.testing.expectEqualStrings("posts", ef.collection_channel);
    try std.testing.expectEqualStrings("posts/REC1", ef.record_channel);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_collection, "\"topic\":\"posts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_collection, "\"title\":\"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_record, "\"topic\":\"posts/REC1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_record, "\"title\":\"hi\"") != null);
}

test "buildEventFrames: delete is id-only (no body fields)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ef = try buildEventFrames(a, "posts", .delete, "REC1", null);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_collection, "\"action\":\"delete\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_collection, "\"id\":\"REC1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_collection, "\"title\"") == null);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `buildEventFrames`/`EventFrames` undefined.

- [ ] **Step 3: Implement — add to `src/realtime/hub.zig`** (after `shouldDeliver`)

```zig
pub const EventFrames = struct {
    collection_channel: []const u8,
    record_channel: []const u8,
    frame_collection: []const u8,
    frame_record: []const u8,
};

/// Build the two channels + two serialized frames for a record event. create/update carry `record`
/// (full, hidden fields already stripped by the caller's records.get); delete carries only `{id}`.
pub fn buildEventFrames(
    alloc: std.mem.Allocator,
    collection: []const u8,
    action: protocol.Action,
    record_id: []const u8,
    record: ?std.json.Value,
) !EventFrames {
    const coll_channel = try alloc.dupe(u8, collection);
    const rec_channel = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ collection, record_id });

    const body: std.json.Value = if (action == .delete) blk: {
        var o: std.json.ObjectMap = .empty;
        try o.put(alloc, "id", .{ .string = record_id });
        break :blk .{ .object = o };
    } else record.?;

    return .{
        .collection_channel = coll_channel,
        .record_channel = rec_channel,
        .frame_collection = try protocol.serializeEvent(alloc, coll_channel, action, body),
        .frame_record = try protocol.serializeEvent(alloc, rec_channel, action, body),
    };
}
```

- [ ] **Step 4: Run to verify pass**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS (2 new tests).

- [ ] **Step 5: Commit**

```bash
git add src/realtime/hub.zig
git commit -m "feat(realtime): event-frame building (id-only delete)"
```

---

## Done criteria for 7a

- `mise exec zig@0.16.0 -- zig build test --summary all` green on branch `realtime`.
- Pure protocol codec (parse client / serialize events + control frames); the `Conn` model (auth + subs + expiry-aware `requestContext`); `shouldDeliver` proven across the leakage matrix (public/locked/macro viewRule × anon/owner/non-owner/superuser × filter match/no-match × create/update/delete × expired); id-only delete frames. No WebSocket, no facil.io, no `main` merge — those are Plan 7b.

---

## Self-Review (author)

- **Spec coverage:** wire protocol (§3 → Task 1); `Conn`/subscription/auth model + expiry-aware context (§2,§3,§5 → Task 2); `shouldDeliver` viewRule+filter reuse and the id-only/coarse delete (§4,§5 → Task 3); event-frame building with id-only delete + dual channels (§3,§4 → Task 4). Live WS upgrade/callbacks, `verifyToken`, `broadcast` publish, Origin check, smoke (§2,§8 7b) are explicitly Plan 7b.
- **Placeholder scan:** none — every code step is complete. The `subFilter` deref note in Task 2 gives an exact fallback, not a vague "fix it".
- **Type consistency:** `protocol.Action` (Task 1) used by `shouldDeliver` (Task 3) and `buildEventFrames` (Task 4); `Conn`/`AuthIdentity` (Task 2) consumed by Task 3; `combineClauses` uses the verified `&&` operator; `rules.decide`/`rules.matches`/`request.RequestContext` signatures match the current code.
- **Deferred to 7b (intentional):** the live `Conn` fields (handle/settings/clientId/allocator), `verifyToken`, facil.io `subscribe`/`publish`, the `broadcast` hook, Origin check, route. 7a's `Conn` is the pure data core they build on.
