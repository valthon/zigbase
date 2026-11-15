const std = @import("std");
const RequestArena = @import("../request_arena.zig").RequestArena;
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const ddl = @import("../ddl.zig");
const rules = @import("../rules.zig");
const policy = @import("../policy.zig");
const tenancy = @import("../tenancy/tenancy.zig");
const request = @import("../request.zig");
const collections = @import("../collections.zig");
const colcache = @import("../colcache.zig");
const records = @import("../records.zig");
const values = @import("../values.zig");
const migrations = @import("../migrations.zig");
const auth = @import("../auth.zig");
const protocol = @import("protocol.zig");
const connection = @import("connection.zig");
const Conn = connection.Conn;
const App = @import("../app.zig").App;
const Ctx = @import("../ctx.zig").Ctx;
const lexer = @import("../query/lexer.zig");
const parser = @import("../query/parser.zig");
const compiler = @import("../query/compiler.zig");
const joiner = @import("../query/joiner.zig");

pub const DeliverError = policy.PolicyError || @typeInfo(@typeInfo(@TypeOf(matchesSnapshot)).@"fn".return_type.?).error_union.error_set;

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
pub const SubscribeOutcome = enum {
    ok,
    unknown,
    auth_required,
    limit,
    invalid_filter,
    hidden_field,
    restricted_relation,

    /// Both transports use the existing error-frame envelope and messages.
    pub fn errorMessage(self: SubscribeOutcome) ?[]const u8 {
        return switch (self) {
            .ok => null,
            .unknown => "unknown collection",
            .auth_required => "authentication required to subscribe",
            .limit => "subscription limit reached",
            .invalid_filter => "invalid subscription filter",
            .hidden_field => "Cannot filter by a hidden field.",
            .restricted_relation => "Cannot filter through a relation with restricted target visibility.",
        };
    }
};

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
        const saved_token = ia.dupe(u8, token) catch {
            conn.clearAuth();
            return false;
        };
        conn.setAuth(.{ .record = record, .is_superuser = v.is_superuser, .exp = v.exp, .token = saved_token });
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
    defer alloc.free(json); // scratch: only the re-parsed tree below escapes
    // `.alloc_always` forces every string/key in the parsed tree to be copied onto `alloc`, so the
    // returned value is fully self-contained and does NOT reference `json` — freeing the scratch
    // buffer above is then safe. With the default (`.alloc_if_needed`), strings that need no
    // unescaping would alias `json` and dangle after it is freed.
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{ .allocate = .alloc_always });
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
    return subscribeFilterCheck(app, conn, alloc, topic, null);
}

/// Reject invalid client filters before either transport installs or replaces a
/// subscription. Delivery still revalidates against current identity and schema.
pub fn subscribeFilterCheck(app: *App, conn: *const Conn, alloc: RequestArena, topic: []const u8, filter: ?[]const u8) SubscribeOutcome {
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
    const current = currentIdentity(alloc, app, &r, conn) orelse {
        app.pool.releaseReader(&r);
        return .auth_required;
    };
    const rctx = current.requestContext(now);
    const lookup = collections.get(alloc.a, &r, t.collection) catch {
        app.pool.releaseReader(&r);
        return .unknown;
    };
    if (lookup) |col| {
        defer app.pool.releaseReader(&r);
        const decision = subscribeDecision(col, rctx.auth != null, rctx.is_superuser, false);
        if (decision != .ok) return decision;
        if (filter) |f| validateClientFilter(alloc.a, &r, col, f, &rctx) catch |err| return switch (err) {
            error.HiddenField => .hidden_field,
            error.RestrictedRelation => .restricted_relation,
            else => .invalid_filter,
        };
        return .ok;
    }
    // Release before the custom predicate: its Ctx may acquire another reader.
    app.pool.releaseReader(&r);
    return subscribeDecision(null, rctx.auth != null, rctx.is_superuser, canSubscribeTopic(app, alloc, rctx, topic));
}

const FilterError = lexer.LexError || parser.ParseError || compiler.CompileError;

/// Self-freeing validation shared by subscription and delivery checks.
fn validateClientFilter(alloc: std.mem.Allocator, reader: *db.Db, col: schema.Collection, filter: []const u8, rctx: *const request.RequestContext) FilterError!void {
    if (filter.len == 0) return;
    if (filter.len > records.max_filter_len) return error.BadFilter;
    var j = joiner.Joiner.init(alloc, reader, col);
    defer j.deinit();
    j.client_rctx = rctx;
    const sa = j.scratch.allocator();
    const tokens = try lexer.lex(sa, filter);
    const ast = try parser.parse(sa, tokens);
    _ = try compiler.compile(sa, &j, ast, rctx, db.dbDialect(reader), &.{});
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
                // @public or superuser: anyone may learn of the delete — UNLESS a per-row
                // predicate (tenant scope OR a view ability) constrains this subscriber, in which
                // case authorize the deleted row's snapshot against that composed predicate (no
                // rule clause). No snapshot -> deny.
                if (!row_constrained) return true;
                const snap = delete_snapshot orelse return false;
                return matchesSnapshot(alloc, col, record_id, "", snap, &rctx);
            },
            .check => {
                // Owner/expression-scoped viewRule: authorize the deleted row against its
                // snapshot (the live row is gone). The tenant predicate, when applicable, is
                // composed in by `matchesSnapshot`->`policy.matchesRule`. No snapshot -> deny.
                const snap = delete_snapshot orelse return false;
                return matchesSnapshot(alloc, col, record_id, col.viewRule.?, snap, &rctx);
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
    if (sub_filter) |f| if (f.len > 0) {
        // Defense in depth: identity or schema may have changed since subscribe.
        try validateClientFilter(alloc, reader, col, f, &rctx);
        try clauses.append(alloc, f);
    };
    // Unconstrained ONLY when there is no rule/filter clause AND no per-row predicate (tenant
    // scope OR a view ability). Otherwise run a guarded query: `matchesRule` ANDs the
    // tenant/ability predicate in (and tolerates an empty rule, so an ability/tenant-only
    // constraint is evaluated even with no viewRule/filter clause).
    if (clauses.items.len == 0 and !row_constrained) return true;

    const combined = if (clauses.items.len > 0) try combineClauses(alloc, clauses.items) else "";
    defer if (clauses.items.len > 0) alloc.free(combined); // scratch: matchesRule only reads it
    return policy.matchesRule(alloc, reader, col, record_id, combined, &rctx);
}

