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

/// Set true by the server just before `zap.start`; gates `broadcast` so it is a no-op when the
/// facil.io reactor isn't running (tests/CLI), avoiding "facil.io cluster inactive" noise + UB.
pub var active: bool = false;

/// Max concurrent subscriptions per connection (bounds per-conn facil.io subscription state).
const MAX_SUBS = 256;

/// Live per-connection state: the pure 7a `Conn` plus the zap handle / settings / app.
///
/// Two arenas: `durable` holds state that must persist across frames (auth record, subscription
/// keys/filters, sub_args, sub_ids); `frame` is per-callback scratch reset at the top of each
/// callback. facil.io serializes a connection's callbacks on one thread, so resetting `frame`
/// per callback is safe.
pub const LiveConn = struct {
    conn: connection.Conn = .{},
    handle: zap.WebSockets.WsHandle = null,
    settings: WS.WebSocketSettings = undefined, // facil.io holds &settings; must outlive the conn
    app: *App,
    durable: std.heap.ArenaAllocator,
    frame: std.heap.ArenaAllocator,
    client_id: [15]u8 = undefined,
    sub_args: std.ArrayList(*WS.SubscribeArgs) = .empty,
    sub_ids: std.StringHashMapUnmanaged(usize) = .empty, // topic -> facil.io subscription id
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
    if (!std.mem.eql(u8, target_protocol, "websocket")) return;
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
    lc.* = .{
        .app = app,
        .durable = std.heap.ArenaAllocator.init(app.allocator),
        .frame = std.heap.ArenaAllocator.init(app.allocator),
    };
    const cid = id.collectionId(app.io);
    @memcpy(&lc.client_id, &cid);
    lc.settings = .{
        .on_open = onOpen,
        .on_message = onMessage,
        .on_close = onClose,
        .context = lc,
    };
    WS.upgrade(r.h, &lc.settings) catch {
        lc.durable.deinit();
        lc.frame.deinit();
        app.allocator.destroy(lc);
        return;
    };
}

fn onOpen(context: ?*LiveConn, handle: zap.WebSockets.WsHandle) anyerror!void {
    const lc = context orelse return;
    lc.handle = handle;
    const a = lc.frame.allocator();
    const frame = try protocol.connectFrame(a, &lc.client_id);
    WS.write(handle, frame, true) catch {};
}

fn onMessage(context: ?*LiveConn, handle: zap.WebSockets.WsHandle, message: []const u8, is_text: bool) anyerror!void {
    _ = is_text;
    const lc = context orelse return;
    _ = lc.frame.reset(.retain_capacity);
    const fa = lc.frame.allocator();
    const da = lc.durable.allocator();
    const msg = protocol.parseClient(fa, message) catch {
        WS.write(handle, try protocol.errorFrame(fa, "bad message"), true) catch {};
        return;
    };
    switch (msg) {
        .auth => |m| {
            var r = lc.app.pool.acquireReader() catch {
                WS.write(handle, try protocol.authFrame(fa, false), true) catch {};
                return;
            };
            defer lc.app.pool.releaseReader(&r);
            // auth record must persist across frames -> durable allocator
            if (auth.verifyToken(da, lc.app, &r, m.token)) |v| {
                lc.conn.setAuth(.{ .record = v.record, .is_superuser = v.is_superuser, .exp = v.exp });
                WS.write(handle, try protocol.authFrame(fa, true), true) catch {};
            } else {
                lc.conn.clearAuth();
                WS.write(handle, try protocol.authFrame(fa, false), true) catch {};
            }
        },
        .subscribe => |m| {
            if (lc.conn.subs.count() >= MAX_SUBS) {
                WS.write(handle, try protocol.errorFrame(fa, "subscription limit reached"), true) catch {};
                return;
            }
            var r = lc.app.pool.acquireReader() catch return;
            const ok = blk: {
                defer lc.app.pool.releaseReader(&r);
                const t = protocol.parseTopic(m.topic);
                const col = (collections.get(fa, &r, t.collection) catch break :blk false) orelse break :blk false;
                _ = col;
                break :blk true;
            };
            if (!ok) {
                WS.write(handle, try protocol.errorFrame(fa, "unknown collection"), true) catch {};
                return;
            }
            // subscription keys/filters + sub_args must persist across frames -> durable allocator
            lc.conn.addSub(da, m.topic, m.filter) catch return;
            const args = da.create(WS.SubscribeArgs) catch return;
            args.* = .{ .channel = m.topic, .on_message = onChannelMessage, .context = lc };
            const sub_id = WS.subscribe(handle, args) catch 0;
            lc.sub_args.append(da, args) catch {};
            // track topic -> facil.io subscription id so unsubscribe can really cancel it
            if (sub_id != 0) lc.sub_ids.put(da, args.channel, sub_id) catch {};
            WS.write(handle, try protocol.ackFrame(fa, "subscribe", m.topic), true) catch {};
        },
        .unsubscribe => |m| {
            // Real unsubscribe: cancel the facil.io subscription via the vendored binding.
            if (lc.sub_ids.fetchRemove(m.topic)) |kv| {
                fio.websocket_unsubscribe(handle, kv.value);
            }
            _ = lc.conn.removeSub(m.topic);
            WS.write(handle, try protocol.ackFrame(fa, "unsubscribe", m.topic), true) catch {};
        },
    }
}

