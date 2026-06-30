//! Cross-instance realtime over Postgres `LISTEN`/`NOTIFY` (#159, PR-6b).
//!
//! ## Why
//! ZigBase's realtime change-feed is app-layer: after a record write COMMITs, the writing
//! instance publishes event frames into facil.io's in-process pub/sub (`ws.broadcast` →
//! `WS.publish`), and each local subscriber's `onChannelMessage` re-authorizes + delivers. That
//! is complete realtime parity for SQLite, which is single-process. But the entire point of the
//! Postgres backend is multi-instance deployment: a write on instance A must reach subscribers on
//! instances B/C that share the one database. In-process pub/sub never crosses the process
//! boundary, so without this bridge realtime silently fragments across instances.
//!
//! ## How (NOTIFY, not logical decoding)
//! On the SAME after-commit dispatch point, the writer additionally issues
//! `NOTIFY zigbase_rt, '<payload>'` carrying a MINIMAL `{o,c,a,i[,s]}` body (origin, collection,
//! action, id, and — for deletes only — the pre-delete snapshot). Every process runs ONE
//! dedicated listener connection (`startListener`) that `LISTEN`s on the channel and, for each
//! notification from a DIFFERENT instance, re-feeds the EXISTING in-process hub: it re-fetches the
//! live row (create/update) or uses the carried snapshot (delete), then `WS.publish`es the same
//! frames `broadcast` would have — so the unchanged `onChannelMessage` path runs each subscriber's
//! existing view/ability/tenant authz locally. No large payloads on the wire, no replication
//! slots, no `wal_level=logical`, and the app's authz is never bypassed.
//!
//! ## Self-delivery
//! The writer ALSO receives its own NOTIFY (PG delivers to every LISTENer, including the same
//! process's listener connection). Each payload carries a per-process `origin` id; the listener
//! drops notifications whose origin is its own, so the writing instance delivers exactly once
//! (in-process), and only REMOTE instances act on the NOTIFY.
//!
//! ## Gating
//! The whole module compiles in both builds, but every wire op funnels through the `db.Db` seam
//! helpers (`db.dbListen`/`dbNotify`/`dbWaitNotification`) which are comptime no-ops on SQLite.
//! `emit`/`startListener` additionally early-return unless the active backend is Postgres, so the
//! default single-binary story links zero new behavior and SQLite realtime is byte-identical.

const std = @import("std");
const build_options = @import("build_options");
const db = @import("../db.zig");
const App = @import("../app.zig").App;
const entropy = @import("../entropy.zig");
const protocol = @import("protocol.zig");

/// The single NOTIFY channel all instances LISTEN on. A valid SQL identifier (the driver
/// validates it again before interpolating into `LISTEN "<channel>"`).
pub const channel = "zigbase_rt";

/// NOTIFY's payload hard limit is 8000 bytes; stay comfortably under it. A delete snapshot that
/// would overflow is dropped (see `encode`) — remote instances then conservatively deny
/// owner/expression-scoped deletes (the safe direction) while `@public` deletes still deliver.
const max_payload = 7900;

// ---- per-process origin id --------------------------------------------------

var origin_hex: [16]u8 = undefined;
var origin_ready: bool = false;
var origin_mu: std.atomic.Mutex = .unlocked;

/// A stable, per-process random id (16 hex chars) tagging every NOTIFY this instance emits, so a
/// listener can skip its OWN notifications (already delivered in-process). Lazily initialized; the
/// `io` provides the CSPRNG (and honors the deterministic test seed via `entropy.fill`).
pub fn originId(io: std.Io) []const u8 {
    while (!origin_mu.tryLock()) std.atomic.spinLoopHint();
    defer origin_mu.unlock();
    if (!origin_ready) {
        var raw: [8]u8 = undefined;
        entropy.fill(io, &raw);
        const hex = "0123456789abcdef";
        for (raw, 0..) |b, i| {
            origin_hex[i * 2] = hex[b >> 4];
            origin_hex[i * 2 + 1] = hex[b & 0x0f];
        }
        origin_ready = true;
    }
    return &origin_hex;
}

// ---- payload codec ----------------------------------------------------------