/// A built delete-authz sandbox: a `:memory:` DB carrying an EMPTY collection registry, the deleted
/// row's collection table, and the single snapshot row. It depends ONLY on (collection, snapshot) —
/// NOT on any subscriber — so it is reusable across every subscriber of one delete event. `key` is
/// the exact `<id>\x00<name>\x00<CREATE TABLE DDL>\x00<canonical snapshot JSON>` bytes it was built
/// for; a reuse is gated on an EXACT `mem.eql` match (never a hash) so a cached sandbox can only
/// ever authorize the SAME (collection schema, snapshot) it was built from — no collision could
/// authorize a delete against the wrong row or a stale table shape. The key lives on `arena`; `db`
/// is the SQLite handle. `deinit` closes both.
const SnapshotSandbox = struct {
    arena: std.heap.ArenaAllocator,
    db: db.Db,
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

/// The registry tables the sandbox carries, all EMPTY: `_collections` (+ its later columns) and
/// `_storage_namespaces` (which `collections.get`'s SELECT joins). They exist only so the query
/// joiner's relation-target lookup (`collections.get`) runs and finds NOTHING — which is what makes
/// every relation-traversing rule a conservative deny (`error.UnknownField`) rather than an error.
fn sandboxRegistry(tmp: *db.Db) db.DbError!void {
    try tmp.exec(migrations.collections_table_sql);
    try tmp.exec(migrations.collections_options_column_sql);
    try tmp.exec(migrations.collections_rename_epoch_column_sql);
    try tmp.exec(@import("../files/namespace.zig").table_sql);
}

/// The sandbox's CREATE TABLE for `col`: its physical columns exactly as the live table declares
/// them (relation fields stay RELATION-typed, so multi-relation operators compile as they do live),
/// but with NO foreign-key clauses. The sandbox holds no target tables, and a delete's authz only
/// reads the one snapshot row, so an FK has nothing to enforce. This deliberately bypasses
/// `collections.create`: its relation-target resolution rejects (`error.Validation`) any collection
/// whose targets are absent, which in the sandbox is every collection with a relation field
/// (#486). `col` is a registry-loaded collection, so an auth collection's system fields are
/// already in `col.fields`.
fn sandboxTableSql(alloc: std.mem.Allocator, col: schema.Collection) ![]u8 {
    var rel_names: std.ArrayList([]const u8) = .empty;
    defer rel_names.deinit(alloc);
    for (col.fields) |f| if (f.options == .relation) try rel_names.append(alloc, f.name);
    return ddl.createTableSql(alloc, col, null, @import("../sql/dialect.zig").Dialect.sqlite, rel_names.items);
}

/// Evaluate `rule` against a single deleted-record `snapshot` (F4), reusing a thread-local sandbox
/// across a delete event's subscribers (#18). The sandbox is a throwaway in-memory DB holding an
/// EMPTY collection registry and `col`'s table with ONLY the snapshot row inserted (its real id,
/// `created`/`updated`, and every field converted back to its live storage form by the write path's
/// `values.bindValue`); the standard guarded SELECT then runs per subscriber against `col`. Reuses
/// the exact rule machinery without touching the (now row-less) live DB.
///
/// Column, macro, tenant-scope and ability predicates (all of which compile to columns of `col`'s
/// own table plus bound params) therefore see the same stored values the live row held (subject to
/// the SQLite-dialect caveat below). A relation-TRAVERSING rule
/// (`owner.name = …`) cannot: the registry is empty, so the joiner's target lookup fails with
/// `error.UnknownField`, mapped below to a deny — a conservative failure for delete events, which
/// is the safe direction.
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
/// single-row sandbox, relation-traversing rules deny, and the typical authz fields (owner id,
/// tenant key, ability `.via` account id) are plain string equality that is identical across
/// dialects.
fn matchesSnapshot(
    alloc: std.mem.Allocator,
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
    // FAIL CLOSED, per item (#499): a failure that is a property of THIS retained event — a
    // snapshot value that no longer fits its field, or a rule that cannot be evaluated against the
    // snapshot (`SnapshotItemError`) — is a logged DENY for this subscriber, never an error. As an
    // error it would repeat on every attempt: backfill turned it into a 500 for the whole page on
    // every retry of the checkpoint until the event left retention, and the live fan-out logged a
    // dropped delivery per subscriber. Every OTHER failure propagates: OutOfMemory and a sandbox
    // SQLite failure (`db.DbError`, which is also how SQLite reports its own allocation failures)
    // say the server cannot answer NOW, so backfill answers 500 without advancing the checkpoint
    // and a retry can deliver the item. Denying those would skip the delete for good.
    const sandbox = snapshotSandbox(col, snapshot) catch |err| {
        if (!isSnapshotItemError(err)) return err;
        std.log.warn("realtime: delete on {s}/{s} not delivered: its snapshot could not be prepared for authorization: {s}", .{ col.name, record_id, @errorName(err) });
        return false;
    };
    // ONLY the guarded SELECT is per-subscriber; the sandbox build above is shared across the
    // event's fan-out on this reactor thread (#18). `rctx` is this subscriber's identity, so the
    // decision stays per-subscriber even though the single-row input is shared. The sandbox table
    // was built from `col`'s exact DDL (it is part of the cache key), so `col` describes it.
    return policy.matchesRule(alloc, &sandbox.db, col, record_id, rule, rctx) catch |err| {
        if (!isSnapshotItemError(err)) return err;
        if (err == error.UnknownField) {
            // Related collections are deliberately absent from the isolated delete sandbox, so a
            // relation-traversing rule is a known conservative denial, not an operational fault.
            // The same error also covers a rule naming a column `col` does not have (which the
            // live create/update path rejects too); the info line makes either visible when
            // diagnosing a missing delete frame.
            std.log.info("realtime: delete on {s}/{s} not delivered: its rule references a field outside the deleted record (relation traversal or unknown field)", .{ col.name, record_id });
        } else {
            std.log.warn("realtime: delete on {s}/{s} not delivered: its rule could not be evaluated against the snapshot: {s}", .{ col.name, record_id, @errorName(err) });
        }
        return false;
    };
}

/// The delete-authorization failures that belong to ONE retained item and repeat on every attempt
/// (#499), so `matchesSnapshot` denies the item instead of failing: a snapshot value the sandbox
/// cannot store by its field's type (`values.ValueError`, `values.EncryptError`), and a rule that
/// cannot be compiled against the snapshot's collection (lexer/parser/compiler/joiner errors —
/// `UnknownField` is how every relation traversal ends in the registry-less sandbox). Deliberately
/// absent: `OutOfMemory` and every `db.DbError`, which propagate (see `matchesSnapshot`).
const SnapshotItemError = error{
    // values.ValueError (its OutOfMemory excluded) and values.EncryptError
    TypeMismatch,
    TooPrecise,
    Overflow,
    BadNumber,
    BadSelect,
    NotObject,
    FieldKeyMissing,
    // rules.RuleError's rule-shape members: rules, lexer, parser, compiler, joiner
    BadRule,
    UnexpectedChar,
    UnterminatedString,
    InvalidEscape,
    UnexpectedToken,
    BadOperand,
    Empty,
    TooDeep,
    BadFilter,
    BadValue,
    UnknownField,
    NotARelation,
    MultiRelationTraversal,
    EncryptedField,
    HiddenField,
    RestrictedRelation,
};

comptime {
    // Every name above must still be an error those layers can return: a rename there fails the
    // build here instead of silently turning an item failure into a repeating 500.
    const Sources = values.ValueError || values.EncryptError || policy.PolicyError;
    for (@typeInfo(SnapshotItemError).error_set.?) |e| _ = @errorName(@field(Sources, e.name));
}

fn isSnapshotItemError(err: anyerror) bool {
    inline for (@typeInfo(SnapshotItemError).error_set.?) |e| {
        if (err == @field(SnapshotItemError, e.name)) return true;
    }
    return false;
}

/// Build — or reuse from the thread-local slot — the delete sandbox for (col, snapshot). The
/// caller has already validated `snapshot` is an object with a string `id`.
fn snapshotSandbox(col: schema.Collection, snapshot: std.json.Value) !*SnapshotSandbox {
    // Compute the exact cache key on a throwaway arena first:
    // "<id>\x00<name>\x00<table DDL>\x00<fields JSON>\x00<canonical JSON>". The stable collection
    // id, the DDL and the serialized field definitions key the SCHEMA: a schema change on the same
    // collection rebuilds rather than reusing a table of the old shape, and the field options that
    // drive the INSERT's storage conversion (a fixed number's scale, multi-value-ness) are part of
    // the key even when they leave the DDL unchanged. The name keys the INSERT target, and the
    // canonical snapshot JSON keys the row. All are far cheaper than the build they guard, so
    // forming the key per delivery still leaves the reuse a net win.
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const snap_json = try std.json.Stringify.valueAlloc(sa, snapshot, .{});
    const table_sql = try sandboxTableSql(sa, col);
    const fields_json = try schema.fieldsToJson(sa, col.fields);
    const key = try std.fmt.allocPrint(sa, "{s}\x00{s}\x00{s}\x00{s}\x00{s}", .{ col.id, col.name, table_sql, fields_json, snap_json });

    if (snapshot_sandbox) |*cached| {
        if (std.mem.eql(u8, cached.key, key)) return cached; // hit: same (collection, snapshot)
        cached.deinit(); // miss: evict the prior event's build before replacing it
        snapshot_sandbox = null;
    }

    // Build a fresh sandbox that OWNS its key on its own arena (page-allocator backed, so it
    // outlives the per-delivery arena and never touches a tracked test allocator). The build's
    // statement scratch goes on `sa`.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer arena.deinit();
    const owned_key = try arena.allocator().dupe(u8, key);

    var tmp = try db.Db.openMemory();
    errdefer tmp.close();
    try sandboxRegistry(&tmp);
    try tmp.exec(try sa.dupeZ(u8, table_sql));

    // Direct INSERT of the snapshot's real id + every column, each converted back to the form the
    // LIVE table stores. (We bypass records.create on purpose: it regenerates the id and re-runs
    // validation, neither of which we want for an authz snapshot of an already-validated row.)
    // The snapshot is a record READ (`values.readValue` API form), so binding it by its JSON type
    // would diverge from the live column for any field whose API form is not its storage form —
    // and a divergent column can make the sandbox ALLOW where the live row denies:
    //   - `created`/`updated`: the stored text (rules compare them like any column);
    //   - a fixed-scale number reads as "250.00" but is stored as the scaled integer 25000;
    //   - a json field stores every value as JSON text (`true`, `"admin"`), scalars included.
    // So every field binds through `values.bindValue` — the exact write-path conversion — by its
    // SCHEMA type. An `.encrypted` field is the exception and binds NULL: no rule can reference one
    // (the joiner rejects it, `error.EncryptedField`), so its value is never read, and binding its
    // at-rest envelope could only fail. A hidden field CAN be referenced (operator rules set
    // `allow_hidden`), so the snapshot carries it (`records.getDeleteSnapshot`); only the auth
    // credentials and hidden encrypted fields are left out of it. A field absent from the snapshot
    // binds NULL.
    var cols_sql: std.ArrayList(u8) = .empty;
    var ph_sql: std.ArrayList(u8) = .empty;
    try cols_sql.appendSlice(sa, "\"id\",\"created\",\"updated\"");
    try ph_sql.appendSlice(sa, "?1,?2,?3");
    for (col.fields, 0..) |f, i| {
        try cols_sql.append(sa, ',');
        try cols_sql.appendSlice(sa, try ddl.quoteIdent(sa, f.name));
        try ph_sql.appendSlice(sa, try std.fmt.allocPrint(sa, ",?{d}", .{i + 4}));
    }
    const sql = try std.fmt.allocPrintSentinel(sa, "INSERT INTO {s} ({s}) VALUES ({s});", .{ try ddl.quoteIdent(sa, col.name), cols_sql.items, ph_sql.items }, 0);
    var st = try tmp.prepare(sql);
    defer st.finalize();
    try st.bindText(1, snapshot.object.get("id").?.string);
    inline for (.{ "created", "updated" }, 2..) |name, idx| {
        switch (snapshot.object.get(name) orelse .null) {
            .string => |s| try st.bindText(idx, s),
            .null => try st.bindNull(idx),
            else => return error.TypeMismatch,
        }
    }
    for (col.fields, 0..) |f, i| {
        const idx: c_int = @intCast(i + 4);
        if (f.encrypted) {
            try st.bindNull(idx);
            continue;
        }
        try values.bindValue(sa, &st, idx, f, snapshot.object.get(f.name) orelse .null);
    }
    _ = try st.step();

    // Publish into the thread-local slot and return a pointer to it. No errdefer fires past this
    // point, so the moved-in `arena`/`tmp` are owned solely by the slot (no double-free).
    snapshot_sandbox = .{ .arena = arena, .db = tmp, .key = owned_key };
    return &snapshot_sandbox.?;
}

pub const EventFrames = struct {
    collection_channel: []const u8,
    record_channel: []const u8,
    frame_collection: []const u8,
    frame_record: []const u8,

    /// Free all four allocations. Production callers (ws.zig/pg_bridge.zig) build these under a
    /// throwaway per-call arena and skip this (arena reclaim); tests running under a raw allocator
    /// must call it.
    pub fn deinit(self: EventFrames, alloc: std.mem.Allocator) void {
        alloc.free(self.collection_channel);
        alloc.free(self.record_channel);
        alloc.free(self.frame_collection);
        alloc.free(self.frame_record);
    }
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
    errdefer alloc.free(coll_channel);
    const rec_channel = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ collection, record_id });
    errdefer alloc.free(rec_channel);

    // The delete-only wrapper map (`delete_body`) is pure scratch: both serializeEvent calls below
    // stringify it into a fresh, self-contained buffer, so it is freed before this function returns
    // (never escapes). It must NOT be freed for create/update, where `body` is the CALLER's own
    // `record` value (aliased, not owned here).
    var delete_body: std.json.ObjectMap = .empty;
    defer if (action == .delete) delete_body.deinit(alloc);
    const body: std.json.Value = if (action == .delete) blk: {
        try delete_body.put(alloc, "id", .{ .string = record_id });
        // Attach the deletion snapshot (if any) so subscribers can re-authorize owner-scoped
        // deletes. Stripped in frameForDelivery before the frame reaches the client.
        if (record) |snap| try delete_body.put(alloc, delete_snapshot_key, snap);
        break :blk .{ .object = delete_body };
    } else record.?;

    const frame_collection = try protocol.serializeEvent(alloc, coll_channel, action, body);
    errdefer alloc.free(frame_collection);
    return .{
        .collection_channel = coll_channel,
        .record_channel = rec_channel,
        .frame_collection = frame_collection,
        .frame_record = try protocol.serializeEvent(alloc, rec_channel, action, body),
    };
}

