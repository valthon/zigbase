//! Route-level PostgreSQL parity for the verified-sender and analytics endpoints (#487).
//!
//! `GET/POST /api/senders`, `POST /api/senders/:id/verify`, `GET /api/analytics/events` and
//! `GET /api/analytics/rollups/:name` answered 500 on `-Dpostgres=true`: `mail/senders.zig` and
//! `analytics/api.zig` sent SQLite `?N` placeholders (and `datetime('now')`/`julianday(...)`) to
//! PostgreSQL unlowered, and the rollups read relied on SQLite failing at PREPARE for a summary
//! table that has not been created yet — PostgreSQL prepares lazily, so the missing table surfaced
//! at the first `step()` instead and escaped as `StepFailed`.
//!
//! One scenario drives every handler through a real `db.Pool` and asserts exact responses. It runs
//! against SQLite (the reference, in every build) and against a live PostgreSQL, so the two
//! backends must agree. The PostgreSQL arm uses a dedicated per-run database (pool connections
//! cannot inherit a per-test `search_path`), dropped on teardown. That database is created with a
//! non-byte-order ICU collation and a far-from-UTC session `TimeZone`, the two settings under which
//! text ordering and the resend-throttle age could diverge from SQLite (on a server without
//! database-level ICU locales, PostgreSQL 14 and older or a non-ICU build, the database takes the
//! server default and the locale premise is not asserted). The PostgreSQL tests skip when
//! `-Dpostgres` is off, `ZIGBASE_PG_TEST_URL` is unset or unreachable, or the role cannot create
//! the database or schema it needs.

const std = @import("std");
const db = @import("../../db.zig");
const migrations = @import("../../migrations.zig");
const http = @import("../../http.zig");
const RequestArena = @import("../../request_arena.zig").RequestArena;
const app_mod = @import("../../app.zig");
const crypto = @import("../../crypto.zig");
const jwt = @import("../../jwt.zig");
const tenancy = @import("../../tenancy/tenancy.zig");
const senders_api = @import("../../api/senders.zig");
const analytics = @import("../../analytics/analytics.zig");
const analytics_api = @import("../../analytics/api.zig");
const collections = @import("../../collections.zig");
const records = @import("../../records.zig");
const auth = @import("../../auth.zig");

const testing = std.testing;
const secret = "pg-487-routes-secret-0123456789ab";
const pg_enabled = @import("build_options").postgres;

const Handler = *const fn (*http.RequestCtx) anyerror!http.Response;

const Reply = struct {
    status: u16,
    json: std.json.Value,
};

/// Calls one handler as the server would: a fresh request arena, the superuser bearer token, and
/// the given query/body/path params. The response body is parsed onto `out` (the scenario arena).
const Client = struct {
    app: *app_mod.App,
    out: std.mem.Allocator,
    authorization: []const u8,

    fn call(self: Client, handler: Handler, method: http.Method, query: []const u8, body: []const u8, params: []const http.Param) !Reply {
        // The handler's response graph lives on its own request arena (contract 4), a child of
        // the scenario arena so the parsed reply can outlive it.
        var arena = std.heap.ArenaAllocator.init(self.out);
        defer arena.deinit();
        var ctx = http.RequestCtx{
            .method = method,
            .path = "/",
            .query = query,
            .body = body,
            .allocator = RequestArena.from(&arena),
            .app = self.app,
            .params = params,
            .authorization = self.authorization,
            .headers = &.{.{ .key = tenancy.account_header, .value = "acc1" }},
        };
        const res = try handler(&ctx);
        const json = try std.json.parseFromSliceLeaky(std.json.Value, self.out, res.body, .{ .allocate = .alloc_always });
        return .{ .status = res.status, .json = json };
    }
};

fn str(v: std.json.Value, key: []const u8) []const u8 {
    return v.object.get(key).?.string;
}

fn items(v: std.json.Value) []std.json.Value {
    return v.object.get("items").?.array.items;
}

fn expectIds(reply: Reply, want: []const []const u8) !void {
    try testing.expectEqual(@as(u16, 200), reply.status);
    const got = items(reply.json);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, str(g, "id"));
}