fn actionStr(a: protocol.Action) []const u8 {
    return switch (a) {
        .create => "create",
        .update => "update",
        .delete => "delete",
    };
}

/// Encode the NOTIFY payload. create/update stay minimal (`{o,c,a,i}`) — the remote re-fetches the
/// live row. delete carries the pre-delete `s`napshot so remote instances can authorize
/// owner/expression-scoped deletes (the live row is gone). An oversize snapshot is dropped.
pub fn encode(
    a: std.mem.Allocator,
    origin: []const u8,
    collection: []const u8,
    action: protocol.Action,
    record_id: []const u8,
    record: ?std.json.Value,
) ![]u8 {
    const with_snapshot = action == .delete and record != null;
    const s = try encodeObj(a, origin, collection, action, record_id, if (with_snapshot) record else null);
    if (s.len <= max_payload) return s;
    // Oversize (only possible with a snapshot): re-encode minimally without it.
    if (with_snapshot) return encodeObj(a, origin, collection, action, record_id, null);
    return s;
}

fn encodeObj(
    a: std.mem.Allocator,
    origin: []const u8,
    collection: []const u8,
    action: protocol.Action,
    record_id: []const u8,
    snapshot: ?std.json.Value,
) ![]u8 {
    var o: std.json.ObjectMap = .empty;
    try o.put(a, "o", .{ .string = origin });
    try o.put(a, "c", .{ .string = collection });
    try o.put(a, "a", .{ .string = actionStr(action) });
    try o.put(a, "i", .{ .string = record_id });
    if (snapshot) |snap| try o.put(a, "s", snap);
    return std.json.Stringify.valueAlloc(a, std.json.Value{ .object = o }, .{});
}

/// A decoded cross-instance event. `snapshot` is the delete authorization snapshot (delete only).
pub const Event = struct {
    origin: []const u8,
    collection: []const u8,
    action: protocol.Action,
    id: []const u8,
    snapshot: ?std.json.Value,
};

fn strField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Parse a NOTIFY payload into an `Event` (allocating into `a`), or null if malformed.
pub fn decode(a: std.mem.Allocator, payload: []const u8) ?Event {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, payload, .{}) catch return null;
    if (parsed != .object) return null;
    const o = parsed.object;
    const origin = strField(o, "o") orelse return null;
    const collection = strField(o, "c") orelse return null;
    const astr = strField(o, "a") orelse return null;
    const record_id = strField(o, "i") orelse return null;
    const action: protocol.Action = if (std.mem.eql(u8, astr, "create"))
        .create
    else if (std.mem.eql(u8, astr, "update"))
        .update
    else if (std.mem.eql(u8, astr, "delete"))
        .delete
    else
        return null;
    return .{
        .origin = origin,
        .collection = collection,
        .action = action,
        .id = record_id,
        .snapshot = o.get("s"),
    };
}

// ---- emit (writer → NOTIFY) -------------------------------------------------

/// Fan a just-committed record event out to OTHER instances via `NOTIFY`. Called from
/// `ws.broadcast` AFTER the local in-process publish. A no-op unless the active backend is
/// Postgres; failures are swallowed (realtime is best-effort — a missed NOTIFY never fails the
/// write, and the writing instance already delivered locally).
pub fn emit(
    app: *App,
    collection: []const u8,
    action: protocol.Action,
    record_id: []const u8,
    record: ?std.json.Value,
) void {
    if (!build_options.postgres) return;
    if (db.poolBackend(app.pool) != .postgres) return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const payload = encode(a, originId(app.io), collection, action, record_id, record) catch return;
    var c = app.pool.acquireReader() catch return;
    defer app.pool.releaseReader(&c);
    db.dbNotify(&c, a, channel, payload) catch {};
}

// ---- listener (NOTIFY → in-process hub) -------------------------------------

const ListenerCtx = struct {
    app: *App,
    conn: db.Db,
    on_event: *const fn (*App, Event) void,
};