test "event frame construction releases partial allocations" {
    const Check = struct {
        fn run(alloc: std.mem.Allocator) !void {
            inline for (.{ protocol.Action.create, protocol.Action.update, protocol.Action.delete }) |action| {
                const frames = try buildEventFrames(alloc, "posts", action, "r1", .{ .object = .empty });
                defer frames.deinit(alloc);
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

/// Two-factor policy is dynamic even for an already-open transport. Use the
/// same verifier as HTTP, including epoch/session revocation and current record
/// data. The fresh record graph is used only during this subscription/delivery
/// decision; its interlinked JSON lives on that scratch arena, not the connection.
fn currentIdentity(arena: RequestArena, app: *App, reader: *db.Db, conn: *const Conn) ?Conn {
    const a = arena.a;
    var current = conn.*;
    const previous = conn.auth orelse return current;
    const verified = auth.verifyToken(a, app, reader, previous.token) orelse return null;
    defer a.free(verified.collection);
    defer a.free(verified.sid);
    current.auth = .{ .record = verified.record, .is_superuser = verified.is_superuser, .exp = verified.exp, .token = previous.token };
    return current;
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
    return frameForCollectionDelivery(a, app, conn, sub_filter, channel, message, null) catch |err| switch (err) {
        error.AuthenticationChanged => null,
        else => blk: {
            std.log.err("realtime: dropped delivery on {s}: {s}", .{ channel, @errorName(err) });
            break :blk null;
        },
    };
}

/// Backfill pins collection identity so a dropped/recreated collection cannot
/// reinterpret a retained record frame as a public custom-topic message.
pub fn frameForCollectionDelivery(
    a: std.mem.Allocator,
    app: *App,
    conn: *const Conn,
    sub_filter: ?[]const u8,
    channel: []const u8,
    message: []const u8,
    expected_collection_id: ?[]const u8,
) !?[]const u8 {
    // The public feature-signal channel carries a fixed, non-record frame: forward verbatim
    // (no per-record viewRule authorization, no collection lookup).
    if (expected_collection_id == null and std.mem.eql(u8, channel, FEATURES_CHANNEL)) return message;

    const t = protocol.parseTopic(channel);
    var r = try app.pool.acquireReader();
    var reader_held = true;
    defer if (reader_held) app.pool.releaseReader(&r);
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const current = currentIdentity(RequestArena.from(&scratch), app, &r, conn) orelse return error.AuthenticationChanged;

    // Resolve the topic to a collection FIRST. A non-collection topic is a consumer CUSTOM
    // channel (#143): forward its frame VERBATIM only while its subscription
    // guard still permits this identity (including after failed reauthentication).
    // R1-4: cached metadata — this runs once per SUBSCRIBER per event; the cache removes
    // the per-delivery `_collections` SELECT + schema-JSON parse (and caches the NEGATIVE
    // result for custom non-collection topics). Falls back to a direct load when no cache
    // is installed (tests / Postgres backend).
    var col_lease = try colcache.lease(app.col_cache, &r, a, t.collection);
    defer col_lease.release();
    const col = col_lease.col orelse {
        // Record events retain their type even after their collection is dropped.
        // Never reinterpret their private envelope as a verbatim custom message.
        const header = try std.json.parseFromSliceLeaky(struct { type: []const u8 = "" }, sa, message, .{ .ignore_unknown_fields = true });
        if (expected_collection_id != null or std.mem.eql(u8, header.type, "event")) {
            std.log.info("realtime: dropped record event for missing collection {s}", .{t.collection});
            return null;
        }
        const now = try auth.nowUnixPub(&r);
        // A consumer predicate may acquire its own reader. Match subscribeCheck's
        // lock order rather than holding a pool reader across application code.
        app.pool.releaseReader(&r);
        reader_held = false;
        return if (canSubscribeTopic(app, RequestArena.from(&scratch), current.requestContext(now), channel)) message else null;
    };
    if (expected_collection_id) |id| if (!std.mem.eql(u8, col.id, id)) return null;

    // #17: parse ONLY the three envelope fields the delivery decision needs — `action`,
    // `record.id`, and (delete only) the private `_deleteSnapshot` — with a TYPED parse +
    // `ignore_unknown_fields`, so the (arbitrarily large) record body is tokenized past but NEVER
    // materialized into a per-subscriber `ObjectMap` tree. This function runs once per SUBSCRIBER
    // per event; the old `parseFromSlice(Value)` built + discarded the whole record on every one of
    // them (10 KiB record × 1000 subscribers = ~10 MiB of throwaway allocation per event). For
    // create/update the record body is returned to the client VERBATIM below — never inspected.
    //
    // `parseFromSliceLeaky` never frees what it allocates, and nothing here needs `env` (or the
    // delete-snapshot subtree) to outlive this call — so it is parsed onto a THROWAWAY scratch
    // arena backed by `a`, reclaimed on return, rather than leaking per delivery.
    const env = try std.json.parseFromSliceLeaky(DeliveryEnvelope, sa, message, .{ .ignore_unknown_fields = true });
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

    const now = try auth.nowUnixPub(&r);
    const deliver = try shouldDeliver(a, &r, col, &current, now, action, record_id, sub_filter, delete_snapshot);
    if (!deliver) return null;

    if (action == .delete and delete_snapshot != null) {
        // Re-serialize an id-only delete frame so the private snapshot never reaches the client.
        // `clean` is scratch too (serializeEvent stringifies it into a fresh, independent buffer
        // before this call returns) — build it on `sa` so `scratch.deinit()` reclaims it.
        var clean: std.json.ObjectMap = .empty;
        try clean.put(sa, "id", .{ .string = record_id });
        return try protocol.serializeEvent(a, channel, .delete, .{ .object = clean });
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

/// The former write-path scratch leak (collections.create/records.create not freeing their DDL/SQL
/// scratch) is FIXED, so `mkColl`/`mkRec` are now leak-clean under the RAW `std.testing.allocator`:
/// `mkColl` returns a fully-owned Collection freed by `Collection.deinit`, and `mkRec` frees the
/// input map + the returned self-contained record (`records.freeRecord`), escaping only a duped id.
/// The `@public`/empty/null/id-only-delete `shouldDeliver` tests are therefore un-masked. The
/// guarded-query authz path (`shouldDeliver`/`matchesSnapshot` -> `policy.matchesRule`) and the
/// `colcache.lease` collection-lookup (its cache==null fallback owns a private arena, freed by
/// `release()`) are BOTH self-freeing, so every `shouldDeliver` and `frameForDelivery` test in this
/// file now runs under the raw `std.testing.allocator`. Only two tests remain wrapped in an arena,
/// and both are legitimate contract-4 (they call code that TAKES a `RequestArena`/`*ArenaAllocator`
/// by contract): `subscribeCheck` and `authVerb`.
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
    /// Insert a record and return ONLY its id, duped onto `a` (caller `defer a.free(rid)`). The
    /// record graph is self-contained: the input map and the returned self-contained record are freed
    /// here (`records.freeRecord`) so nothing escapes but the duped id — mirrors the write-path
    /// leak-detector test in records.zig.
    fn mkRec(self: *TestDb, a: std.mem.Allocator, col: schema.Collection, owner: []const u8) ![]const u8 {
        var data: std.json.ObjectMap = .empty;
        try data.put(a, "owner", .{ .string = owner });
        const rec = try records.create(a, std.testing.io, &self.d, col, .{ .object = data });
        data.deinit(a);
        const rid = try a.dupe(u8, rec.object.get("id").?.string);
        records.freeRecord(a, rec);
        return rid;
    }
};

fn authedConn(a: std.mem.Allocator, id: []const u8, is_super: bool) !Conn {
    var rec: std.json.ObjectMap = .empty;
    try rec.put(a, "id", .{ .string = id });
    var c = Conn{};
    c.setAuth(.{ .record = .{ .object = rec }, .is_superuser = is_super, .exp = 9999999999 });
    return c;
}

/// Free the auth-record ObjectMap backing a test `Conn` (from `authedConn` or an inline
/// `setAuth`). Its keys are static ("id") and its values are caller LITERALS — neither is
/// owned by `a` — so ONLY the map's backing array is freed (never the entries, unlike
/// `records.freeRecord`). No-op on an unauthenticated (anon) Conn.
fn freeConn(a: std.mem.Allocator, c: *Conn) void {
    if (c.auth) |ident| {
        var obj = ident.record.object;
        obj.deinit(a);
    }
}

test "public viewRule (@public): create delivered to anyone, no filter" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    const col = try tdb.mkColl(a, "posts", rules.public_sentinel);
    defer col.deinit(a);
    const rid = try tdb.mkRec(a, col, "u1");
    defer a.free(rid);
    var anon = Conn{};
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &anon, 0, .create, rid, null, null));
}

test "@public viewRule + view ability: create is NOT delivered to a non-member" {
    // Regression for the HIGH realtime-abilities bypass: a collection can be `@public` for the
    // access RULE yet have visibility narrowed by a relationship ability (#155). Realtime
    // delivery must honor the ability exactly like records.list — before the fix, the `@public`
    // early-return in shouldDeliver delivered the full record to any subscriber, bypassing it.
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    // The DB-owned collection is freed via `Collection.deinit`; the ability mutation below lives on a
    // struct COPY (`col`) so the owned base never carries the literal `.via` into deinit.
    const base = try tdb.mkColl(a, "posts", rules.public_sentinel);
    defer base.deinit(a);
    var col = base;
    // A view ability: visibility depends on the subscriber's relationship via `owner`, not the rule.
    col.options.abilities = .{ .view = .{ .relationship = .{ .via = "owner" } } };
    const rid = try tdb.mkRec(a, col, "u1");
    defer a.free(rid);
    // A non-superuser subscriber with NO qualifying membership must receive NOTHING: the ability's
    // empty qualifying set compiles to constant-false, so the guarded query matches no row.
    var outsider = try authedConn(a, "outsider", false);
    defer freeConn(a, &outsider);
    try std.testing.expect(!(try shouldDeliver(a, &tdb.d, col, &outsider, 0, .create, rid, null, null)));
    // A superuser bypasses abilities (consistent with rules.decide) and still receives it.
    var su = try authedConn(a, "root", true);
    defer freeConn(a, &su);
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &su, 0, .create, rid, null, null));
}

test "empty viewRule (\"\") is now LOCKED: anon receives nothing, superuser does" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    const col = try tdb.mkColl(a, "posts", "");
    defer col.deinit(a);
    const rid = try tdb.mkRec(a, col, "u1");
    defer a.free(rid);
    var anon = Conn{};
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &anon, 0, .create, rid, null, null));
    var su = try authedConn(a, "admin", true);
    defer freeConn(a, &su);
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &su, 0, .create, rid, null, null));
}

test "null viewRule: superuser-only" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    const col = try tdb.mkColl(a, "locked", null);
    defer col.deinit(a);
    const rid = try tdb.mkRec(a, col, "u1");
    defer a.free(rid);
    var anon = Conn{};
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &anon, 0, .create, rid, null, null));
    var su = try authedConn(a, "admin", true);
    defer freeConn(a, &su);
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &su, 0, .create, rid, null, null));
}

test "macro viewRule: only the owner receives the record" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    const col = try tdb.mkColl(a, "notes", "owner = @request.auth.id");
    defer col.deinit(a);
    const rid = try tdb.mkRec(a, col, "u1");
    defer a.free(rid);
    var owner = try authedConn(a, "u1", false);
    defer freeConn(a, &owner);
    var other = try authedConn(a, "u2", false);
    defer freeConn(a, &other);
    var anon = Conn{};
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &owner, 0, .update, rid, null, null));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &other, 0, .update, rid, null, null));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &anon, 0, .update, rid, null, null));
}

test "subscription filter narrows within an authorized viewRule" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    const col = try tdb.mkColl(a, "items", rules.public_sentinel);
    defer col.deinit(a);
    const rid = try tdb.mkRec(a, col, "alice");
    defer a.free(rid);
    var anon = Conn{};
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &anon, 0, .create, rid, "owner = \"alice\"", null));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &anon, 0, .create, rid, "owner = \"bob\"", null));
}

test "delete is id-only: locked -> only superuser; @public -> anyone" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    const pub_col = try tdb.mkColl(a, "p", rules.public_sentinel);
    defer pub_col.deinit(a);
    const locked = try tdb.mkColl(a, "l", null);
    defer locked.deinit(a);
    var anon = Conn{};
    // @public: anyone learns of the delete (no snapshot needed).
    try std.testing.expect(try shouldDeliver(a, &tdb.d, pub_col, &anon, 0, .delete, "GONE", null, null));
    // null/locked: only a superuser.
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, locked, &anon, 0, .delete, "GONE", null, null));
    var su = try authedConn(a, "admin", true);
    defer freeConn(a, &su);
    try std.testing.expect(try shouldDeliver(a, &tdb.d, locked, &su, 0, .delete, "GONE", null, null));
}

test "F4: owner-scoped delete only notifies the owner (snapshot authz)" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    const col = try tdb.mkColl(a, "notes", "owner = @request.auth.id");
    defer col.deinit(a);
    // The deleted row's snapshot: owned by u1. The live row is gone (delete already committed),
    // so authorization must come from this snapshot.
    var snap: std.json.ObjectMap = .empty;
    defer snap.deinit(a);
    try snap.put(a, "id", .{ .string = "GONE" });
    try snap.put(a, "owner", .{ .string = "u1" });
    const snapshot: std.json.Value = .{ .object = snap };

    var owner = try authedConn(a, "u1", false);
    defer freeConn(a, &owner);
    var other = try authedConn(a, "u2", false);
    defer freeConn(a, &other);
    var anon = Conn{};
    // Owner: receives the delete. Non-owner and anonymous: do NOT (no id leak).
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &owner, 0, .delete, "GONE", null, snapshot));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &other, 0, .delete, "GONE", null, snapshot));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &anon, 0, .delete, "GONE", null, snapshot));
    // No snapshot at all -> conservative deny, even for the would-be owner.
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &owner, 0, .delete, "GONE", null, null));
}

test "#18 hoist: the thread-local delete sandbox is reused per-subscriber AND rebuilt per event, with no cross-subscriber/cross-event leak" {
    // The sandbox depends only on (collection, snapshot); it is cached thread-locally and reused
    // across a delete event's subscribers, then rebuilt when the (collection, snapshot) changes.
    // This drives the reuse path (same snapshot, many subscribers) and the rebuild path (a second
    // snapshot, then back to the first) and asserts the per-subscriber authz decision is ALWAYS
    // computed from that subscriber's own rctx — never leaked from a prior cache occupant.
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    const col = try tdb.mkColl(a, "notes", "owner = @request.auth.id");
    defer col.deinit(a);

    var snap1: std.json.ObjectMap = .empty;
    defer snap1.deinit(a);
    try snap1.put(a, "id", .{ .string = "R1" });
    try snap1.put(a, "owner", .{ .string = "u1" });
    const s1: std.json.Value = .{ .object = snap1 };
    var snap2: std.json.ObjectMap = .empty;
    defer snap2.deinit(a);
    try snap2.put(a, "id", .{ .string = "R2" });
    try snap2.put(a, "owner", .{ .string = "u2" });
    const s2: std.json.Value = .{ .object = snap2 };

    var owner1 = try authedConn(a, "u1", false); // owns R1
    defer freeConn(a, &owner1);
    var owner2 = try authedConn(a, "u2", false); // owns R2
    defer freeConn(a, &owner2);
    var anon = Conn{};

    // Event 1 (snapshot owned by u1): first call BUILDS the sandbox, the next two REUSE it. Each
    // subscriber's decision comes from its own identity — a reused sandbox must not carry u1's
    // "allow" over to u2/anon.
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &owner1, 0, .delete, "R1", null, s1));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &owner2, 0, .delete, "R1", null, s1));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &anon, 0, .delete, "R1", null, s1));

    // Event 2 (different snapshot owned by u2): the key changes -> REBUILD. Now u2 is the owner and
    // u1 is denied — proving the rebuild swapped in the new row and did not reuse event 1's row.
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &owner2, 0, .delete, "R2", null, s2));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &owner1, 0, .delete, "R2", null, s2));

    // Back to event 1's snapshot: another rebuild; u1 allowed, u2 denied again. Interleaving proves
    // the cache never stalely authorizes against the wrong event's row.
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &owner1, 0, .delete, "R1", null, s1));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &owner2, 0, .delete, "R1", null, s1));
}

