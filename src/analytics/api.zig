//! Tenant-scoped analytics read API (#158).
//!
//!   GET /api/analytics/events?name=&actor=&since=&limit=   — the raw activity feed
//!   GET /api/analytics/rollups/:name?from=&to=&group=       — a rollup's summary rows
//!
//! BOTH endpoints are authenticated and FAIL CLOSED. Authorization, in one place so it can't drift:
//!
//!   * Anonymous            → 401.
//!   * Superuser            → sees everything (optional filters only).
//!   * Tenancy enabled,
//!     non-superuser        → scoped to the request's ACTIVE account (verified `_memberships` row,
//!                            the same `tenancy.resolve` path the records chokepoints use). No
//!                            active account ⇒ an empty result, never another account's data.
//!   * Tenancy DISABLED,
//!     non-superuser        → the feed is scoped to the caller's OWN events (actor = self); a
//!                            rollup (a cross-tenant aggregate) is superuser-only ⇒ 403.
//!
//! A member can therefore NEVER read another account's events or rollups. The active account /
//! actor are resolved SERVER-SIDE from the verified token — never from a query/body/header value.

const std = @import("std");
const http = @import("../http.zig");
const app_mod = @import("../app.zig");
const db = @import("../db.zig");
const auth = @import("../auth.zig");
const tenancy = @import("../tenancy/tenancy.zig");
const params_mod = @import("../query/params.zig");
const analytics = @import("analytics.zig");
const ApiError = @import("../api/error.zig").ApiError;

/// Hard cap on rows returned by the feed (defends against an unbounded scan); the default is 50.
const default_limit: usize = 50;
const max_limit: usize = 200;

/// The principal resolved from the bearer/cookie token, plus the request's verified account scope.
const Scope = struct {
    is_superuser: bool,
    actor: []const u8,
    actor_collection: []const u8,
    /// Active account id (verified active membership), or "" when none / tenancy disabled.
    account: []const u8,
};

/// Authenticate + resolve the active account scope. Returns null when the request is anonymous
/// (the caller turns that into a 401). Mirrors `api/accounts.zig` (fail closed: a resolution error
/// leaves `account` empty).
fn resolveScope(ctx: *http.RequestCtx, app: *app_mod.App, conn: *db.Db) !?Scope {
    const a = (auth.authenticate(app.io, ctx.allocator, app, ctx, conn) catch null) orelse return null;
    var actor: []const u8 = "";
    if (a.record == .object) {
        if (a.record.object.get("id")) |id_v| {
            if (id_v == .string) actor = id_v.string;
        }
    }
    var account: []const u8 = "";
    if (app.tenancy.enabled and !a.is_superuser and actor.len > 0) {
        const requested = requestedAccount(ctx, app) orelse "";
        const res = tenancy.resolve(ctx.allocator, conn, a.collection, actor, requested) catch
            tenancy.Resolution{};
        account = res.account_id;
    }
    return .{ .is_superuser = a.is_superuser, .actor = actor, .actor_collection = a.collection, .account = account };
}

/// The requested account id (header, else signed cookie) — verified into a real scope only when
/// `tenancy.resolve` finds an active membership. Mirrors `api/records.zig`'s resolver.
fn requestedAccount(ctx: *http.RequestCtx, app: *app_mod.App) ?[]const u8 {
    switch (app.tenancy.resolver) {
        .header => {
            if (ctx.header(tenancy.account_header)) |h| if (h.len > 0) return h;
            if (ctx.cookie(tenancy.account_cookie)) |c| if (c.len > 0) return tenancy.verifyAccount(app.jwt_secret, c);
            return null;
        },
    }
}

/// A bound-parameter SQL builder: accumulates `WHERE` conditions and their text params so the
/// account id / filters are always bound (`?N`), never interpolated.
const Bound = struct {
    alloc: std.mem.Allocator,
    conds: std.ArrayListUnmanaged([]const u8) = .empty,
    params: std.ArrayListUnmanaged([]const u8) = .empty,

    fn add(self: *Bound, comptime col_op: []const u8, value: []const u8) !void {
        const n = self.params.items.len + 1;
        try self.conds.append(self.alloc, try std.fmt.allocPrint(self.alloc, col_op ++ " ?{d}", .{n}));
        try self.params.append(self.alloc, value);
    }

    fn whereClause(self: *Bound) ![]const u8 {
        if (self.conds.items.len == 0) return "";
        const joined = try std.mem.join(self.alloc, " AND ", self.conds.items);
        return std.fmt.allocPrint(self.alloc, " WHERE {s}", .{joined});
    }

    fn bindAll(self: *Bound, st: *db.Stmt) !void {
        for (self.params.items, 0..) |p, i| try st.bindText(@intCast(i + 1), p);
    }
};

