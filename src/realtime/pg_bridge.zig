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
//! `NOTIFY zigbase_rt, '<payload>'` carrying a SMALL, FIXED-SIZE `{o,c,a,i[,t]}` body (origin,
//! collection, action, id, and — for deletes — a random **token**, NOT the row data). Every
//! process runs ONE dedicated listener connection (`startListener`) that `LISTEN`s on the channel
//! and, for each notification from a DIFFERENT instance, re-feeds the EXISTING in-process hub: it
//! re-fetches the live row (create/update) or reads the deleted row's at-rest snapshot from a side
//! table by token (delete), then `WS.publish`es the same frames `broadcast` would have — so the
//! unchanged `onChannelMessage` path runs each subscriber's existing view/ability/tenant authz
//! locally. No replication slots, no `wal_level=logical`, and the app's authz is never bypassed.
//!
//! ## Why a side table, not the snapshot inline (security)
//! A delete authorizes against the deleted row's snapshot (the live row is gone). Putting that
//! snapshot in the NOTIFY payload would broadcast the row's column data — including the DECRYPTED
//! plaintext of `.encrypted` fields — to ANY DB role that can `LISTEN zigbase_rt` (a role needing
//! only CONNECT, not SELECT/RLS/column grants), defeating ciphertext-at-rest. So the snapshot is
//! written to `_rt_delete_snapshots` (migration 0018, PG-only) as its **at-rest (ciphertext)**
//! representation, keyed by a random token; only the token rides the wire. The receiving instance
//! reads it back over its own authenticated DB connection. This also keeps the payload fixed-size
//! (no 8000-byte NOTIFY overflow) and closes forged-NOTIFY deletes: a fabricated token has no
//! side-table row, so the delete is never delivered.
//!
//! ## Self-delivery
//! The writer ALSO receives its own NOTIFY (PG delivers to every LISTENer, including the same
//! process's listener). Each payload carries a per-process `origin` id; the listener drops
//! notifications whose origin is its own, so the writing instance delivers exactly once
//! (in-process), and only REMOTE instances act on the NOTIFY.
//!
//! ## Gating
//! The whole module compiles in both builds, but every wire op funnels through the `db.Db` seam
//! helpers (`db.dbListen`/`dbNotify`/`dbWaitNotification`) which are comptime no-ops on SQLite.
//! `emit`/`startListener`/`crossInstanceEnabled` additionally early-return unless the active
//! backend is Postgres, so the default single-binary story links zero new behavior and SQLite
//! realtime is byte-identical.

const std = @import("std");
const build_options = @import("build_options");
const db = @import("../db.zig");
const App = @import("../app.zig").App;
const entropy = @import("../entropy.zig");
const crypto = @import("../crypto.zig");
const protocol = @import("protocol.zig");

/// The single NOTIFY channel all instances LISTEN on. A valid SQL identifier (the driver
/// validates it again before interpolating into `LISTEN "<channel>"`).
pub const channel = "zigbase_rt";

/// How long a delete snapshot lives in the side table before the writer GCs it. The cross-instance
/// propagation window is sub-second (NOTIFY is near-instant; listeners read within ms), so this is
/// a generous orphan-cleanup bound, not a correctness deadline.
const snapshot_ttl_seconds = 60;

/// True when cross-instance realtime applies: Postgres is compiled in AND the active backend is
/// Postgres. Used to gate the delete-snapshot capture on the writer path.
pub fn crossInstanceEnabled(app: *App) bool {
    if (!build_options.postgres) return false;
    return db.poolBackend(app.pool) == .postgres;
}

// ---- per-process origin id --------------------------------------------------

var origin_hex: [16]u8 = undefined;
var origin_ready = std.atomic.Value(bool).init(false);
var origin_mu: std.atomic.Mutex = .unlocked;