/// Open a dedicated connection, `LISTEN` on the channel, and spawn a detached, process-lifetime
/// thread that feeds each REMOTE notification to `on_event`. A no-op (returns cleanly) unless the
/// active backend is Postgres. The thread runs until the connection drops (e.g. process exit);
/// realtime is best-effort, so a dropped listener simply stops fanning in remote events — the
/// instance still serves local subscribers.
pub fn startListener(app: *App, on_event: *const fn (*App, Event) void) !void {
    if (!build_options.postgres) return;
    if (db.poolBackend(app.pool) != .postgres) return;
    // Prime the origin id on the serving thread so `emit` and the listener agree.
    _ = originId(app.io);
    var conn = try app.pool.openReader();
    errdefer conn.close();
    try db.dbListen(&conn, channel);
    const ctx = try app.allocator.create(ListenerCtx);
    errdefer app.allocator.destroy(ctx);
    ctx.* = .{ .app = app, .conn = conn, .on_event = on_event };
    const t = try std.Thread.spawn(.{}, listenerLoop, .{ctx});
    t.detach();
}

fn listenerLoop(ctx: *ListenerCtx) void {
    defer {
        ctx.conn.close();
        ctx.app.allocator.destroy(ctx);
    }
    while (true) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const maybe = db.dbWaitNotification(&ctx.conn, a) catch break; // conn dropped → stop
        const n = maybe orelse continue; // a non-notification async message: ignore
        if (!std.mem.eql(u8, n.channel, channel)) continue;
        const ev = decode(a, n.payload) orelse continue;
        if (std.mem.eql(u8, ev.origin, originId(ctx.app.io))) continue; // our own write: already local
        ctx.on_event(ctx.app, ev);
    }
}

// ---- tests (codec; the live cross-instance path is in backend/postgres/realtime_pg_test.zig) ---

test "encode/decode round-trip: create is minimal (no snapshot)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const payload = try encode(a, "abc123", "posts", .create, "REC1", null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"s\"") == null); // no snapshot key
    const ev = decode(a, payload).?;
    try std.testing.expectEqualStrings("abc123", ev.origin);
    try std.testing.expectEqualStrings("posts", ev.collection);
    try std.testing.expectEqual(protocol.Action.create, ev.action);
    try std.testing.expectEqualStrings("REC1", ev.id);
    try std.testing.expect(ev.snapshot == null);
}

test "encode/decode round-trip: delete carries the authz snapshot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var snap: std.json.ObjectMap = .empty;
    try snap.put(a, "id", .{ .string = "REC1" });
    try snap.put(a, "owner", .{ .string = "u1" });
    const payload = try encode(a, "o1", "notes", .delete, "REC1", .{ .object = snap });
    const ev = decode(a, payload).?;
    try std.testing.expectEqual(protocol.Action.delete, ev.action);
    try std.testing.expect(ev.snapshot != null);
    try std.testing.expectEqualStrings("u1", ev.snapshot.?.object.get("owner").?.string);
}

test "encode: oversize delete snapshot is dropped (NOTIFY 8000-byte limit)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var snap: std.json.ObjectMap = .empty;
    try snap.put(a, "id", .{ .string = "REC1" });
    const big = try a.alloc(u8, 9000);
    @memset(big, 'x');
    try snap.put(a, "blob", .{ .string = big });
    const payload = try encode(a, "o1", "notes", .delete, "REC1", .{ .object = snap });
    try std.testing.expect(payload.len <= max_payload);
    const ev = decode(a, payload).?;
    try std.testing.expect(ev.snapshot == null); // dropped → remote conservatively denies
    try std.testing.expectEqualStrings("REC1", ev.id); // id still present
}

test "decode: malformed / missing fields return null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(decode(a, "not json") == null);
    try std.testing.expect(decode(a, "{\"c\":\"posts\"}") == null); // missing o/a/i
    try std.testing.expect(decode(a, "{\"o\":\"x\",\"c\":\"p\",\"a\":\"frob\",\"i\":\"1\"}") == null); // bad action
}

test "originId is stable within a process" {
    const id1 = originId(std.testing.io);
    const id2 = originId(std.testing.io);
    try std.testing.expectEqual(@as(usize, 16), id1.len);
    try std.testing.expectEqualStrings(id1, id2);
}
