const std = @import("std");
const RequestArena = @import("../request_arena.zig").RequestArena;
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
pub fn canSubscribeTopic(app: *App, arena: RequestArena, rctx: request.RequestContext, topic: []const u8) bool {
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
/// transport. `requested_account` is the handshake-captured account request (header/signed-cookie),
/// verified here against _memberships — an unverified value never grants scope. A pool-acquire
/// failure is an auth failure (false), matching the old inline behavior (authFrame(false)).
///
/// `identity_arena` is a DEDICATED per-connection arena that holds ONLY the active identity (the
/// cloned auth record + resolved account_id/memberships). It is RESET on every auth frame so the
/// prior identity's bytes are reclaimed — a valid-token re-auth loop (a client spamming
/// {"action":"auth"} with a live JWT) can therefore no longer grow per-connection memory without
/// bound (#11 residual). It MUST be separate from the connection-durable arena (which also holds
/// subscription keys/filters/sub_ids/requested_account that must survive a re-auth), and callers
/// MUST NOT alias identity bytes into a long-lived delivery snapshot: WS callbacks are
/// fio-serialized (a delivery never overlaps a re-auth), and the SSE delivery path snapshots a
/// DEEP COPY of the identity (`sse.snapshotForDelivery`) so no in-flight lock-free delivery reads
/// the bytes this reset releases.
pub fn authVerb(app: *App, conn: *Conn, identity_arena: *std.heap.ArenaAllocator, token: []const u8, requested_account: []const u8) bool {
    var r = app.pool.acquireReader() catch return false;
    defer app.pool.releaseReader(&r);
    // #11: verify on a THROWAWAY scratch arena, never the identity one. `verifyToken` allocates the
    // parsed JWT claims, the collection lookup, and the full record JSON into the allocator it is
    // handed — and `jwt.peekClaims` base64-decodes + JSON-parses the payload BEFORE any validation,
    // so even a GARBAGE token allocates. Only a SUCCESSFUL identity is persisted below (deep-cloned
    // into the freshly-reset identity arena); the scratch (incl. every failed-token allocation) is
    // reclaimed on return.
    var scratch = std.heap.ArenaAllocator.init(app.allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();
    if (auth.verifyToken(sa, app, &r, token)) |v| {
        // #11 residual: reclaim the PRIOR identity's bytes before cloning the new one, so a re-auth
        // loop can't grow this arena. Safe: the active identity is fully replaced below, and (see
        // the doc comment) no in-flight delivery aliases the released bytes.
        _ = identity_arena.reset(.retain_capacity);
        const ia = identity_arena.allocator();
        // Deep-clone the verified record onto the identity arena (the scratch arena that backs `v`
        // is about to be freed). Re-materialize via stringify→parse — a self-contained deep copy.
        const record = cloneJson(ia, v.record) catch {
            conn.clearAuth();
            return false;
        };
        conn.setAuth(.{ .record = record, .is_superuser = v.is_superuser, .exp = v.exp });
        // Reset the account scope to static empties on EVERY re-auth: the `identity_arena.reset`
        // above reclaimed the bytes backing the prior `account_id`/`memberships`, and the tenancy
        // branch below refreshes them onto the fresh arena ONLY for a non-superuser tenant. Without
        // this, a superuser (or tenancy-off, or unresolved) re-auth on the same socket would leave
        // both fields dangling into the reset arena — and `sse.snapshotForDelivery` reads
        // `memberships` unconditionally, so cloning that stale slice is a wild-pointer copy.
        conn.setTenancyScope("", &.{});
        // #156: resolve + cache the active account scope against _memberships. Superusers bypass
        // tenancy. A failed/absent resolution leaves account_id="" → tenant-owned delivery fails
        // closed (deny). The resolution runs on scratch, then its identity-scoped state is duped.
        if (conn.tenancy_enabled and !v.is_superuser) {
            const uid = recordIdOf(record);
            if (uid.len > 0) {
                const res = tenancy.resolve(sa, &r, v.collection, uid, requested_account) catch tenancy.Resolution{};
                const acc = ia.dupe(u8, res.account_id) catch "";
                const ms = cloneMemberships(ia, res.memberships) catch &.{};
                conn.setTenancyScope(acc, ms);
            }
        }
        return true;
    }
    // A FAILED auth drops the identity AND reclaims its bytes (clear the refs first, then reset).
    conn.clearAuth();
    _ = identity_arena.reset(.retain_capacity);
    return false;
}

/// Deep-copy a JSON value onto `alloc` (independent of the source arena) via stringify→parse — the
/// canonical self-contained clone; the result owns all its bytes. Public so the SSE delivery
/// snapshot can deep-copy the identity off the resettable identity arena (see `authVerb`).
pub fn cloneJson(alloc: std.mem.Allocator, v: std.json.Value) !std.json.Value {
    const json = try std.json.Stringify.valueAlloc(alloc, v, .{});
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
}

/// Deep-copy the resolved membership slice (account/role strings) onto `alloc`. Public for the same
/// reason as `cloneJson` — the SSE delivery snapshot reuses it.
pub fn cloneMemberships(alloc: std.mem.Allocator, src: []const request.Membership) ![]const request.Membership {
    if (src.len == 0) return &.{};
    const out = try alloc.alloc(request.Membership, src.len);
    for (src, out) |m, *o| o.* = .{ .account = try alloc.dupe(u8, m.account), .role = try alloc.dupe(u8, m.role) };
    return out;
}

/// The `subscribe` authorization body (moved from ws.onMessage, F5/#143): MAX_SUBS cap, the
/// public __features carve-out, collection lookup, and the subscribeDecision precedence (a REAL
/// collection topic ALWAYS uses per-collection authz; the canSubscribe predicate gates ONLY
/// non-collection custom topics). Pure decision — the caller performs the transport-side
/// subscription + reply. `alloc` is per-call scratch (the collection lookup borrows it).
pub fn subscribeCheck(app: *App, conn: *const Conn, alloc: RequestArena, topic: []const u8) SubscribeOutcome {
    // #3: a re-subscribe to an already-held topic is a REPLACE (the transports take the
    // `Conn.updateFilter` path) — it reuses the existing subscription slot and never grows
    // `subs.count()`, so it must not trip the cap. Only a genuinely NEW topic counts against
    // MAX_SUBS. Without the `hasSub` guard the cap was double-broken: duplicate subscribes both
    // bypassed it (count never grew) AND could be spuriously rejected once at the cap.
    if (!conn.hasSub(topic) and conn.subs.count() >= connection.MAX_SUBS) return .limit;
    const t = protocol.parseTopic(topic);
    // The feature-management signal channel is PUBLIC and is not a collection.
    if (std.mem.eql(u8, t.collection, FEATURES_CHANNEL)) return .ok;
    var r = app.pool.acquireReader() catch return .unknown;
    const now = auth.nowUnixPub(&r) catch 0;
    const rctx = conn.requestContext(now);
    const lookup = collections.get(alloc.a, &r, t.collection) catch {
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
    // Whether a per-ROW predicate — a tenant scope OR a relationship ability — applies to THIS
    // subscriber on THIS collection. When it does, delivery must run the guarded query even if the
    // viewRule alone would `allow` (e.g. `@public`), so the record is narrowed to what this
    // subscriber may actually see — otherwise a tenant-owned OR ability-guarded collection leaks
    // across accounts over WebSocket/SSE. Deriving this from `policy.rowConstrained` (the same
    // condition `policy.decide` uses) keeps realtime delivery from diverging from the REST
    // chokepoints: tenancy AND abilities are both honored, and neither can be forgotten here
    // again. The rule-clause decision below still uses the RAW rule (`rules.decide`), so an
    // `@public` rule never compiles as a guard expression — the tenant/ability predicates are
    // composed inside `policy.matchesRule`.
    const row_constrained = policy.rowConstrained(col, .view, &rctx);

    if (action == .delete) {
        switch (rules.decide(col.viewRule, &rctx)) {
            .deny_locked => return false, // locked: superuser already short-circuited to .allow
            .allow => {
                // @public or superuser: anyone may learn of the delete — UNLESS the collection is
                // tenant-scoped for this subscriber, in which case authorize the deleted row's
                // snapshot against the tenant predicate (no rule clause). No snapshot -> deny.
                if (!row_constrained) return true;
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
    if (clauses.items.len == 0 and !row_constrained) return true;

    const combined = if (clauses.items.len > 0) try combineClauses(alloc, clauses.items) else "";
    return policy.matchesRule(alloc, reader, col, record_id, combined, &rctx);
}

/// A built delete-authz sandbox: a `:memory:` DB carrying the minimal `_collections` registry, a
/// recreation of the deleted row's collection, and the single snapshot row. It depends ONLY on
/// (collection, snapshot) — NOT on any subscriber — so it is reusable across every subscriber of one
/// delete event. `key` is the exact `<collection>\x00<canonical snapshot JSON>` bytes it was built
/// for; a reuse is gated on an EXACT `mem.eql` match (never a hash) so a cached sandbox can only
/// ever authorize the SAME (collection, snapshot) it was built from — no collision could authorize a
/// delete against the wrong row. Everything (key, schema, row) lives on `arena`; `db` is the live
/// SQLite handle. `deinit` closes both.
const SnapshotSandbox = struct {
    arena: std.heap.ArenaAllocator,
    db: db.Db,
    live_col: schema.Collection,
    key: []const u8,
    fn deinit(self: *SnapshotSandbox) void {
        self.db.close();
        self.arena.deinit();
    }
};

/// #18 hoist: a THREAD-LOCAL single-slot reuse of the delete sandbox across ONE delete event's
/// per-subscriber fan-out. The sandbox depends only on (collection, snapshot), which is IDENTICAL
/// for every subscriber of a given delete event — but facil.io owns the fan-out loop and invokes
/// the per-subscriber delivery callback (`frameForDelivery`) once per subscriber, with no shared
/// per-event scope we own. This slot lets all of an event's deliveries that land on the same
/// reactor thread reuse a SINGLE build: T sandbox builds for T reactor threads instead of one per
/// subscriber (once-per-event when the fan-out is single-threaded). It is lock-free by construction
/// — each thread owns its slot and its SQLite handle, which is only ever touched by that thread and
/// only for read-only SELECTs (`policy.matchesRule`), sequentially — and memory-bounded to one
/// sandbox per reactor thread (a key miss `deinit`s the prior build before replacing it). A
/// backing `std.heap.page_allocator` keeps the slot off any request/test arena so a lingering
/// last-event sandbox is reclaimed by the OS at process exit, never flagged as a leak. A FULLY
/// cross-thread single build would require owning the fan-out loop (facil.io owns it) — out of
/// scope for a realtime-only change.
threadlocal var snapshot_sandbox: ?SnapshotSandbox = null;

/// Evaluate `rule` against a single deleted-record `snapshot` (F4), reusing a thread-local sandbox
/// across a delete event's subscribers (#18). The sandbox is a throwaway in-memory DB (a MINIMAL
/// schema: just the _collections registry — R1-3) with `col`'s table recreated and ONLY the snapshot
/// row inserted (id + its stored columns preserved verbatim); the standard guarded SELECT then runs
/// per subscriber. Reuses the exact rule machinery without touching the (now row-less) live DB.
/// Relation-traversing rules resolve against empty target tables in the temp DB and therefore won't
/// match — a conservative (deny) failure for delete events, which is the safe direction.
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
    if (snapshot.object.get("id")) |rid| {
        if (rid != .string) return false;
    } else return false;
    const sandbox = try snapshotSandbox(io, col, snapshot);
    // ONLY the guarded SELECT is per-subscriber; the sandbox build above is shared across the
    // event's fan-out on this reactor thread (#18). `rctx` is this subscriber's identity, so the
    // decision stays per-subscriber even though the single-row input is shared.
    return policy.matchesRule(alloc, &sandbox.db, sandbox.live_col, record_id, rule, rctx) catch false;
}

/// Build — or reuse from the thread-local slot — the delete sandbox for (col, snapshot). The
/// caller has already validated `snapshot` is an object with a string `id`.
fn snapshotSandbox(io: std.Io, col: schema.Collection, snapshot: std.json.Value) !*SnapshotSandbox {
    // Compute the exact cache key on a throwaway arena first: "<id>\x00<name>\x00<canonical JSON>".
    // The stable collection id keys the SCHEMA (so two collections that share a name + snapshot can
    // never reuse each other's sandbox — the schema build depends on the id's fields), the name
    // keys the INSERT target, and the canonical snapshot JSON keys the row. Canonical JSON of the
    // deleted row is far cheaper than the schema build it guards, so forming the key per delivery
    // still leaves the reuse a net win.
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const snap_json = try std.json.Stringify.valueAlloc(sa, snapshot, .{});
    const key = try std.fmt.allocPrint(sa, "{s}\x00{s}\x00{s}", .{ col.id, col.name, snap_json });

    if (snapshot_sandbox) |*cached| {
        if (std.mem.eql(u8, cached.key, key)) return cached; // hit: same (collection, snapshot)
        cached.deinit(); // miss: evict the prior event's build before replacing it
        snapshot_sandbox = null;
    }

    // Build a fresh sandbox that OWNS its key + schema + row on its own arena (page-allocator
    // backed, so it outlives the per-delivery arena and never touches a tracked test allocator).
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const owned_key = try aa.dupe(u8, key);

    var tmp = try db.Db.openMemory();
    errdefer tmp.close();
    // R1-3: the sandbox needs ONLY the `_collections` registry (+ its `options` column) —
    // collections.create below reads and writes it — plus the one collection table that
    // create() builds. Semantics are unchanged: tenancy/ability predicates compile to columns
    // on the target table + bound params, and relation-traversing rules resolve against an EMPTY
    // `_collections` (conservative deny) because user collections were never present in the sandbox.
    try tmp.exec(migrations.collections_table_sql);
    try tmp.exec(migrations.collections_options_column_sql);
    // Recreate the collection table (fresh id; we never persist relation FKs, so an isolated
    // schema is enough to evaluate column/macro comparisons).
    var spec = col;
    spec.id = "";
    spec.indexes = &.{}; // unique indexes are irrelevant for a single-row authz probe
    const live_col = try collections.create(aa, io, &tmp, spec);

    // Direct INSERT preserving the snapshot's real id + stored scalar columns, binding each value
    // by its JSON type. (We bypass records.create on purpose: it regenerates the id and re-runs
    // validation, neither of which we want for an authz snapshot of an already-validated row.)
    var cols_sql: std.ArrayList(u8) = .empty;
    var ph_sql: std.ArrayList(u8) = .empty;
    const Bind = struct { v: std.json.Value };
    var binds: std.ArrayList(Bind) = .empty;
    try cols_sql.appendSlice(aa, "\"id\",\"created\",\"updated\"");
    try ph_sql.appendSlice(aa, "?1,'',''");
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
        try cols_sql.append(aa, ',');
        try cols_sql.appendSlice(aa, try std.fmt.allocPrint(aa, "\"{s}\"", .{name}));
        try ph_sql.append(aa, ',');
        try ph_sql.appendSlice(aa, try std.fmt.allocPrint(aa, "?{d}", .{n}));
        try binds.append(aa, .{ .v = e.value_ptr.* });
        n += 1;
    }
    const sql = try std.fmt.allocPrintSentinel(aa, "INSERT INTO \"{s}\" ({s}) VALUES ({s});", .{ col.name, cols_sql.items, ph_sql.items }, 0);
    var st = try tmp.prepare(sql);
    defer st.finalize();
    try st.bindText(1, snapshot.object.get("id").?.string);
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

    // Publish into the thread-local slot and return a pointer to it. No errdefer fires past this
    // point, so the moved-in `arena`/`tmp` are owned solely by the slot (no double-free).
    snapshot_sandbox = .{ .arena = arena, .db = tmp, .live_col = live_col, .key = owned_key };
    return &snapshot_sandbox.?;
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

    // #17: parse ONLY the three envelope fields the delivery decision needs — `action`,
    // `record.id`, and (delete only) the private `_deleteSnapshot` — with a TYPED parse +
    // `ignore_unknown_fields`, so the (arbitrarily large) record body is tokenized past but NEVER
    // materialized into a per-subscriber `ObjectMap` tree. This function runs once per SUBSCRIBER
    // per event; the old `parseFromSlice(Value)` built + discarded the whole record on every one of
    // them (10 KiB record × 1000 subscribers = ~10 MiB of throwaway allocation per event). For
    // create/update the record body is returned to the client VERBATIM below — never inspected.
    const env = std.json.parseFromSliceLeaky(DeliveryEnvelope, a, message, .{ .ignore_unknown_fields = true }) catch return null;
    const action: protocol.Action = if (std.mem.eql(u8, env.action, "create"))
        .create
    else if (std.mem.eql(u8, env.action, "update"))
        .update
    else if (std.mem.eql(u8, env.action, "delete"))
        .delete
    else
        return null;
    const record_id = env.record.id;
    if (record_id.len == 0) return null;

    // F4: the deleted-record authorization snapshot rides the published frame under a private key.
    // It is materialized (deletes only) for per-subscriber authz, then stripped so the client frame
    // is id-only.
    const delete_snapshot: ?std.json.Value = if (action == .delete) env.record._deleteSnapshot else null;

    const now = auth.nowUnixPub(&r) catch return null;
    const deliver = shouldDeliver(a, app.io, &r, col, conn, now, action, record_id, sub_filter, delete_snapshot) catch return null;
    if (!deliver) return null;

    if (action == .delete and delete_snapshot != null) {
        // Re-serialize an id-only delete frame so the private snapshot never reaches the client.
        var clean: std.json.ObjectMap = .empty;
        clean.put(a, "id", .{ .string = record_id }) catch return null;
        return protocol.serializeEvent(a, channel, .delete, .{ .object = clean }) catch null;
    }
    return message;
}

/// The minimal shape `frameForDelivery` extracts from a published record frame (#17). Every other
/// envelope + record field is skipped by `ignore_unknown_fields` — no full-tree materialization.
const DeliveryEnvelope = struct {
    action: []const u8 = "",
    record: struct {
        id: []const u8 = "",
        /// The private per-subscriber delete-authz snapshot (delete frames only; stripped before
        /// the client sees the id-only frame). Materialized only when actually present.
        _deleteSnapshot: ?std.json.Value = null,
    } = .{},
};

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

test "@public viewRule + view ability: create is NOT delivered to a non-member" {
    // Regression for the HIGH realtime-abilities bypass: a collection can be `@public` for the
    // access RULE yet have visibility narrowed by a relationship ability (#155). Realtime
    // delivery must honor the ability exactly like records.list — before the fix, the `@public`
    // early-return in shouldDeliver delivered the full record to any subscriber, bypassing it.
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var col = try tdb.mkColl(a, "posts", rules.public_sentinel);
    // A view ability: visibility depends on the subscriber's relationship via `owner`, not the rule.
    col.options.abilities = .{ .view = .{ .relationship = .{ .via = "owner" } } };
    const rid = try tdb.mkRec(a, col, "u1");
    // A non-superuser subscriber with NO qualifying membership must receive NOTHING: the ability's
    // empty qualifying set compiles to constant-false, so the guarded query matches no row.
    var outsider = try authedConn(a, "outsider", false);
    try std.testing.expect(!(try shouldDeliver(a, std.testing.io, &tdb.d, col, &outsider, 0, .create, rid, null, null)));
    // A superuser bypasses abilities (consistent with rules.decide) and still receives it.
    var su = try authedConn(a, "root", true);
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &su, 0, .create, rid, null, null));
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

test "#18 hoist: the thread-local delete sandbox is reused per-subscriber AND rebuilt per event, with no cross-subscriber/cross-event leak" {
    // The sandbox depends only on (collection, snapshot); it is cached thread-locally and reused
    // across a delete event's subscribers, then rebuilt when the (collection, snapshot) changes.
    // This drives the reuse path (same snapshot, many subscribers) and the rebuild path (a second
    // snapshot, then back to the first) and asserts the per-subscriber authz decision is ALWAYS
    // computed from that subscriber's own rctx — never leaked from a prior cache occupant.
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try tdb.mkColl(a, "notes", "owner = @request.auth.id");

    var snap1: std.json.ObjectMap = .empty;
    try snap1.put(a, "id", .{ .string = "R1" });
    try snap1.put(a, "owner", .{ .string = "u1" });
    const s1: std.json.Value = .{ .object = snap1 };
    var snap2: std.json.ObjectMap = .empty;
    try snap2.put(a, "id", .{ .string = "R2" });
    try snap2.put(a, "owner", .{ .string = "u2" });
    const s2: std.json.Value = .{ .object = snap2 };

    var owner1 = try authedConn(a, "u1", false); // owns R1
    var owner2 = try authedConn(a, "u2", false); // owns R2
    var anon = Conn{};

    // Event 1 (snapshot owned by u1): first call BUILDS the sandbox, the next two REUSE it. Each
    // subscriber's decision comes from its own identity — a reused sandbox must not carry u1's
    // "allow" over to u2/anon.
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &owner1, 0, .delete, "R1", null, s1));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &owner2, 0, .delete, "R1", null, s1));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &anon, 0, .delete, "R1", null, s1));

    // Event 2 (different snapshot owned by u2): the key changes -> REBUILD. Now u2 is the owner and
    // u1 is denied — proving the rebuild swapped in the new row and did not reuse event 1's row.
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &owner2, 0, .delete, "R2", null, s2));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &owner1, 0, .delete, "R2", null, s2));

    // Back to event 1's snapshot: another rebuild; u1 allowed, u2 denied again. Interleaving proves
    // the cache never stalely authorizes against the wrong event's row.
    try std.testing.expect(try shouldDeliver(a, std.testing.io, &tdb.d, col, &owner1, 0, .delete, "R1", null, s1));
    try std.testing.expect(!try shouldDeliver(a, std.testing.io, &tdb.d, col, &owner2, 0, .delete, "R1", null, s1));
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
    var app: App = undefined;
    const anon = request.RequestContext{};
    // No dispatch wired (tests/CLI): custom topics default to PUBLIC signal channels.
    app.dispatch = null;
    try std.testing.expect(canSubscribeTopic(&app, RequestArena.from(&arena), anon, "availability"));
    // Dispatch present but NO predicate -> still public by default.
    var d = @import("../events.zig").Dispatch{};
    app.dispatch = &d;
    try std.testing.expect(canSubscribeTopic(&app, RequestArena.from(&arena), anon, "orders"));
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
    try std.testing.expect(!canSubscribeTopic(&app, RequestArena.from(&arena), anon, "private"));
    // A guard gating on auth: anonymous denied, authenticated allowed.
    d.realtime_can_subscribe = Guard.onlyAuthed;
    try std.testing.expect(!canSubscribeTopic(&app, RequestArena.from(&arena), anon, "private"));
    var rec: std.json.ObjectMap = .empty;
    try rec.put(a, "id", .{ .string = "u1" });
    const authed = request.RequestContext{ .auth = .{ .object = rec }, .is_superuser = false };
    try std.testing.expect(canSubscribeTopic(&app, RequestArena.from(&arena), authed, "private"));
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
    try std.testing.expectEqual(SubscribeOutcome.ok, subscribeCheck(&app, &anon, RequestArena.from(&arena), FEATURES_CHANNEL));
    // @public collection: anonymous ok.
    try std.testing.expectEqual(SubscribeOutcome.ok, subscribeCheck(&app, &anon, RequestArena.from(&arena), "pub_posts"));
    // locked collection: anonymous rejected.
    try std.testing.expectEqual(SubscribeOutcome.auth_required, subscribeCheck(&app, &anon, RequestArena.from(&arena), "locked_posts"));
    // non-collection custom topic: default-allowed (public signal channel, #143).
    try std.testing.expectEqual(SubscribeOutcome.ok, subscribeCheck(&app, &anon, RequestArena.from(&arena), "availability"));
    // MAX_SUBS: a conn at the cap is rejected BEFORE any lookup.
    var full = Conn{};
    var i: usize = 0;
    while (i < connection.MAX_SUBS) : (i += 1) {
        const topic = try std.fmt.allocPrint(a, "t{d}", .{i});
        try full.addSub(a, topic, null);
    }
    try std.testing.expectEqual(SubscribeOutcome.limit, subscribeCheck(&app, &full, RequestArena.from(&arena), "one_more"));
}