/// A stable, per-process random id (16 hex chars) tagging every NOTIFY this instance emits, so a
/// listener can skip its OWN notifications (already delivered in-process). Double-checked locking:
/// the hot path (called on every broadcast + notification) reads the initialized flag lock-free
/// and returns; only the first caller takes the lock to fill it. `io` provides the CSPRNG (and
/// honors the deterministic test seed via `entropy.fill`).
pub fn originId(io: std.Io) []const u8 {
    if (origin_ready.load(.acquire)) return &origin_hex;
    while (!origin_mu.tryLock()) std.atomic.spinLoopHint();
    defer origin_mu.unlock();
    // `.acquire` (paired with the `.release` store below) so a later lock-free `.acquire` reader
    // that observes `origin_ready == true` is guaranteed to see the initialized `origin_hex` bytes.
    if (!origin_ready.load(.acquire)) {
        var raw: [8]u8 = undefined;
        entropy.fill(io, &raw);
        const hex = "0123456789abcdef";
        for (raw, 0..) |b, i| {
            origin_hex[i * 2] = hex[b >> 4];
            origin_hex[i * 2 + 1] = hex[b & 0x0f];
        }
        origin_ready.store(true, .release);
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

/// Encode the (small, fixed-size) NOTIFY payload: `{o,c,a,i}` plus, for a delete, the side-table
/// `t`oken. NO row data ever rides the wire — create/update re-fetch the live row remotely; delete
/// reads the at-rest snapshot from the side table by token.
pub fn encode(
    a: std.mem.Allocator,
    origin: []const u8,
    collection: []const u8,
    action: protocol.Action,
    record_id: []const u8,
    token: ?[]const u8,
) ![]u8 {
    var o: std.json.ObjectMap = .empty;
    defer o.deinit(a); // scratch: valueAlloc reads it into a fresh, self-contained buffer
    try o.put(a, "o", .{ .string = origin });
    try o.put(a, "c", .{ .string = collection });
    try o.put(a, "a", .{ .string = actionStr(action) });
    try o.put(a, "i", .{ .string = record_id });
    if (token) |t| try o.put(a, "t", .{ .string = t });
    return std.json.Stringify.valueAlloc(a, std.json.Value{ .object = o }, .{});
}

/// A decoded cross-instance event. `token` keys the deleted row's at-rest snapshot in the side
/// table (delete only; null for create/update). Each field is an independent, fresh dupe onto the
/// allocator `decode`/`decodeAny` were given — free with `deinit`.
pub const Event = struct {
    origin: []const u8,
    collection: []const u8,
    action: protocol.Action,
    id: []const u8,
    token: ?[]const u8,

    pub fn deinit(self: Event, alloc: std.mem.Allocator) void {
        alloc.free(self.origin);
        alloc.free(self.collection);
        alloc.free(self.id);
        if (self.token) |t| alloc.free(t);
    }
};

fn strField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Parse a NOTIFY payload into an `Event`. The parse tree is scratch (freed via `parsed.deinit()`
/// before returning) — every `Event` field is a FRESH dupe onto `a`, not an alias into the freed
/// tree, so the result is self-contained and safe under any allocator (small, infrequent codec —
/// unlike `hub.frameForDelivery`'s hot per-subscriber path, duping here costs nothing worth
/// avoiding). Returns null if malformed.
pub fn decode(a: std.mem.Allocator, payload: []const u8) ?Event {
    const parsed = std.json.parseFromSlice(std.json.Value, a, payload, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const o = parsed.value.object;
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
    const token = strField(o, "t");
    return .{
        .origin = a.dupe(u8, origin) catch return null,
        .collection = a.dupe(u8, collection) catch return null,
        .action = action,
        .id = a.dupe(u8, record_id) catch return null,
        .token = if (token) |t| (a.dupe(u8, t) catch return null) else null,
    };
}

// ---- custom-topic broadcast/signal codec (#188 theme) -----------------------

/// A payload-less cross-instance signal: nothing but a topic name rides the wire (spec §2.1).
/// Both fields are fresh dupes (see `decodeAny`) — free with `deinit`.
pub const Signal = struct {
    origin: []const u8,
    topic: []const u8,
    pub fn deinit(self: Signal, alloc: std.mem.Allocator) void {
        alloc.free(self.origin);
        alloc.free(self.topic);
    }
};
/// A message-broadcast reference: the frame lives in _rt_broadcasts, keyed by this token. Both
/// fields are fresh dupes (see `decodeAny`) — free with `deinit`.
pub const MessageRef = struct {
    origin: []const u8,
    token: []const u8,
    pub fn deinit(self: MessageRef, alloc: std.mem.Allocator) void {
        alloc.free(self.origin);
        alloc.free(self.token);
    }
};
/// Any decoded zigbase_rt payload kind.
pub const Payload = union(enum) {
    record: Event,
    signal: Signal,
    message: MessageRef,

    pub fn deinit(self: Payload, alloc: std.mem.Allocator) void {
        switch (self) {
            .record => |e| e.deinit(alloc),
            .signal => |s| s.deinit(alloc),
            .message => |m| m.deinit(alloc),
        }
    }
};

/// Encode {"o":origin,"s":topic}.
pub fn encodeSignal(a: std.mem.Allocator, origin: []const u8, topic: []const u8) ![]u8 {
    var o: std.json.ObjectMap = .empty;
    defer o.deinit(a);
    try o.put(a, "o", .{ .string = origin });
    try o.put(a, "s", .{ .string = topic });
    return std.json.Stringify.valueAlloc(a, std.json.Value{ .object = o }, .{});
}

/// Encode {"o":origin,"m":token}. NO payload bytes — the token keys the side table.
pub fn encodeMessage(a: std.mem.Allocator, origin: []const u8, token: []const u8) ![]u8 {
    var o: std.json.ObjectMap = .empty;
    defer o.deinit(a);
    try o.put(a, "o", .{ .string = origin });
    try o.put(a, "m", .{ .string = token });
    return std.json.Stringify.valueAlloc(a, std.json.Value{ .object = o }, .{});
}

/// Decode ANY payload kind. Kind detection is by key: "s" => signal, "m" => message, else the
/// record codec. An OLD instance's decoder (`decode`) returns null on s/m payloads (missing
/// c/a/i) — rolling upgrades are safe by construction (pinned by test below).
///
/// The parse tree is scratch (freed via `parsed.deinit()`) — every returned field is a fresh dupe
/// onto `a`, matching `decode`'s discipline (this small, infrequent codec is never the hot
/// per-subscriber path `hub.frameForDelivery` optimizes against).
pub fn decodeAny(a: std.mem.Allocator, payload: []const u8) ?Payload {
    {
        const parsed = std.json.parseFromSlice(std.json.Value, a, payload, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const o = parsed.value.object;
        const origin = strField(o, "o") orelse return null;
        if (strField(o, "s")) |topic| return .{ .signal = .{
            .origin = a.dupe(u8, origin) catch return null,
            .topic = a.dupe(u8, topic) catch return null,
        } };
        if (strField(o, "m")) |token| return .{ .message = .{
            .origin = a.dupe(u8, origin) catch return null,
            .token = a.dupe(u8, token) catch return null,
        } };
    }
    // Neither "s" nor "m": re-parse via the record codec (self-contained; dupes its own fields).
    const ev = decode(a, payload) orelse return null;
    return .{ .record = ev };
}

// ---- delete-snapshot side table (writer + reader) ---------------------------

/// Persist a deleted row's AT-REST snapshot (from `records.getAtRest` — encrypted fields stay
/// ciphertext) in `_rt_delete_snapshots`, keyed by a fresh random token returned for the NOTIFY
/// payload. MUST run on the Postgres writer INSIDE the delete transaction so the row commits
/// atomically with the delete (and is readable by remote listeners after the post-commit NOTIFY).
/// Also GCs expired tokens (cheap piggyback). Returns null on any error (cross-instance delete
/// then degrades to no remote delivery — local subscribers are unaffected).
pub fn storeDeleteSnapshot(alloc: std.mem.Allocator, io: std.Io, w: *db.Db, snapshot: std.json.Value) ?[]const u8 {
    // #39: keep the degrade-to-no-remote-delivery `?`-return, but do NOT collapse every failure to
    // a silent null — a persistent store failure (table dropped, permission change, degraded
    // connection) would otherwise stop ALL cross-instance deletes with zero operator-visible signal.
    return storeDeleteSnapshotInner(alloc, io, w, snapshot) catch |e| {
        std.log.warn("realtime: cross-instance delete-snapshot store failed (remote subscribers will miss this delete): {s}", .{@errorName(e)});
        return null;
    };
}

fn storeDeleteSnapshotInner(alloc: std.mem.Allocator, io: std.Io, w: *db.Db, snapshot: std.json.Value) ![]const u8 {
    const token = try crypto.genToken(io, alloc, 32);
    const snap_json = try std.json.Stringify.valueAlloc(alloc, snapshot, .{});
    defer alloc.free(snap_json); // scratch: bound into the INSERT below, not retained after
    // GC orphaned tokens first (writers whose listeners never consumed them). Bounds the table to
    // ~the TTL window of deletes; native PG interval compare on the indexed `created` column.
    // Best-effort: a GC failure must not fail the store itself.
    w.exec("DELETE FROM \"_rt_delete_snapshots\" WHERE \"created\" < now() - interval '" ++
        std.fmt.comptimePrint("{d}", .{snapshot_ttl_seconds}) ++ " seconds';") catch {};
    var st = try w.prepare("INSERT INTO \"_rt_delete_snapshots\" (\"token\",\"snapshot\") VALUES ($1,$2);");
    defer st.finalize();
    try st.bindText(1, token);
    try st.bindText(2, snap_json);
    _ = try st.step();
    return token;
}

/// Read a deleted row's at-rest snapshot back by `token` (on the reader `r`). Returns null if the
/// token has no row — which is exactly how a FORGED NOTIFY delete is rejected (no real delete →
/// no token row → no delivery). The caller feeds the (ciphertext-preserving) snapshot to the
/// delete authz; the delivered frame is id-only, so nothing is decrypted here.
pub fn readDeleteSnapshot(alloc: std.mem.Allocator, r: *db.Db, token: []const u8) ?std.json.Value {
    // #39: a MISSING row (forged/expired token) is a legitimate silent fail-closed drop, but a real
    // DB/parse error is an operator-visible fault — collapsing both to a silent null made an
    // undelivered remote delete indistinguishable from a forged token. Split them: no-row → null
    // (quiet), any error → logged null.
    return (readDeleteSnapshotInner(alloc, r, token) catch |e| {
        std.log.warn("realtime: cross-instance delete-snapshot read failed (remote delete not delivered): {s}", .{@errorName(e)});
        return null;
    });
}

/// Returns null (NOT an error) when the token has no side-table row — the forged/expired-token
/// fail-closed drop. Real DB/parse failures propagate so the wrapper can log them.
fn readDeleteSnapshotInner(alloc: std.mem.Allocator, r: *db.Db, token: []const u8) !?std.json.Value {
    var st = try r.prepare("SELECT \"snapshot\" FROM \"_rt_delete_snapshots\" WHERE \"token\" = $1;");
    defer st.finalize();
    try st.bindText(1, token);
    if (!(try st.step())) return null; // no row: forged/expired token — quiet drop
    // Dupe before finalize — `columnText` aliases stmt-owned memory, and the JSON parser may keep
    // references into its input for string values.
    const json = try alloc.dupe(u8, st.columnText(0));
    return try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
}

// ---- emit (writer → NOTIFY) -------------------------------------------------

/// Fan a just-committed record event out to OTHER instances via `NOTIFY`. Called from
/// `ws.broadcast` AFTER the local in-process publish. `notify_token` keys the delete snapshot in
/// the side table (null for create/update). A no-op unless the active backend is Postgres; a
/// failure is logged (best-effort — the writing instance already delivered locally).
pub fn emit(
    app: *App,
    collection: []const u8,
    action: protocol.Action,
    record_id: []const u8,
    notify_token: ?[]const u8,
) void {
    if (!build_options.postgres) return;
    if (db.poolBackend(app.pool) != .postgres) return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const payload = encode(a, originId(app.io), collection, action, record_id, notify_token) catch return;
    var c = app.pool.acquireReader() catch |e| {
        std.log.warn("realtime: cross-instance NOTIFY skipped (pool acquire failed): {s}", .{@errorName(e)});
        return;
    };
    defer app.pool.releaseReader(&c);
    db.dbNotify(&c, a, channel, payload) catch |e| {
        std.log.warn("realtime: cross-instance NOTIFY failed: {s}", .{@errorName(e)});
    };
}

// ---- custom-topic broadcast/signal fan-out (#188 theme) ---------------------

/// Fan a custom-topic SIGNAL out to other instances (spec §2.1). A no-op unless the active
/// backend is Postgres. Belt: NOTIFY has an ~8000-byte ceiling; topics are channel names, so
/// >1024 bytes is a can't-happen guarded with a warn + skip.
pub fn emitSignal(app: *App, topic: []const u8) void {
    if (!build_options.postgres) return;
    if (db.poolBackend(app.pool) != .postgres) return;
    if (topic.len > 1024) {
        std.log.warn("realtime: cross-instance signal skipped (topic too long: {d} bytes)", .{topic.len});
        return;
    }
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const payload = encodeSignal(a, originId(app.io), topic) catch return;
    var c = app.pool.acquireReader() catch |e| {
        std.log.warn("realtime: cross-instance signal NOTIFY skipped (pool acquire failed): {s}", .{@errorName(e)});
        return;
    };
    defer app.pool.releaseReader(&c);
    db.dbNotify(&c, a, channel, payload) catch |e| {
        std.log.warn("realtime: cross-instance signal NOTIFY failed: {s}", .{@errorName(e)});
    };
}

/// Persist an enveloped broadcast frame in _rt_broadcasts keyed by a fresh random token; GCs rows
/// older than the shared TTL as a piggyback (same as storeDeleteSnapshot). Returns null on any
/// error (the broadcast degrades to local-only delivery). The token is 32 CSPRNG bytes, so a
/// forged/guessed token cannot resolve to another topic's frame (readBroadcast returns null).
pub fn storeBroadcast(alloc: std.mem.Allocator, io: std.Io, c: *db.Db, topic: []const u8, frame: []const u8) ?[]const u8 {
    const token = crypto.genToken(io, alloc, 32) catch return null;
    c.exec("DELETE FROM \"_rt_broadcasts\" WHERE \"created\" < now() - interval '" ++
        std.fmt.comptimePrint("{d}", .{snapshot_ttl_seconds}) ++ " seconds';") catch {};
    var st = c.prepare("INSERT INTO \"_rt_broadcasts\" (\"token\",\"topic\",\"frame\") VALUES ($1,$2,$3);") catch return null;
    defer st.finalize();
    st.bindText(1, token) catch return null;
    st.bindText(2, topic) catch return null;
    st.bindText(3, frame) catch return null;
    _ = st.step() catch return null;
    return token;
}

/// Fan a custom-topic MESSAGE broadcast out via token + side-table (spec §2.2, option b made
/// honest). The autocommit INSERT precedes the NOTIFY on ONE pooled connection, so a receiver
/// that gets the notification always finds the row. Best-effort: any failure logs and degrades
/// to local-only delivery (matching record-event `emit`).
///
/// `_rt_broadcasts` is written (INSERT + GC DELETE), so this needs a write-capable connection —
/// `acquireReader()` can hand back a read-replica in a standard PG HA topology, where the write
/// would fail. `bound_conn`, when non-null, is the writer connection the CALLER already holds
/// (e.g. `ctx.realtime().broadcast()` called from a record hook, whose `Ctx.bound_conn` is the
/// triggering write's in-transaction connection — see `events.zig`'s `RecordEvent` doc). Reusing
/// it is required, not just an optimization: the pool writer is a single non-reentrant lock, so
/// calling `acquireWriter()` while already holding it would deadlock permanently. Only acquire a
/// fresh writer when the caller isn't already holding one (route handlers, jobs, cron).
pub fn emitMessage(app: *App, bound_conn: ?*db.Db, topic: []const u8, frame: []const u8) void {
    if (!build_options.postgres) return;
    if (db.poolBackend(app.pool) != .postgres) return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = bound_conn orelse app.pool.acquireWriter();
    defer if (bound_conn == null) app.pool.releaseWriter();
    const token = storeBroadcast(a, app.io, c, topic, frame) orelse {
        std.log.warn("realtime: cross-instance broadcast skipped (side-table store failed)", .{});
        return;
    };
    const payload = encodeMessage(a, originId(app.io), token) catch return;
    db.dbNotify(c, a, channel, payload) catch |e| {
        std.log.warn("realtime: cross-instance broadcast NOTIFY failed: {s}", .{@errorName(e)});
    };
}

/// Read a broadcast frame back by token. No row = FORGED or EXPIRED token = drop (the same
/// forged-NOTIFY closure deletes have). The token PRIMARY KEY is 32 CSPRNG bytes, so a fabricated
/// or guessed token cannot alias a real row.
pub const Broadcast = struct { topic: []const u8, frame: []const u8 };
pub fn readBroadcast(alloc: std.mem.Allocator, r: *db.Db, token: []const u8) ?Broadcast {
    // #39: same split as readDeleteSnapshot — no row (forged/expired) is a quiet fail-closed drop;
    // a real DB error is logged rather than silently indistinguishable from a forged token.
    return (readBroadcastInner(alloc, r, token) catch |e| {
        std.log.warn("realtime: cross-instance broadcast read failed (remote broadcast not delivered): {s}", .{@errorName(e)});
        return null;
    });
}

fn readBroadcastInner(alloc: std.mem.Allocator, r: *db.Db, token: []const u8) !?Broadcast {
    var st = try r.prepare("SELECT \"topic\",\"frame\" FROM \"_rt_broadcasts\" WHERE \"token\" = $1;");
    defer st.finalize();
    try st.bindText(1, token);
    if (!(try st.step())) return null; // no row: forged/expired token — quiet drop
    // Dupe before finalize — `columnText` aliases stmt-owned memory.
    const topic = try alloc.dupe(u8, st.columnText(0));
    const frame = try alloc.dupe(u8, st.columnText(1));
    return .{ .topic = topic, .frame = frame };
}

// ---- listener (NOTIFY → in-process hub) -------------------------------------

const ListenerCtx = struct {
    app: *App,
    on_event: *const fn (*App, Payload) void,
};

/// Spawn a detached, process-lifetime listener thread (Postgres only) that feeds each REMOTE
/// notification to `on_event`. The thread owns its connection and AUTO-RECONNECTS with capped
/// backoff on any drop (PG restart/failover/idle timeout) — multi-instance realtime must not stop
/// silently. A no-op (returns cleanly) unless the active backend is Postgres.
pub fn startListener(app: *App, on_event: *const fn (*App, Payload) void) !void {
    if (!build_options.postgres) return;
    if (db.poolBackend(app.pool) != .postgres) return;
    _ = originId(app.io); // prime on the serving thread so `emit` + the listener agree
    const ctx = try app.allocator.create(ListenerCtx);
    errdefer app.allocator.destroy(ctx);
    ctx.* = .{ .app = app, .on_event = on_event };
    const t = try std.Thread.spawn(.{}, listenerLoop, .{ctx});
    t.detach();
}

/// Open a dedicated reader connection and `LISTEN` on the channel.
fn openListenConn(app: *App) !db.Db {
    var conn = try app.pool.openReader();
    errdefer conn.close();
    try db.dbListen(&conn, channel);
    return conn;
}

const backoff_min_ms: u64 = 250;
const backoff_cap_ms: u64 = 30_000;
/// A session that stayed connected at least this long is "proven healthy" (#43): its backoff
/// resets to the floor. A shorter session is treated as flapping.
const healthy_session_ms: u64 = 5_000;

/// Pure backoff policy (#43): given how long the just-ended LISTEN session lasted, decide whether
/// to sleep before reconnecting and what the next backoff is. A session that lasted at least
/// `healthy_session_ms` is proven healthy → reset to the floor with NO sleep. A shorter one (a
/// proxy/failover peer that ACCEPTS the connect + LISTEN but drops on the first wait) is flapping →
/// sleep the current backoff and grow it, so reconnects have a real floor instead of spinning
/// connect/LISTEN cycles at full rate. The OLD code reset the backoff the instant a connect
/// succeeded and never slept post-drop, so that flapping case was an unthrottled reconnect loop.
fn nextBackoff(session_ms: u64, cur_backoff_ms: u64) struct { sleep_ms: u64, next_ms: u64 } {
    if (session_ms >= healthy_session_ms) return .{ .sleep_ms = 0, .next_ms = backoff_min_ms };
    return .{ .sleep_ms = cur_backoff_ms, .next_ms = @min(cur_backoff_ms * 2, backoff_cap_ms) };
}

fn listenerLoop(ctx: *ListenerCtx) void {
    defer ctx.app.allocator.destroy(ctx);
    var backoff_ms: u64 = backoff_min_ms;
    while (true) {
        var conn = openListenConn(ctx.app) catch |e| {
            std.log.err("realtime: PG LISTEN connect failed: {s}; retrying in {d}ms", .{ @errorName(e), backoff_ms });
            // backoff_ms is bounded to [backoff_min_ms, backoff_cap_ms] (30s), well within i64.
            ctx.app.io.sleep(std.Io.Duration.fromMilliseconds(@intCast(backoff_ms)), .awake) catch {};
            backoff_ms = @min(backoff_ms * 2, backoff_cap_ms);
            continue;
        };
        std.log.info("realtime: PG LISTEN bridge connected on \"{s}\"", .{channel});
        // Time the session so the backoff resets ONLY after a connection has proven healthy, not
        // the instant a (possibly-flapping) connect succeeds (#43). Uses the same monotonic clock
        // the rest of the codebase reads (`std.Io.Timestamp.now`, cf. http_client.zig).
        const started_ns = std.Io.Timestamp.now(ctx.app.io, .awake).nanoseconds;
        processUntilDrop(ctx, &conn);
        conn.close();
        const elapsed_ns = std.Io.Timestamp.now(ctx.app.io, .awake).nanoseconds - started_ns;
        const session_ms: u64 = @intCast(@max(0, @divTrunc(elapsed_ns, std.time.ns_per_ms)));
        const b = nextBackoff(session_ms, backoff_ms);
        backoff_ms = b.next_ms;
        if (b.sleep_ms == 0) {
            std.log.err("realtime: PG LISTEN connection dropped; reconnecting (events during the gap are missed)", .{});
        } else {
            std.log.err("realtime: PG LISTEN connection dropped after {d}ms; backing off {d}ms before reconnect (events during the gap are missed)", .{ session_ms, b.sleep_ms });
            // b.sleep_ms is a prior backoff value, bounded to backoff_cap_ms (30s), well within i64.
            ctx.app.io.sleep(std.Io.Duration.fromMilliseconds(@intCast(b.sleep_ms)), .awake) catch {};
        }
    }
}

/// Consume notifications on `conn` until it errors (returns so the caller reconnects).
fn processUntilDrop(ctx: *ListenerCtx, conn: *db.Db) void {
    while (true) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const maybe = db.dbWaitNotification(conn, a) catch return; // conn dropped → reconnect
        const n = maybe orelse continue; // a non-notification async message: ignore
        if (!std.mem.eql(u8, n.channel, channel)) continue;
        const p = decodeAny(a, n.payload) orelse continue;
        const origin = switch (p) {
            .record => |ev| ev.origin,
            .signal => |s| s.origin,
            .message => |m| m.origin,
        };
        if (std.mem.eql(u8, origin, originId(ctx.app.io))) continue; // our own write: already local
        ctx.on_event(ctx.app, p);
    }
}

// ---- tests (codec; the live cross-instance path is in backend/postgres/realtime_pg_test.zig) ---

test "encode/decode round-trip: create is minimal (no token)" {
    const a = std.testing.allocator;
    const payload = try encode(a, "abc123", "posts", .create, "REC1", null);
    defer a.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"t\"") == null); // no token key
    const ev = decode(a, payload).?;
    defer ev.deinit(a);
    try std.testing.expectEqualStrings("abc123", ev.origin);
    try std.testing.expectEqualStrings("posts", ev.collection);
    try std.testing.expectEqual(protocol.Action.create, ev.action);
    try std.testing.expectEqualStrings("REC1", ev.id);
    try std.testing.expect(ev.token == null);
}

test "encode/decode round-trip: delete carries only a token (no row data)" {
    const a = std.testing.allocator;
    const payload = try encode(a, "o1", "notes", .delete, "REC1", "tok_xyz");
    defer a.free(payload);
    // The payload must NOT contain any record/field data — only the token.
    try std.testing.expect(std.mem.indexOf(u8, payload, "tok_xyz") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "owner") == null);
    const ev = decode(a, payload).?;
    defer ev.deinit(a);
    try std.testing.expectEqual(protocol.Action.delete, ev.action);
    try std.testing.expectEqualStrings("tok_xyz", ev.token.?);
}

test "decode: malformed / missing fields return null" {
    const a = std.testing.allocator;
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

test "s/m kinds: encode/decode round-trip; NO payload bytes on the message wire" {
    const a = std.testing.allocator;
    const sig = try encodeSignal(a, "o1", "orders");
    defer a.free(sig);
    const sp = decodeAny(a, sig).?;
    defer sp.deinit(a);
    try std.testing.expectEqualStrings("orders", sp.signal.topic);
    try std.testing.expectEqualStrings("o1", sp.signal.origin);
    const msg = try encodeMessage(a, "o1", "tok_abc");
    defer a.free(msg);
    const mp = decodeAny(a, msg).?;
    defer mp.deinit(a);
    try std.testing.expectEqualStrings("tok_abc", mp.message.token);
    // The message payload carries ONLY origin + token — no topic, no frame, no data.
    try std.testing.expect(std.mem.indexOf(u8, msg, "orders") == null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "data") == null);
    // decodeAny still decodes record payloads (all three kinds through one entry).
    const rec = try encode(a, "o2", "posts", .create, "R1", null);
    defer a.free(rec);
    const rp = decodeAny(a, rec).?;
    defer rp.deinit(a);
    try std.testing.expectEqualStrings("posts", rp.record.collection);
}

test "nextBackoff: a healthy session resets; a flapping session floors + grows the reconnect (#43)" {
    // A session that lasted past the healthy threshold: reset to the floor, no pre-reconnect sleep.
    {
        const b = nextBackoff(healthy_session_ms, backoff_cap_ms);
        try std.testing.expectEqual(@as(u64, 0), b.sleep_ms);
        try std.testing.expectEqual(backoff_min_ms, b.next_ms);
    }
    // A session that dropped almost immediately (accept + LISTEN then drop on first wait): sleep the
    // CURRENT backoff before reconnecting and double it — this is the anti-spin floor.
    {
        const b = nextBackoff(0, backoff_min_ms);
        try std.testing.expectEqual(backoff_min_ms, b.sleep_ms);
        try std.testing.expectEqual(backoff_min_ms * 2, b.next_ms);
    }
    // Growth is capped.
    {
        const b = nextBackoff(healthy_session_ms - 1, backoff_cap_ms);
        try std.testing.expectEqual(backoff_cap_ms, b.sleep_ms);
        try std.testing.expectEqual(backoff_cap_ms, b.next_ms);
    }
}

test "rolling-upgrade tolerance: the OLD record decoder returns null on s/m payloads" {
    const a = std.testing.allocator;
    const sig = try encodeSignal(a, "o1", "orders");
    defer a.free(sig);
    try std.testing.expect(decode(a, sig) == null);
    const msg = try encodeMessage(a, "o1", "tok");
    defer a.free(msg);
    try std.testing.expect(decode(a, msg) == null);
}
