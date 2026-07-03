const std = @import("std");
const zap = @import("zap");
const fio = zap.fio;
const App = @import("../app.zig").App;
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const collections = @import("../collections.zig");
const records = @import("../records.zig");
const pg_bridge = @import("pg_bridge.zig");
const auth = @import("../auth.zig");
const id = @import("../id.zig");
const protocol = @import("protocol.zig");
const connection = @import("connection.zig");
const hub = @import("hub.zig");
const sse = @import("sse.zig");
const request = @import("../request.zig");
const tenancy = @import("../tenancy/tenancy.zig");
const Ctx = @import("../ctx.zig").Ctx;

/// Set true by the server just before `zap.start`; gates `broadcast` so it is a no-op when the
/// facil.io reactor isn't running (tests/CLI), avoiding "facil.io cluster inactive" noise + UB.
pub var active: bool = false;

/// Re-exported from hub.zig (moved so the delivery chokepoint can use it); consumers/tests keep
/// this name.
pub const FEATURES_CHANNEL = hub.FEATURES_CHANNEL;

/// Re-exported from connection.zig (hoisted for transport sharing); consumers/tests keep this name.
pub const MAX_CONNECTIONS = connection.MAX_CONNECTIONS;
pub const connectionCount = connection.connectionCount;

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
    /// The account the subscriber asked to act within, captured from the HTTP handshake
    /// (`X-Account-Id` header or the signed `zb_account` cookie) and duped onto `durable`. It is
    /// VERIFIED against `_memberships` at `auth`-frame time; an unverified value never grants scope.
    /// "" when tenancy is off or no account was requested. (#156)
    requested_account: []const u8 = "",
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

/// The account the subscriber requested at the HTTP handshake: the `X-Account-Id` header (unsigned —
/// the membership check at resolve time is the real gate) or the signed `zb_account` cookie. The
/// returned slice is duped onto `da` (the connection-durable arena) because zap.Request buffers are
/// freed after the upgrade callback returns. null when neither is present/valid. (#156)
pub fn requestedAccountFromUpgrade(app: *App, r: zap.Request, da: std.mem.Allocator) ?[]const u8 {
    if (r.getHeader("x-account-id")) |h| if (h.len > 0) return da.dupe(u8, h) catch null;
    const ch = r.getHeader("cookie") orelse return null;
    const raw = cookieValue(ch, tenancy.account_cookie) orelse return null;
    const verified = tenancy.verifyAccount(app.jwt_secret, raw) orelse return null;
    return da.dupe(u8, verified) catch null;
}

/// Extract the value of cookie `name` from a raw `Cookie` header (mirrors `http.RequestCtx.cookie`).
pub fn cookieValue(header: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, header, ';');
    while (it.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, " ");
        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
            if (std.mem.eql(u8, trimmed[0..eq], name)) return trimmed[eq + 1 ..];
        }
    }
    return null;
}

