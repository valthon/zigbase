const std = @import("std");
const zap = @import("zap");
const fio = zap.fio;
const App = @import("../app.zig").App;
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const collections = @import("../collections.zig");
const rules = @import("../rules.zig");
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

/// F9: global cap on concurrent WebSocket connections. Deliberately a module-level constant in the
/// realtime layer (NOT config.zig) so an operator can't accidentally disable it and a parallel
/// config workstream doesn't conflict. New upgrades past this cap are rejected with 503.
pub const MAX_CONNECTIONS: usize = 10_000;

/// Live WS connection count. Bumped on a successful upgrade, decremented on close. Connection
/// callbacks for one socket are serialized by facil.io but different sockets run on different
/// threads, so this is an atomic.
var live_connections: std.atomic.Value(usize) = .init(0);

/// Current live WS connection count (test/introspection helper).
pub fn connectionCount() usize {
    return live_connections.load(.monotonic);
}

/// Atomically reserve a global connection slot (F9). Returns false (and leaves the count unchanged)
/// when the cap is already reached, so the caller must reject the upgrade. Pair a successful
/// reservation with exactly one `releaseConnectionSlot`.
fn reserveConnectionSlot() bool {
    if (live_connections.fetchAdd(1, .monotonic) >= MAX_CONNECTIONS) {
        _ = live_connections.fetchSub(1, .monotonic);
        return false;
    }
    return true;
}

fn releaseConnectionSlot() void {
    _ = live_connections.fetchSub(1, .monotonic);
}

/// F5: may a socket subscribe to a collection with this `view_rule`? Anonymous sockets may
/// subscribe ONLY to a public (@public) collection. Any other collection — locked, owner-scoped,
/// or any expression — requires a live authenticated (or superuser) identity first. Delivery is
/// still independently gated per record by `hub.shouldDeliver`; this just stops anonymous sockets
/// from registering subscriptions on gated data.
fn subscribeAuthorized(view_rule: ?[]const u8, authed: bool, is_superuser: bool) bool {
    if (rules.isPublic(view_rule)) return true;
    return authed or is_superuser;
}

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

/// Is `origin` allowed for an upgrade? (F12, secure-by-default)
/// An empty allowlist no longer means "allow any". The rules, in order:
///   1. No `Origin` header (a non-browser client — CLI/server-to-server, which cannot
///      be CSRF'd via a victim's browser) => allowed.
///   2. **Same-origin**: the Origin's authority equals the request `Host`. This is the
///      embedded admin UI and any frontend served from this same binary; a malicious
///      cross-site page cannot forge `Origin` to match the target's Host, so same-origin
///      is always safe and must work out of the box without configuring an allowlist.
///   3. Otherwise (a genuine cross-origin browser upgrade) => allowed only if the origin
///      is on the explicit CSV allowlist.
/// Delivery is still subject to per-record viewRule authorization regardless.
pub fn originAllowed(allowlist: []const u8, origin: ?[]const u8, host: ?[]const u8) bool {
    const o = origin orelse return true; // no Origin header => non-browser client
    // Same-origin: Origin is `scheme://authority`; allow when authority == Host.
    if (host) |h| {
        if (std.mem.indexOf(u8, o, "://")) |i| {
            if (std.mem.eql(u8, o[i + 3 ..], h)) return true;
        }
    }
    if (allowlist.len == 0) return false; // cross-origin browser upgrade but no allowlist => deny
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
    if (!originAllowed(app.realtime_allowed_origins, r.getHeader("origin"), r.getHeader("host"))) {
        r.setStatus(.forbidden);
        r.markAsFinished(true);
        return;
    }
    // F9: reserve a global connection slot up front; reject past the cap. Reserving before alloc
    // (and releasing on any failure below) keeps the counter exact under concurrent upgrades.
    if (!reserveConnectionSlot()) {
        r.setStatus(.service_unavailable);
        r.markAsFinished(true);
        return;
    }
    errdefer releaseConnectionSlot();
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
        releaseConnectionSlot(); // release the reserved slot
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
            const Outcome = enum { ok, unknown, auth_required };
            const outcome: Outcome = blk: {
                defer lc.app.pool.releaseReader(&r);
                const t = protocol.parseTopic(m.topic);
                const col = (collections.get(fa, &r, t.collection) catch break :blk .unknown) orelse break :blk .unknown;
                // F5: a socket may subscribe anonymously ONLY to a public (@public viewRule)
                // collection. For any other collection require a live (non-expired) auth first, so
                // an unauthenticated socket cannot subscribe to (and tie up resources on) gated data.
                const now = auth.nowUnixPub(&r) catch 0;
                const rctx = lc.conn.requestContext(now);
                if (!subscribeAuthorized(col.viewRule, rctx.auth != null, rctx.is_superuser))
                    break :blk .auth_required;
                break :blk .ok;
            };
            switch (outcome) {
                .ok => {},
                .unknown => {
                    WS.write(handle, try protocol.errorFrame(fa, "unknown collection"), true) catch {};
                    return;
                },
                .auth_required => {
                    WS.write(handle, try protocol.errorFrame(fa, "authentication required to subscribe"), true) catch {};
                    return;
                },
            }
            // subscription keys/filters + sub_args must persist across frames -> durable allocator.
            // m.topic is parsed from the per-message buffer and is freed once onMessage returns, so
            // dupe it durably and use that copy for BOTH the facil.io subscription args and the
            // sub_ids key. Keying sub_ids off the ephemeral m.topic was a use-after-free: a later
            // unsubscribe's fetchRemove() would compare against freed memory and crash the worker.
            const channel = da.dupe(u8, m.topic) catch return;
            lc.conn.addSub(da, m.topic, m.filter) catch return;
            const args = da.create(WS.SubscribeArgs) catch return;
            args.* = .{ .channel = channel, .on_message = onChannelMessage, .context = lc };
            const sub_id = WS.subscribe(handle, args) catch 0;
            lc.sub_args.append(da, args) catch {};
            // track topic -> facil.io subscription id so unsubscribe can really cancel it
            if (sub_id != 0) lc.sub_ids.put(da, channel, sub_id) catch {};
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

    // F4: the deleted-record authorization snapshot rides in the published delete frame under a
    // private key. Pull it out for per-subscriber authz, then strip it so the client frame is id-only.
    const delete_snapshot: ?std.json.Value = if (action == .delete) rv.object.get(hub.delete_snapshot_key) else null;

    const t = protocol.parseTopic(channel);
    var r = lc.app.pool.acquireReader() catch return;
    defer lc.app.pool.releaseReader(&r);
    const col = (collections.get(a, &r, t.collection) catch return) orelse return;
    const now = auth.nowUnixPub(&r) catch return;
    const filter_ptr = lc.conn.subFilter(channel);
    const sub_filter: ?[]const u8 = if (filter_ptr) |p| p.* else null;

    const deliver = hub.shouldDeliver(a, lc.app.io, &r, col, &lc.conn, now, action, record_id, sub_filter, delete_snapshot) catch return;
    if (!deliver) return;

    if (action == .delete and delete_snapshot != null) {
        // Re-serialize an id-only delete frame so the private snapshot never reaches the client.
        var clean: std.json.ObjectMap = .empty;
        clean.put(a, "id", idv) catch return;
        const frame = protocol.serializeEvent(a, channel, .delete, .{ .object = clean }) catch return;
        WS.write(handle, frame, true) catch {};
    } else {
        WS.write(handle, message, true) catch {};
    }
}

