const std = @import("std");
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const rules = @import("../rules.zig");
const policy = @import("../policy.zig");
const tenancy = @import("../tenancy/tenancy.zig");
const request = @import("../request.zig");
const collections = @import("../collections.zig");
const colcache = @import("../colcache.zig");
const records = @import("../records.zig");
const migrations = @import("../migrations.zig");
const auth = @import("../auth.zig");
const protocol = @import("protocol.zig");
const connection = @import("connection.zig");
const Conn = connection.Conn;
const App = @import("../app.zig").App;
const Ctx = @import("../ctx.zig").Ctx;

pub const DeliverError = policy.PolicyError;

/// Fixed PUBLIC realtime channel for the feature-management "changed" signal (#128/#129/#130).
/// (moved from ws.zig — the delivery chokepoint needs it; ws.zig re-exports it.)
pub const FEATURES_CHANNEL = "__features";

/// F5: may a socket subscribe to a collection with this `view_rule`? Anonymous sockets may
/// subscribe ONLY to a public (@public) collection. Any other collection — locked, owner-scoped,
/// or any expression — requires a live authenticated (or superuser) identity first. Delivery is
/// still independently gated per record by `hub.shouldDeliver`; this just stops anonymous sockets
/// from registering subscriptions on gated data.
pub fn subscribeAuthorized(view_rule: ?[]const u8, authed: bool, is_superuser: bool) bool {
    if (policy.isPublic(view_rule)) return true;
    return authed or is_superuser;
}

/// The result of authorizing a subscribe request. `.limit` (NEW in the extraction) is the
/// MAX_SUBS rejection — previously an inline check in ws.onMessage; folded in here so BOTH
/// transports share the complete decision.
pub const SubscribeOutcome = enum { ok, unknown, auth_required, limit };

