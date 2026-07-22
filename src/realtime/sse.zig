//! SSE realtime transport (#188) — the connection registry + concurrency layer.
//!
//! WHY SSE NEEDS WHAT WS DOESN'T: facil.io serializes all of a WS connection's callbacks
//! per-connection, so LiveConn needs no locks. The SSE uplink is a plain REST request on a
//! zap worker thread, OUTSIDE facil.io's per-connection serialization, racing deliveries and
//! on_close on reactor threads. Hence: a registry + per-conn mutex + refcount.
//!
//! LOCK-ORDERING LAW: `registry_mu` and a conn's `mu` are NEVER held simultaneously.
//! Registry critical sections are pointer-only (lookup/insert/remove + refs.fetchAdd); all
//! conn-state work happens under `mu` after `registry_mu` is released. Deadlock is impossible
//! by construction — there is no second lock to wait on while holding either. We never call a
//! fio API that can take another connection's task lock while holding `mu` (http_sse_write is
//! a thread-safe enqueue; http_sse_subscribe/unsubscribe take only the sse-internal spinlock).
//!
//! MUTEX FLAVOR: std.Thread.Mutex is gone in Zig 0.16; `std.atomic.Mutex` (spinlock) is the
//! codebase convention (db.zig, mail/capture.zig). Uplink verbs hold `mu` across a BOUNDED
//! DB read (token verify / subscribe authz) — a delivery or on_close for the SAME connection
//! spins for those milliseconds; accepted as the simplest correct regime (per-connection
//! contention only; cross-connection paths never share these locks).
//!
//! TTL/REAPING: on_close is the single authoritative reap. The heartbeat tick (`: ping`)
//! makes a dead peer fail a write -> fio closes the socket -> on_close. NO sweeper thread in
//! v1: a second reap path racing on_close is precisely the double-free hazard this design
//! eliminates; the registry cannot leak, and a closed-but-briefly-pinned entry answers 404.
const std = @import("std");
const RequestArena = @import("../request_arena.zig").RequestArena;
const zap = @import("zap");
const sse_fio = @import("sse_fio.zig");
const ws = @import("ws.zig");
const App = @import("../app.zig").App;
const connection = @import("connection.zig");
const hub = @import("hub.zig");
const protocol = @import("protocol.zig");
const id_mod = @import("../id.zig");

/// Alias for the callback-scoped fio string type (pub/sub delivery callback params).
const fio_str = sse_fio.fio.fio_str_info_s;