/// Listener on_upgrade hook for BOTH realtime transports. facil.io routes an exact
/// `Accept: text/event-stream` request here with target == "sse" (spike §1) — the same
/// callback WS upgrades use. Dispatch:
///   - "websocket" + /api/realtime      -> WS path (unchanged).
///   - "sse"       + /api/realtime/sse  -> SSE path (#188).
///   - anything else -> 404 + markAsFinished (fixes the old early-`return` that silently
///     swallowed "sse" targets without finishing the request).
/// Shared gates, in order: originAllowed (F12), the ONE global connection slot (F9 — WS+SSE
/// share MAX_CONNECTIONS), tenancy capture (inside each arm; zap.Request buffers are freed
/// after this returns).
pub fn handleUpgrade(r: zap.Request, target_protocol: []const u8) anyerror!void {
    const Server = @import("../server.zig").Server;
    const app = Server.instance.?.app;
    const path = r.path orelse "";
    const is_ws = std.mem.eql(u8, target_protocol, "websocket") and std.mem.eql(u8, path, "/api/realtime");
    const is_sse = std.mem.eql(u8, target_protocol, "sse") and std.mem.eql(u8, path, "/api/realtime/sse");
    if (!is_ws and !is_sse) {
        r.setStatus(.not_found);
        r.markAsFinished(true);
        return;
    }
    if (!originAllowed(app.realtime_allowed_origins, r.getHeader("origin"), r.getHeader("host"))) {
        r.setStatus(.forbidden);
        r.markAsFinished(true);
        return;
    }
    // F9: reserve the SHARED (WS+SSE) global connection slot up front; reject past the cap.
    if (!connection.reserveConnectionSlot()) {
        r.setStatus(.service_unavailable);
        r.markAsFinished(true);
        return;
    }
    if (is_sse) {
        sse.openStream(r, app); // owns releasing the slot on any failure inside
        return;
    }
    errdefer connection.releaseConnectionSlot();
    const lc = try app.allocator.create(LiveConn);
    lc.* = .{
        .app = app,
        .durable = std.heap.ArenaAllocator.init(app.allocator),
        .frame = std.heap.ArenaAllocator.init(app.allocator),
    };
    const cid = id.collectionId(app.io);
    @memcpy(&lc.client_id, &cid);
    // #156: carry tenancy through the realtime path. `tenancy_enabled` is set unconditionally from
    // the app config so the realtime RequestContext ALWAYS fails closed (an unresolved account
    // denies tenant-owned delivery, never leaks). Capture the requested account from the handshake
    // now (zap.Request buffers are freed after this returns) — it is VERIFIED at auth time.
    if (app.tenancy.enabled) {
        lc.conn.tenancy_enabled = true;
        if (requestedAccountFromUpgrade(app, r, lc.durable.allocator())) |acc| lc.requested_account = acc;
    }
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
        connection.releaseConnectionSlot(); // release the reserved slot
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
            const ok = hub.authVerb(lc.app, &lc.conn, da, m.token, lc.requested_account);
            WS.write(handle, try protocol.authFrame(fa, ok), true) catch {};
        },
        .subscribe => |m| {
            switch (hub.subscribeCheck(lc.app, &lc.conn, fa, m.topic)) {
                .limit => {
                    WS.write(handle, try protocol.errorFrame(fa, "subscription limit reached"), true) catch {};
                    return;
                },
                .unknown => {
                    WS.write(handle, try protocol.errorFrame(fa, "unknown collection"), true) catch {};
                    return;
                },
                .auth_required => {
                    WS.write(handle, try protocol.errorFrame(fa, "authentication required to subscribe"), true) catch {};
                    return;
                },
                .ok => {},
            }
            // fio-side residue (UNCHANGED — ws.zig:328-341): durable channel dupe, conn.addSub,
            // SubscribeArgs, WS.subscribe, sub_ids bookkeeping, ack write.
            const channel = da.dupe(u8, m.topic) catch return;
            lc.conn.addSub(da, m.topic, m.filter) catch return;
            const args = da.create(WS.SubscribeArgs) catch return;
            args.* = .{ .channel = channel, .on_message = onChannelMessage, .context = lc };
            const sub_id = WS.subscribe(handle, args) catch 0;
            lc.sub_args.append(da, args) catch {};
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
    const filter_ptr = lc.conn.subFilter(channel);
    const sub_filter: ?[]const u8 = if (filter_ptr) |p| p.* else null;
    if (hub.frameForDelivery(a, lc.app, &lc.conn, sub_filter, channel, message)) |frame| {
        WS.write(handle, frame, true) catch {};
    }
}

fn onClose(context: ?*LiveConn, uuid: isize) anyerror!void {
    _ = uuid;
    const lc = context orelse return;
    const app = lc.app;
    lc.durable.deinit();
    lc.frame.deinit();
    app.allocator.destroy(lc);
    connection.releaseConnectionSlot(); // F9: free the global connection slot
}