/// Set every sender row's `updated` stamp to the text `value` (test-only literal SQL).
fn setUpdated(pool: *db.Pool, out: std.mem.Allocator, value: []const u8) !void {
    const w = pool.acquireWriter();
    defer pool.releaseWriter();
    try w.exec(try std.fmt.allocPrintSentinel(out, "UPDATE \"_sender_identities\" SET \"updated\"={s};", .{value}, 0));
}

fn expectRollups(reply: Reply, want: []const struct { []const u8, []const u8, i64 }) !void {
    try testing.expectEqual(@as(u16, 200), reply.status);
    const got = items(reply.json);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqualStrings(w[0], str(g, "bucket"));
        try testing.expectEqualStrings(w[1], str(g, "account"));
        try testing.expectEqual(w[2], g.object.get("value").?.integer);
    }
}

/// Create a `users` auth collection with one user who is an active member of `acc1`, and return a
/// bearer token for that user (a non-superuser, so the handlers apply their account scope).
fn memberBearer(pool: *db.Pool, out: std.mem.Allocator) ![]const u8 {
    const w = pool.acquireWriter();
    defer pool.releaseWriter();
    _ = try collections.create(out, testing.io, w, .{ .id = "", .name = "users", .type = .auth, .fields = &.{} });
    const col = (try collections.get(out, w, "users")).?;
    var data: std.json.ObjectMap = .empty;
    try data.put(out, "email", .{ .string = "member@example.com" });
    try data.put(out, "password", .{ .string = "correct horse battery" });
    const prepared = try auth.applyCreate(testing.io, out, .{ .object = data }, col.options.auth.minPasswordLength);
    const rec = try records.create(out, testing.io, w, col, prepared);
    const uid = rec.object.get("id").?.string;
    const token_key = rec.object.get("tokenKey") orelse blk: {
        const sql = try std.fmt.allocPrintSentinel(out, "SELECT \"tokenKey\" FROM \"users\" WHERE \"id\"='{s}';", .{uid}, 0);
        var st = try w.prepare(sql);
        defer st.finalize();
        try testing.expect(try st.step());
        break :blk std.json.Value{ .string = try out.dupe(u8, st.columnText(0)) };
    };
    try w.exec(try std.fmt.allocPrintSentinel(out, "INSERT INTO \"_memberships\" (\"id\",\"created\",\"updated\",\"account\",\"user_collection\",\"user\",\"role\",\"status\") " ++
        "VALUES ('m1','','','acc1','users','{s}','member','active');", .{uid}, 0));
    const key = crypto.deriveKey(secret, token_key.string);
    const token = try jwt.sign(out, .{ .id = uid, .collection = "users", .type = .auth, .iat = 1, .exp = 9999999999 }, &key);
    return std.fmt.allocPrint(out, "Bearer {s}", .{token});
}

fn tokenFor(conn: *db.Db, out: std.mem.Allocator, id: []const u8) ![]const u8 {
    // Ids are server-minted base36; interpolating one into a test-only literal is safe.
    const sql = try std.fmt.allocPrintSentinel(out, "SELECT \"verification_token\" FROM \"_sender_identities\" WHERE \"id\"='{s}';", .{id}, 0);
    var st = try conn.prepare(sql);
    defer st.finalize();
    try testing.expect(try st.step());
    return out.dupe(u8, st.columnText(0));
}