test "tenant scoping: a subscriber receives ONLY its account's frames; unresolved account gets nothing" {
    // CRITICAL regression guard (#156): the realtime delivery path must apply the tenant predicate.
    // Before the fix `Conn.requestContext` never set tenancy_enabled/account_id, so a tenant-owned
    // `@public` collection broadcast to every subscriber — a cross-tenant leak. This test FAILS
    // under that code and passes after the fix.
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;

    // A tenant-owned collection with a NATURAL @public viewRule (the whole point of auto-scoping).
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "account", .options = .{ .text = .{} } },
    };
    // The DB-owned collection is freed via `Collection.deinit`; the `tenant_field` mutation below
    // lives on a struct COPY (`col`) so the owned base never carries the literal into deinit.
    const base_col = try collections.create(a, std.testing.io, &tdb.d, .{
        .id = "",
        .name = "projects",
        .fields = &fields,
        .viewRule = rules.public_sentinel,
    });
    defer base_col.deinit(a);
    var col = base_col;
    col.options.tenant_field = "account";
    try tdb.d.exec("INSERT INTO projects (id,created,updated,title,account) VALUES " ++
        "('rA','t','t','a','accA'),('rB','t','t','b','accB');");

    // A subscriber whose connection is scoped to accA (tenancy_enabled + resolved account). The one
    // `rec` map is shared (by value) across connA/connNone/legacy, so free its backing exactly once.
    var rec: std.json.ObjectMap = .empty;
    defer rec.deinit(a);
    try rec.put(a, "id", .{ .string = "uA" });
    var connA = Conn{ .tenancy_enabled = true, .account_id = "accA" };
    connA.setAuth(.{ .record = .{ .object = rec }, .is_superuser = false, .exp = 9999999999 });

    // create/update of accA's row -> delivered; accB's row -> NOT delivered (cross-tenant denied).
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &connA, 0, .create, "rA", null, null));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &connA, 0, .create, "rB", null, null));
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &connA, 0, .update, "rA", null, null));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &connA, 0, .update, "rB", null, null));

    // delete uses the pre-delete snapshot: accA's snapshot delivered, accB's not.
    var snapA: std.json.ObjectMap = .empty;
    defer snapA.deinit(a);
    try snapA.put(a, "id", .{ .string = "rA" });
    try snapA.put(a, "account", .{ .string = "accA" });
    var snapB: std.json.ObjectMap = .empty;
    defer snapB.deinit(a);
    try snapB.put(a, "id", .{ .string = "rB" });
    try snapB.put(a, "account", .{ .string = "accB" });
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &connA, 0, .delete, "rA", null, .{ .object = snapA }));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &connA, 0, .delete, "rB", null, .{ .object = snapB }));

    // A subscriber with tenancy enabled but NO resolved account receives NOTHING on a tenant-owned
    // collection (fail closed) — even though the viewRule is @public.
    var connNone = Conn{ .tenancy_enabled = true, .account_id = "" };
    connNone.setAuth(.{ .record = .{ .object = rec }, .is_superuser = false, .exp = 9999999999 });
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &connNone, 0, .create, "rA", null, null));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &connNone, 0, .create, "rB", null, null));

    // A superuser bypasses tenancy (receives both); tenancy OFF on the conn = byte-identical legacy
    // (@public delivers all), proving the gate is the per-connection tenancy flag.
    var su = try authedConn(a, "admin", true);
    defer freeConn(a, &su);
    su.tenancy_enabled = true;
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &su, 0, .create, "rB", null, null));
    var legacy = Conn{ .tenancy_enabled = false };
    legacy.setAuth(.{ .record = .{ .object = rec }, .is_superuser = false, .exp = 9999999999 });
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &legacy, 0, .create, "rB", null, null));
}

/// #486 fixture: an `owners` target collection plus a `posts` collection carrying a TEXT
/// `account`, a RELATION `owner` (-> owners), a RELATION `org` (-> owners, used as a relation-typed
/// tenant field / ability `.via`), and a multi-RELATION `members` (-> owners). The delete sandbox
/// never holds `owners`, which is what used to make every snapshot authz on `posts` fail with
/// `error.Validation` (dropped delivery). Returns both owned collections; free with `deinit`.
const RelFixture = struct {
    owners: schema.Collection,
    posts: schema.Collection,
    fn init(a: std.mem.Allocator, tdb: *TestDb, view_rule: ?[]const u8) !RelFixture {
        const owners = try collections.create(a, std.testing.io, &tdb.d, .{
            .id = "",
            .name = "owners",
            .fields = &[_]schema.Field{.{ .id = "o1", .name = "name", .options = .{ .text = .{} } }},
        });
        errdefer owners.deinit(a);
        const posts = try collections.create(a, std.testing.io, &tdb.d, .{
            .id = "",
            .name = "posts",
            .fields = &[_]schema.Field{
                .{ .id = "p1", .name = "account", .options = .{ .text = .{} } },
                .{ .id = "p2", .name = "owner", .options = .{ .relation = .{ .targetCollectionId = owners.id, .maxSelect = 1 } } },
                .{ .id = "p3", .name = "org", .options = .{ .relation = .{ .targetCollectionId = owners.id, .maxSelect = 1 } } },
                .{ .id = "p4", .name = "members", .options = .{ .relation = .{ .targetCollectionId = owners.id, .maxSelect = 9 } } },
                .{ .id = "p5", .name = "expires", .options = .{ .date = .{} } },
            },
            .viewRule = view_rule,
        });
        return .{ .owners = owners, .posts = posts };
    }
    fn deinit(self: RelFixture, a: std.mem.Allocator) void {
        self.posts.deinit(a);
        self.owners.deinit(a);
    }
};

/// The deleted `posts` row: account accA, owner u1, org accA, members ["u1"].
fn relSnapshot(a: std.mem.Allocator, map: *std.json.ObjectMap, members: *std.json.Array) !std.json.Value {
    try members.append(.{ .string = "u1" });
    try map.put(a, "id", .{ .string = "GONE" });
    try map.put(a, "account", .{ .string = "accA" });
    try map.put(a, "owner", .{ .string = "u1" });
    try map.put(a, "org", .{ .string = "accA" });
    try map.put(a, "members", .{ .array = members.* });
    return .{ .object = map.* };
}

test "#486: tenant-owned (TEXT tenant field) collection WITH a relation delivers deletes to its tenant only" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    const fx = try RelFixture.init(a, &tdb, rules.public_sentinel);
    defer fx.deinit(a);
    var col = fx.posts;
    col.options.tenant_field = "account";
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(a);
    var members = std.json.Array.init(a);
    defer members.deinit();
    const snap = try relSnapshot(a, &map, &members);

    var rec: std.json.ObjectMap = .empty;
    defer rec.deinit(a);
    try rec.put(a, "id", .{ .string = "u1" });
    var member = Conn{ .tenancy_enabled = true, .account_id = "accA" };
    member.setAuth(.{ .record = .{ .object = rec }, .is_superuser = false, .exp = 9999999999 });
    var outsider = Conn{ .tenancy_enabled = true, .account_id = "accB" };
    outsider.setAuth(.{ .record = .{ .object = rec }, .is_superuser = false, .exp = 9999999999 });
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &member, 0, .delete, "GONE", null, snap));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &outsider, 0, .delete, "GONE", null, snap));
}

test "#486: relation-typed tenant field delivers deletes to its tenant only" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    const fx = try RelFixture.init(a, &tdb, rules.public_sentinel);
    defer fx.deinit(a);
    var col = fx.posts;
    col.options.tenant_field = "org";
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(a);
    var members = std.json.Array.init(a);
    defer members.deinit();
    const snap = try relSnapshot(a, &map, &members);

    var rec: std.json.ObjectMap = .empty;
    defer rec.deinit(a);
    try rec.put(a, "id", .{ .string = "u1" });
    var member = Conn{ .tenancy_enabled = true, .account_id = "accA" };
    member.setAuth(.{ .record = .{ .object = rec }, .is_superuser = false, .exp = 9999999999 });
    var outsider = Conn{ .tenancy_enabled = true, .account_id = "accB" };
    outsider.setAuth(.{ .record = .{ .object = rec }, .is_superuser = false, .exp = 9999999999 });
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &member, 0, .delete, "GONE", null, snap));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &outsider, 0, .delete, "GONE", null, snap));
}

test "#486: relation-via ability delivers deletes to members only" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    const fx = try RelFixture.init(a, &tdb, rules.public_sentinel);
    defer fx.deinit(a);
    var col = fx.posts;
    col.options.abilities = .{ .view = .{ .relationship = .{ .via = "org" } } };
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(a);
    var members = std.json.Array.init(a);
    defer members.deinit();
    const snap = try relSnapshot(a, &map, &members);

    var member = try authedConn(a, "u1", false);
    defer freeConn(a, &member);
    member.memberships = &.{.{ .account = "accA", .role = "member" }};
    var outsider = try authedConn(a, "u2", false);
    defer freeConn(a, &outsider);
    outsider.memberships = &.{.{ .account = "accB", .role = "member" }};
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &member, 0, .delete, "GONE", null, snap));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &outsider, 0, .delete, "GONE", null, snap));
}

test "#486: owner rule on a relation field delivers deletes to the owner only" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    const fx = try RelFixture.init(a, &tdb, "owner = @request.auth.id");
    defer fx.deinit(a);
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(a);
    var members = std.json.Array.init(a);
    defer members.deinit();
    const snap = try relSnapshot(a, &map, &members);

    var owner = try authedConn(a, "u1", false);
    defer freeConn(a, &owner);
    var other = try authedConn(a, "u2", false);
    defer freeConn(a, &other);
    var anon = Conn{};
    try std.testing.expect(try shouldDeliver(a, &tdb.d, fx.posts, &owner, 0, .delete, "GONE", null, snap));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, fx.posts, &other, 0, .delete, "GONE", null, snap));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, fx.posts, &anon, 0, .delete, "GONE", null, snap));
}

test "#486: an already-EXPIRED TTL row's delete still reaches its owner (and only its owner)" {
    // The snapshot sandbox applies no TTL filter, exactly like live create/update delivery
    // (`policy.matchesRule` never reads `ttl_field`): the owner of a row whose `expires` has passed
    // still learns it was deleted (e.g. by the TTL sweeper), so a client holding it can drop it. The
    // rule, not the TTL, decides who.
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    const fx = try RelFixture.init(a, &tdb, "owner = @request.auth.id");
    defer fx.deinit(a);
    var col = fx.posts;
    col.options.ttl_field = "expires";
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(a);
    var members = std.json.Array.init(a);
    defer members.deinit();
    _ = try relSnapshot(a, &map, &members);
    try map.put(a, "expires", .{ .string = "2000-01-01 00:00:00.000Z" });
    const snap: std.json.Value = .{ .object = map }; // taken AFTER the last put (the map may grow)

    var owner = try authedConn(a, "u1", false);
    defer freeConn(a, &owner);
    var other = try authedConn(a, "u2", false);
    defer freeConn(a, &other);
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &owner, 0, .delete, "GONE", null, snap));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &other, 0, .delete, "GONE", null, snap));
}

test "#486: a multi-relation rule sees the snapshot's array value in the delete sandbox" {
    // A multi-value field is stored live as its JSON array text; the sandbox must bind the
    // snapshot's array the same way (it used to leave array/object columns NULL), so a
    // `members ~ @request.auth.id` rule decides a delete exactly as it decides a live view.
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    const fx = try RelFixture.init(a, &tdb, "members ~ @request.auth.id");
    defer fx.deinit(a);
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(a);
    var members = std.json.Array.init(a);
    defer members.deinit();
    const snap = try relSnapshot(a, &map, &members);

    var member = try authedConn(a, "u1", false);
    defer freeConn(a, &member);
    var other = try authedConn(a, "u2", false);
    defer freeConn(a, &other);
    try std.testing.expect(try shouldDeliver(a, &tdb.d, fx.posts, &member, 0, .delete, "GONE", null, snap));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, fx.posts, &other, 0, .delete, "GONE", null, snap));
}