fn emptyItems(ctx: *http.RequestCtx) !http.Response {
    _ = ctx;
    return .{ .status = 200, .body = "{\"items\":[]}" };
}

/// GET /api/analytics/events — the tenant-scoped raw activity feed.
pub fn events(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app orelse return ApiError.internal().toResponse(ctx.allocator);
    var reader = try app.pool.acquireReader();
    defer app.pool.releaseReader(&reader);

    const scope = (try resolveScope(ctx, app, &reader)) orelse
        return (ApiError{ .status = 401, .message = "Authentication required." }).toResponse(ctx.allocator);

    var b = Bound{ .alloc = ctx.allocator };

    // Base authorization scope (fail closed).
    if (scope.is_superuser) {
        // no base scope — superuser sees all events
    } else if (app.tenancy.enabled) {
        if (scope.account.len == 0) return emptyItems(ctx); // no active account ⇒ nothing
        try b.add("\"account\" =", scope.account);
    } else {
        if (scope.actor.len == 0) return emptyItems(ctx);
        try b.add("\"actor\" =", scope.actor);
        try b.add("\"actor_collection\" =", scope.actor_collection);
    }

    // Optional filters.
    const qp = params_mod.parse(ctx.allocator, ctx.query) catch params_mod.Params{ .pairs = &.{} };
    if (qp.get("name")) |v| if (v.len > 0) try b.add("\"name\" =", v);
    if (qp.get("actor")) |v| if (v.len > 0) try b.add("\"actor\" =", v);
    if (qp.get("since")) |v| if (v.len > 0) try b.add("\"occurred_at\" >=", v);

    const limit = parseLimit(qp.get("limit"));
    const where = try b.whereClause();
    const sql = try std.fmt.allocPrintSentinel(ctx.allocator, "SELECT \"id\",\"created\",\"name\",\"payload\",\"actor_collection\",\"actor\",\"account\",\"occurred_at\" " ++
        "FROM \"_events\"{s} ORDER BY \"occurred_at\" DESC, \"id\" DESC LIMIT {d};", .{ where, limit }, 0);

    var st = reader.prepare(sql) catch return emptyItems(ctx);
    defer st.finalize();
    try b.bindAll(&st);

    var items = std.json.Array.init(ctx.allocator);
    while (try st.step()) {
        var o: std.json.ObjectMap = .empty;
        try o.put(ctx.allocator, "id", .{ .string = try ctx.allocator.dupe(u8, st.columnText(0)) });
        try o.put(ctx.allocator, "created", .{ .string = try ctx.allocator.dupe(u8, st.columnText(1)) });
        try o.put(ctx.allocator, "name", .{ .string = try ctx.allocator.dupe(u8, st.columnText(2)) });
        try o.put(ctx.allocator, "payload", parsePayload(ctx.allocator, st.columnText(3)));
        try o.put(ctx.allocator, "actor_collection", .{ .string = try ctx.allocator.dupe(u8, st.columnText(4)) });
        try o.put(ctx.allocator, "actor", .{ .string = try ctx.allocator.dupe(u8, st.columnText(5)) });
        try o.put(ctx.allocator, "account", .{ .string = try ctx.allocator.dupe(u8, st.columnText(6)) });
        try o.put(ctx.allocator, "occurred_at", .{ .string = try ctx.allocator.dupe(u8, st.columnText(7)) });
        try items.append(.{ .object = o });
    }
    return wrapItems(ctx, items);
}