/// The whole route scenario. `pool` is a freshly migrated, empty database on either backend.
fn runScenario(pool: *db.Pool) !void {
    var scenario = std.heap.ArenaAllocator.init(testing.allocator);
    defer scenario.deinit();
    const out = scenario.allocator();
    const backend = db.poolBackend(pool);

    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try w.exec("INSERT INTO \"_superusers\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('su1','','','root@example.com','su-token-key',1);");
        try w.exec("INSERT INTO \"_events\" (\"id\",\"created\",\"updated\",\"name\",\"payload\",\"actor_collection\",\"actor\",\"account\",\"occurred_at\") VALUES " ++
            "('e1','t','t','user.signup','{\"n\":1}','users','u1','acc1','2026-01-01T08:00:00Z')," ++
            "('e2','t','t','user.signup','{}','users','u2','acc1','2026-01-01T09:00:00Z')," ++
            "('e3','t','t','user.signup','{}','users','u1','acc2','2026-01-02T10:00:00Z')," ++
            "('e4','t','t','other.event','{}','users','u1','acc1','2026-01-02T10:00:00Z')," ++
            "('e5','t','t','user.signup','{}','users','u1','acc1','2026-01-03T00:00:00Z');");
    }

    const key = crypto.deriveKey(secret, "su-token-key");
    const token = try jwt.sign(out, .{ .id = "su1", .collection = "_superusers", .type = .auth, .iat = 1, .exp = 9999999999 }, &key);

    const registry = analytics.Registry{ .rollups = &.{.{
        .name = "signups_daily",
        .event = "user.signup",
        .every = .{ .interval = .hourly },
        .group_account = true,
        .group_actor = false,
        .time_bucket = .day,
        .metric = .count,
    }} };
    var app = app_mod.App{
        .allocator = testing.allocator,
        .io = testing.io,
        .pool = pool,
        .jwt_secret = secret,
        .tenancy = .{ .enabled = true, .resolver = .header, .auth_collection = "users" },
    };
    app.analytics = @ptrCast(&registry);
    const c = Client{ .app = &app, .out = out, .authorization = try std.fmt.allocPrint(out, "Bearer {s}", .{token}) };
    const member = Client{ .app = &app, .out = out, .authorization = try memberBearer(pool, out) };

    // ---- senders: list, create, throttle, re-issue, verify, list, already-verified ----
    {
        const empty = try c.call(senders_api.list, .GET, "", "", &.{});
        try testing.expectEqual(@as(u16, 200), empty.status);
        try testing.expectEqual(@as(usize, 0), items(empty.json).len);

        const created = try c.call(senders_api.create, .POST, "", "{\"email\":\"From@App.com\"}", &.{});
        try testing.expectEqual(@as(u16, 201), created.status);
        try testing.expectEqualStrings("from@app.com", str(created.json, "email"));
        try testing.expectEqualStrings("pending", str(created.json, "status"));
        const sid = str(created.json, "id");

        // An immediate re-request is inside the resend window: the row's age (seconds since
        // `updated`, computed in SQL) is ~0.
        const throttled = try c.call(senders_api.create, .POST, "", "{\"email\":\"from@app.com\"}", &.{});
        try testing.expectEqual(@as(u16, 429), throttled.status);

        // A stamp in SQLite's `datetime('now')` form (the shape `migrate-db` copies over) is read as
        // UTC: on PostgreSQL the session TimeZone is UTC+14 here, and reading the stamp as local
        // time would age it by 14 hours and lift the throttle.
        try setUpdated(pool, out, switch (backend) {
            .sqlite => "datetime('now')",
            .postgres => "to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI:SS')",
        });
        const throttled_sqlite_form = try c.call(senders_api.create, .POST, "", "{\"email\":\"from@app.com\"}", &.{});
        try testing.expectEqual(@as(u16, 429), throttled_sqlite_form.status);

        // A stamp that is not a date-time reads as age 0 on both backends (SQLite's `julianday` is
        // NULL): still throttled, never a 500. A valid old date-time followed by other text is not
        // a date-time either: PostgreSQL must not read an age from its prefix and lift the throttle.
        for ([_][]const u8{ "''", "'garbage'", "'2026-13-01 00:00:00'", "'2000-01-01 00:00:00junk'" }) |bad| {
            try setUpdated(pool, out, bad);
            const r = try c.call(senders_api.create, .POST, "", "{\"email\":\"from@app.com\"}", &.{});
            try testing.expectEqual(@as(u16, 429), r.status);
        }
        // Year 0000 is a date to `julianday` (an age of ~2026 years: re-issued) but out of range
        // for a PostgreSQL timestamp, which reads it as not a date-time (throttled). Never a 500.
        try setUpdated(pool, out, "'0000-06-01 00:00:00'");
        const year_zero = try c.call(senders_api.create, .POST, "", "{\"email\":\"from@app.com\"}", &.{});
        try testing.expectEqual(@as(u16, switch (backend) {
            .sqlite => 201,
            .postgres => 429,
        }), year_zero.status);

        // Age the row past the window: the same row gets a fresh token.
        const first_token = blk: {
            const w = pool.acquireWriter();
            defer pool.releaseWriter();
            const t = try tokenFor(w, out, sid);
            try w.exec("UPDATE \"_sender_identities\" SET \"updated\"='2000-01-01T00:00:00Z';");
            break :blk t;
        };
        const reissued = try c.call(senders_api.create, .POST, "", "{\"email\":\"from@app.com\"}", &.{});
        try testing.expectEqual(@as(u16, 201), reissued.status);
        try testing.expectEqualStrings(sid, str(reissued.json, "id"));
        const tok = blk: {
            const w2 = pool.acquireWriter();
            defer pool.releaseWriter();
            break :blk try tokenFor(w2, out, sid);
        };
        try testing.expect(!std.mem.eql(u8, first_token, tok));

        const params = [_]http.Param{.{ .key = "id", .value = sid }};
        const wrong = try c.call(senders_api.verify, .POST, "", "{\"token\":\"not-the-token\"}", &params);
        try testing.expectEqual(@as(u16, 404), wrong.status);
        const body = try std.fmt.allocPrint(out, "{{\"token\":\"{s}\"}}", .{tok});
        const ok = try c.call(senders_api.verify, .POST, "", body, &params);
        try testing.expectEqual(@as(u16, 200), ok.status);
        try testing.expect(ok.json.object.get("verified").?.bool);

        const listed = try c.call(senders_api.list, .GET, "", "", &.{});
        try testing.expectEqual(@as(u16, 200), listed.status);
        const rows = items(listed.json);
        try testing.expectEqual(@as(usize, 1), rows.len);
        try testing.expectEqualStrings(sid, str(rows[0], "id"));
        try testing.expectEqualStrings("verified", str(rows[0], "status"));
        // `verified_at` is each backend's `now` text: SQLite `YYYY-MM-DD HH:MM:SS`, PostgreSQL
        // ISO-8601 `YYYY-MM-DDTHH:MM:SSZ` (the engine-wide `nowTextExpr` convention).
        const verified_at = str(rows[0], "verified_at");
        switch (backend) {
            .sqlite => {
                try testing.expectEqual(@as(usize, 19), verified_at.len);
                try testing.expectEqual(@as(u8, ' '), verified_at[10]);
            },
            .postgres => {
                try testing.expectEqual(@as(usize, 20), verified_at.len);
                try testing.expectEqual(@as(u8, 'T'), verified_at[10]);
                try testing.expectEqual(@as(u8, 'Z'), verified_at[19]);
            },
        }

        // A member of acc1 (not a superuser) lists through the `"account"=$1` scope.
        const as_member = try member.call(senders_api.list, .GET, "", "", &.{});
        try testing.expectEqual(@as(u16, 200), as_member.status);
        try testing.expectEqual(@as(usize, 1), items(as_member.json).len);
        try testing.expectEqualStrings(sid, str(items(as_member.json)[0], "id"));

        const again = try c.call(senders_api.create, .POST, "", "{\"email\":\"from@app.com\"}", &.{});
        try testing.expectEqual(@as(u16, 200), again.status);
        try testing.expectEqualStrings("verified", str(again.json, "status"));
    }

    // ---- analytics events: keyset pagination over (occurred_at DESC, id DESC) + filters ----
    {
        const p1 = try c.call(analytics_api.events, .GET, "limit=2", "", &.{});
        try expectIds(p1, &.{ "e5", "e4" });
        try testing.expect(p1.json.object.get("hasNext").?.bool);
        const cur1 = str(p1.json, "nextCursor");
        try testing.expectEqualStrings("2026-01-02T10:00:00Z|e4", cur1);

        const p2 = try c.call(analytics_api.events, .GET, try std.fmt.allocPrint(out, "limit=2&cursor={s}", .{cur1}), "", &.{});
        try expectIds(p2, &.{ "e3", "e2" });
        const cur2 = str(p2.json, "nextCursor");
        try testing.expectEqualStrings("2026-01-01T09:00:00Z|e2", cur2);

        const p3 = try c.call(analytics_api.events, .GET, try std.fmt.allocPrint(out, "limit=2&cursor={s}", .{cur2}), "", &.{});
        try expectIds(p3, &.{"e1"});
        try testing.expect(!p3.json.object.get("hasNext").?.bool);
        try testing.expect(p3.json.object.get("nextCursor").? == .null);
        try testing.expectEqual(@as(i64, 1), items(p3.json)[0].object.get("payload").?.object.get("n").?.integer);

        const filtered = try c.call(analytics_api.events, .GET, "name=user.signup&actor=u1&since=2026-01-02", "", &.{});
        try expectIds(filtered, &.{ "e5", "e3" });

        // Range filters compare bytewise on both backends: `Z` (0x5A) sorts before `z` (0x7A), so
        // e3 (`...10:00:00Z`) is below the lowercase bound. A locale collation would include it.
        const lower_z = try c.call(analytics_api.events, .GET, "name=user.signup&actor=u1&since=2026-01-02T10:00:00z", "", &.{});
        try expectIds(lower_z, &.{"e5"});

        // A member of acc1 sees only acc1's events (`"account" = $1`, the clause in #487's log).
        const scoped = try member.call(analytics_api.events, .GET, "", "", &.{});
        try expectIds(scoped, &.{ "e5", "e4", "e2", "e1" });

        const bad = try c.call(analytics_api.events, .GET, "cursor=nope", "", &.{});
        try testing.expectEqual(@as(u16, 400), bad.status);
    }

    // ---- analytics rollups: before the first run (no summary table), then after ----
    {
        const name = [_]http.Param{.{ .key = "name", .value = "signups_daily" }};
        const before = try c.call(analytics_api.rollups, .GET, "", "", &name);
        try testing.expectEqual(@as(u16, 200), before.status);
        try testing.expectEqual(@as(usize, 0), items(before.json).len);

        {
            const w = pool.acquireWriter();
            defer pool.releaseWriter();
            // Two accounts whose order depends on the collation: bytewise `B` < `a`.
            try w.exec("INSERT INTO \"_events\" (\"id\",\"created\",\"updated\",\"name\",\"payload\",\"actor_collection\",\"actor\",\"account\",\"occurred_at\") VALUES " ++
                "('e6','t','t','user.signup','{}','users','u3','a','2025-12-31T00:00:00Z')," ++
                "('e7','t','t','user.signup','{}','users','u4','B','2025-12-31T00:00:00Z');");
            try analytics.runRollup(w, testing.allocator, registry.rollups[0]);
        }

        const all = try c.call(analytics_api.rollups, .GET, "", "", &name);
        try expectRollups(all, &.{
            .{ "2026-01-03", "acc1", 1 },
            .{ "2026-01-02", "acc2", 1 },
            .{ "2026-01-01", "acc1", 2 },
            .{ "2025-12-31", "B", 1 },
            .{ "2025-12-31", "a", 1 },
        });

        const scoped = try member.call(analytics_api.rollups, .GET, "", "", &name);
        try expectRollups(scoped, &.{
            .{ "2026-01-03", "acc1", 1 },
            .{ "2026-01-01", "acc1", 2 },
        });

        const ranged = try c.call(analytics_api.rollups, .GET, "from=2026-01-02&to=2026-01-02", "", &name);
        try testing.expectEqual(@as(u16, 200), ranged.status);
        const r = items(ranged.json);
        try testing.expectEqual(@as(usize, 1), r.len);
        try testing.expectEqualStrings("acc2", str(r[0], "account"));

        const missing = try c.call(analytics_api.rollups, .GET, "", "", &.{.{ .key = "name", .value = "nope" }});
        try testing.expectEqual(@as(u16, 404), missing.status);
    }
}