test "#486: a relation-TRAVERSING rule still conservatively denies a delete (no widening)" {
    // The related `owners` row is not in the sandbox, so `owner.name`/`owner.id` cannot be
    // evaluated: the decision is a deny for everyone (superuser aside), never an error and never
    // an allow — not even for the subscriber whose id the live traversal would have matched.
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    inline for (.{ "owner.name = \"alice\"", "owner.id = @request.auth.id", "owner.id != \"\"" }) |rule| {
        const fx = try RelFixture.init(a, &tdb, rule);
        defer {
            fx.deinit(a);
            tdb.d.exec("DROP TABLE posts; DROP TABLE owners; DELETE FROM _storage_namespaces; DELETE FROM _collections;") catch unreachable;
        }
        var map: std.json.ObjectMap = .empty;
        defer map.deinit(a);
        var members = std.json.Array.init(a);
        defer members.deinit();
        const snap = try relSnapshot(a, &map, &members);
        var owner = try authedConn(a, "u1", false);
        defer freeConn(a, &owner);
        try std.testing.expect(!try shouldDeliver(a, &tdb.d, fx.posts, &owner, 0, .delete, "GONE", null, snap));
        var su = try authedConn(a, "root", true);
        defer freeConn(a, &su);
        try std.testing.expect(try shouldDeliver(a, &tdb.d, fx.posts, &su, 0, .delete, "GONE", null, snap));
    }
}

test "#486: an auth collection's owner-scoped delete reaches its owner" {
    // Registry-loaded auth collections already carry the injected system fields; the sandbox must
    // build their table from those fields as-is.
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    const users = try collections.create(a, std.testing.io, &tdb.d, .{
        .id = "",
        .name = "people",
        .type = .auth,
        .fields = &[_]schema.Field{.{ .id = "b1", .name = "bio", .options = .{ .text = .{} } }},
        .viewRule = "id = @request.auth.id",
    });
    defer users.deinit(a);
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(a);
    try map.put(a, "id", .{ .string = "u1" });
    try map.put(a, "email", .{ .string = "u1@example.com" });
    try map.put(a, "bio", .{ .string = "hi" });
    var self_conn = try authedConn(a, "u1", false);
    defer freeConn(a, &self_conn);
    var other = try authedConn(a, "u2", false);
    defer freeConn(a, &other);
    try std.testing.expect(try shouldDeliver(a, &tdb.d, users, &self_conn, 0, .delete, "u1", null, .{ .object = map }));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, users, &other, 0, .delete, "u1", null, .{ .object = map }));
}

test "#486: an auth collection's `verified` rule decides deletes from the snapshot's bool" {
    // `verified` is an injected auth system field (a bool column). It is the only such flag a rule
    // can name: `emailVisibility` is not a column here (the joiner rejects it as an unknown field).
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    inline for (.{ .{ "verified = true", true }, .{ "verified != true", false } }) |c| {
        const people = try collections.create(a, std.testing.io, &tdb.d, .{
            .id = "",
            .name = "people",
            .type = .auth,
            .fields = &[_]schema.Field{.{ .id = "b1", .name = "bio", .options = .{ .text = .{} } }},
            .viewRule = c[0],
        });
        defer {
            people.deinit(a);
            tdb.d.exec("DROP TABLE people; DELETE FROM _storage_namespaces; DELETE FROM _collections;") catch unreachable;
        }
        var viewer = try authedConn(a, "u2", false);
        defer freeConn(a, &viewer);
        for ([_]bool{ true, false }) |on| {
            var map: std.json.ObjectMap = .empty;
            defer map.deinit(a);
            try map.put(a, "id", .{ .string = "u1" });
            try map.put(a, "email", .{ .string = "u1@example.com" });
            try map.put(a, "verified", .{ .bool = on });
            try std.testing.expectEqual(on == c[1], try shouldDeliver(a, &tdb.d, people, &viewer, 0, .delete, "u1", null, .{ .object = map }));
        }
    }
}

test "#486: a viewRule on a hidden field decides deletes from the private snapshot, which never reaches a frame" {
    // Operator rules may reference hidden fields (`allow_hidden`), but the hook-facing record a
    // delete starts from strips them. The authorization snapshot (`ws.prepareDelete` ->
    // `records.getDeleteSnapshot`) must carry the hidden value, or the rule compares NULL and the
    // owner never receives the delete. The value must still never reach a delivered frame.
    var env = try PoolEnv.init();
    defer env.deinit();
    const a = std.testing.allocator;
    var app = App{ .allocator = a, .io = std.testing.io, .pool = &env.pool };
    var hnotes: schema.Collection = undefined;
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const principals = try collections.create(a, std.testing.io, w, .{ .id = "", .name = "principals", .type = .auth, .fields = &.{} });
        defer principals.deinit(a);
        try w.exec("INSERT INTO principals (id,created,updated,email,passwordHash,tokenKey,verified) VALUES ('u1','','','u1@example.test','','test-key',1),('u2','','','u2@example.test','','test-key',1);");
        hnotes = try collections.create(a, std.testing.io, w, .{
            .id = "",
            .name = "hnotes",
            .fields = &[_]schema.Field{
                .{ .id = "f1", .name = "owner", .options = .{ .relation = .{ .targetCollectionId = principals.id, .maxSelect = 1 } } },
                .{ .id = "f2", .name = "tier", .hidden = true, .options = .{ .text = .{} } },
            },
            .viewRule = "owner = @request.auth.id && tier = 'gold-hidden-marker'",
        });
        try w.exec("INSERT INTO hnotes (id,created,updated,owner,tier) VALUES ('n1','','','u1','gold-hidden-marker'),('n2','','','u1','bronze-hidden-marker');");
    }
    defer hnotes.deinit(a);

    const jwt = @import("../jwt.zig");
    const key = @import("../crypto.zig").deriveKey(app.jwt_secret, "test-key");
    var owner = try authedConn(a, "u1", false);
    defer freeConn(a, &owner);
    var other = try authedConn(a, "u2", false);
    defer freeConn(a, &other);
    const owner_token = try jwt.sign(a, .{ .id = "u1", .collection = "principals", .type = .auth, .iat = 0, .exp = 9999999999 }, &key);
    defer a.free(owner_token);
    const other_token = try jwt.sign(a, .{ .id = "u2", .collection = "principals", .type = .auth, .iat = 0, .exp = 9999999999 }, &key);
    defer a.free(other_token);
    owner.auth.?.token = owner_token;
    other.auth.?.token = other_token;

    inline for (.{ .{ "n1", true }, .{ "n2", false } }) |c| {
        const snapshot = blk: {
            const w = env.pool.acquireWriter();
            defer env.pool.releaseWriter();
            // What the delete handler hands `prepareDelete`: the hook read, hidden fields stripped.
            const hook_read = (try records.get(a, w, hnotes, c[0])).?;
            defer records.freeRecord(a, hook_read);
            try std.testing.expect(hook_read.object.get("tier") == null);
            const rt = try @import("ws.zig").prepareDelete(a, &app, w, hnotes, c[0], hook_read);
            // Only a re-read carries `tier`; the reused hook read must not be freed twice.
            const tier = rt.snapshot.?.object.get("tier") orelse return error.TestExpectedHiddenFieldInSnapshot;
            try std.testing.expect(std.mem.endsWith(u8, tier.string, "-hidden-marker"));
            break :blk rt.snapshot.?;
        };
        defer records.freeRecord(a, snapshot);
        const ef = try buildEventFrames(a, "hnotes", .delete, c[0], snapshot);
        defer ef.deinit(a);
        const out = try frameForCollectionDelivery(a, &app, &owner, null, "hnotes", ef.frame_collection, hnotes.id);
        defer if (out) |o| a.free(o);
        try std.testing.expectEqual(c[1], out != null);
        if (out) |o| {
            try std.testing.expect(std.mem.indexOf(u8, o, "hidden-marker") == null);
            try std.testing.expect(std.mem.indexOf(u8, o, "tier") == null);
            try std.testing.expect(std.mem.indexOf(u8, o, delete_snapshot_key) == null);
        }
        try std.testing.expect((try frameForCollectionDelivery(a, &app, &other, null, "hnotes", ef.frame_collection, hnotes.id)) == null);
    }
}

test "#486: an encrypted field binds NULL in the delete sandbox, whatever the snapshot holds" {
    // Rules cannot reference an encrypted field (`error.EncryptedField`), so its snapshot value is
    // never needed. A value that is not an at-rest string envelope used to fail the sandbox build.
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    const col = try collections.create(a, std.testing.io, &tdb.d, .{
        .id = "",
        .name = "sealed",
        .fields = &[_]schema.Field{
            .{ .id = "s1", .name = "owner", .options = .{ .text = .{} } },
            .{ .id = "s2", .name = "secret", .encrypted = true, .options = .{ .text = .{} } },
        },
        .viewRule = "owner = @request.auth.id",
    });
    defer col.deinit(a);
    var owner = try authedConn(a, "u1", false);
    defer freeConn(a, &owner);
    var other = try authedConn(a, "u2", false);
    defer freeConn(a, &other);
    for ([_]std.json.Value{ .{ .string = "v1.envelope" }, .{ .integer = 7 }, .null }) |secret| {
        var map: std.json.ObjectMap = .empty;
        defer map.deinit(a);
        try map.put(a, "id", .{ .string = "GONE" });
        try map.put(a, "owner", .{ .string = "u1" });
        try map.put(a, "secret", secret);
        try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &owner, 0, .delete, "GONE", null, .{ .object = map }));
        try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &other, 0, .delete, "GONE", null, .{ .object = map }));
    }
}

/// Live-vs-delete PARITY: create `data` in `col` for real, read it back the way the delete path
/// captures its snapshot (`records.get`), then assert that the LIVE view decision for `conn` (an
/// `.update` delivery, evaluated against the stored row) and the DELETE decision (evaluated against
/// the snapshot in the sandbox) are BOTH `expect`. A sandbox column that diverged from the stored
/// form would make the two disagree — in the fail-open direction when the sandbox allows.
fn expectDeleteParity(a: std.mem.Allocator, tdb: *TestDb, col: schema.Collection, data: std.json.Value, conn: *const Conn, expect: bool) !void {
    const rec = try records.create(a, std.testing.io, &tdb.d, col, data);
    defer records.freeRecord(a, rec);
    const rid = rec.object.get("id").?.string;
    const snap = (try records.get(a, &tdb.d, col, rid)).?;
    defer records.freeRecord(a, snap);
    try std.testing.expectEqual(expect, try shouldDeliver(a, &tdb.d, col, conn, 0, .update, rid, null, null));
    try std.testing.expectEqual(expect, try shouldDeliver(a, &tdb.d, col, conn, 0, .delete, rid, null, snap));
}

/// One `typed` collection per rule: a text `owner`, a fixed-scale-2 `price`, and a json `meta`.
fn typedCollection(a: std.mem.Allocator, tdb: *TestDb, view_rule: []const u8) !schema.Collection {
    return collections.create(a, std.testing.io, &tdb.d, .{
        .id = "",
        .name = "typed",
        .fields = &[_]schema.Field{
            .{ .id = "t1", .name = "owner", .options = .{ .text = .{} } },
            .{ .id = "t2", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } },
            .{ .id = "t3", .name = "meta", .options = .{ .json = .{} } },
        },
        .viewRule = view_rule,
    });
}

fn dropTyped(tdb: *TestDb) void {
    tdb.d.exec("DROP TABLE typed; DELETE FROM _storage_namespaces; DELETE FROM _collections;") catch unreachable;
}

test "delete sandbox stores the snapshot's created/updated: a timestamp rule decides as it does live" {
    // Regression (review F1): the sandbox used to insert `created`/`updated` as '' — so
    // `created < "<future>"`-style rules ALLOWED every delete that live denies.
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    var viewer = try authedConn(a, "u2", false);
    defer freeConn(a, &viewer);
    const cases = .{
        .{ "created < \"2000-01-01 00:00:00\"", false },
        .{ "created > \"2000-01-01 00:00:00\"", true },
        .{ "updated < \"2000-01-01 00:00:00\"", false },
        .{ "updated != \"\"", true },
    };
    inline for (cases) |c| {
        const col = try typedCollection(a, &tdb, c[0]);
        defer {
            col.deinit(a);
            dropTyped(&tdb);
        }
        var data: std.json.ObjectMap = .empty;
        defer data.deinit(a);
        try data.put(a, "owner", .{ .string = "u1" });
        try expectDeleteParity(a, &tdb, col, .{ .object = data }, &viewer, c[1]);
    }
}