/// GET /api/analytics/rollups/:name — a rollup's tenant-scoped summary rows.
pub fn rollups(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app orelse return ApiError.internal().toResponse(ctx.allocator);
    const name = ctx.param("name") orelse return ApiError.notFound().toResponse(ctx.allocator);

    // The rollup must be DECLARED (and `name` a safe identifier) — else 404 (no table-name oracle).
    const reg = analytics.registryFromApp(app) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const spec = reg.byName(name) orelse return ApiError.notFound().toResponse(ctx.allocator);

    var reader = try app.pool.acquireReader();
    defer app.pool.releaseReader(&reader);

    const scope = (try resolveScope(ctx, app, &reader)) orelse
        return (ApiError{ .status = 401, .message = "Authentication required." }).toResponse(ctx.allocator);

    var b = Bound{ .alloc = ctx.allocator };
    if (scope.is_superuser) {
        // superuser sees all buckets
    } else if (app.tenancy.enabled and spec.group_account) {
        if (scope.account.len == 0) return emptyItems(ctx);
        try b.add("\"account\" =", scope.account);
    } else {
        // A non-account-grouped rollup is a cross-tenant aggregate; tenancy-disabled apps have no
        // per-account separation either. Either way a non-superuser must not read it. Fail closed.
        return (ApiError{ .status = 403, .message = "Forbidden." }).toResponse(ctx.allocator);
    }

    const qp = params_mod.parse(ctx.allocator, ctx.query) catch params_mod.Params{ .pairs = &.{} };
    if (qp.get("from")) |v| if (v.len > 0) try b.add("\"bucket\" >=", v);
    if (qp.get("to")) |v| if (v.len > 0) try b.add("\"bucket\" <=", v);

    const table = analytics.summaryTable(ctx.allocator, name) catch
        return ApiError.notFound().toResponse(ctx.allocator);
    const where = try b.whereClause();
    const sql = try std.fmt.allocPrintSentinel(ctx.allocator, "SELECT \"bucket\",\"account\",\"actor\",\"value\",\"computed_at\" FROM \"{s}\"{s} " ++
        "ORDER BY \"bucket\" DESC, \"account\", \"actor\";", .{ table, where }, 0);

    // The summary table is created lazily on the first rollup run; until then, return an empty set.
    var st = reader.prepare(sql) catch return emptyItems(ctx);
    defer st.finalize();
    try b.bindAll(&st);

    var items = std.json.Array.init(ctx.allocator);
    while (try st.step()) {
        var o: std.json.ObjectMap = .empty;
        try o.put(ctx.allocator, "bucket", .{ .string = try ctx.allocator.dupe(u8, st.columnText(0)) });
        try o.put(ctx.allocator, "account", .{ .string = try ctx.allocator.dupe(u8, st.columnText(1)) });
        try o.put(ctx.allocator, "actor", .{ .string = try ctx.allocator.dupe(u8, st.columnText(2)) });
        try o.put(ctx.allocator, "value", .{ .integer = st.columnInt(3) });
        try o.put(ctx.allocator, "computed_at", .{ .string = try ctx.allocator.dupe(u8, st.columnText(4)) });
        try items.append(.{ .object = o });
    }
    return wrapItems(ctx, items);
}

fn wrapItems(ctx: *http.RequestCtx, items: std.json.Array) !http.Response {
    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator, "items", .{ .array = items });
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.allocator, std.json.Value{ .object = root }, .{}) };
}

/// Parse the stored payload text back into a JSON value for the response; a non-JSON payload (or an
/// empty cell) renders as JSON null rather than failing the whole feed.
fn parsePayload(alloc: std.mem.Allocator, text: []const u8) std.json.Value {
    if (text.len == 0) return .null;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch return .null;
    return parsed.value;
}

fn parseLimit(raw: ?[]const u8) usize {
    const v = raw orelse return default_limit;
    const n = std.fmt.parseInt(usize, v, 10) catch return default_limit;
    if (n == 0) return default_limit;
    return @min(n, max_limit);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseLimit clamps to [1,200] with a default of 50" {
    try std.testing.expectEqual(@as(usize, 50), parseLimit(null));
    try std.testing.expectEqual(@as(usize, 50), parseLimit("0"));
    try std.testing.expectEqual(@as(usize, 50), parseLimit("notanumber"));
    try std.testing.expectEqual(@as(usize, 10), parseLimit("10"));
    try std.testing.expectEqual(@as(usize, 200), parseLimit("9999"));
}

test "parsePayload: valid JSON round-trips; empty/garbage -> null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(parsePayload(a, "") == .null);
    try std.testing.expect(parsePayload(a, "not json") == .null);
    const v = parsePayload(a, "{\"plan\":\"pro\"}");
    try std.testing.expect(v == .object);
    try std.testing.expectEqualStrings("pro", v.object.get("plan").?.string);
}