/// Pure subscribe-authorization decision (#143, F5), factored out so the security PRECEDENCE
/// is testable in one place: a REAL collection topic (`col != null`) ALWAYS uses per-collection
/// authz (`subscribeAuthorized`) — the custom-topic predicate is NEVER consulted for it, so a
/// custom subscribe can't reach a collection's records. Only a NON-collection custom topic
/// (`col == null`) is gated by `custom_allowed` (the `canSubscribe` result; default true).
pub fn subscribeDecision(col: ?schema.Collection, authed: bool, is_superuser: bool, custom_allowed: bool) SubscribeOutcome {
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
pub fn canSubscribeTopic(app: *App, arena: std.mem.Allocator, rctx: request.RequestContext, topic: []const u8) bool {
    const d = app.dispatch orelse return true;
    const predicate = d.realtime_can_subscribe orelse return true;
    var cx = Ctx{ .app = app, .arena = arena, .rctx = rctx };
    defer cx.deinit();
    return predicate(&cx, topic);
}

/// The string `id` of a record JSON object, or "" when absent/non-object.
fn recordIdOf(rec: std.json.Value) []const u8 {
    if (rec != .object) return "";
    const v = rec.object.get("id") orelse return "";
    return if (v == .string) v.string else "";
}

/// The `auth` verb body (moved from ws.onMessage, #156): verify the token on a pooled reader,
/// install/clear the connection identity, resolve + cache the tenancy scope. Returns the
/// {"type":"auth","status":"ok"|"error"} outcome; the CALLER writes the frame on its own
/// transport. `durable_alloc` MUST be the connection-durable arena (the auth record and
/// resolved memberships persist across frames). `requested_account` is the handshake-captured
/// account request (header/signed-cookie), verified here against _memberships — an unverified
/// value never grants scope. A pool-acquire failure is an auth failure (false), matching the
/// old inline behavior (authFrame(false)).
pub fn authVerb(app: *App, conn: *Conn, durable_alloc: std.mem.Allocator, token: []const u8, requested_account: []const u8) bool {
    var r = app.pool.acquireReader() catch return false;
    defer app.pool.releaseReader(&r);
    if (auth.verifyToken(durable_alloc, app, &r, token)) |v| {
        conn.setAuth(.{ .record = v.record, .is_superuser = v.is_superuser, .exp = v.exp });
        // #156: resolve + cache the active account scope against _memberships (durable
        // allocator → persists across frames). Superusers bypass tenancy. A failed/absent
        // resolution leaves account_id="" → tenant-owned delivery fails closed (deny).
        if (conn.tenancy_enabled and !v.is_superuser) {
            const uid = recordIdOf(v.record);
            if (uid.len > 0) {
                const res = tenancy.resolve(durable_alloc, &r, v.collection, uid, requested_account) catch tenancy.Resolution{};
                conn.setTenancyScope(res.account_id, res.memberships);
            }
        }
        return true;
    }
    conn.clearAuth();
    return false;
}

/// The `subscribe` authorization body (moved from ws.onMessage, F5/#143): MAX_SUBS cap, the
/// public __features carve-out, collection lookup, and the subscribeDecision precedence (a REAL
/// collection topic ALWAYS uses per-collection authz; the canSubscribe predicate gates ONLY
/// non-collection custom topics). Pure decision — the caller performs the transport-side
/// subscription + reply. `alloc` is per-call scratch (the collection lookup borrows it).
pub fn subscribeCheck(app: *App, conn: *const Conn, alloc: std.mem.Allocator, topic: []const u8) SubscribeOutcome {
    if (conn.subs.count() >= connection.MAX_SUBS) return .limit;
    const t = protocol.parseTopic(topic);
    // The feature-management signal channel is PUBLIC and is not a collection.
    if (std.mem.eql(u8, t.collection, FEATURES_CHANNEL)) return .ok;
    var r = app.pool.acquireReader() catch return .unknown;
    const now = auth.nowUnixPub(&r) catch 0;
    const rctx = conn.requestContext(now);
    const lookup = collections.get(alloc, &r, t.collection) catch {
        app.pool.releaseReader(&r);
        return .unknown;
    };
    // Release the reader now: the canSubscribe predicate is handed a Ctx that may acquire its own.
    app.pool.releaseReader(&r);
    const custom_allowed = lookup == null and canSubscribeTopic(app, alloc, rctx, topic);
    return subscribeDecision(lookup, rctx.auth != null, rctx.is_superuser, custom_allowed);
}

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
/// delete: authorized against a SNAPSHOT of the deleted row (the live row is gone). F4 fix — the
/// writer embeds the deleted record's fields in the delete frame so an owner-scoped viewRule still
/// only notifies the authorized owner instead of every non-locked subscriber. `delete_snapshot` is
/// the deleted record object (from the broadcast frame's private snapshot); when null we fall back
/// to the coarse "deliver unless locked" behavior (e.g. no snapshot available).
pub fn shouldDeliver(
    alloc: std.mem.Allocator,
    io: std.Io,
    reader: *db.Db,
    col: schema.Collection,
    conn: *const Conn,
    now: i64,
    action: protocol.Action,
    record_id: []const u8,
    sub_filter: ?[]const u8,
    delete_snapshot: ?std.json.Value,
) DeliverError!bool {
    const rctx = conn.requestContext(now);
    // Whether the tenant scope applies to THIS subscriber on THIS collection (tenancy enabled +
    // tenant-owned + non-superuser). When it does, delivery must be scoped to the subscriber's
    // active account even if the viewRule alone would `allow` (e.g. `@public`) — otherwise a
    // tenant-owned collection leaks across accounts over WebSocket. The rule-clause decision below
    // uses the RAW rule (`rules.decide`), not the tenancy-forced `policy.decide`, so an `@public`
    // rule never gets compiled as a guard expression — the tenant predicate is composed inside
    // `policy.matchesRule`.
    const scope_applies = tenancy.scopeApplies(col, &rctx);

    if (action == .delete) {
        switch (rules.decide(col.viewRule, &rctx)) {
            .deny_locked => return false, // locked: superuser already short-circuited to .allow
            .allow => {
                // @public or superuser: anyone may learn of the delete — UNLESS the collection is
                // tenant-scoped for this subscriber, in which case authorize the deleted row's
                // snapshot against the tenant predicate (no rule clause). No snapshot -> deny.
                if (!scope_applies) return true;
                const snap = delete_snapshot orelse return false;
                return matchesSnapshot(alloc, io, col, record_id, "", snap, &rctx) catch false;
            },
            .check => {
                // Owner/expression-scoped viewRule: authorize the deleted row against its
                // snapshot (the live row is gone). The tenant predicate, when applicable, is
                // composed in by `matchesSnapshot`->`policy.matchesRule`. No snapshot -> deny.
                const snap = delete_snapshot orelse return false;
                return matchesSnapshot(alloc, io, col, record_id, col.viewRule.?, snap, &rctx) catch false;
            },
        }
    }

    var clauses: std.ArrayList([]const u8) = .empty;
    defer clauses.deinit(alloc);
    switch (rules.decide(col.viewRule, &rctx)) {
        .deny_locked => return false,
        .allow => {},
        .check => try clauses.append(alloc, col.viewRule.?),
    }
    if (sub_filter) |f| if (f.len > 0) try clauses.append(alloc, f);
    // Unconstrained ONLY when there is no rule/filter clause AND no tenant scope. Otherwise run a
    // guarded query: `matchesRule` ANDs the tenant predicate in (and tolerates an empty rule, so a
    // tenant-only constraint is evaluated even with no viewRule/filter clause).
    if (clauses.items.len == 0 and !scope_applies) return true;

    const combined = if (clauses.items.len > 0) try combineClauses(alloc, clauses.items) else "";
    return policy.matchesRule(alloc, reader, col, record_id, combined, &rctx);
}

/// Evaluate `rule` against a single deleted-record `snapshot` (F4). Builds a throwaway in-memory
/// DB (a MINIMAL schema: just the _collections registry — R1-3), recreates `col`'s table, inserts
/// ONLY the snapshot row (id + its stored columns preserved
/// verbatim), and runs the standard guarded SELECT. Reuses the exact rule machinery without
/// touching the (now row-less) live DB. Relation-traversing rules resolve against empty target
/// tables in the temp DB and therefore won't match — a conservative (deny) failure for delete
/// events, which is the safe direction.
///
/// BACKEND-AGNOSTIC (#159, PR-6): the sandbox is `db.Db.openMemory()`, which is ALWAYS the SQLite
/// union arm (SQLite is compiled into every build; Postgres has no `:memory:` analog). So this
/// delete-snapshot authz works identically whether the LIVE backend is SQLite or Postgres — it is
/// a self-contained, SQLite-dialect rule evaluator that never touches the live DB. `matchesRule`
/// derives its dialect per-`Db` (`db.dbDialect`), so the temp DB compiles SQLite SQL while the
/// create/update path against the live `reader` compiles Postgres `$n`/`now()` SQL — each
/// self-consistent.
///
/// CAVEAT (dialect divergence, not blocking): a DELETE event is therefore ALWAYS authorized in the
/// SQLite dialect even on a Postgres-backed instance, whereas create/update authorize in the
/// Postgres dialect against the live row. A rule relying on dialect-divergent SCALAR semantics
/// (date/time functions, `LIKE` case-sensitivity, boolean coercion) could authorize a delete event
/// marginally differently than Postgres would authorize a live view. Blast radius is narrow — a
/// single-row sandbox, relation rules deny against empty target tables, and the typical authz
/// fields (owner id, tenant key) are plain string equality that is identical across dialects — and
/// this is pre-existing F4 behavior, not new in PR-6. Owner/tenant-scoped deletes are unaffected.
fn matchesSnapshot(
    alloc: std.mem.Allocator,
    io: std.Io,
    col: schema.Collection,
    record_id: []const u8,
    rule: []const u8,
    snapshot: std.json.Value,
    rctx: *const request.RequestContext,
) !bool {
    if (snapshot != .object) return false;
    var tmp = try db.Db.openMemory();
    defer tmp.close();
    // R1-3: the sandbox needs ONLY the `_collections` registry (+ its `options` column) —
    // collections.create below reads and writes it — plus the one collection table that
    // create() builds. The full migration suite (~28 CREATE TABLEs) ran here before, ONCE
    // PER SUBSCRIBER PER DELETE EVENT: the dominant fan-out cost. Semantics are unchanged:
    // tenancy/ability predicates compile to columns on the target table + bound params,
    // and relation-traversing rules already resolved against an EMPTY `_collections`
    // (conservative deny) because user collections were never present in the sandbox.
    try tmp.exec(migrations.collections_table_sql);
    try tmp.exec(migrations.collections_options_column_sql);
    // Recreate the collection table (fresh id; we never persist relation FKs, so an isolated
    // schema is enough to evaluate column/macro comparisons).
    var spec = col;
    spec.id = "";
    spec.indexes = &.{}; // unique indexes are irrelevant for a single-row authz probe
    const live_col = try collections.create(alloc, io, &tmp, spec);

    // Direct INSERT preserving the snapshot's real id + stored scalar columns, binding each value
    // by its JSON type. (We bypass records.create on purpose: it regenerates the id and re-runs
    // validation, neither of which we want for an authz snapshot of an already-validated row.)
    var cols_sql: std.ArrayList(u8) = .empty;
    var ph_sql: std.ArrayList(u8) = .empty;
    const Bind = struct { v: std.json.Value };
    var binds: std.ArrayList(Bind) = .empty;
    try cols_sql.appendSlice(alloc, "\"id\",\"created\",\"updated\"");
    try ph_sql.appendSlice(alloc, "?1,'',''");
    var n: c_int = 2;
    var it = snapshot.object.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        if (std.mem.eql(u8, name, "id") or std.mem.eql(u8, name, "created") or std.mem.eql(u8, name, "updated")) continue;
        if (schema.fieldByName(live_col, name) == null) continue; // skip non-column keys (e.g. expand)
        switch (e.value_ptr.*) {
            .string, .integer, .float, .bool, .number_string => {},
            else => continue, // null/object/array: leave column NULL
        }
        try cols_sql.append(alloc, ',');
        try cols_sql.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\"{s}\"", .{name}));
        try ph_sql.append(alloc, ',');
        try ph_sql.appendSlice(alloc, try std.fmt.allocPrint(alloc, "?{d}", .{n}));
        try binds.append(alloc, .{ .v = e.value_ptr.* });
        n += 1;
    }
    const sql = try std.fmt.allocPrintSentinel(alloc, "INSERT INTO \"{s}\" ({s}) VALUES ({s});", .{ col.name, cols_sql.items, ph_sql.items }, 0);
    var st = try tmp.prepare(sql);
    defer st.finalize();
    const rid = (snapshot.object.get("id") orelse return false);
    if (rid != .string) return false;
    try st.bindText(1, rid.string);
    var bi: c_int = 2;
    for (binds.items) |b| {
        switch (b.v) {
            .string => |s| try st.bindText(bi, s),
            .number_string => |s| try st.bindText(bi, s),
            .integer => |x| try st.bindInt(bi, x),
            .float => |x| try st.bindDouble(bi, x),
            .bool => |x| try st.bindInt(bi, if (x) 1 else 0),
            else => try st.bindNull(bi),
        }
        bi += 1;
    }
    _ = try st.step();
    return policy.matchesRule(alloc, &tmp, live_col, record_id, rule, rctx) catch false;
}