test "delete sandbox stores a fixed-scale number scaled, as live does" {
    // Regression (review F2): "250.00" (the API form) used to be bound as text into the INTEGER
    // column (-> 250), while live stores 25000 — so `price < 100` allowed a delete live denies,
    // and `price = 250` denied one live allows.
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    var viewer = try authedConn(a, "u2", false);
    defer freeConn(a, &viewer);
    const cases = .{
        .{ "price < 100", false },
        .{ "price = 250", true },
        .{ "price > 249.99", true },
    };
    inline for (cases) |c| {
        const col = try typedCollection(a, &tdb, c[0]);
        defer {
            col.deinit(a);
            dropTyped(&tdb);
        }
        var data: std.json.ObjectMap = .empty;
        defer data.deinit(a);
        try data.put(a, "price", .{ .string = "250.00" });
        try expectDeleteParity(a, &tdb, col, .{ .object = data }, &viewer, c[1]);
    }
}

test "delete sandbox stores a json field's scalar as JSON text, as live does" {
    // Regression (review F3): a json scalar used to be bound raw (true -> 1, "admin" -> admin),
    // while live stores JSON text (`true`, `"admin"`). Live compares a json column's JSON TEXT
    // against the literal's text, so a json string `"admin"` does NOT equal the literal "admin"
    // live — the old sandbox said it did (`meta = "admin"` allowed a delete live denies), and
    // `meta != true` on a stored `true` was allowed by the old sandbox ('1' != 'true') too.
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    var viewer = try authedConn(a, "u2", false);
    defer freeConn(a, &viewer);
    const Case = struct { rule: []const u8, meta: std.json.Value, expect: bool };
    const cases = [_]Case{
        .{ .rule = "meta != true", .meta = .{ .bool = true }, .expect = false },
        .{ .rule = "meta = true", .meta = .{ .bool = true }, .expect = true },
        .{ .rule = "meta != \"admin\"", .meta = .{ .string = "admin" }, .expect = true },
        .{ .rule = "meta = \"admin\"", .meta = .{ .string = "admin" }, .expect = false },
    };
    for (cases) |c| {
        const col = try typedCollection(a, &tdb, c.rule);
        defer {
            col.deinit(a);
            dropTyped(&tdb);
        }
        var data: std.json.ObjectMap = .empty;
        defer data.deinit(a);
        try data.put(a, "meta", c.meta);
        try expectDeleteParity(a, &tdb, col, .{ .object = data }, &viewer, c.expect);
    }
}

test "delete sandbox cache: a schema change with the same id, name and snapshot rebuilds" {
    // The thread-local sandbox is reused only for an EXACT key match. The key carries the table DDL
    // AND the field definitions: a scale change leaves the DDL identical (INTEGER either way) but
    // changes the stored form of the same snapshot value, so it must rebuild too.
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(std.testing.allocator);
    try map.put(std.testing.allocator, "id", .{ .string = "r1" });
    try map.put(std.testing.allocator, "price", .{ .string = "250.0" });
    const snap: std.json.Value = .{ .object = map };
    var fields = [_]schema.Field{.{ .id = "p1", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 1 } } }};
    const col = schema.Collection{ .id = "same-id", .name = "cached", .fields = &fields };
    const expectStored = struct {
        fn f(c: schema.Collection, s: std.json.Value, sql: [:0]const u8, want: i64) !void {
            const sb = try snapshotSandbox(c, s);
            var st = try sb.db.prepare(sql);
            defer st.finalize();
            try std.testing.expect(try st.step());
            try std.testing.expectEqual(want, st.columnInt(0));
        }
    }.f;
    try expectStored(col, snap, "SELECT \"price\" FROM \"cached\";", 2500);
    fields[0].options.number.scale = 2; // same id/name/snapshot, same DDL — different stored form
    try expectStored(col, snap, "SELECT \"price\" FROM \"cached\";", 25000);
    // A new column (DDL change) is present after the rebuild.
    var wider = [_]schema.Field{ fields[0], .{ .id = "p2", .name = "extra", .options = .{ .text = .{} } } };
    const col2 = schema.Collection{ .id = "same-id", .name = "cached", .fields = &wider };
    try expectStored(col2, snap, "SELECT COUNT(\"extra\") FROM \"cached\";", 0);
}

test "expired identity is treated as anonymous" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    const col = try tdb.mkColl(a, "notes", "owner = @request.auth.id");
    defer col.deinit(a);
    const rid = try tdb.mkRec(a, col, "u1");
    defer a.free(rid);
    var rec: std.json.ObjectMap = .empty;
    try rec.put(a, "id", .{ .string = "u1" });
    var c = Conn{};
    defer freeConn(a, &c);
    c.setAuth(.{ .record = .{ .object = rec }, .is_superuser = false, .exp = 100 });
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &c, 50, .update, rid, null, null));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &c, 200, .update, rid, null, null));
}

test "buildEventFrames: create carries the full record on both channels" {
    const a = std.testing.allocator;
    var rec: std.json.ObjectMap = .empty;
    defer rec.deinit(a);
    try rec.put(a, "id", .{ .string = "REC1" });
    try rec.put(a, "title", .{ .string = "hi" });
    const ef = try buildEventFrames(a, "posts", .create, "REC1", .{ .object = rec });
    defer ef.deinit(a);
    try std.testing.expectEqualStrings("posts", ef.collection_channel);
    try std.testing.expectEqualStrings("posts/REC1", ef.record_channel);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_collection, "\"topic\":\"posts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_collection, "\"title\":\"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_record, "\"topic\":\"posts/REC1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_record, "\"title\":\"hi\"") != null);
}

test "buildEventFrames: delete is id-only (no body fields)" {
    const a = std.testing.allocator;
    const ef = try buildEventFrames(a, "posts", .delete, "REC1", null);
    defer ef.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_collection, "\"action\":\"delete\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_collection, "\"id\":\"REC1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_collection, "\"title\"") == null);
}

test "F4: delete frame carries the private authz snapshot (stripped before client delivery)" {
    const a = std.testing.allocator;
    var snap: std.json.ObjectMap = .empty;
    defer snap.deinit(a);
    try snap.put(a, "id", .{ .string = "REC1" });
    try snap.put(a, "owner", .{ .string = "u1" });
    const ef = try buildEventFrames(a, "notes", .delete, "REC1", .{ .object = snap });
    defer ef.deinit(a);
    // The PUBLISHED frame includes the snapshot under the private key so subscribers can authorize.
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_collection, delete_snapshot_key) != null);
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_collection, "\"owner\":\"u1\"") != null);
    // (onChannelMessage strips delete_snapshot_key and re-serializes an id-only frame before
    // WS.write, so the client never sees the snapshot — covered by the hub authz tests above.)
}

test "R1-3: delete sandbox registry is minimal — two empty tables, not the migration suite" {
    var tmp = try db.Db.openMemory();
    defer tmp.close();
    try sandboxRegistry(&tmp);
    var st = try tmp.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type='table';");
    defer st.finalize();
    try std.testing.expect(try st.step());
    // `_collections` and `_storage_namespaces` only. This pins the per-delete-event cost: the full
    // suite (migrations.run) creates dozens of tables.
    try std.testing.expectEqual(@as(i64, 2), st.columnInt(0));
}

test "R1-3: a relation-target lookup in the sandbox registry finds nothing (and does not error)" {
    // THE REGRESSION THIS EXISTS FOR: the sandbox is hand-seeded and built in the LIVE SERVING
    // PROCESS on every delete-event delivery. The query joiner resolves a traversed relation's
    // target with `collections.get`; if the registry ever stops carrying a table that SELECT reads,
    // every relation-traversing delete authz turns from a conservative deny into a dropped
    // delivery — while `zig build test` stays green unless this path is exercised.
    var tmp = try db.Db.openMemory();
    defer tmp.close();
    try sandboxRegistry(&tmp);
    try std.testing.expect((try collections.get(std.testing.allocator, &tmp, "anything")) == null);
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
    var app: App = undefined;
    const anon = request.RequestContext{};
    // No dispatch wired (tests/CLI): custom topics default to PUBLIC signal channels.
    app.dispatch = null;
    try std.testing.expect(canSubscribeTopic(&app, RequestArena.forTest(std.testing.allocator), anon, "availability"));
    // Dispatch present but NO predicate -> still public by default.
    var d = @import("../events.zig").Dispatch{};
    app.dispatch = &d;
    try std.testing.expect(canSubscribeTopic(&app, RequestArena.forTest(std.testing.allocator), anon, "orders"));
}

test "canSubscribeTopic: a canSubscribe guard returning false denies (#143)" {
    const a = std.testing.allocator;
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
    try std.testing.expect(!canSubscribeTopic(&app, RequestArena.forTest(a), anon, "private"));
    // A guard gating on auth: anonymous denied, authenticated allowed.
    d.realtime_can_subscribe = Guard.onlyAuthed;
    try std.testing.expect(!canSubscribeTopic(&app, RequestArena.forTest(a), anon, "private"));
    var rec: std.json.ObjectMap = .empty;
    defer rec.deinit(a);
    try rec.put(a, "id", .{ .string = "u1" });
    const authed = request.RequestContext{ .auth = .{ .object = rec }, .is_superuser = false };
    try std.testing.expect(canSubscribeTopic(&app, RequestArena.forTest(a), authed, "private"));
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
    // MASKED (legitimate contract-4): `subscribeCheck` TAKES a `RequestArena` and, by that
    // contract, leaks its `collections.get` lookup graph into the arena wholesale (production frees
    // it at request end). A `RequestArena` is exactly the contract-4 case the ratchet permits an
    // arena for, so this test keeps one. (The setup also provisions collections on `a`, discarding
    // the returned graphs — an arena reclaims those too.)
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
    const a = std.testing.allocator;
    var app = App{ .allocator = a, .io = std.testing.io, .pool = &env.pool };
    var c = Conn{};
    // contract-4 (legitimate, not a masking workaround): `authVerb`'s `identity_arena` parameter is
    // typed `*std.heap.ArenaAllocator` — the real per-connection identity arena in production — so a
    // genuine arena is the only value that satisfies the signature here (there is no `forTest`-style
    // bypass for a concrete `*ArenaAllocator`, only for `RequestArena`). It does not mask leak
    // detection for the rest of this test: `a` above is the raw allocator, and this arena only ever
    // receives the deep-cloned identity `authVerb` itself would clone in production.
    var id_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer id_arena.deinit();
    // Pre-install an identity to prove a failed auth CLEARS it (the ws contract).
    var rec: std.json.ObjectMap = .empty;
    defer rec.deinit(a);
    try rec.put(a, "id", .{ .string = "u1" });
    c.setAuth(.{ .record = .{ .object = rec }, .is_superuser = false, .exp = 9999999999 });
    try std.testing.expect(!authVerb(&app, &c, &id_arena, "not-a-jwt", ""));
    try std.testing.expect(c.auth == null);
}

test "frameForDelivery: custom topic rechecks its guard; public signals forward verbatim" {
    var env = try PoolEnv.init();
    defer env.deinit();
    // Leak-clean under the raw allocator: "orders" is not a collection (`collections.get` returns
    // null after freeing its own SELECT scratch — see collections.zig `defer alloc.free(sql)`), so
    // no collection graph is materialized; and both topics forward the message VERBATIM (no
    // guarded-query path, no owned frame allocated). Nothing escapes onto `a`.
    const a = std.testing.allocator;
    var app = App{ .allocator = a, .io = std.testing.io, .pool = &env.pool };
    var anon = Conn{};
    // A non-collection topic: the exact message bytes come back (pointer-equal slice).
    const msg = "{\"type\":\"message\",\"topic\":\"orders\",\"data\":1}";
    const out = frameForDelivery(a, &app, &anon, null, "orders", msg).?;
    try std.testing.expectEqualStrings(msg, out);
    // __features: verbatim too.
    const sig = "{\"type\":\"signal\",\"topic\":\"__features\"}";
    try std.testing.expectEqualStrings(sig, frameForDelivery(a, &app, &anon, null, FEATURES_CHANNEL, sig).?);
    const Guard = struct {
        fn canSubscribe(cx: *Ctx, _: []const u8) bool {
            return cx.rctx.auth != null;
        }
    };
    var dispatch = @import("../events.zig").Dispatch{ .realtime_can_subscribe = Guard.canSubscribe };
    app.dispatch = &dispatch;
    // A cleared identity cannot retain a private custom-topic subscription.
    try std.testing.expect(frameForDelivery(a, &app, &anon, null, "orders", msg) == null);
    try std.testing.expectEqualStrings(sig, frameForDelivery(a, &app, &anon, null, FEATURES_CHANNEL, sig).?);
}