/// Publish a record event to its collection + record channels. Called from the record-writer path
/// (any thread); `fio_publish` is a non-blocking enqueue. `record` is the full record for
/// create/update (hidden fields already stripped) and the deletion snapshot for delete.
///
/// On Postgres this ALSO fans the event out to other app instances via `NOTIFY` (#159, PR-6b) so
/// multi-instance deployments deliver realtime correctly; on SQLite (single-process) `emit` is a
/// no-op and behavior is byte-identical. `notify_token` (delete only) keys the deleted row's
/// at-rest snapshot in the side table — see `prepareDelete`; null for create/update and on
/// SQLite. The NOTIFY carries only the token, never the (possibly encrypted) row data.
pub fn broadcast(app: *App, col: schema.Collection, action: protocol.Action, record_id: []const u8, record: ?std.json.Value, notify_token: ?[]const u8) void {
    if (!active) return; // reactor not running (tests/CLI): no-op to avoid "cluster inactive" + UB
    publishFrames(col.name, action, record_id, record);
    pg_bridge.emit(app, col.name, action, record_id, notify_token);
}

/// Realtime metadata for a just-deleted row.
pub const DeleteRealtime = struct {
    /// The snapshot fed to per-subscriber delete AUTHZ (`hub.matchesSnapshot`). It is the AT-REST
    /// representation (`.encrypted` fields are CIPHERTEXT, not decrypted) so the LOCAL delete authz
    /// compares the SAME representation as the cross-instance REMOTE path AND the live create/update
    /// path (which both compare the ciphertext column) — all three agree. The delivered delete frame
    /// is id-only regardless (the snapshot is stripped before any client sees it), so the
    /// representation choice never changes what subscribers receive.
    snapshot: ?std.json.Value,
    /// Cross-instance NOTIFY token keying the side-table snapshot (Postgres only; null otherwise).
    token: ?[]const u8,
};

/// Prepare a just-deleted row for realtime delivery + cross-instance fan-out (#159, PR-6b). MUST be
/// called on the writer INSIDE the delete transaction (before the row is removed). `decrypted` is
/// the snapshot the caller already read for its hooks (hidden fields stripped, `.encrypted` fields
/// DECRYPTED).
///
/// Delete authz must use the AT-REST (ciphertext) snapshot so local == remote == live. We only
/// re-read it when it could DIFFER from `decrypted` (the collection has an `.encrypted` field) or
/// when the cross-instance side table needs it (Postgres). Otherwise — the common case: SQLite (or
/// any collection with no encrypted fields) — `decrypted` IS the at-rest representation, so we reuse
/// it with NO extra read and SQLite stays byte-identical.
pub fn prepareDelete(alloc: std.mem.Allocator, app: *App, w: *db.Db, col: schema.Collection, record_id: []const u8, decrypted: ?std.json.Value) DeleteRealtime {
    const cross = pg_bridge.crossInstanceEnabled(app);
    if (!cross and !schema.hasEncryptedField(col)) return .{ .snapshot = decrypted, .token = null };
    const at_rest = (records.getAtRest(alloc, w, col, record_id) catch |e| {
        std.log.warn("realtime: delete-snapshot capture failed for {s}/{s}: {s}", .{ col.name, record_id, @errorName(e) });
        return .{ .snapshot = decrypted, .token = null };
    }) orelse return .{ .snapshot = decrypted, .token = null };
    const token = if (cross) pg_bridge.storeDeleteSnapshot(alloc, app.io, w, at_rest) else null;
    return .{ .snapshot = at_rest, .token = token };
}

/// Build + publish the two event frames into the LOCAL in-process hub (no NOTIFY). Shared by the
/// writer path (`broadcast`) and the cross-instance listener (`onRemoteEvent`), so a notification
/// from another instance flows through the exact same `onChannelMessage` per-subscriber authz.
fn publishFrames(collection: []const u8, action: protocol.Action, record_id: []const u8, record: ?std.json.Value) void {
    if (!active) return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ef = hub.buildEventFrames(a, collection, action, record_id, record) catch return;
    WS.publish(.{ .channel = ef.collection_channel, .message = ef.frame_collection });
    WS.publish(.{ .channel = ef.record_channel, .message = ef.frame_record });
}