pub const EventFrames = struct {
    collection_channel: []const u8,
    record_channel: []const u8,
    frame_collection: []const u8,
    frame_record: []const u8,
};

/// Private key carrying the deleted record's authorization SNAPSHOT inside the *published* delete
/// frame (F4). It is consumed by `frameForDelivery` for per-subscriber authz and STRIPPED before
/// the id-only frame is delivered to the client — a subscriber never sees it.
pub const delete_snapshot_key = "_deleteSnapshot";

/// Build the two channels + two serialized frames for a record event. create/update carry `record`
/// (full, hidden fields already stripped by the caller's records.get). delete carries `{id}` plus,
/// when a snapshot of the deleted row is available, a private `_deleteSnapshot` object used only for
/// per-subscriber authorization (stripped before delivery).
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
        // Attach the deletion snapshot (if any) so subscribers can re-authorize owner-scoped
        // deletes. Stripped in frameForDelivery before the frame reaches the client.
        if (record) |snap| try o.put(alloc, delete_snapshot_key, snap);
        break :blk .{ .object = o };
    } else record.?;

    return .{
        .collection_channel = coll_channel,
        .record_channel = rec_channel,
        .frame_collection = try protocol.serializeEvent(alloc, coll_channel, action, body),
        .frame_record = try protocol.serializeEvent(alloc, rec_channel, action, body),
    };
}