fn onChannelMessage(context: ?*LiveConn, handle: zap.WebSockets.WsHandle, channel: []const u8, message: []const u8) anyerror!void {
    const lc = context orelse return;
    if (!lc.conn.hasSub(channel)) return; // keep BEFORE reset/alloc so dead channels cost nothing
    _ = lc.frame.reset(.retain_capacity);
    const a = lc.frame.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, a, message, .{}) catch return;
    if (parsed.value != .object) return;
    const obj = parsed.value.object;
    const av = obj.get("action") orelse return;
    if (av != .string) return;
    const action_str = av.string;
    const action: protocol.Action = if (std.mem.eql(u8, action_str, "create")) .create
        else if (std.mem.eql(u8, action_str, "update")) .update
        else if (std.mem.eql(u8, action_str, "delete")) .delete
        else return;
    const rv = obj.get("record") orelse return;
    if (rv != .object) return;
    const idv = rv.object.get("id") orelse return;
    if (idv != .string) return;
    const record_id = idv.string;

    const t = protocol.parseTopic(channel);
    var r = lc.app.pool.acquireReader() catch return;
    defer lc.app.pool.releaseReader(&r);
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
    lc.durable.deinit();
    lc.frame.deinit();
    app.allocator.destroy(lc);
}

/// Publish a record event to its collection + record channels. Called from the record-writer path
/// (any thread); `fio_publish` is a non-blocking enqueue. `record` is the full record for
/// create/update (hidden fields already stripped) and is ignored for delete (id-only).
pub fn broadcast(app: *App, col: schema.Collection, action: protocol.Action, record_id: []const u8, record: ?std.json.Value) void {
    if (!active) return; // reactor not running (tests/CLI): no-op to avoid "cluster inactive" + UB
    _ = app;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ef = hub.buildEventFrames(a, col.name, action, record_id, record) catch return;
    WS.publish(.{ .channel = ef.collection_channel, .message = ef.frame_collection });
    WS.publish(.{ .channel = ef.record_channel, .message = ef.frame_record });
}

test "originAllowed: empty allowlist allows any; CSV matches exactly" {
    try std.testing.expect(originAllowed("", null));
    try std.testing.expect(originAllowed("", "https://anything"));
    try std.testing.expect(originAllowed("https://a.com, https://b.com", "https://b.com"));
    try std.testing.expect(!originAllowed("https://a.com", "https://evil.com"));
    try std.testing.expect(!originAllowed("https://a.com", null));
}

test "broadcast is a no-op when inactive" {
    // active defaults to false; broadcast must return immediately without touching the reactor.
    try std.testing.expect(!active);
    var app: App = undefined;
    broadcast(&app, undefined, .create, "rec1", null); // would crash if it didn't early-return
}
