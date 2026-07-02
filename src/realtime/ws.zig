const std = @import("std");
const zap = @import("zap");
const fio = zap.fio;
const App = @import("../app.zig").App;
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const collections = @import("../collections.zig");
const records = @import("../records.zig");
const policy = @import("../policy.zig");
const pg_bridge = @import("pg_bridge.zig");
const auth = @import("../auth.zig");
const id = @import("../id.zig");
const protocol = @import("protocol.zig");
const connection = @import("connection.zig");
const hub = @import("hub.zig");
const request = @import("../request.zig");
const tenancy = @import("../tenancy/tenancy.zig");
const Ctx = @import("../ctx.zig").Ctx;

/// Set true by the server just before `zap.start`; gates `broadcast` so it is a no-op when the
/// facil.io reactor isn't running (tests/CLI), avoiding "facil.io cluster inactive" noise + UB.
pub var active: bool = false;

/// Fixed PUBLIC realtime channel for the feature-management "changed" signal
/// (#128/#129/#130). It is signal-only: the STANDARD signal frame
/// `{"type":"signal","topic":"__features"}` is published whenever any flag/experiment
/// override changes (0.10.0 — the bespoke `{"type":"features.changed"}` frame is gone);
/// clients re-`GET /api/state` on receipt. No per-subject state or experiment assignment
/// is ever pushed. It is NOT a collection — the subscribe path allows anonymous
/// subscription to it explicitly and the delivery path forwards its frames unchanged.
pub const FEATURES_CHANNEL = "__features";

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
    if (policy.isPublic(view_rule)) return true;
    return authed or is_superuser;
}

/// The result of authorizing a subscribe request: deliver, unknown-collection error, or
/// authentication-required error.
const SubscribeOutcome = enum { ok, unknown, auth_required };

/// Pure subscribe-authorization decision (#143, F5), factored out so the security PRECEDENCE
/// is testable in one place: a REAL collection topic (`col != null`) ALWAYS uses per-collection
/// authz (`subscribeAuthorized`) — the custom-topic predicate is NEVER consulted for it, so a
/// custom subscribe can't reach a collection's records. Only a NON-collection custom topic
/// (`col == null`) is gated by `custom_allowed` (the `canSubscribe` result; default true).
fn subscribeDecision(col: ?schema.Collection, authed: bool, is_superuser: bool, custom_allowed: bool) SubscribeOutcome {
    if (col) |c| {
        return if (subscribeAuthorized(c.viewRule, authed, is_superuser)) .ok else .auth_required;
    }
    return if (custom_allowed) .ok else .auth_required;
}

/// #143: may a socket subscribe to a NON-collection custom topic? Consulted ONLY after the
/// topic is confirmed NOT to be a collection (collection topics keep their own per-record
/// authz). DEFAULT — no `.realtime = .{ .canSubscribe = fn }` configured — is to ALLOW any
/// named custom topic, i.e. custom topics are PUBLIC signal channels (exactly the historical
/// `__features` behavior). A configured predicate gates private channels: returning false
/// denies. The predicate receives a lightweight `Ctx` carrying the socket's resolved identity
/// (`ctx.user()` / `ctx.rctx`); it may acquire its own reader for richer checks.
fn canSubscribeTopic(app: *App, arena: std.mem.Allocator, rctx: request.RequestContext, topic: []const u8) bool {
    const d = app.dispatch orelse return true;
    const predicate = d.realtime_can_subscribe orelse return true;
    var cx = Ctx{ .app = app, .arena = arena, .rctx = rctx };
    defer cx.deinit();
    return predicate(&cx, topic);
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
fn requestedAccountFromUpgrade(app: *App, r: zap.Request, da: std.mem.Allocator) ?[]const u8 {
    if (r.getHeader("x-account-id")) |h| if (h.len > 0) return da.dupe(u8, h) catch null;
    const ch = r.getHeader("cookie") orelse return null;
    const raw = cookieValue(ch, tenancy.account_cookie) orelse return null;
    const verified = tenancy.verifyAccount(app.jwt_secret, raw) orelse return null;
    return da.dupe(u8, verified) catch null;
}

/// Extract the value of cookie `name` from a raw `Cookie` header (mirrors `http.RequestCtx.cookie`).
fn cookieValue(header: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, header, ';');
    while (it.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, " ");
        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
            if (std.mem.eql(u8, trimmed[0..eq], name)) return trimmed[eq + 1 ..];
        }
    }
    return null;
}