/// Transport-neutral per-subscriber delivery (the body of the old ws.onChannelMessage —
/// F4 delete-snapshot authz, #143 custom-topic verbatim forward, #156 tenancy, all via
/// `shouldDeliver`). Returns the frame to deliver or null; both transports reduce to
/// `if (frameForDelivery(...)) |f| <transport write>(f)`. The caller has already checked
/// `conn.hasSub(channel)` and passes the subscription's filter — this function never reads
/// `conn.subs`, so SSE may pass an identity-only snapshot Conn (see sse.snapshotForDelivery).
pub fn frameForDelivery(
    a: std.mem.Allocator,
    app: *App,
    conn: *const Conn,
    sub_filter: ?[]const u8,
    channel: []const u8,
    message: []const u8,
) ?[]const u8 {
    // The public feature-signal channel carries a fixed, non-record frame: forward verbatim
    // (no per-record viewRule authorization, no collection lookup).
    if (std.mem.eql(u8, channel, FEATURES_CHANNEL)) return message;

    const t = protocol.parseTopic(channel);
    var r = app.pool.acquireReader() catch return null;
    defer app.pool.releaseReader(&r);

    // Resolve the topic to a collection FIRST. A non-collection topic is a consumer CUSTOM
    // channel (#143): forward its frame VERBATIM with NO per-record viewRule — subscription
    // was already authorized at subscribe time via `canSubscribe`.
    // R1-4: cached metadata — this runs once per SUBSCRIBER per event; the cache removes
    // the per-delivery `_collections` SELECT + schema-JSON parse (and caches the NEGATIVE
    // result for custom non-collection topics). Falls back to a direct load when no cache
    // is installed (tests / Postgres backend).
    var col_lease = colcache.lease(app.col_cache, &r, a, t.collection) catch return null;
    defer col_lease.release();
    const col = col_lease.col orelse return message;

    const parsed = std.json.parseFromSlice(std.json.Value, a, message, .{}) catch return null;
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;
    const av = obj.get("action") orelse return null;
    if (av != .string) return null;
    const action: protocol.Action = if (std.mem.eql(u8, av.string, "create")) .create
        else if (std.mem.eql(u8, av.string, "update")) .update
        else if (std.mem.eql(u8, av.string, "delete")) .delete
        else return null;
    const rv = obj.get("record") orelse return null;
    if (rv != .object) return null;
    const idv = rv.object.get("id") orelse return null;
    if (idv != .string) return null;
    const record_id = idv.string;

    // F4: the deleted-record authorization snapshot rides the published frame under a private
    // key. Pull it out for per-subscriber authz, then strip it so the client frame is id-only.
    const delete_snapshot: ?std.json.Value = if (action == .delete) rv.object.get(delete_snapshot_key) else null;

    const now = auth.nowUnixPub(&r) catch return null;
    const deliver = shouldDeliver(a, app.io, &r, col, conn, now, action, record_id, sub_filter, delete_snapshot) catch return null;
    if (!deliver) return null;

    if (action == .delete and delete_snapshot != null) {
        // Re-serialize an id-only delete frame so the private snapshot never reaches the client.
        var clean: std.json.ObjectMap = .empty;
        clean.put(a, "id", idv) catch return null;
        return protocol.serializeEvent(a, channel, .delete, .{ .object = clean }) catch null;
    }
    return message;
}

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
    fn mkColl(self: *TestDb, a: std.mem.Allocator, name: []const u8, view_rule: ?[]const u8) !schema.Collection {
        return collections.create(a, std.testing.io, &self.d, .{
            .id = "",
            .name = name,
            .fields = &[_]schema.Field{.{ .id = "f1", .name = "owner", .options = .{ .text = .{} } }},
            .listRule = "",
            .viewRule = view_rule,
            .createRule = "",
            .updateRule = "",
            .deleteRule = "",
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

test "public viewRule (@public): create delivered to anyone, no filter" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try tdb.mkColl(a, "posts", rules.public_sentinel);
    const rid = try tdb.mkRec(a, col, "u1");
    var anon = Conn{};
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &anon, 0, .create, rid, null, null));
}