/// Spin-acquire (the std.atomic.Mutex idiom used across the codebase — mail/capture.zig:23).
fn lockMu(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

/// One live SSE stream. Everything mutable is guarded by `mu` except `refs` (atomic).
pub const SseConn = struct {
    conn: connection.Conn = .{}, // guarded by mu
    mu: std.atomic.Mutex = .unlocked,
    /// Base ref (stream + registry) = 1; +1 per pinned uplink. Freed at zero (unref).
    refs: std.atomic.Value(usize) = .init(1),
    closed: bool = false, // guarded by mu
    /// http_sse_dup'd at on_open; http_sse_free at last unref. NULL in unit tests (no
    /// reactor) — every fio call is `if (handle) |h|`-gated so the concurrency machinery
    /// is testable without facil.io.
    handle: ?sse_fio.Handle = null,
    sub_ids: std.StringHashMapUnmanaged(usize) = .empty, // topic -> fio sub id; guarded by mu
    /// Durable per-connection arena: subscription keys/filters, sub_ids, requested_account.
    /// Allocations only under mu; freed at last unref — NEVER earlier.
    durable: std.heap.ArenaAllocator,
    /// Identity-only arena: the active auth record + resolved account/memberships. RESET on every
    /// auth frame (hub.authVerb, #11 residual) so a re-auth loop can't grow memory without bound.
    /// Because the uplink (which resets this) races lock-free deliveries, `snapshotForDelivery`
    /// takes a DEEP COPY of the identity onto the per-delivery arena — a delivery NEVER aliases
    /// these bytes after unlock, so the reset is safe. Freed at last unref.
    identity: std.heap.ArenaAllocator,
    app: *App,
    /// The uplink capability: 32 CSPRNG base36 chars, delivered only on the Origin-gated
    /// stream (connect frame). The registry key is this buffer's slice.
    client_id: [32]u8 = undefined,
    /// Handshake-captured tenancy request (#156), duped onto `durable`; verified at auth time.
    requested_account: []const u8 = "",
};

var registry_mu: std.atomic.Mutex = .unlocked;
var registry: std.StringHashMapUnmanaged(*SseConn) = .empty; // clientId -> conn

/// Allocate + initialize a conn (client_id from the CSPRNG seam). The caller owns the base
/// ref and must either reach on_open (which registers it) or destroy via `unref`.
pub fn create(app: *App) !*SseConn {
    const sc = try app.allocator.create(SseConn);
    sc.* = .{
        .app = app,
        .durable = std.heap.ArenaAllocator.init(app.allocator),
        .identity = std.heap.ArenaAllocator.init(app.allocator),
    };
    id_mod.generate(app.io, &sc.client_id);
    return sc;
}

/// Register a conn (on_open, BEFORE the connect frame is written — registry-visible strictly
/// before the client can learn the id, so a POST with a valid id can never race registration).
///
/// LOCK ORDER: takes `registry_mu` only; no `conn.mu` is held here (nor anywhere up the stack).
pub fn registryInsert(sc: *SseConn) !void {
    lockMu(&registry_mu);
    defer registry_mu.unlock();
    try registry.put(sc.app.allocator, sc.client_id[0..], sc);
}

/// Resolve + pin a clientId (uplink path). On hit the refcount is bumped UNDER registry_mu,
/// so the entry cannot be freed while pinned; the caller MUST pair with `unref`. Miss => null
/// (the caller answers 404).
///
/// LOCK ORDER: takes `registry_mu` only. The fetchAdd happens inside the registry critical
/// section so a concurrent `markClosedAndRelease` cannot remove-then-free between our `get`
/// and our ref bump.
pub fn pin(client_id: []const u8) ?*SseConn {
    lockMu(&registry_mu);
    defer registry_mu.unlock();
    const sc = registry.get(client_id) orelse return null;
    _ = sc.refs.fetchAdd(1, .monotonic);
    return sc;
}

/// Drop one ref; the LAST ref destroys: durable arena, fio handle (if any), the struct.
///
/// LOCK ORDER: takes NO lock. The refcount is atomic; the destroy path runs only for the
/// thread that observes the 1->0 transition, so no other thread can still reach `sc`.
pub fn unref(sc: *SseConn) void {
    if (sc.refs.fetchSub(1, .acq_rel) != 1) return;
    const app = sc.app;
    sc.sub_ids = .empty; // keys/values live on the durable arena
    sc.durable.deinit();
    sc.identity.deinit();
    if (sc.handle) |h| sse_fio.free(h);
    app.allocator.destroy(sc);
}

/// The transport-independent on_close body, in fio-callback order (spec §1.3):
///   (1) registry remove — no NEW uplink can pin after this;
///   (2) closed = true under mu — a pinned-but-not-yet-run uplink sees it and 404s;
///   (3) release the shared WS+SSE connection slot, exactly once, here and only here;
///   (4) drop the base ref.
/// Exactly one on_close per stream (fio guarantee) => no double release/free.
///
/// LOCK ORDER: `registry_mu` and `sc.mu` are taken in SEPARATE, non-nested critical sections
/// (each `{ ... }` block releases before the next acquires) — the lock-ordering law holds.
pub fn markClosedAndRelease(sc: *SseConn) void {
    {
        lockMu(&registry_mu);
        defer registry_mu.unlock();
        _ = registry.remove(sc.client_id[0..]);
    }
    {
        lockMu(&sc.mu);
        defer sc.mu.unlock();
        sc.closed = true;
    }
    connection.releaseConnectionSlot();
    unref(sc);
}

/// ---- uplink (POST /api/realtime/sse/:clientId) ------------------------------
pub const Reply = struct { status: u16, frame: []const u8 };

/// Run one uplink verb against a pinned conn (zap worker thread — the out-of-band path the
/// per-conn mutex exists for). The whole verb, INCLUDING the fio subscribe/unsubscribe call
/// and the durable-arena channel dupe, runs under `mu` — the closed-flag check and the
/// subscribe happen in ONE critical section, so http_sse_subscribe is never called after
/// closed=true (the named race, spec §1.3). Returns null when the conn is already closed:
/// the caller's 404 is byte-identical to an unknown id (non-oracle).
/// The verb bodies are hub.authVerb / hub.subscribeCheck — the SAME code WS runs.
pub fn handleUplink(sc: *SseConn, a: RequestArena, body: []const u8) !?Reply {
    lockMu(&sc.mu);
    defer sc.mu.unlock();
    if (sc.closed) return null;
    const msg = protocol.parseClient(a.a, body) catch {
        return .{ .status = 400, .frame = try protocol.errorFrame(a.a, "bad message") };
    };
    // `parseClient` dupes its strings fresh onto `a.a` (never an alias of `body`) and none of them
    // are retained past this function (every use below either reads them transiently or dupes them
    // again onto `da`, the durable arena) — free them here, on every return path, regardless of
    // which verb ran. A no-op-ish shrink under the real per-request arena `a` is normally backed
    // by; a real free under a raw allocator (tests).
    defer switch (msg) {
        .auth => |m| a.a.free(m.token),
        .subscribe => |m| {
            a.a.free(m.topic);
            if (m.filter) |f| a.a.free(f);
        },
        .unsubscribe => |m| a.a.free(m.topic),
    };
    const da = sc.durable.allocator();
    switch (msg) {
        .auth => |m| {
            const ok = hub.authVerb(sc.app, &sc.conn, &sc.identity, m.token, sc.requested_account);
            return .{ .status = 200, .frame = try protocol.authFrame(a.a, ok) };
        },
        .subscribe => |m| {
            switch (hub.subscribeCheck(sc.app, &sc.conn, a, m.topic)) {
                .limit => return .{ .status = 200, .frame = try protocol.errorFrame(a.a, "subscription limit reached") },
                .unknown => return .{ .status = 200, .frame = try protocol.errorFrame(a.a, "unknown collection") },
                .auth_required => return .{ .status = 200, .frame = try protocol.errorFrame(a.a, "authentication required to subscribe") },
                .ok => {},
            }
            // #3: replace-in-place on a repeat subscribe (mirrors ws.zig) — reuse the single fio
            // subscription instead of stacking a second, which bypassed MAX_SUBS and duplicated
            // every delivered frame.
            if (try sc.conn.updateFilter(da, m.topic, m.filter)) {
                return .{ .status = 200, .frame = try protocol.ackFrame(a.a, "subscribe", m.topic) };
            }
            // Same durable-dupe discipline as WS (the m.topic buffer dies with this request).
            const channel = try da.dupe(u8, m.topic);
            try sc.conn.addSub(da, m.topic, m.filter);
            if (sc.handle) |h| {
                const sub_id = sse_fio.subscribe(h, channel, onChannelMessage, sc);
                if (sub_id == 0) {
                    // #30: don't ack a failed fio subscribe as success — roll back + surface an error.
                    _ = sc.conn.removeSub(da, m.topic);
                    std.log.warn("realtime: SSE subscribe to \"{s}\" failed (fio subscribe returned 0)", .{m.topic});
                    return .{ .status = 200, .frame = try protocol.errorFrame(a.a, "subscribe failed") };
                }
                sc.sub_ids.put(da, channel, sub_id) catch {
                    // #30: fio subscribe SUCCEEDED but recording its id failed — without the id a
                    // later unsubscribe can't cancel it, stranding a live fio subscription the
                    // client can't drop. Roll back (fio-unsubscribe + drop the logical sub) and
                    // surface an error instead of acking a success we can't honor (mirror sub_id==0).
                    sse_fio.unsubscribe(h, sub_id);
                    _ = sc.conn.removeSub(da, m.topic);
                    std.log.warn("realtime: SSE subscribe to \"{s}\" failed (sub_id store OOM)", .{m.topic});
                    return .{ .status = 200, .frame = try protocol.errorFrame(a.a, "subscribe failed") };
                };
            }
            return .{ .status = 200, .frame = try protocol.ackFrame(a.a, "subscribe", m.topic) };
        },
        .unsubscribe => |m| {
            if (sc.sub_ids.fetchRemove(m.topic)) |kv| {
                if (sc.handle) |h| sse_fio.unsubscribe(h, kv.value);
            }
            _ = sc.conn.removeSub(da, m.topic);
            return .{ .status = 200, .frame = try protocol.ackFrame(a.a, "unsubscribe", m.topic) };
        },
    }
}

// Delivery-decision inputs, copied OUT of the locked conn so hub.frameForDelivery (DB work)
/// runs with NO lock held. `identity` is an identity-only Conn (subs deliberately empty —
/// frameForDelivery never reads them; hasSub/filter are resolved here). The identity (auth record
/// / memberships / account_id) is DEEP-COPIED onto the per-delivery arena `a`, NOT aliased from the
/// connection's identity arena: that arena is RESET on re-auth (hub.authVerb, #11 residual), and a
/// re-auth on the uplink thread can land while this delivery does its lock-free DB work, so a
/// shallow alias would dangle. The deep copy makes the snapshot self-contained. An auth/unsubscribe
/// landing between snapshot and write mirrors the WS status quo (an in-flight frame is decided
/// under the identity current at decision time).
pub const DeliverySnapshot = struct {
    identity: connection.Conn,
    sub_filter: ?[]const u8,
};

/// LOCK ORDER: takes `sc.mu` only (never `registry_mu`) — reads conn state and copies the
/// delivery-decision inputs out before returning, so the caller does DB work lock-free.
pub fn snapshotForDelivery(sc: *SseConn, a: std.mem.Allocator, channel: []const u8) ?DeliverySnapshot {
    lockMu(&sc.mu);
    defer sc.mu.unlock();
    if (sc.closed) return null;
    if (!sc.conn.hasSub(channel)) return null;
    const fp = sc.conn.subFilter(channel);
    const filter: ?[]const u8 = if (fp) |p|
        (if (p.*) |s| (a.dupe(u8, s) catch return null) else null)
    else
        null;
    // DEEP-COPY the identity onto `a` (see the struct doc): the source bytes live on the
    // identity arena, which a concurrent re-auth may reset out from under the lock-free delivery.
    const auth_copy: ?connection.AuthIdentity = if (sc.conn.auth) |ident| .{
        .record = hub.cloneJson(a, ident.record) catch return null,
        .is_superuser = ident.is_superuser,
        .exp = ident.exp,
    } else null;
    const account_copy = a.dupe(u8, sc.conn.account_id) catch return null;
    const memberships_copy = hub.cloneMemberships(a, sc.conn.memberships) catch return null;
    return .{
        .identity = .{
            .auth = auth_copy,
            .tenancy_enabled = sc.conn.tenancy_enabled,
            .account_id = account_copy,
            .memberships = memberships_copy,
        },
        .sub_filter = filter,
    };
}

// ---- stream lifecycle (fio callbacks) ---------------------------------------

/// Open an SSE stream on a live upgrade request. The caller (ws.handleUpgrade) has already
/// passed the Origin gate and reserved the shared connection slot. On a `create` failure the
/// slot is released here and the request is finished with a status; on an `upgrade` failure
/// this function does NEITHER — it relies on facil.io having already invoked `on_close` (==
/// `onClose` -> `markClosedAndRelease(sc)`) itself, which already ran the full teardown (see the
/// comment below). On success the request object is dead (http1_upgrade2sse sent the headers +
/// swapped the protocol, spike §4.5) and on_open fires on the reactor.
pub fn openStream(r: zap.Request, app: *App) void {
    const sc = create(app) catch {
        connection.releaseConnectionSlot();
        r.setStatus(.internal_server_error);
        r.markAsFinished(true);
        return;
    };
    // #156: tenancy capture, verbatim WS semantics — request buffers die after this returns.
    if (app.tenancy.enabled) {
        sc.conn.tenancy_enabled = true;
        if (ws.requestedAccountFromUpgrade(app, r, sc.durable.allocator())) |acc| sc.requested_account = acc;
    }
    if (!sse_fio.upgrade(r.h, onOpen, onClose, sc)) {
        // DO NOT tear down here. Exactly like the WS arm, facil.io's SSE upgrade-FAILURE paths
        // invoke our `on_close` (== `onClose` -> `markClosedAndRelease(sc)`) THEMSELVES before
        // returning -1, which already ran the FULL teardown (registry remove — a no-op since we
        // were never registered; `closed = true`; releaseConnectionSlot; unref -> durable.deinit
        // + destroy(sc)). Both -1 paths do this:
        //   • http_upgrade2sse invalid-handle  (http.c:1343-1347:  sse.on_close(&sse))
        //   • http1_upgrade2sse failed/malloc   (http1.c:500-504:  fio_close(uuid); sse->on_close(sse))
        // Repeating it here was a double-free + double slot-release (the same class of bug the WS
        // arm had). facil has also already produced/closed the response on both paths (a 200 was
        // flushed + the socket closed on the malloc path; the handle is terminal on invalid-handle),
        // so the caller must do NOTHING but stop.
    }
}

/// on_open (reactor, fio-serialized): dup the handle, apply the heartbeat override, register
/// in the registry, THEN write the connect frame — registry-visible strictly before the
/// client can learn the id.
fn onOpen(h: sse_fio.Handle) callconv(.c) void {
    const sc: *SseConn = @ptrCast(@alignCast(h.*.udata orelse return));
    sc.handle = sse_fio.dup(h);
    if (sc.app.sse_heartbeat_seconds != 0) sse_fio.setTimeout(h, sc.app.sse_heartbeat_seconds);
    registryInsert(sc) catch {
        // Can't register -> the uplink capability would never resolve; close the stream
        // (on_close performs the normal teardown; the registry remove is a no-op).
        std.log.err("realtime: SSE registry insert failed; closing stream", .{});
        sse_fio.close(h);
        return;
    };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const frame = protocol.connectFrame(arena.allocator(), sc.client_id[0..]) catch return;
    _ = sse_fio.writeData(h, frame);
}

/// on_close (reactor, exactly once per stream — fio guarantee). facil.io itself tears down
/// the connection's pub/sub subscriptions at socket close (same as WS).
fn onClose(h: sse_fio.Handle) callconv(.c) void {
    const sc: *SseConn = @ptrCast(@alignCast(h.*.udata orelse return));
    markClosedAndRelease(sc);
}

/// Pub/sub delivery (reactor; fio-serialized against other deliveries and on_close for THIS
/// connection — http.c:1246-1261 — but NOT against the uplink): snapshot the decision inputs
/// under mu, run the shared authz chokepoint with NO lock held, enqueue the write.
/// NO reset-per-callback arena here — that WS trick is only safe under fio's full
/// per-connection serialization (spike §3); delivery uses a per-call arena.
fn onChannelMessage(h: sse_fio.Handle, channel_info: fio_str, message_info: fio_str, udata: ?*anyopaque) callconv(.c) void {
    const sc: *SseConn = @ptrCast(@alignCast(udata orelse return));
    const channel = sse_fio.sliceOf(channel_info);
    const message = sse_fio.sliceOf(message_info);
    // Slow-consumer backpressure (issue #203), identical policy to WS: a peer that isn't draining
    // its stream accumulates queued outbound frames without bound (OOM/DoS). Past the per-connection
    // high-water-mark, close the stream (on_close reaps) rather than dropping frames. This runs
    // fio-serialized against on_close for THIS connection and takes NO lock — the lock-ordering law
    // (registry_mu vs conn mu never nested) is untouched.
    const hwm = sc.app.realtime_outbound_hwm;
    if (connection.outboundOverHwm(connection.pendingOutbound(sse_fio.uuid(h)), hwm)) {
        std.log.warn("realtime: disconnecting slow SSE consumer (outbound queue > {d} frames)", .{hwm});
        sse_fio.close(h);
        return;
    }
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const snap = snapshotForDelivery(sc, a, channel) orelse return;
    if (hub.frameForDelivery(a, sc.app, &snap.identity, snap.sub_filter, channel, message)) |frame| {
        _ = sse_fio.writeData(h, frame); // lock-free enqueue; a dead peer fails -> on_close reaps
    }
}

// ---- concurrency tests ------------------------------------------------------
// These are the risk-item tests (spec §4.1): refcount asserted, pin-then-close 404s and frees
// exactly once, threaded stress under std.testing.allocator's double-free/leak detection.

fn testApp() App {
    return .{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined };
}

/// TEST-ONLY: drop the registry's backing store so std.testing.allocator sees no leak. The
/// map's backing capacity is the one cross-test global; entries are already removed by
/// markClosedAndRelease, so this frees only the (empty) table.
fn registryReset(alloc: std.mem.Allocator) void {
    lockMu(&registry_mu);
    defer registry_mu.unlock();
    registry.deinit(alloc);
    registry = .empty;
}

test "SSE upgrade-failure teardown: facil's on_close (markClosedAndRelease) frees a never-registered conn + releases the slot exactly once (no leak)" {
    // Proves the fix does not LEAK. On the SSE upgrade-failure path facil.io calls our on_close
    // (== markClosedAndRelease) and openStream's failure branch now does NOTHING — so
    // markClosedAndRelease must be the SOLE, COMPLETE teardown of a conn that was created + had its
    // slot reserved but was NEVER registryInsert'd (on_open never ran). This mirrors that exact
    // state: create() + reserveConnectionSlot(), then the single facil on_close.
    const base = connection.connectionCount();
    var app = testApp();
    const sc = try create(&app);
    _ = connection.reserveConnectionSlot(); // openStream reserved the slot before sse_fio.upgrade
    try std.testing.expectEqual(base + 1, connection.connectionCount());
    // NOTE: deliberately NO registryInsert — the upgrade failed before on_open could register it,
    // so markClosedAndRelease's registry.remove must tolerate a never-inserted key (no-op).
    markClosedAndRelease(sc); // == facil.io's on_close on the -1 failure path
    try std.testing.expectEqual(base, connection.connectionCount()); // slot released exactly once
    // std.testing.allocator fails the test on a leak OR a double-free of sc / its durable arena —
    // that IS the exactly-once assertion. (No registryReset needed: sc was never inserted.)
}

test "registry: insert/pin/remove; pin bumps refs; unref at zero frees exactly once" {
    var app = testApp();
    const sc = try create(&app);
    _ = connection.reserveConnectionSlot(); // pair with markClosedAndRelease below
    try registryInsert(sc);
    defer registryReset(std.testing.allocator);
    // Copy the id: markClosedAndRelease frees `sc`, so we must not read `sc.client_id` after.
    const cid: [32]u8 = sc.client_id;
    try std.testing.expectEqual(@as(usize, 1), sc.refs.load(.monotonic));

    const pinned = pin(sc.client_id[0..]).?;
    try std.testing.expectEqual(sc, pinned);
    try std.testing.expectEqual(@as(usize, 2), sc.refs.load(.monotonic));
    // A random id (right length, wrong bytes) misses.
    try std.testing.expect(pin("ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ") == null);
    unref(pinned); // uplink done -> back to the base ref

    markClosedAndRelease(sc); // registry remove + closed + slot release + base unref -> freed
    try std.testing.expect(pin(cid[0..]) == null); // no new pin after close
    try std.testing.expectEqual(@as(usize, 0), connection.connectionCount());
    // std.testing.allocator fails the test on leak or double-free — that IS the assertion.
}

test "pin-then-close: a pinned conn survives on_close; closed flag is visible; last unref frees" {
    var app = testApp();
    const sc = try create(&app);
    _ = connection.reserveConnectionSlot();
    try registryInsert(sc);
    defer registryReset(std.testing.allocator);

    const pinned = pin(sc.client_id[0..]).?; // uplink in flight...
    markClosedAndRelease(sc); // ...stream closes first
    // Memory is valid (the pin holds a ref); the conn reports closed (uplink answers the
    // non-oracle 404 — Task 8's handleUplink returns null on this flag).
    {
        lockMu(&pinned.mu);
        defer pinned.mu.unlock();
        try std.testing.expect(pinned.closed);
    }
    unref(pinned); // the LAST ref -> freed now (allocator verifies exactly once)
}

test "threaded stress: pins + closed-checks race markClosedAndRelease with no use-after-free" {
    var app = testApp();
    const sc = try create(&app);
    _ = connection.reserveConnectionSlot();
    try registryInsert(sc);
    defer registryReset(std.testing.allocator);
    var cid: [32]u8 = sc.client_id; // copy: the workers must not read through sc after free

    const Worker = struct {
        fn run(client_id: *const [32]u8) void {
            // Pin/verb/unpin in a loop until the registry stops answering (closed+removed).
            while (true) {
                const p = pin(client_id[0..]) orelse return;
                lockMu(&p.mu);
                const dead = p.closed;
                p.mu.unlock();
                unref(p);
                if (dead) return;
                std.atomic.spinLoopHint();
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{&cid});
    // Let the workers spin a moment, then close underneath them.
    var spin: usize = 0;
    while (spin < 10_000) : (spin += 1) std.atomic.spinLoopHint();
    markClosedAndRelease(sc);
    for (&threads) |*t| t.join();
    // Post-close pins miss; the allocator proves exactly-once free and zero leaks.
    try std.testing.expect(pin(cid[0..]) == null);
}

// ---- uplink verb tests (pool-backed) ----------------------------------------

test "handleUplink: closed conn returns null (non-oracle); bad body 400; unsubscribe acks without DB" {
    var app = testApp();
    const a = std.testing.allocator;
    const sc = try create(&app);
    _ = connection.reserveConnectionSlot();
    try registryInsert(sc);
    defer registryReset(std.testing.allocator);

    // Bad body -> 400 + the exact WS error frame.
    const bad = (try handleUplink(sc, RequestArena.forTest(a), "not json")).?;
    defer a.free(bad.frame);
    try std.testing.expectEqual(@as(u16, 400), bad.status);
    try std.testing.expectEqualStrings("{\"type\":\"error\",\"message\":\"bad message\"}", bad.frame);

    // Unsubscribe of an unknown topic: 200 + ack (WS parity — unsubscribe is idempotent).
    const un = (try handleUplink(sc, RequestArena.forTest(a), "{\"action\":\"unsubscribe\",\"topic\":\"nope\"}")).?;
    defer a.free(un.frame);
    try std.testing.expectEqual(@as(u16, 200), un.status);
    try std.testing.expect(std.mem.indexOf(u8, un.frame, "\"action\":\"unsubscribe\"") != null);

    const pinned = pin(sc.client_id[0..]).?;
    markClosedAndRelease(sc);
    // Closed: the verb reports null — the api layer maps it to the SAME 404 as unknown.
    try std.testing.expect((try handleUplink(pinned, RequestArena.forTest(a), "{\"action\":\"unsubscribe\",\"topic\":\"x\"}")) == null);
    unref(pinned);
}

test "handleUplink: subscribe/auth run the SHARED hub verbs (pool-backed decision parity)" {
    // Mirrors hub.zig's subscribeCheck decision-table test THROUGH the SSE uplink, proving
    // the uplink adds no authz of its own. Uses the same file-backed pool harness.
    const db = @import("../db.zig");
    const migrations = @import("../migrations.zig");
    const collections = @import("../collections.zig");
    const rules = @import("../rules.zig");
    const ga = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", ga);
    defer ga.free(dir_path);
    const db_path = try std.fmt.allocPrintSentinel(ga, "{s}/test.db", .{dir_path}, 0);
    defer ga.free(db_path);
    var pool = try db.Pool.init(ga, std.testing.io, db_path);
    defer pool.deinit();
    var arena = std.heap.ArenaAllocator.init(ga);
    defer arena.deinit();
    const a = arena.allocator();
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try migrations.run(w);
        _ = try collections.create(a, std.testing.io, w, .{ .id = "", .name = "sse_pub", .fields = &.{}, .viewRule = rules.public_sentinel });
        _ = try collections.create(a, std.testing.io, w, .{ .id = "", .name = "sse_locked", .fields = &.{}, .viewRule = null });
    }
    var app = App{ .allocator = ga, .io = std.testing.io, .pool = &pool };
    const sc = try create(&app);
    _ = connection.reserveConnectionSlot();
    try registryInsert(sc);
    defer registryReset(ga);

    // Anonymous subscribe to @public: 200 + ack; the sub is registered on the conn.
    const ok = (try handleUplink(sc, RequestArena.from(&arena), "{\"action\":\"subscribe\",\"topic\":\"sse_pub\"}")).?;
    try std.testing.expectEqual(@as(u16, 200), ok.status);
    try std.testing.expect(std.mem.indexOf(u8, ok.frame, "\"type\":\"ack\"") != null);
    try std.testing.expect(sc.conn.hasSub("sse_pub"));
    // Anonymous subscribe to locked: 200 + the exact WS error frame; no sub registered.
    const deny = (try handleUplink(sc, RequestArena.from(&arena), "{\"action\":\"subscribe\",\"topic\":\"sse_locked\"}")).?;
    try std.testing.expectEqual(@as(u16, 200), deny.status);
    try std.testing.expectEqualStrings("{\"type\":\"error\",\"message\":\"authentication required to subscribe\"}", deny.frame);
    try std.testing.expect(!sc.conn.hasSub("sse_locked"));
    // Unknown collection... is a CUSTOM topic (#143 default-public) -> ack; a garbage auth
    // token -> {"type":"auth","status":"error"}.
    const auth_bad = (try handleUplink(sc, RequestArena.from(&arena), "{\"action\":\"auth\",\"token\":\"garbage\"}")).?;
    try std.testing.expectEqualStrings("{\"type\":\"auth\",\"status\":\"error\"}", auth_bad.frame);

    markClosedAndRelease(sc);
}