test "cloneJson / cloneMemberships: deep copy is independent of the source arena (#11)" {
    // The #11 fix verifies the token on a THROWAWAY arena, then deep-clones the identity onto the
    // durable one. Prove the clone survives after the source arena is freed.
    const ga = std.testing.allocator;
    var durable = std.heap.ArenaAllocator.init(ga);
    defer durable.deinit();
    const da = durable.allocator();

    var record: std.json.Value = undefined;
    var mss: []const request.Membership = undefined;
    {
        var src = std.heap.ArenaAllocator.init(ga);
        defer src.deinit(); // free the SOURCE before we read the clones
        const sa = src.allocator();
        var obj: std.json.ObjectMap = .empty;
        try obj.put(sa, "id", .{ .string = "u1" });
        try obj.put(sa, "name", .{ .string = "Ada" });
        record = try cloneJson(da, .{ .object = obj });
        const src_ms = try sa.alloc(request.Membership, 1);
        src_ms[0] = .{ .account = try sa.dupe(u8, "accA"), .role = try sa.dupe(u8, "admin") };
        mss = try cloneMemberships(da, src_ms);
    }
    // Source arena is gone; the durable clones must still be intact.
    try std.testing.expectEqualStrings("u1", recordIdOf(record));
    try std.testing.expectEqualStrings("Ada", record.object.get("name").?.string);
    try std.testing.expectEqual(@as(usize, 1), mss.len);
    try std.testing.expectEqualStrings("accA", mss[0].account);
    try std.testing.expectEqualStrings("admin", mss[0].role);
    // Empty memberships clone to the empty slice (no allocation).
    try std.testing.expectEqual(@as(usize, 0), (try cloneMemberships(da, &.{})).len);
}