test "empty viewRule (\"\") is now LOCKED: anon receives nothing, superuser does" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try tdb.mkColl(a, "posts", "");
    const rid = try tdb.mkRec(a, col, "u1");
    var anon = Conn{};
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &anon, 0, .create, rid, null, null));
    var su = try authedConn(a, "admin", true);
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &su, 0, .create, rid, null, null));
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
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &anon, 0, .create, rid, null, null));
    var su = try authedConn(a, "admin", true);
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &su, 0, .create, rid, null, null));
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
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &owner, 0, .update, rid, null, null));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &other, 0, .update, rid, null, null));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &anon, 0, .update, rid, null, null));
}

test "subscription filter narrows within an authorized viewRule" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try tdb.mkColl(a, "items", rules.public_sentinel);
    const rid = try tdb.mkRec(a, col, "alice");
    var anon = Conn{};
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &anon, 0, .create, rid, "owner = \"alice\"", null));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &anon, 0, .create, rid, "owner = \"bob\"", null));
}

test "delete is id-only: locked -> only superuser; @public -> anyone" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pub_col = try tdb.mkColl(a, "p", rules.public_sentinel);
    const locked = try tdb.mkColl(a, "l", null);
    var anon = Conn{};
    // @public: anyone learns of the delete (no snapshot needed).
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, pub_col, &anon, 0, .delete, "GONE", null, null));
    // null/locked: only a superuser.
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, locked, &anon, 0, .delete, "GONE", null, null));
    var su = try authedConn(a, "admin", true);
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, locked, &su, 0, .delete, "GONE", null, null));
}