/// Cross-instance bridge callback (#159, PR-6b): a record event NOTIFY'd by ANOTHER instance.
/// Re-feeds the local hub so each local subscriber's existing view/ability/tenant authz runs in
/// `onChannelMessage` — create/update re-fetch the live row, delete reads the at-rest snapshot from
/// the side table by token. Swallowed failures are logged so a silently-undelivered remote event is
/// visible to operators.
fn onRemoteEvent(app: *App, ev: pg_bridge.Event) void {
    if (!active) return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = app.pool.acquireReader() catch |e| {
        std.log.err("realtime: remote event dropped (pool acquire failed): {s}", .{@errorName(e)});
        return;
    };
    defer app.pool.releaseReader(&r);
    // per-EVENT (not per-subscriber); left uncached deliberately — see onChannelMessage for the hot path.
    const col = (collections.get(a, &r, ev.collection) catch |e| {
        std.log.err("realtime: remote event dropped (collection lookup failed for {s}): {s}", .{ ev.collection, @errorName(e) });
        return;
    }) orelse return; // not a real collection (or dropped): nothing to deliver
    if (ev.action == .delete) {
        // The live row is gone; read its at-rest snapshot back by token. A missing token / no
        // side-table row means either a non-cross-instance writer or a FORGED NOTIFY — deny
        // delivery (fail closed). The snapshot rides the published frame under a private authz key
        // and is stripped before any client receives the id-only delete frame.
        const token = ev.token orelse return;
        const snapshot = pg_bridge.readDeleteSnapshot(a, &r, token) orelse return;
        publishFrames(col.name, .delete, ev.id, snapshot);
    } else {
        // Re-fetch the current row (hidden fields stripped, TTL-respecting) so subscribers get the
        // real payload; skip if it was deleted/expired in the meantime.
        const rec = (records.get(a, &r, col, ev.id) catch |e| {
            std.log.err("realtime: remote event dropped (record fetch failed for {s}/{s}): {s}", .{ col.name, ev.id, @errorName(e) });
            return;
        }) orelse return;
        publishFrames(col.name, ev.action, ev.id, rec);
    }
}

/// Start the Postgres cross-instance LISTEN bridge (#159, PR-6b). A no-op on SQLite / when the
/// active backend is not Postgres. Best-effort: a failure to start logs + leaves single-instance
/// realtime working. Called once by the server just before `zap.start` (reactor live).
pub fn startRemoteListener(app: *App) void {
    pg_bridge.startListener(app, &onRemoteEvent) catch |e| {
        std.log.warn("realtime: Postgres LISTEN bridge unavailable: {s}", .{@errorName(e)});
    };
}

/// Build the standard signal frame `{"type":"signal","topic":"<json-escaped topic>"}`.
fn signalFrameAlloc(a: std.mem.Allocator, topic: []const u8) ![]const u8 {
    var o: std.json.ObjectMap = .empty;
    try o.put(a, "type", .{ .string = "signal" });
    try o.put(a, "topic", .{ .string = topic });
    return std.json.Stringify.valueAlloc(a, std.json.Value{ .object = o }, .{});
}

/// Splice pre-serialized payload bytes into the standard message envelope:
/// `{"type":"message","topic":"<json-escaped topic>","data":<data_json>}`.
/// `data_json` MUST already be valid JSON (ctx.RealtimeApi.broadcast produces it via
/// std.json.Stringify) — it is spliced verbatim, never re-parsed or re-serialized.
fn messageEnvelopeAlloc(a: std.mem.Allocator, topic: []const u8, data_json: []const u8) ![]const u8 {
    var w: std.ArrayList(u8) = .empty;
    try w.appendSlice(a, "{\"type\":\"message\",\"topic\":");
    try w.appendSlice(a, try std.json.Stringify.valueAlloc(a, std.json.Value{ .string = topic }, .{}));
    try w.appendSlice(a, ",\"data\":");
    try w.appendSlice(a, data_json);
    try w.appendSlice(a, "}");
    return w.toOwnedSlice(a);
}

/// Signal-only feature-management push (#128/#129/#130): publish the STANDARD signal frame
/// `{"type":"signal","topic":"__features"}` on the public `FEATURES_CHANNEL` so subscribed
/// clients re-`GET /api/state`. One frame grammar for every topic push (0.10.0, Breaking:
/// replaces the bespoke `{"type":"features.changed"}` frame). Called from every override
/// write path (`ctx.setFlag`/`App.setFlag` and the admin settings verbs). A no-op when the
/// reactor isn't running (tests/CLI). NEVER pushes per-subject state or experiment
/// assignments — those stay behind the authenticated `/api/state` projection.
pub fn broadcastFeaturesChanged() void {
    signalTopic(FEATURES_CHANNEL);
}