test "authVerb: bad token clears auth and returns false (transport-neutral)" {
    var env = try PoolEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App{ .allocator = a, .io = std.testing.io, .pool = &env.pool };
    var c = Conn{};
    var id_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer id_arena.deinit();
    // Pre-install an identity to prove a failed auth CLEARS it (the ws contract).
    var rec: std.json.ObjectMap = .empty;
    try rec.put(a, "id", .{ .string = "u1" });
    c.setAuth(.{ .record = .{ .object = rec }, .is_superuser = false, .exp = 9999999999 });
    try std.testing.expect(!authVerb(&app, &c, &id_arena, "not-a-jwt", ""));
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
            .id = "",
            .name = "fitems",
            .fields = &[_]schema.Field{.{ .id = "f1", .name = "owner", .options = .{ .text = .{} } }},
            .viewRule = rules.public_sentinel,
        });
        var data: std.json.ObjectMap = .empty;
        try data.put(a, "owner", .{ .string = "alice" });
        rec_val = try records.create(a, std.testing.io, w, pub_col, .{ .object = data });
        rid = rec_val.object.get("id").?.string;
        _ = try collections.create(a, std.testing.io, w, .{
            .id = "",
            .name = "flocked",
            .fields = &.{},
            .viewRule = null,
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
            .id = "",
            .name = "fnotes",
            .fields = &[_]schema.Field{.{ .id = "f1", .name = "owner", .options = .{ .text = .{} } }},
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