test "Bound builds a parameterized WHERE and binds in order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b = Bound{ .alloc = arena.allocator() };
    try std.testing.expectEqualStrings("", try b.whereClause());
    try b.add("\"account\" =", "acc1");
    try b.add("\"name\" =", "user.signup");
    try std.testing.expectEqualStrings(" WHERE \"account\" = ?1 AND \"name\" = ?2", try b.whereClause());
    try std.testing.expectEqual(@as(usize, 2), b.params.items.len);
    try std.testing.expectEqualStrings("acc1", b.params.items[0]);
}

// --- End-to-end tenant-scoping tests (the security-critical read path) -------
// These exercise the FULL handler (auth.authenticate + tenancy.resolve + the scoped query),
// proving a member of account A can never read account B's events or rollups.

const migrations = @import("../migrations.zig");
const collections = @import("../collections.zig");
const records = @import("../records.zig");
const api_auth = @import("../api/auth.zig");

const TenantTestEnv = struct {
    tmp: std.testing.TmpDir,
    pool: db.Pool,
    arena: std.heap.ArenaAllocator,
    app: app_mod.App,
    bearer: []const u8, // "Bearer <token>" for u1 (active member of accA only)

    fn init() !*TenantTestEnv {
        const gpa = std.testing.allocator;
        const env = try gpa.create(TenantTestEnv);
        env.tmp = std.testing.tmpDir(.{});
        env.arena = std.heap.ArenaAllocator.init(gpa);
        const a = env.arena.allocator();
        const dir = try env.tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        const path = try std.fmt.allocPrintSentinel(a, "{s}/t.db", .{dir}, 0);
        env.pool = try db.Pool.init(gpa, std.testing.io, path);
        env.app = .{
            .allocator = gpa,
            .io = std.testing.io,
            .pool = &env.pool,
            .tenancy = .{ .enabled = true, .resolver = .header, .auth_collection = "users" },
        };

        var u_id: []const u8 = "";
        var u_tk: []const u8 = "";
        {
            const w = env.pool.acquireWriter();
            defer env.pool.releaseWriter();
            try migrations.run(w);
            _ = try collections.create(a, std.testing.io, w, .{ .id = "", .name = "users", .type = .auth, .fields = &.{} });
            const users_col = (try collections.get(a, w, "users")).?;
            var ud: std.json.ObjectMap = .empty;
            try ud.put(a, "email", .{ .string = "u1@x.io" });
            try ud.put(a, "password", .{ .string = "longenough" });
            const prepared = try auth.applyCreate(std.testing.io, a, .{ .object = ud }, users_col.options.auth.minPasswordLength);
            _ = try records.create(a, std.testing.io, w, users_col, prepared);

            var st = try w.prepare("SELECT id, tokenKey FROM users WHERE email='u1@x.io';");
            _ = try st.step();
            u_id = try a.dupe(u8, st.columnText(0));
            u_tk = try a.dupe(u8, st.columnText(1));
            st.finalize();

            var ins = try w.prepare("INSERT INTO _memberships (id,created,updated,account,user_collection,user,role,status) VALUES ('m1','','','accA','users',?1,'owner','active');");
            try ins.bindText(1, u_id);
            _ = try ins.step();
            ins.finalize();
        }

        var mintctx = http.RequestCtx{ .method = .POST, .path = "/", .allocator = a, .app = &env.app };
        const tok = blk: {
            const w = env.pool.acquireWriter();
            defer env.pool.releaseWriter();
            break :blk try api_auth.mintToken(&mintctx, w, "users", u_id, u_tk, .auth, 100000, "");
        };
        env.bearer = try std.fmt.allocPrint(a, "Bearer {s}", .{tok});
        return env;
    }

    fn deinit(env: *TenantTestEnv) void {
        env.pool.deinit();
        env.arena.deinit();
        env.tmp.cleanup();
        std.testing.allocator.destroy(env);
    }
};