test "senders + analytics routes: SQLite reference run" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/routes.db", .{dir}, 0);
    defer testing.allocator.free(path);
    var pool = try db.Pool.init(testing.allocator, testing.io, path);
    defer pool.deinit();
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try migrations.run(w);
    }
    try runScenario(&pool);
}

/// `url` with its database path segment replaced by `name` (query string kept).
fn withDatabase(a: std.mem.Allocator, url: []const u8, name: []const u8) ![:0]u8 {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
    const slash = std.mem.lastIndexOfScalar(u8, url[0..q], '/') orelse return error.BadTestUrl;
    return std.fmt.allocPrintSentinel(a, "{s}/{s}{s}", .{ url[0..slash], name, url[q..] }, 0);
}

/// Whether the connected role may run CREATE DATABASE (a superuser or CREATEDB role).
fn canCreateDatabase(conn: *db.Db) !bool {
    var st = try conn.prepare("SELECT 1 FROM pg_roles WHERE rolname = current_user AND (rolsuper OR rolcreatedb);");
    defer st.finalize();
    return st.step();
}

test "senders + analytics routes: PostgreSQL matches SQLite (#487)" {
    if (comptime !pg_enabled) return error.SkipZigTest;
    const url = testing.environ.getPosix("ZIGBASE_PG_TEST_URL") orelse return error.SkipZigTest;
    var admin = db.Db.openPostgres(testing.allocator, testing.io, url) catch return error.SkipZigTest;
    defer admin.close();
    if (!try canCreateDatabase(&admin)) return error.SkipZigTest;

    // A per-run name, so concurrent runs against one server never drop each other's database.
    const suffix = try crypto.genHex(testing.io, testing.allocator, 12);
    defer testing.allocator.free(suffix);
    const name = try std.fmt.allocPrint(testing.allocator, "zb_pg487_{s}", .{suffix});
    defer testing.allocator.free(name);
    // ICU `en-US` orders `a` before `B` and `z` before `Z` (unlike byte order), and Kiritimati is
    // UTC+14: the settings under which an uncollated ORDER BY or a zone-dependent age would differ.
    // A database-level ICU locale needs PostgreSQL 15+ built with ICU; without it the database
    // gets the server's default locale and the locale premise below is not asserted.
    const icu = try hasIcuDatabaseLocale(&admin);
    const create = try std.fmt.allocPrintSentinel(testing.allocator, "CREATE DATABASE {s} TEMPLATE template0{s};", .{
        name, if (icu) " LOCALE_PROVIDER icu ICU_LOCALE 'en-US' LOCALE 'C'" else "",
    }, 0);
    defer testing.allocator.free(create);
    const tz = try std.fmt.allocPrintSentinel(testing.allocator, "ALTER DATABASE {s} SET timezone TO 'Pacific/Kiritimati';", .{name}, 0);
    defer testing.allocator.free(tz);
    const drop = try std.fmt.allocPrintSentinel(testing.allocator, "DROP DATABASE IF EXISTS {s} WITH (FORCE);", .{name}, 0);
    defer testing.allocator.free(drop);

    try admin.exec(create);
    defer admin.exec(drop) catch |err| std.log.err("pg 487 cleanup failed: {s}", .{@errorName(err)});
    try admin.exec(tz);

    const target = try withDatabase(testing.allocator, url, name);
    defer testing.allocator.free(target);
    var pool = try db.Pool.init(testing.allocator, testing.io, target);
    defer pool.deinit();
    try testing.expectEqual(db.Backend.postgres, db.poolBackend(&pool));
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        {
            // The scenario's premises hold on this database: a locale order and a non-UTC session.
            var st = try w.prepare("SELECT current_setting('TimeZone'), CASE WHEN 'a' < 'B' THEN 'locale' ELSE 'bytes' END;");
            defer st.finalize();
            try testing.expect(try st.step());
            try testing.expectEqualStrings("Pacific/Kiritimati", st.columnText(0));
            if (icu) try testing.expectEqualStrings("locale", st.columnText(1));
        }
        try migrations.run(w);
        try expectCollationUpgrade(w);
    }
    try runScenario(&pool);
}