test "F4: owner-scoped delete only notifies the owner (snapshot authz)" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try tdb.mkColl(a, "notes", "owner = @request.auth.id");
    // The deleted row's snapshot: owned by u1. The live row is gone (delete already committed),
    // so authorization must come from this snapshot.
    var snap: std.json.ObjectMap = .empty;
    try snap.put(a, "id", .{ .string = "GONE" });
    try snap.put(a, "owner", .{ .string = "u1" });
    const snapshot: std.json.Value = .{ .object = snap };

    var owner = try authedConn(a, "u1", false);
    var other = try authedConn(a, "u2", false);
    var anon = Conn{};
    // Owner: receives the delete. Non-owner and anonymous: do NOT (no id leak).
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &owner, 0, .delete, "GONE", null, snapshot));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &other, 0, .delete, "GONE", null, snapshot));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &anon, 0, .delete, "GONE", null, snapshot));
    // No snapshot at all -> conservative deny, even for the would-be owner.
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &owner, 0, .delete, "GONE", null, null));
}

test "tenant scoping: a subscriber receives ONLY its account's frames; unresolved account gets nothing" {
    // CRITICAL regression guard (#156): the realtime delivery path must apply the tenant predicate.
    // Before the fix `Conn.requestContext` never set tenancy_enabled/account_id, so a tenant-owned
    // `@public` collection broadcast to every subscriber — a cross-tenant leak. This test FAILS
    // under that code and passes after the fix.
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A tenant-owned collection with a NATURAL @public viewRule (the whole point of auto-scoping).
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "account", .options = .{ .text = .{} } },
    };
    var col = try collections.create(a, std.testing.io, &tdb.d, .{
        .id = "",
        .name = "projects",
        .fields = &fields,
        .viewRule = rules.public_sentinel,
    });
    col.options.tenant_field = "account";
    try tdb.d.exec("INSERT INTO projects (id,created,updated,title,account) VALUES " ++
        "('rA','t','t','a','accA'),('rB','t','t','b','accB');");

    // A subscriber whose connection is scoped to accA (tenancy_enabled + resolved account).
    var rec: std.json.ObjectMap = .empty;
    try rec.put(a, "id", .{ .string = "uA" });
    var connA = Conn{ .tenancy_enabled = true, .account_id = "accA" };
    connA.setAuth(.{ .record = .{ .object = rec }, .is_superuser = false, .exp = 9999999999 });

    // create/update of accA's row -> delivered; accB's row -> NOT delivered (cross-tenant denied).
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &connA, 0, .create, "rA", null, null));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &connA, 0, .create, "rB", null, null));
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &connA, 0, .update, "rA", null, null));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &connA, 0, .update, "rB", null, null));

    // delete uses the pre-delete snapshot: accA's snapshot delivered, accB's not.
    var snapA: std.json.ObjectMap = .empty;
    try snapA.put(a, "id", .{ .string = "rA" });
    try snapA.put(a, "account", .{ .string = "accA" });
    var snapB: std.json.ObjectMap = .empty;
    try snapB.put(a, "id", .{ .string = "rB" });
    try snapB.put(a, "account", .{ .string = "accB" });
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &connA, 0, .delete, "rA", null, .{ .object = snapA }));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &connA, 0, .delete, "rB", null, .{ .object = snapB }));

    // A subscriber with tenancy enabled but NO resolved account receives NOTHING on a tenant-owned
    // collection (fail closed) — even though the viewRule is @public.
    var connNone = Conn{ .tenancy_enabled = true, .account_id = "" };
    connNone.setAuth(.{ .record = .{ .object = rec }, .is_superuser = false, .exp = 9999999999 });
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &connNone, 0, .create, "rA", null, null));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &connNone, 0, .create, "rB", null, null));

    // A superuser bypasses tenancy (receives both); tenancy OFF on the conn = byte-identical legacy
    // (@public delivers all), proving the gate is the per-connection tenancy flag.
    var su = try authedConn(a, "admin", true);
    su.tenancy_enabled = true;
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &su, 0, .create, "rB", null, null));
    var legacy = Conn{ .tenancy_enabled = false };
    legacy.setAuth(.{ .record = .{ .object = rec }, .is_superuser = false, .exp = 9999999999 });
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &legacy, 0, .create, "rB", null, null));
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
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &c, 50, .update, rid, null, null));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &c, 200, .update, rid, null, null));
}

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