fn onClose(context: ?*LiveConn, uuid: isize) anyerror!void {
    _ = uuid;
    const lc = context orelse return;
    const app = lc.app;
    lc.durable.deinit();
    lc.frame.deinit();
    app.allocator.destroy(lc);
    releaseConnectionSlot(); // F9: free the global connection slot
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

test "originAllowed: empty allowlist denies cross-origin browser upgrades (F12); same-origin + CSV allowed" {
    // Secure-by-default: an empty allowlist DENIES a cross-origin browser upgrade...
    try std.testing.expect(!originAllowed("", "https://anything", "myhost:8090"));
    // ...but a request with no Origin header (non-browser client) is still allowed.
    try std.testing.expect(originAllowed("", null, null));
    try std.testing.expect(originAllowed("https://a.com", null, null));
    // Same-origin (Origin authority == Host) is always allowed, even with no allowlist —
    // this is the embedded admin UI / a frontend served from the same binary.
    try std.testing.expect(originAllowed("", "http://127.0.0.1:8090", "127.0.0.1:8090"));
    try std.testing.expect(originAllowed("", "https://app.example.com", "app.example.com"));
    // A cross-origin request whose authority differs from Host is NOT same-origin.
    try std.testing.expect(!originAllowed("", "https://evil.com", "127.0.0.1:8090"));
    // Explicit allowlist matches exactly (cross-origin, host differs).
    try std.testing.expect(originAllowed("https://a.com, https://b.com", "https://b.com", "api.myhost"));
    try std.testing.expect(!originAllowed("https://a.com", "https://evil.com", "api.myhost"));
}

test "broadcast is a no-op when inactive" {
    // active defaults to false; broadcast must return immediately without touching the reactor.
    try std.testing.expect(!active);
    var app: App = undefined;
    broadcast(&app, undefined, .create, "rec1", null); // would crash if it didn't early-return
}

test "F5: anonymous subscribe allowed only on @public; gated collections require auth" {
    // @public -> anyone (incl. anonymous) may subscribe.
    try std.testing.expect(subscribeAuthorized("@public", false, false));
    try std.testing.expect(subscribeAuthorized("@public", true, false));
    // null (locked): anonymous rejected; authed/superuser allowed (delivery still gated later).
    try std.testing.expect(!subscribeAuthorized(null, false, false));
    try std.testing.expect(subscribeAuthorized(null, true, false));
    try std.testing.expect(subscribeAuthorized(null, false, true));
    // "" (now LOCKED): anonymous rejected.
    try std.testing.expect(!subscribeAuthorized("", false, false));
    // owner/expression rule: anonymous rejected, authed allowed to subscribe.
    try std.testing.expect(!subscribeAuthorized("owner = @request.auth.id", false, false));
    try std.testing.expect(subscribeAuthorized("owner = @request.auth.id", true, false));
}

test "F9: global connection cap reserves/releases and rejects past MAX_CONNECTIONS" {
    // Drive the count up to the cap, confirm the next reservation is rejected, then release.
    const start = connectionCount();
    try std.testing.expectEqual(@as(usize, 0), start); // tests run single-threaded; clean slate
    // Pre-load to one below the cap without spinning MAX_CONNECTIONS times.
    live_connections.store(MAX_CONNECTIONS - 1, .monotonic);
    try std.testing.expect(reserveConnectionSlot()); // fills the last slot
    try std.testing.expectEqual(MAX_CONNECTIONS, connectionCount());
    try std.testing.expect(!reserveConnectionSlot()); // at cap -> rejected, count unchanged
    try std.testing.expectEqual(MAX_CONNECTIONS, connectionCount());
    releaseConnectionSlot();
    try std.testing.expectEqual(MAX_CONNECTIONS - 1, connectionCount());
    try std.testing.expect(reserveConnectionSlot()); // a freed slot is reusable
    // Clean up the counter so a later test sees a clean slate.
    live_connections.store(0, .monotonic);
}