test "events read is tenant-scoped: a member sees only their account's events" {
    var env = try TenantTestEnv.init();
    defer env.deinit();
    const a = env.arena.allocator();
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try w.exec("INSERT INTO \"_events\" (id,created,updated,name,payload,actor_collection,actor,account,occurred_at) VALUES " ++
            "('eA','t','t','user.signup','{}','users','u1','accA','2026-01-01T00:00:00Z')," ++
            "('eB','t','t','user.signup','{}','users','uX','accB','2026-01-01T00:00:00Z');");
    }
    // u1 is an active member of accA only, asking (via the header) to act within accA.
    const hdrs = [_]http.Param{.{ .key = "x-account-id", .value = "accA" }};
    var ctx = http.RequestCtx{ .method = .GET, .path = "/api/analytics/events", .allocator = a, .app = &env.app, .authorization = env.bearer, .headers = &hdrs };
    const res = try events(&ctx);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    // accA's event is visible; accB's is NOT (no cross-tenant leak).
    try std.testing.expect(std.mem.indexOf(u8, res.body, "eA") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "eB") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "accB") == null);
}

test "events read fails closed: a member who did not activate an account sees nothing" {
    var env = try TenantTestEnv.init();
    defer env.deinit();
    const a = env.arena.allocator();
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try w.exec("INSERT INTO \"_events\" (id,created,updated,name,payload,actor_collection,actor,account,occurred_at) VALUES " ++
            "('eA','t','t','user.signup','{}','users','u1','accA','2026-01-01T00:00:00Z');");
    }
    // No X-Account-Id header → no active account resolved → empty (fail closed), even though
    // u1 IS a member of accA. Activation is required to scope.
    var ctx = http.RequestCtx{ .method = .GET, .path = "/api/analytics/events", .allocator = a, .app = &env.app, .authorization = env.bearer };
    const res = try events(&ctx);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "eA") == null);
}

test "events read requires authentication (anonymous -> 401)" {
    var env = try TenantTestEnv.init();
    defer env.deinit();
    const a = env.arena.allocator();
    var ctx = http.RequestCtx{ .method = .GET, .path = "/api/analytics/events", .allocator = a, .app = &env.app };
    const res = try events(&ctx);
    try std.testing.expectEqual(@as(u16, 401), res.status);
}

test "rollups read is tenant-scoped: a member sees only their account's summary rows" {
    var env = try TenantTestEnv.init();
    defer env.deinit();
    const a = env.arena.allocator();
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try w.exec("CREATE TABLE \"_rollup_signups_daily\" (bucket TEXT, account TEXT, actor TEXT, value INTEGER, computed_at TEXT, PRIMARY KEY(bucket,account,actor));");
        try w.exec("INSERT INTO \"_rollup_signups_daily\" VALUES ('2026-01-01','accA','',5,'t'),('2026-01-01','accB','',9,'t');");
    }
    const reg = analytics.Registry{ .rollups = &.{.{
        .name = "signups_daily",
        .event = "user.signup",
        .every = .{ .interval = .hourly },
        .group_account = true,
        .group_actor = false,
        .time_bucket = .day,
        .metric = .count,
    }} };
    env.app.analytics = @ptrCast(&reg);

    const hdrs = [_]http.Param{.{ .key = "x-account-id", .value = "accA" }};
    const params = [_]http.Param{.{ .key = "name", .value = "signups_daily" }};
    var ctx = http.RequestCtx{ .method = .GET, .path = "/api/analytics/rollups/signups_daily", .allocator = a, .app = &env.app, .authorization = env.bearer, .headers = &hdrs, .params = &params };
    const res = try rollups(&ctx);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    // accA's bucket (value 5) is visible; accB's (value 9) is NOT.
    try std.testing.expect(std.mem.indexOf(u8, res.body, "accA") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "accB") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"value\":9") == null);
}

test "rollups read 404s for an undeclared rollup name" {
    var env = try TenantTestEnv.init();
    defer env.deinit();
    const a = env.arena.allocator();
    const reg = analytics.Registry{ .rollups = &.{} };
    env.app.analytics = @ptrCast(&reg);
    const params = [_]http.Param{.{ .key = "name", .value = "ghost" }};
    var ctx = http.RequestCtx{ .method = .GET, .path = "/api/analytics/rollups/ghost", .allocator = a, .app = &env.app, .authorization = env.bearer, .params = &params };
    const res = try rollups(&ctx);
    try std.testing.expectEqual(@as(u16, 404), res.status);
}