/// The string `id` of a record JSON object, or "" when absent/non-object.
fn recordIdOf(rec: std.json.Value) []const u8 {
    if (rec != .object) return "";
    const v = rec.object.get("id") orelse return "";
    return if (v == .string) v.string else "";
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
                // #156: resolve + cache the active account scope against _memberships (durable
                // allocator → persists across frames). Superusers bypass tenancy. A failed/absent
                // resolution leaves account_id="" → tenant-owned delivery fails closed (deny).
                if (lc.conn.tenancy_enabled and !v.is_superuser) {
                    const uid = recordIdOf(v.record);
                    if (uid.len > 0) {
                        const res = tenancy.resolve(da, &r, v.collection, uid, lc.requested_account) catch tenancy.Resolution{};
                        lc.conn.setTenancyScope(res.account_id, res.memberships);
                    }
                }
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
            const outcome: SubscribeOutcome = blk: {
                const t = protocol.parseTopic(m.topic);
                // The feature-management signal channel is PUBLIC and is not a collection:
                // anyone (incl. anonymous) may subscribe; delivery forwards the signal frame
                // verbatim (no per-record authorization).
                if (std.mem.eql(u8, t.collection, FEATURES_CHANNEL)) break :blk .ok;
                var r = lc.app.pool.acquireReader() catch break :blk .unknown;
                const now = auth.nowUnixPub(&r) catch 0;
                const rctx = lc.conn.requestContext(now);
                const lookup = collections.get(fa, &r, t.collection) catch {
                    lc.app.pool.releaseReader(&r);
                    break :blk .unknown;
                };
                // Release the reader now: `lookup` (and `col.viewRule`) live on the frame arena, and
                // the canSubscribe predicate is handed a Ctx that may acquire its own reader.
                lc.app.pool.releaseReader(&r);
                // A REAL collection topic ALWAYS goes through normal per-collection authz, so the
                // custom-topic predicate can never be used to reach a collection's records: the
                // canSubscribe guard (#143) is consulted ONLY when `lookup == null` (a non-collection
                // custom topic). DEFAULT (no `.realtime.canSubscribe`) allows any custom topic, i.e.
                // custom topics are PUBLIC signal channels — exactly today's `__features` behavior.
                const custom_allowed = lookup == null and canSubscribeTopic(lc.app, fa, rctx, m.topic);
                break :blk subscribeDecision(lookup, rctx.auth != null, rctx.is_superuser, custom_allowed);
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
    // The public feature-signal channel carries a fixed, non-record frame: forward it
    // verbatim (no per-record viewRule authorization, no collection lookup).
    if (std.mem.eql(u8, channel, FEATURES_CHANNEL)) {
        WS.write(handle, message, true) catch {};
        return;
    }
    _ = lc.frame.reset(.retain_capacity);
    const a = lc.frame.allocator();

    const t = protocol.parseTopic(channel);
    var r = lc.app.pool.acquireReader() catch return;
    defer lc.app.pool.releaseReader(&r);

    // Resolve the topic to a collection FIRST. A non-collection topic is a consumer CUSTOM
    // channel (#143): forward its frame VERBATIM with NO per-record viewRule — subscription
    // was already authorized at subscribe time via `canSubscribe`. This mirrors the
    // `__features` precedent and is strictly scoped to topics that are NOT collections, so a
    // custom-topic delivery can never leak a collection's records.
    const col = (collections.get(a, &r, t.collection) catch return) orelse {
        WS.write(handle, message, true) catch {};
        return;
    };

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

test "subscribeDecision: collection topics ALWAYS use collection authz, custom topics use the predicate (#143)" {
    // A REAL collection topic is authorized by its viewRule REGARDLESS of the custom predicate:
    // even with custom_allowed=true, a LOCKED collection denies an anonymous socket. This is the
    // security guarantee that a custom subscribe can't reach a collection's records.
    const locked = schema.Collection{ .id = "c1", .name = "secrets", .fields = &.{}, .viewRule = null };
    try std.testing.expectEqual(SubscribeOutcome.auth_required, subscribeDecision(locked, false, false, true));
    try std.testing.expectEqual(SubscribeOutcome.ok, subscribeDecision(locked, true, false, true)); // authed
    try std.testing.expectEqual(SubscribeOutcome.ok, subscribeDecision(locked, false, true, true)); // superuser
    // A @public collection is open to anonymous (the custom predicate is irrelevant either way).
    const pub_col = schema.Collection{ .id = "c2", .name = "posts", .fields = &.{}, .viewRule = "@public" };
    try std.testing.expectEqual(SubscribeOutcome.ok, subscribeDecision(pub_col, false, false, false));
    // A NON-collection custom topic (col == null) is gated solely by custom_allowed.
    try std.testing.expectEqual(SubscribeOutcome.ok, subscribeDecision(null, false, false, true)); // default public
    try std.testing.expectEqual(SubscribeOutcome.auth_required, subscribeDecision(null, false, false, false)); // guard denied
}

test "canSubscribeTopic: default allows any custom topic (public signal channel) (#143)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var app: App = undefined;
    const anon = request.RequestContext{};
    // No dispatch wired (tests/CLI): custom topics default to PUBLIC signal channels.
    app.dispatch = null;
    try std.testing.expect(canSubscribeTopic(&app, a, anon, "availability"));
    // Dispatch present but NO predicate -> still public by default.
    var d = @import("../events.zig").Dispatch{};
    app.dispatch = &d;
    try std.testing.expect(canSubscribeTopic(&app, a, anon, "orders"));
}

test "canSubscribeTopic: a canSubscribe guard returning false denies (#143)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Guard = struct {
        fn deny(ctx: *Ctx, topic: []const u8) bool {
            _ = ctx;
            _ = topic;
            return false;
        }
        fn onlyAuthed(ctx: *Ctx, topic: []const u8) bool {
            _ = topic;
            return ctx.rctx.auth != null or ctx.rctx.is_superuser;
        }
    };
    var app: App = undefined;
    var d = @import("../events.zig").Dispatch{ .realtime_can_subscribe = Guard.deny };
    app.dispatch = &d;
    const anon = request.RequestContext{};
    try std.testing.expect(!canSubscribeTopic(&app, a, anon, "private"));
    // A guard gating on auth: anonymous denied, authenticated allowed.
    d.realtime_can_subscribe = Guard.onlyAuthed;
    try std.testing.expect(!canSubscribeTopic(&app, a, anon, "private"));
    var rec: std.json.ObjectMap = .empty;
    try rec.put(a, "id", .{ .string = "u1" });
    const authed = request.RequestContext{ .auth = .{ .object = rec }, .is_superuser = false };
    try std.testing.expect(canSubscribeTopic(&app, a, authed, "private"));
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