/// Whether this server can create a database with an ICU locale (PostgreSQL 15+ with ICU, which
/// ships the `en-US` ICU collation).
fn hasIcuDatabaseLocale(conn: *db.Db) !bool {
    var st = try conn.prepare("SELECT (current_setting('server_version_num')::int >= 150000 " ++
        "AND EXISTS (SELECT 1 FROM pg_collation WHERE collprovider = 'i' AND collname = 'en-US-x-icu'))::int;");
    defer st.finalize();
    try testing.expect(try st.step());
    return st.columnInt(0) != 0;
}

/// Count the TEXT columns of the tables `rels` names (a list of `'"t"'::regclass`) whose collation
/// is not "C".
fn uncollatedTextColumns(w: *db.Db, comptime rels: []const u8) !i64 {
    var st = try w.prepare("SELECT count(*) FROM pg_attribute WHERE attrelid IN (" ++ rels ++ ") " ++
        "AND attnum > 0 AND NOT attisdropped AND atttypid = 'text'::regtype AND attcollation <> 'pg_catalog.\"C\"'::regcollation;");
    defer st.finalize();
    try testing.expect(try st.step());
    return st.columnInt(0);
}

/// Migration 0030 on an upgraded database: `_events` as 0015 created it (default collation) and a
/// summary table provisioned before the migration both end up with every TEXT column in "C", and
/// the indexes and populated rows survive. Both tables live later in search_path; a shadowed
/// table stays unchanged. Leaves the database migrated in public for the route scenario.
fn expectCollationUpgrade(w: *db.Db) !void {
    // A fresh install: 0015 created `_events`, 0030 pinned it.
    try testing.expectEqual(@as(i64, 0), try uncollatedTextColumns(w, events_rel));
    try w.exec("ALTER TABLE \"_events\" ALTER COLUMN \"id\" TYPE TEXT COLLATE \"default\", ALTER COLUMN \"account\" TYPE TEXT COLLATE \"default\", " ++
        "ALTER COLUMN \"name\" TYPE TEXT COLLATE \"default\", ALTER COLUMN \"occurred_at\" TYPE TEXT COLLATE \"default\";");
    try w.exec("CREATE TABLE \"_rollup_legacy\" (\"bucket\" TEXT NOT NULL DEFAULT '', \"account\" TEXT NOT NULL DEFAULT '', " ++
        "\"actor\" TEXT NOT NULL DEFAULT '', \"value\" BIGINT NOT NULL DEFAULT 0, \"computed_at\" TEXT NOT NULL DEFAULT '', " ++
        "PRIMARY KEY (\"bucket\",\"account\",\"actor\"));");
    // A quoted schema exercises identifier escaping as well as later-path resolution. The
    // shadowed copy must not be altered: only the relation an unqualified read resolves counts.
    try w.exec("CREATE SCHEMA \"legacy analytics\";");
    try w.exec("ALTER TABLE \"_events\" SET SCHEMA \"legacy analytics\";");
    try w.exec("ALTER TABLE \"_rollup_legacy\" SET SCHEMA \"legacy analytics\";");
    try w.exec("CREATE TABLE public.\"_rollup_shadowed\" (\"bucket\" TEXT);");
    try w.exec("CREATE TABLE \"legacy analytics\".\"_rollup_shadowed\" (\"bucket\" TEXT);");
    try w.exec("SET search_path TO public, \"legacy analytics\";");
    try testing.expect(try analytics.summaryExists(w, "_rollup_legacy"));
    try w.exec("INSERT INTO \"_rollup_legacy\" (\"bucket\",\"account\",\"value\") VALUES ('all','B',7),('all','a',9);");
    try w.exec("INSERT INTO \"_events\" (\"id\",\"created\",\"updated\",\"account\",\"occurred_at\") " ++
        "VALUES ('B','','','B','2026-01-01T00:00:00Z'),('a','','','a','2026-01-01T00:00:00Z');");
    try testing.expectEqual(@as(i64, 8), try uncollatedTextColumns(w, events_rel ++ "," ++ legacy_rel));
    try w.exec("DELETE FROM \"_migrations\" WHERE \"name\" = '0030_analytics_text_collation';");
    try migrations.run(w);
    try testing.expectEqual(@as(i64, 0), try uncollatedTextColumns(w, events_rel ++ "," ++ legacy_rel));
    try testing.expectEqual(@as(i64, 0), try uncollatedTextColumns(w, "'public.\"_rollup_shadowed\"'::regclass"));
    try testing.expectEqual(@as(i64, 1), try uncollatedTextColumns(w, "'\"legacy analytics\".\"_rollup_shadowed\"'::regclass"));
    // Reads must resolve the migrated legacy table, preserving its values and byte order.
    {
        var rows = try w.prepare("SELECT account,value FROM \"_rollup_legacy\" ORDER BY bucket DESC,account,actor;");
        defer rows.finalize();
        try testing.expect(try rows.step());
        try testing.expectEqualStrings("B", rows.columnText(0));
        try testing.expectEqual(@as(i64, 7), rows.columnInt(1));
        try testing.expect(try rows.step());
        try testing.expectEqualStrings("a", rows.columnText(0));
        try testing.expectEqual(@as(i64, 9), rows.columnInt(1));
        try testing.expect(!try rows.step());
    }
    {
        var rows = try w.prepare("SELECT id,account,occurred_at FROM \"_events\" ORDER BY occurred_at DESC,id DESC;");
        defer rows.finalize();
        for ([_][]const u8{ "a", "B" }) |id| {
            try testing.expect(try rows.step());
            try testing.expectEqualStrings(id, rows.columnText(0));
            try testing.expectEqualStrings(id, rows.columnText(1));
            try testing.expectEqualStrings("2026-01-01T00:00:00Z", rows.columnText(2));
        }
        try testing.expect(!try rows.step());
    }
    // Re-run the migration body, not merely the already-applied ledger check.
    try w.exec("DELETE FROM \"_migrations\" WHERE \"name\" = '0030_analytics_text_collation';");
    try migrations.run(w);
    var st = try w.prepare("SELECT count(*) FROM pg_indexes WHERE tablename = '_events' AND indexname IN ('idx_events_account_name_occurred','idx_events_account_occurred');");
    defer st.finalize();
    try testing.expect(try st.step());
    try testing.expectEqual(@as(i64, 2), st.columnInt(0));
    try w.exec("DROP TABLE \"_rollup_legacy\";");
    try w.exec("DELETE FROM \"_events\";");
    try w.exec("ALTER TABLE \"_events\" SET SCHEMA public;");
    try w.exec("SET search_path TO public;");
    try w.exec("DROP TABLE public.\"_rollup_shadowed\";");
    try w.exec("DROP SCHEMA \"legacy analytics\" CASCADE;");
}