/// #143: consumer broadcast. Wrap `data_json` — an ALREADY-SERIALIZED JSON value — in the
/// standard `{"type":"message","topic":…,"data":…}` envelope and publish it to every
/// subscriber of a custom `topic`. The envelope is structural (0.10.0): no consumer-reachable
/// path can publish an unenveloped frame, and a non-JSON payload is impossible by
/// construction (the public `ctx.realtime().broadcast` serializes via std.json.Stringify and
/// errors at the call site). There is NO per-record viewRule on delivery — subscription
/// authorization is enforced once, at subscribe time, by `canSubscribeTopic`. EXPLICIT
/// opt-in: `data_json` must be safe for every subscriber of `topic` (gate private channels
/// with `.realtime = .{ .canSubscribe = fn }`; prefer `signalTopic` + an authenticated
/// re-fetch for per-subject state). A no-op when the reactor isn't running (tests/CLI).
/// `topic` is a consumer channel name, not a collection name. Callable from any thread
/// (incl. a background job): `fio_publish` is a non-blocking enqueue that copies the frame.
pub fn broadcastTopic(topic: []const u8, data_json: []const u8) void {
    if (!active) return; // reactor not running (tests/CLI): no-op
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const frame = messageEnvelopeAlloc(arena.allocator(), topic, data_json) catch return;
    WS.publish(.{ .channel = topic, .message = frame });
}

/// #143: signal-only consumer push. Publish `{"type":"signal","topic":"<topic>"}` on a custom
/// `topic` so subscribers re-fetch over an authenticated GET — the recommended default for
/// private/per-subject state (carries NO payload). A no-op when the reactor isn't running.
pub fn signalTopic(topic: []const u8) void {
    if (!active) return; // reactor not running (tests/CLI): no-op
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const frame = signalFrameAlloc(arena.allocator(), topic) catch return;
    WS.publish(.{ .channel = topic, .message = frame });
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
    broadcast(&app, undefined, .create, "rec1", null, null); // would crash if it didn't early-return
}

test "broadcastFeaturesChanged is a no-op when inactive" {
    // Like broadcast, the feature signal must early-return when the reactor isn't running
    // so the override write paths (ctx.setFlag / admin settings) are safe in tests/CLI.
    try std.testing.expect(!active);
    broadcastFeaturesChanged(); // would touch the inactive cluster (UB) if it didn't early-return
}

test "broadcastTopic/signalTopic are no-ops when inactive (#143)" {
    // Like broadcast/broadcastFeaturesChanged, the consumer publish entry points must early-return
    // when the reactor isn't running so ctx.realtime() is safe to call from tests/CLI/background jobs.
    try std.testing.expect(!active);
    broadcastTopic("orders", "{\"n\":1}"); // pre-serialized payload; enveloped internally
    signalTopic("availability"); // builds + would publish a signal frame; must early-return
}

test "messageEnvelopeAlloc splices the standard message envelope + JSON-escapes the topic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "{\"type\":\"message\",\"topic\":\"orders\",\"data\":{\"id\":\"r1\"}}",
        try messageEnvelopeAlloc(a, "orders", "{\"id\":\"r1\"}"),
    );
    // topic escaping: a quote in the topic must not break the frame
    try std.testing.expectEqualStrings(
        "{\"type\":\"message\",\"topic\":\"a\\\"b\",\"data\":1}",
        try messageEnvelopeAlloc(a, "a\"b", "1"),
    );
}

test "broadcastFeaturesChanged uses the standard signal frame (0.10.0 wire fix)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // broadcastFeaturesChanged delegates to signalTopic(FEATURES_CHANNEL); this pins the frame.
    try std.testing.expectEqualStrings(
        "{\"type\":\"signal\",\"topic\":\"__features\"}",
        try signalFrameAlloc(a, FEATURES_CHANNEL),
    );
}