test "backfill delivery propagates allocation and identity uncertainty" {
    var env = try PoolEnv.init();
    defer env.deinit();
    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = &env.pool };
    const anon = Conn{};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, frameForCollectionDelivery(failing.allocator(), &app, &anon, null, "posts", "{}", "expected-id"));
    var revoked = Conn{};
    revoked.auth = .{ .record = .null, .is_superuser = false, .exp = 0, .token = "invalid" };
    try std.testing.expectError(error.AuthenticationChanged, frameForCollectionDelivery(std.testing.allocator, &app, &revoked, null, "posts", "{}", "expected-id"));
    // Ordinary revocation stays a silent live-delivery denial (not an error log).
    try std.testing.expect(frameForDelivery(std.testing.allocator, &app, &revoked, null, "posts", "{}") == null);
}

test "frameForDelivery: viewRule deny -> null; @public + matching filter -> frame; mismatching filter -> null" {
    var env = try PoolEnv.init();
    defer env.deinit();
    const a = std.testing.allocator;
    var app = App{ .allocator = a, .io = std.testing.io, .pool = &env.pool };
    var pub_col: schema.Collection = undefined;
    var locked_col: schema.Collection = undefined;
    var rec: std.json.Value = undefined;
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        pub_col = try collections.create(a, std.testing.io, w, .{
            .id = "",
            .name = "fitems",
            .fields = &[_]schema.Field{.{ .id = "f1", .name = "owner", .options = .{ .text = .{} } }},
            .viewRule = rules.public_sentinel,
        });
        var data: std.json.ObjectMap = .empty;
        try data.put(a, "owner", .{ .string = "alice" });
        rec = try records.create(a, std.testing.io, w, pub_col, .{ .object = data });
        data.deinit(a);
        locked_col = try collections.create(a, std.testing.io, w, .{
            .id = "",
            .name = "flocked",
            .fields = &.{},
            .viewRule = null,
        });
    }
    defer pub_col.deinit(a);
    defer locked_col.deinit(a);

    const rid = rec.object.get("id").?.string;
    const ef = try buildEventFrames(a, "fitems", .create, rid, rec);
    defer ef.deinit(a);
    // Reuses the same record body for a differently-named/locked topic — only the frame's channel
    // name matters for this assertion, not the record contents.
    const lf = try buildEventFrames(a, "flocked", .create, "R1", rec);
    defer lf.deinit(a);
    records.freeRecord(a, rec);

    var anon = Conn{};
    // @public, no filter: delivered verbatim.
    try std.testing.expectEqualStrings(ef.frame_collection, frameForDelivery(a, &app, &anon, null, "fitems", ef.frame_collection).?);
    // Filter narrows: match delivers, mismatch denies.
    try std.testing.expect(frameForDelivery(a, &app, &anon, "owner = \"alice\"", "fitems", ef.frame_collection) != null);
    try std.testing.expect(frameForDelivery(a, &app, &anon, "owner = \"bob\"", "fitems", ef.frame_collection) == null);
    // Locked collection: anonymous denied outright (frame for a locked col).
    try std.testing.expect(frameForDelivery(a, &app, &anon, null, "flocked", lf.frame_collection) == null);
}

test "frameForDelivery: committed mid-fanout policy and revocation affect later subscribers" {
    var env = try PoolEnv.init();
    defer env.deinit();
    const a = std.testing.allocator;
    var cache = colcache.Cache.init(a);
    defer cache.deinit();
    var app = App{ .allocator = a, .io = std.testing.io, .pool = &env.pool, .col_cache = &cache };
    const Guard = struct {
        fn canSubscribe(cx: *Ctx, _: []const u8) bool {
            return cx.rctx.auth != null;
        }
    };
    var dispatch = @import("../events.zig").Dispatch{ .realtime_can_subscribe = Guard.canSubscribe };
    app.dispatch = &dispatch;
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const principals = try collections.create(a, app.io, w, .{ .id = "", .name = "principals", .type = .auth, .fields = &.{} });
        defer principals.deinit(a);
        const posts = try collections.create(a, app.io, w, .{
            .id = "",
            .name = "fanout_posts",
            .viewRule = "owner = @request.auth.id",
            .fields = &.{.{ .id = "owner", .name = "owner", .options = .{ .text = .{} } }},
        });
        defer posts.deinit(a);
        try w.exec("INSERT INTO principals (id,created,updated,email,passwordHash,tokenKey,verified) VALUES ('u1','','','u1@example.test','','test-key',1);");
        try w.exec("INSERT INTO fanout_posts (id,created,updated,owner) VALUES ('r1','','','u1');");
    }
    const jwt = @import("../jwt.zig");
    const key = @import("../crypto.zig").deriveKey(app.jwt_secret, "test-key");
    const token = try jwt.sign(a, .{ .id = "u1", .collection = "principals", .type = .auth, .iat = 0, .exp = 9999999999 }, &key);
    defer a.free(token);
    const retained = Conn{ .auth = .{ .record = .null, .is_superuser = false, .exp = 9999999999, .token = token } };
    const subscribers = [_]Conn{retained} ** 10;
    const frame = "{\"action\":\"update\",\"record\":{\"id\":\"r1\"}}";
    // Warm col_cache for record/custom topics. The auth collection is re-read
    // directly per callback; mutations below must not reuse cached auth state.
    try std.testing.expect(frameForDelivery(a, &app, &retained, null, "fanout_posts", frame) != null);
    try std.testing.expect(frameForDelivery(a, &app, &retained, null, "private_topic", frame) != null);
    // Deterministically interleave a COMMITTED writer between subscriber callbacks,
    // without timing/sleep races. Both WS and SSE invoke this same seam independently.
    // No two-factor runtime is installed: newly required 2FA must fail closed.
    // This does not exercise enabled factor callbacks or enrollment lookups.
    for ([_][:0]const u8{
        "UPDATE _collections SET options='{\"auth\":{\"two_factor\":\"required\"}}' WHERE name='principals';",
        "UPDATE principals SET tokenKey='revoked';",
    }) |mutation| {
        {
            const w = env.pool.acquireWriter();
            defer env.pool.releaseWriter();
            try w.exec("UPDATE _collections SET options='{}' WHERE name='principals';");
            try w.exec("UPDATE principals SET tokenKey='test-key';");
        }
        for (&subscribers, 0..) |*subscriber, index| {
            if (index == 5) {
                const w = env.pool.acquireWriter();
                defer env.pool.releaseWriter();
                try w.exec("BEGIN;");
                errdefer w.exec("ROLLBACK;") catch |err| std.log.err("fanout test rollback: {s}", .{@errorName(err)});
                try w.exec(mutation);
                try w.exec("COMMIT;");
            }
            const record_frame = frameForDelivery(a, &app, subscriber, null, "fanout_posts", frame);
            const custom_frame = frameForDelivery(a, &app, subscriber, null, "private_topic", frame);
            try std.testing.expectEqual(index < 5, record_frame != null);
            try std.testing.expectEqual(index < 5, custom_frame != null);
            if (record_frame) |value| try std.testing.expect(value.ptr == frame.ptr);
            if (custom_frame) |value| try std.testing.expect(value.ptr == frame.ptr);
        }
    }
}

test "frameForDelivery: F4 delete snapshot authorizes, then is STRIPPED to an id-only frame" {
    var env = try PoolEnv.init();
    defer env.deinit();
    const a = std.testing.allocator;
    var app = App{ .allocator = a, .io = std.testing.io, .pool = &env.pool };
    var fnotes: schema.Collection = undefined;
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        fnotes = try collections.create(a, std.testing.io, w, .{
            .id = "",
            .name = "fnotes",
            .fields = &[_]schema.Field{.{ .id = "f1", .name = "owner", .options = .{ .text = .{} } }},
            .viewRule = "owner = @request.auth.id",
        });
    }
    defer fnotes.deinit(a);
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const principals = try collections.create(a, std.testing.io, w, .{ .id = "", .name = "principals", .type = .auth, .fields = &.{} });
        defer principals.deinit(a);
        try w.exec("INSERT INTO principals (id,created,updated,email,passwordHash,tokenKey,verified) VALUES ('u1','','','u1@example.test','','test-key',1),('u2','','','u2@example.test','','test-key',1);");
    }

    var snap: std.json.ObjectMap = .empty;
    try snap.put(a, "id", .{ .string = "GONE" });
    try snap.put(a, "owner", .{ .string = "u1" });
    const ef = try buildEventFrames(a, "fnotes", .delete, "GONE", .{ .object = snap });
    defer ef.deinit(a);
    // `buildEventFrames` only ALIASES `snap` into its own scratch wrapper (stringified into the
    // independent `ef` buffers before returning) — the map itself is still ours to free (values are
    // literals, so only the backing array needs it, matching `freeConn`'s convention below).
    snap.deinit(a);
    // The published frame carries the private snapshot (precondition).
    try std.testing.expect(std.mem.indexOf(u8, ef.frame_collection, delete_snapshot_key) != null);

    var owner = try authedConn(a, "u1", false);
    defer freeConn(a, &owner);
    var other = try authedConn(a, "u2", false);
    defer freeConn(a, &other);
    const jwt = @import("../jwt.zig");
    const key = @import("../crypto.zig").deriveKey(app.jwt_secret, "test-key");
    const owner_token = try jwt.sign(a, .{ .id = "u1", .collection = "principals", .type = .auth, .iat = 0, .exp = 9999999999 }, &key);
    defer a.free(owner_token);
    const other_token = try jwt.sign(a, .{ .id = "u2", .collection = "principals", .type = .auth, .iat = 0, .exp = 9999999999 }, &key);
    defer a.free(other_token);
    owner.auth.?.token = owner_token;
    other.auth.?.token = other_token;
    // Owner: delivered — and the delivered frame is ID-ONLY (snapshot + owner field stripped).
    // The id-only frame is a FRESH re-serialization (frameForDelivery strips the snapshot before
    // returning), so it escapes onto `a` and must be freed here — unlike the verbatim-forward case.
    const out = frameForDelivery(a, &app, &owner, null, "fnotes", ef.frame_collection).?;
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, delete_snapshot_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"owner\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"GONE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"action\":\"delete\"") != null);
    // Non-owner: nothing (no id leak, and nothing allocated on the deny path).
    try std.testing.expect(frameForDelivery(a, &app, &other, null, "fnotes", ef.frame_collection) == null);
    // A runtime requirement on a build that omitted the subsystem must still
    // invalidate the retained identity, not bypass checks because no runtime exists.
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try w.exec("UPDATE \"_collections\" SET \"options\"='{\"auth\":{\"two_factor\":\"required\"}}' WHERE \"name\"='principals';");
    }
    try std.testing.expect(frameForDelivery(a, &app, &owner, null, "fnotes", ef.frame_collection) == null);
}

test "subscription filters cannot infer private related fields or hidden base fields" {
    const a = std.testing.allocator;
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const target = try tdb.mkColl(a, "targets", null);
    defer target.deinit(a);
    const col = try collections.create(a, std.testing.io, &tdb.d, .{ .id = "", .name = "sources", .fields = &.{
        .{ .id = "f1", .name = "target", .options = .{ .relation = .{ .targetCollectionId = target.id, .maxSelect = 1 } } },
        .{ .id = "f2", .name = "secret", .hidden = true, .options = .{ .text = .{} } },
    }, .viewRule = "target.owner = 'alice'" });
    defer col.deinit(a);
    try tdb.d.exec("INSERT INTO targets (id,created,updated,owner) VALUES ('t1','t','t','alice');");
    try tdb.d.exec("INSERT INTO sources (id,created,updated,target,secret) VALUES ('s1','t','t','t1','value');");
    var anon = Conn{};
    // Trusted viewRule can gate delivery on a private target.
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &anon, 0, .create, "s1", null, null));
    try std.testing.expectError(error.RestrictedRelation, shouldDeliver(a, &tdb.d, col, &anon, 0, .create, "s1", "target.owner = 'alice'", null));
    try std.testing.expectError(error.HiddenField, shouldDeliver(a, &tdb.d, col, &anon, 0, .create, "s1", "secret = 'value'", null));
    var su = try authedConn(a, "root", true);
    defer freeConn(a, &su);
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &su, 0, .create, "s1", "target.owner = 'alice'", null));
}