const events_rel = "'\"_events\"'::regclass";
const legacy_rel = "'\"_rollup_legacy\"'::regclass";

test "analytics.summaryExists resolves the summary table through search_path on PostgreSQL" {
    if (comptime !pg_enabled) return error.SkipZigTest;
    const url = testing.environ.getPosix("ZIGBASE_PG_TEST_URL") orelse return error.SkipZigTest;
    var conn = db.Db.openPostgres(testing.allocator, testing.io, url) catch return error.SkipZigTest;
    defer conn.close();
    {
        // The test creates a schema; a role without CREATE on the database skips it.
        var st = try conn.prepare("SELECT has_database_privilege(current_database(), 'CREATE')::int;");
        defer st.finalize();
        try testing.expect(try st.step());
        if (st.columnInt(0) == 0) return error.SkipZigTest;
    }

    const suffix = try crypto.genHex(testing.io, testing.allocator, 12);
    defer testing.allocator.free(suffix);
    // Statement text lives in fixed stack buffers (no allocation to leak-check).
    var drop_buf: [64]u8 = undefined;
    var buf: [160]u8 = undefined;
    const drop = try std.fmt.bufPrintZ(&drop_buf, "DROP SCHEMA zb487_{s} CASCADE;", .{suffix});
    try conn.exec(try std.fmt.bufPrintZ(&buf, "CREATE SCHEMA zb487_{s};", .{suffix}));
    defer conn.exec(drop) catch |err| std.log.err("pg 487 schema cleanup failed: {s}", .{@errorName(err)});
    try conn.exec(try std.fmt.bufPrintZ(&buf, "CREATE TABLE zb487_{s}.\"_rollup_later\" (\"bucket\" TEXT);", .{suffix}));
    try conn.exec(try std.fmt.bufPrintZ(&buf, "CREATE TABLE zb487_{s}.\"_rollup_Mixed\" (\"bucket\" TEXT);", .{suffix}));

    // The schema is LATER on the path than the current schema: an unqualified read finds the table
    // there, so the existence check must too.
    try conn.exec(try std.fmt.bufPrintZ(&buf, "SET search_path TO public, zb487_{s};", .{suffix}));
    try testing.expect(try analytics.summaryExists(&conn, "_rollup_later"));
    try testing.expect(try analytics.summaryExists(&conn, "_rollup_Mixed"));
    try testing.expect(!try analytics.summaryExists(&conn, "_rollup_mixed"));
    try testing.expect(!try analytics.summaryExists(&conn, "_rollup_absent"));

    // Off the path, an unqualified read would fail, so the table does not exist for it.
    try conn.exec("SET search_path TO public;");
    try testing.expect(!try analytics.summaryExists(&conn, "_rollup_later"));
}

test "withDatabase swaps only the database segment" {
    const got = try withDatabase(testing.allocator, "postgres://u:p@127.0.0.1:5432/zbpgtest?sslmode=prefer", "other");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("postgres://u:p@127.0.0.1:5432/other?sslmode=prefer", got);
}