test "F4: delete frame carries the private authz snapshot (stripped before client delivery)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var snap: std.json.ObjectMap = .empty;
    try snap.put(a, "id", .{ .string = "REC1" });
    try snap.put(a, "owner", .{ .string = "u1" });
    const ef = try buildEventFrames(a, "notes", .delete, "REC1", .{ .object = snap });
    // The PUBLISHED frame includes the snapshot under the private key so subscribers can authorize.
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_collection, delete_snapshot_key) != null);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_collection, "\"owner\":\"u1\"") != null);
    // (onChannelMessage strips delete_snapshot_key and re-serializes an id-only frame before
    // WS.write, so the client never sees the snapshot — covered by the hub authz tests above.)
}

test "R1-3: delete sandbox schema is minimal — 2 DDLs, not the migration suite" {
    var tmp = try db.Db.openMemory();
    defer tmp.close();
    try tmp.exec(migrations.collections_table_sql);
    try tmp.exec(migrations.collections_options_column_sql);
    var st = try tmp.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type='table';");
    defer st.finalize();
    try std.testing.expect(try st.step());
    // Exactly the _collections registry. This pins the per-subscriber-per-delete cost:
    // the full suite (migrations.run) creates dozens of tables; the sandbox needs one.
    try std.testing.expectEqual(@as(i64, 1), st.columnInt(0));
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

const PoolEnv = struct {
    tmp: std.testing.TmpDir,
    db_path: [:0]u8,
    pool: db.Pool,

    fn init() !PoolEnv {
        const ga = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", ga);
        defer ga.free(dir_path);
        const db_path = try std.fmt.allocPrintSentinel(ga, "{s}/test.db", .{dir_path}, 0);
        errdefer ga.free(db_path);
        var pool = try db.Pool.init(ga, std.testing.io, db_path);
        errdefer pool.deinit();
        {
            const w = pool.acquireWriter();
            defer pool.releaseWriter();
            try migrations.run(w);
        }
        return .{ .tmp = tmp, .db_path = db_path, .pool = pool };
    }
    fn deinit(self: *PoolEnv) void {
        self.pool.deinit();
        std.testing.allocator.free(self.db_path);
        self.tmp.cleanup();
    }
};

test "subscribeCheck decision table: limit / __features / unknown / auth_required / ok (transport-neutral)" {
    var env = try PoolEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App{ .allocator = a, .io = std.testing.io, .pool = &env.pool };

    // Provision a @public and a locked collection on the pool's writer.
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        _ = try collections.create(a, std.testing.io, w, .{
            .id = "",
            .name = "pub_posts",
            .fields = &.{},
            .viewRule = rules.public_sentinel,
        });
        _ = try collections.create(a, std.testing.io, w, .{
            .id = "",
            .name = "locked_posts",
            .fields = &.{},
            .viewRule = null,
        });
    }

    var anon = Conn{};
    // __features: always ok, even anonymous, even at any sub count below the cap.
    try std.testing.expectEqual(SubscribeOutcome.ok, subscribeCheck(&app, &anon, a, FEATURES_CHANNEL));
    // @public collection: anonymous ok.
    try std.testing.expectEqual(SubscribeOutcome.ok, subscribeCheck(&app, &anon, a, "pub_posts"));
    // locked collection: anonymous rejected.
    try std.testing.expectEqual(SubscribeOutcome.auth_required, subscribeCheck(&app, &anon, a, "locked_posts"));
    // non-collection custom topic: default-allowed (public signal channel, #143).
    try std.testing.expectEqual(SubscribeOutcome.ok, subscribeCheck(&app, &anon, a, "availability"));
    // MAX_SUBS: a conn at the cap is rejected BEFORE any lookup.
    var full = Conn{};
    var i: usize = 0;
    while (i < connection.MAX_SUBS) : (i += 1) {
        const topic = try std.fmt.allocPrint(a, "t{d}", .{i});
        try full.addSub(a, topic, null);
    }
    try std.testing.expectEqual(SubscribeOutcome.limit, subscribeCheck(&app, &full, a, "one_more"));
}

test "authVerb: bad token clears auth and returns false (transport-neutral)" {
    var env = try PoolEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App{ .allocator = a, .io = std.testing.io, .pool = &env.pool };
    var c = Conn{};
    // Pre-install an identity to prove a failed auth CLEARS it (the ws contract).
    var rec: std.json.ObjectMap = .empty;
    try rec.put(a, "id", .{ .string = "u1" });
    c.setAuth(.{ .record = .{ .object = rec }, .is_superuser = false, .exp = 9999999999 });
    try std.testing.expect(!authVerb(&app, &c, a, "not-a-jwt", ""));
    try std.testing.expect(c.auth == null);
}