test "#499: a delete snapshot that cannot be authorized is a per-item deny, never an error" {
    // `frameForCollectionDelivery` is the backfill chokepoint: an error there 500s the whole page,
    // and the retained event repeats it on every retry of the checkpoint. A snapshot that no longer
    // fits its field (here a string in a bool column) must deny that one item for every caller,
    // while well-formed deletes on the same relation-bearing collection still reach their owner.
    var env = try PoolEnv.init();
    defer env.deinit();
    const a = std.testing.allocator;
    var app = App{ .allocator = a, .io = std.testing.io, .pool = &env.pool };
    var rnotes: schema.Collection = undefined;
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const principals = try collections.create(a, std.testing.io, w, .{ .id = "", .name = "principals", .type = .auth, .fields = &.{} });
        defer principals.deinit(a);
        try w.exec("INSERT INTO principals (id,created,updated,email,passwordHash,tokenKey,verified) VALUES ('u1','','','u1@example.test','','test-key',1),('u2','','','u2@example.test','','test-key',1);");
        rnotes = try collections.create(a, std.testing.io, w, .{
            .id = "",
            .name = "rnotes",
            .fields = &[_]schema.Field{
                .{ .id = "f1", .name = "owner", .options = .{ .relation = .{ .targetCollectionId = principals.id, .maxSelect = 1 } } },
                .{ .id = "f2", .name = "flag", .options = .{ .bool = .{} } },
            },
            .viewRule = "owner = @request.auth.id",
        });
    }
    defer rnotes.deinit(a);

    const jwt = @import("../jwt.zig");
    const key = @import("../crypto.zig").deriveKey(app.jwt_secret, "test-key");
    var owner = try authedConn(a, "u1", false);
    defer freeConn(a, &owner);
    var other = try authedConn(a, "u2", false);
    defer freeConn(a, &other);
    const owner_token = try jwt.sign(a, .{ .id = "u1", .collection = "principals", .type = .auth, .iat = 0, .exp = 9999999999 }, &key);
    defer a.free(owner_token);
    const other_token = try jwt.sign(a, .{ .id = "u2", .collection = "principals", .type = .auth, .iat = 0, .exp = 9999999999 }, &key);
    defer a.free(other_token);
    owner.auth.?.token = owner_token;
    other.auth.?.token = other_token;

    inline for (.{ .{ std.json.Value{ .bool = true }, true }, .{ std.json.Value{ .string = "not-a-bool" }, false } }) |c| {
        const ef = try snapshotFramesForTest(a, c[0]);
        defer ef.deinit(a);
        const out = try frameForCollectionDelivery(a, &app, &owner, null, "rnotes", ef.frame_collection, rnotes.id);
        defer if (out) |o| a.free(o);
        try std.testing.expectEqual(c[1], out != null);
        try std.testing.expect((try frameForCollectionDelivery(a, &app, &other, null, "rnotes", ef.frame_collection, rnotes.id)) == null);
    }
}

fn snapshotFramesForTest(a: std.mem.Allocator, flag: std.json.Value) !EventFrames {
    var snap: std.json.ObjectMap = .empty;
    defer snap.deinit(a);
    try snap.put(a, "id", .{ .string = "GONE" });
    try snap.put(a, "owner", .{ .string = "u1" });
    try snap.put(a, "flag", flag);
    return buildEventFrames(a, "rnotes", .delete, "GONE", .{ .object = snap });
}

test "delete delivery fixture releases snapshot on every allocation failure" {
    const Check = struct {
        fn run(a: std.mem.Allocator) !void {
            const frames = try snapshotFramesForTest(a, .{ .bool = true });
            defer frames.deinit(a);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "live delivery drops queued record deletes after collection removal" {
    var env = try PoolEnv.init();
    defer env.deinit();
    const a = std.testing.allocator;
    var app = App{ .allocator = a, .io = std.testing.io, .pool = &env.pool };
    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk try collections.create(a, std.testing.io, w, .{
            .id = "",
            .name = "rnotes",
            .fields = &.{
                .{ .id = "owner", .name = "owner", .options = .{ .text = .{} } },
                .{ .id = "flag", .name = "flag", .hidden = true, .options = .{ .text = .{} } },
            },
            .viewRule = "owner = @request.auth.id",
        });
    };
    defer col.deinit(a);
    // Queue a private record envelope while metadata still exists. An anonymous
    // subscriber must never receive it via the default-allow custom topic guard.
    const frames = try snapshotFramesForTest(a, .{ .string = "gold-hidden-marker" });
    defer frames.deinit(a);
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try w.exec("DROP TABLE rnotes; DELETE FROM _collections WHERE name='rnotes';");
    }
    const anon = Conn{};
    try std.testing.expect(frameForDelivery(a, &app, &anon, null, frames.collection_channel, frames.frame_collection) == null);
    try std.testing.expect(frameForDelivery(a, &app, &anon, null, frames.record_channel, frames.frame_record) == null);
    // Public custom messages still retain their intended behavior.
    const message = "{\"type\":\"message\",\"data\":1}";
    try std.testing.expectEqualStrings(message, frameForDelivery(a, &app, &anon, null, "rnotes", message).?);
}

test "delete preparation propagates snapshot OOM and database failures before removal" {
    var env = try PoolEnv.init();
    defer env.deinit();
    const a = std.testing.allocator;
    var app = App{ .allocator = a, .io = std.testing.io, .pool = &env.pool };
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    const col = try collections.create(a, std.testing.io, w, .{
        .id = "",
        .name = "capture_notes",
        .fields = &.{.{ .id = "tier", .name = "tier", .hidden = true, .options = .{ .text = .{} } }},
    });
    defer col.deinit(a);
    try w.exec("INSERT INTO capture_notes (id,created,updated,tier) VALUES ('n1','','','gold');");
    const hook_read = (try records.get(a, w, col, "n1")).?;
    defer records.freeRecord(a, hook_read);
    try std.testing.expect(hook_read.object.get("tier") == null);
    try w.beginImmediate();
    var txn_open = true;
    defer if (txn_open) w.rollback() catch |err| std.log.err("test rollback failed: {s}", .{@errorName(err)});
    const ws = @import("ws.zig");
    try std.testing.expectError(error.OutOfMemory, ws.prepareDelete(std.testing.failing_allocator, &app, w, col, "n1", hook_read));
    // Transactional DDL makes the required capture SELECT fail without losing the
    // initial hook record. The caller must roll back, never broadcast that record.
    try w.exec("ALTER TABLE capture_notes RENAME COLUMN tier TO lost_tier;");
    try std.testing.expectError(error.PrepareFailed, ws.prepareDelete(a, &app, w, col, "n1", hook_read));
    try w.rollback();
    txn_open = false;
    const surviving = (try records.getDeleteSnapshot(a, w, col, "n1")).?;
    defer records.freeRecord(a, surviving);
    try std.testing.expectEqualStrings("gold", surviving.object.get("tier").?.string);
}

test "#499: a sandbox database failure or OutOfMemory propagates instead of denying the delete" {
    // These say the server cannot answer NOW, not that the item is unauthorizable: denying them
    // would let backfill answer 200 and advance the checkpoint past a delete the owner may see.
    // An error lets the page answer 500 and a retry of the same checkpoint deliver it.
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    const col = try typedCollection(a, &tdb, "owner = @request.auth.id");
    defer col.deinit(a);
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(a);
    try map.put(a, "id", .{ .string = "GONE" });
    try map.put(a, "owner", .{ .string = "u1" });
    var owner = try authedConn(a, "u1", false);
    defer freeConn(a, &owner);
    // Evict whatever an earlier test cached, and leave the slot empty for later tests.
    if (snapshot_sandbox) |*c| c.deinit();
    snapshot_sandbox = null;
    defer {
        if (snapshot_sandbox) |*c| c.deinit();
        snapshot_sandbox = null;
    }
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &owner, 0, .delete, "GONE", null, .{ .object = map }));

    // A SQLite failure inside the (cached) sandbox: its table is gone, so the guarded SELECT
    // cannot be prepared. Same snapshot, same key: the next delivery reuses this sandbox.
    try snapshot_sandbox.?.db.exec("DROP TABLE typed;");
    try std.testing.expectError(error.PrepareFailed, shouldDeliver(a, &tdb.d, col, &owner, 0, .delete, "GONE", null, .{ .object = map }));

    // OutOfMemory in the rule evaluation's allocator.
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, shouldDeliver(failing.allocator(), &tdb.d, col, &owner, 0, .delete, "GONE", null, .{ .object = map }));
}

test "#499: an unauthorizable delete snapshot denies at shouldDeliver for every non-superuser" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    const col = try typedCollection(a, &tdb, "owner = @request.auth.id");
    defer col.deinit(a);
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(a);
    try map.put(a, "id", .{ .string = "GONE" });
    try map.put(a, "owner", .{ .string = "u1" });
    try map.put(a, "price", .{ .string = "not-a-number" }); // cannot be stored in the fixed column
    var owner = try authedConn(a, "u1", false);
    defer freeConn(a, &owner);
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &owner, 0, .delete, "GONE", null, .{ .object = map }));
    // The superuser short-circuits before any snapshot evaluation, as for every delete.
    var su = try authedConn(a, "root", true);
    defer freeConn(a, &su);
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &su, 0, .delete, "GONE", null, .{ .object = map }));
}

test "relation delete authorization matches live delivery at signed integer boundaries" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    const a = std.testing.allocator;
    const owners = try collections.create(a, std.testing.io, &tdb.d, .{ .id = "", .name = "owners", .fields = &.{} });
    defer owners.deinit(a);
    try tdb.d.exec("INSERT INTO owners (id,created,updated) VALUES ('u1','',''),('u2','','');");
    const col = try collections.create(a, std.testing.io, &tdb.d, .{
        .id = "",
        .name = "boundary_notes",
        .fields = &.{
            .{ .id = "o1", .name = "owner", .options = .{ .relation = .{ .targetCollectionId = owners.id, .maxSelect = 1 } } },
            .{ .id = "n1", .name = "amount", .options = .{ .number = .{ .mode = .int } } },
        },
        .viewRule = "owner = @request.auth.id",
    });
    defer col.deinit(a);
    var owner = try authedConn(a, "u1", false);
    defer freeConn(a, &owner);
    var other = try authedConn(a, "u2", false);
    defer freeConn(a, &other);
    for ([_]i64{ std.math.minInt(i64), std.math.maxInt(i64) }) |amount| {
        var input: std.json.ObjectMap = .empty;
        defer input.deinit(a);
        try input.put(a, "owner", .{ .string = "u1" });
        // JSON integers bind directly on the write path; reads return decimal strings.
        try input.put(a, "amount", .{ .integer = amount });
        const created = try records.create(a, std.testing.io, &tdb.d, col, .{ .object = input });
        defer records.freeRecord(a, created);
        const rid = created.object.get("id").?.string;
        const snapshot = (try records.getDeleteSnapshot(a, &tdb.d, col, rid)).?;
        defer records.freeRecord(a, snapshot);
        try std.testing.expect(snapshot.object.get("amount").? == .string);
        const live_owner = try shouldDeliver(a, &tdb.d, col, &owner, 0, .update, rid, null, null);
        const live_other = try shouldDeliver(a, &tdb.d, col, &other, 0, .update, rid, null, null);
        try std.testing.expect(live_owner);
        try std.testing.expect(!live_other);
        try std.testing.expect(try records.deleteInTxn(a, &tdb.d, col, rid));
        try std.testing.expectEqual(live_owner, try shouldDeliver(a, &tdb.d, col, &owner, 0, .delete, rid, null, snapshot));
        try std.testing.expectEqual(live_other, try shouldDeliver(a, &tdb.d, col, &other, 0, .delete, rid, null, snapshot));
    }
}