test "frameForDelivery: custom topic + __features forward VERBATIM (no authz, no parse requirement)" {
    var env = try PoolEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App{ .allocator = a, .io = std.testing.io, .pool = &env.pool };
    var anon = Conn{};
    // A non-collection topic: the exact message bytes come back (pointer-equal slice).
    const msg = "{\"type\":\"message\",\"topic\":\"orders\",\"data\":1}";
    const out = frameForDelivery(a, &app, &anon, null, "orders", msg).?;
    try std.testing.expectEqualStrings(msg, out);
    // __features: verbatim too.
    const sig = "{\"type\":\"signal\",\"topic\":\"__features\"}";
    try std.testing.expectEqualStrings(sig, frameForDelivery(a, &app, &anon, null, FEATURES_CHANNEL, sig).?);
}

test "frameForDelivery: viewRule deny -> null; @public + matching filter -> frame; mismatching filter -> null" {
    var env = try PoolEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App{ .allocator = a, .io = std.testing.io, .pool = &env.pool };
    var rid: []const u8 = undefined;
    var rec_val: std.json.Value = undefined;
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const pub_col = try collections.create(a, std.testing.io, w, .{
            .id = "", .name = "fitems", .fields = &[_]schema.Field{.{ .id = "f1", .name = "owner", .options = .{ .text = .{} } }},
            .viewRule = rules.public_sentinel,
        });
        var data: std.json.ObjectMap = .empty;
        try data.put(a, "owner", .{ .string = "alice" });
        rec_val = try records.create(a, std.testing.io, w, pub_col, .{ .object = data });
        rid = rec_val.object.get("id").?.string;
        _ = try collections.create(a, std.testing.io, w, .{
            .id = "", .name = "flocked", .fields = &.{}, .viewRule = null,
        });
    }
    const ef = try buildEventFrames(a, "fitems", .create, rid, rec_val);
    var anon = Conn{};
    // @public, no filter: delivered verbatim.
    try std.testing.expectEqualStrings(ef.frame_collection, frameForDelivery(a, &app, &anon, null, "fitems", ef.frame_collection).?);
    // Filter narrows: match delivers, mismatch denies.
    try std.testing.expect(frameForDelivery(a, &app, &anon, "owner = \"alice\"", "fitems", ef.frame_collection) != null);
    try std.testing.expect(frameForDelivery(a, &app, &anon, "owner = \"bob\"", "fitems", ef.frame_collection) == null);
    // Locked collection: anonymous denied outright (frame for a locked col).
    const lf = try buildEventFrames(a, "flocked", .create, "R1", rec_val);
    try std.testing.expect(frameForDelivery(a, &app, &anon, null, "flocked", lf.frame_collection) == null);
}

test "frameForDelivery: F4 delete snapshot authorizes, then is STRIPPED to an id-only frame" {
    var env = try PoolEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App{ .allocator = a, .io = std.testing.io, .pool = &env.pool };
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        _ = try collections.create(a, std.testing.io, w, .{
            .id = "", .name = "fnotes", .fields = &[_]schema.Field{.{ .id = "f1", .name = "owner", .options = .{ .text = .{} } }},
            .viewRule = "owner = @request.auth.id",
        });
    }
    var snap: std.json.ObjectMap = .empty;
    try snap.put(a, "id", .{ .string = "GONE" });
    try snap.put(a, "owner", .{ .string = "u1" });
    const ef = try buildEventFrames(a, "fnotes", .delete, "GONE", .{ .object = snap });
    // The published frame carries the private snapshot (precondition).
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_collection, delete_snapshot_key) != null);

    var owner = try authedConn(a, "u1", false);
    var other = try authedConn(a, "u2", false);
    // Owner: delivered — and the delivered frame is ID-ONLY (snapshot + owner field stripped).
    const out = frameForDelivery(a, &app, &owner, null, "fnotes", ef.frame_collection).?;
    try std.testing.expect(std.mem.indexOf(u8, out, delete_snapshot_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"owner\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"GONE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"action\":\"delete\"") != null);
    // Non-owner: nothing (no id leak).
    try std.testing.expect(frameForDelivery(a, &app, &other, null, "fnotes", ef.frame_collection) == null);
}
