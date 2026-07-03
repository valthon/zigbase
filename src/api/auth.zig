const std = @import("std");
const http = @import("../http.zig");
const db = @import("../db.zig");
const collections = @import("../collections.zig");
const records = @import("../records.zig");
const schema = @import("../schema.zig");
const ddl = @import("../ddl.zig");
const crypto = @import("../crypto.zig");
const jwt = @import("../jwt.zig");
const auth = @import("../auth.zig");
const clock = @import("../clock.zig");
const events = @import("../events.zig");
const request = @import("../request.zig");
const session = @import("../session.zig");
const id_gen = @import("../id.zig");
const Ctx = @import("../ctx.zig").Ctx;
const ApiError = @import("error.zig").ApiError;
const param_sink = @import("../sql/param_sink.zig");

/// Lower + renumber a curated auth/session/token statement for `conn`'s backend, then prepare it.
/// SQLite gets the verbatim `?N`/`datetime('now')` SQL (zero-cost — the same slice); Postgres gets
/// `$n` placeholders + `now()` expressions (`sql/param_sink.lowerStmtZ`). Every placeholder-bearing
/// CRUD `prepare` in the auth subsystem routes through here so the `$n` rework has one chokepoint.
/// The lowered SQL lives in a transient arena (`Db.prepare` copies it), so it need only outlive the
/// call; this covers the few statements built with a runtime collection/table name too.
fn prep(conn: *db.Db, sql: [:0]const u8) db.DbError!db.Stmt {
    // Arena over the page allocator: no fixed ceiling (lowerStmtZ makes several intermediate
    // allocations that the arena frees together on return), and on SQLite lowerStmtZ is a no-op
    // returning the input slice, so this costs one empty arena. `Db.prepare` copies the text.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const lowered = param_sink.lowerStmtZ(arena.allocator(), db.dbDialect(conn), sql) catch return db.DbError.PrepareFailed;
    return conn.prepare(lowered);
}

fn jsonResponse(ctx: *http.RequestCtx, status: u16, v: std.json.Value, cookies: []const http.Cookie) !http.Response {
    return .{ .status = status, .body = try std.json.Stringify.valueAlloc(ctx.allocator, v, .{}), .cookies = cookies };
}

fn parseBody(ctx: *http.RequestCtx) ?std.json.Value {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.body, .{}) catch return null;
    if (parsed.value != .object) return null;
    return parsed.value;
}

fn strField(obj: std.json.Value, key: []const u8) ?[]const u8 {
    const v = obj.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// True iff the record's `verified` field is truthy. Tolerant of the JSON shapes a
/// bool column can surface as (bool, integer 0/1, or "true"/"false" string).
pub fn recordVerified(rec: std.json.Value) bool {
    if (rec != .object) return false;
    const v = rec.object.get("verified") orelse return false;
    return switch (v) {
        .bool => |b| b,
        .integer => |i| i != 0,
        .string => |s| std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1"),
        else => false,
    };
}

/// Wall-clock seconds (no DB connection needed) for the rate limiter, mirroring
/// scheduler.unixNow — used at the top of the gated endpoints before any conn exists.
/// Honors the dev-only `ZIGBASE_FAKE_NOW` override (see `clock.zig`).
fn wallNowUnix(io: std.Io) i64 {
    return clock.nowUnix(io);
}

/// Rate-limit gate for a sensitive auth endpoint. Returns a 429 Response when the
/// limiter denies the request, else null (proceed). `scope` is the endpoint tag
/// ("login"/"reset"/"verify"). The key is the client IP when known, else falls back
/// to the submitted identity/email so the limiter still functions without a proxy IP.
/// No-op (null) when no limiter is wired (rate_limit_max == 0 / tests).
pub fn rateLimited(ctx: *http.RequestCtx, scope: []const u8, ident: []const u8) !?http.Response {
    const app = ctx.app.?;
    const limiter = app.rate_limiter orelse return null;
    const key = if (ctx.remote_ip.len > 0)
        try std.fmt.allocPrint(ctx.allocator, "{s}:ip:{s}", .{ scope, ctx.remote_ip })
    else
        try std.fmt.allocPrint(ctx.allocator, "{s}:ident:{s}", .{ scope, ident });
    if (limiter.allow(key, wallNowUnix(app.io))) return null;
    return try (ApiError{ .status = 429, .message = "Too many requests. Try again later." }).toResponse(ctx.allocator);
}

/// Per-method variant of `rateLimited`: enforces a method-specific `max`/`window_s`
/// against its own bucket (the `scope` carries collection + method slug so distinct
/// methods/collections never share a bucket) using the SAME shared limiter store —
/// one map + one mutex — as the global limiter. The bucket subject (client IP, else
/// submitted identity) matches `rateLimited` for consistency. Honored independently of
/// the global default, so a configured per-method limit applies even when global
/// limiting is off. No-op (null) when no limiter store is wired (tests/CLI). Fail-safe:
/// the underlying limiter fails open on any bookkeeping error rather than erroring.
pub fn rateLimitedCustom(ctx: *http.RequestCtx, scope: []const u8, ident: []const u8, max: u32, window_s: i64) !?http.Response {
    const app = ctx.app.?;
    const limiter = app.rate_limiter orelse return null;
    const key = if (ctx.remote_ip.len > 0)
        try std.fmt.allocPrint(ctx.allocator, "{s}:ip:{s}", .{ scope, ctx.remote_ip })
    else
        try std.fmt.allocPrint(ctx.allocator, "{s}:ident:{s}", .{ scope, ident });
    if (limiter.allowCustom(key, wallNowUnix(app.io), max, window_s)) return null;
    return try (ApiError{ .status = 429, .message = "Too many requests. Try again later." }).toResponse(ctx.allocator);
}

/// SQL `now` for framework token logic (iat/exp, consumed-token expiry), honoring the
/// dev-only `ZIGBASE_FAKE_NOW` override so issued tokens agree with the frozen wall clock.
pub fn nowUnix(conn: *db.Db) db.DbError!i64 {
    return clock.sqlNowUnix(conn);
}

/// Try each identity field in order; return the matching non-empty row id, or null.
///
/// When an identity field is covered by a `.nocase` index, the comparison is case-INSENSITIVE so
/// the lookup uses that index and AGREES with its case-insensitive uniqueness (#159), IDENTICALLY
/// on both backends: Postgres `lower("idf") = lower($1)` (the `lower()` functional index), SQLite
/// `"idf" COLLATE NOCASE = ?1 COLLATE NOCASE` (the COLLATE NOCASE index). A non-`.nocase` identity
/// field keeps the exact (case-sensitive) compare on both backends.
pub fn findByIdentity(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, identity: []const u8) !?[]const u8 {
    const d = db.dbDialect(conn);
    for (col.options.auth.identityFields) |idf| {
        const col_quoted = try std.fmt.allocPrint(alloc, "\"{s}\"", .{idf});
        defer alloc.free(col_quoted);
        const ci = ddl.isNocaseField(col, idf);
        // `lhs`/`rhs` are freshly allocated ONLY on the `ci` arm (nocaseEqOperand allocates on both
        // backends); otherwise they borrow `col_quoted` / a string literal, so the frees are
        // guarded to `ci` to avoid double-freeing `col_quoted` or freeing a literal.
        const lhs = if (ci) try d.nocaseEqOperand(alloc, col_quoted) else col_quoted;
        defer if (ci) alloc.free(lhs);
        const rhs = if (ci) try d.nocaseEqOperand(alloc, "?1") else "?1";
        defer if (ci) alloc.free(rhs);
        const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT \"id\" FROM \"{s}\" WHERE {s} = {s} AND \"{s}\" != '' LIMIT 1;", .{ col.name, lhs, rhs, idf }, 0);
        defer alloc.free(sql);
        var st = try prep(conn, sql);
        defer st.finalize();
        try st.bindText(1, identity);
        if (try st.step()) return try alloc.dupe(u8, st.columnText(0));
    }
    return null;
}

test "findByIdentity: a .nocase email index makes the SQLite lookup case-insensitive (#159)" {
    // Mirror of the Postgres auth_pg_test case: with a `.nocase` UNIQUE index on email, finding by
    // a DIFFERENT case must resolve the stored record on SQLite too (COLLATE NOCASE index), so both
    // backends behave identically — a user registered as `Bob@x.com` can log in as `bob@x.com`.
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);

    const col = try collections.create(a, std.testing.io, &d, .{
        .id = "",
        .name = "users",
        .type = .auth,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "name", .options = .{ .text = .{} } }},
        .indexes = &[_]schema.Index{.{ .name = "idx_users_email_nocase", .fields = &.{"email"}, .unique = true, .collation = .nocase }},
        .listRule = "",
        .viewRule = "",
        .createRule = "",
        .updateRule = "",
        .deleteRule = "",
    });

    var data: std.json.ObjectMap = .empty;
    try data.put(a, "email", .{ .string = "Bob@x.com" });
    try data.put(a, "password", .{ .string = "correct horse battery" });
    const prepared = try auth.applyCreate(std.testing.io, a, .{ .object = data }, col.options.auth.minPasswordLength);
    const rec = try records.create(a, std.testing.io, &d, col, prepared);
    const rid = rec.object.get("id").?.string;

    // Case-INSENSITIVE lookup: different cases all resolve the same record.
    try std.testing.expectEqualStrings(rid, (try findByIdentity(a, &d, col, "bob@x.com")).?);
    try std.testing.expectEqualStrings(rid, (try findByIdentity(a, &d, col, "BOB@X.COM")).?);
    try std.testing.expectEqualStrings(rid, (try findByIdentity(a, &d, col, "Bob@x.com")).?);
    // A non-matching identity still returns null.
    try std.testing.expect((try findByIdentity(a, &d, col, "carol@x.com")) == null);

    // Case-variant uniqueness: a second record with a case-variant email is rejected by the
    // COLLATE NOCASE unique index (duplicate identity) — parity with the Postgres lower() index.
    var data2: std.json.ObjectMap = .empty;
    try data2.put(a, "email", .{ .string = "bob@x.com" });
    try data2.put(a, "password", .{ .string = "another good passphrase" });
    const prepared2 = try auth.applyCreate(std.testing.io, a, .{ .object = data2 }, col.options.auth.minPasswordLength);
    try std.testing.expectError(error.StepFailed, records.create(a, std.testing.io, &d, col, prepared2));
}

pub fn passwordHashFor(alloc: std.mem.Allocator, conn: *db.Db, table: []const u8, rid: []const u8) !?[]const u8 {
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT \"passwordHash\" FROM \"{s}\" WHERE \"id\" = ?1;", .{table}, 0);
    var st = try prep(conn, sql);
    defer st.finalize();
    try st.bindText(1, rid);
    if (!try st.step()) return null;
    return try alloc.dupe(u8, st.columnText(0));
}

pub fn tokenKeyFor(alloc: std.mem.Allocator, conn: *db.Db, table: []const u8, rid: []const u8) !?[]const u8 {
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT \"tokenKey\" FROM \"{s}\" WHERE \"id\" = ?1;", .{table}, 0);
    var st = try prep(conn, sql);
    defer st.finalize();
    try st.bindText(1, rid);
    if (!try st.step()) return null;
    return try alloc.dupe(u8, st.columnText(0));
}

pub const KeyEpoch = struct { token_key: []const u8, epoch: i64 };

/// Fetch the record's `tokenKey` AND its session `token_epoch` (#99) in ONE SELECT — the
/// same single read every mint path already did for the tokenKey, now carrying one extra
/// column. This is what keeps epoch-mode login zero-new-query: `issue()` no longer runs its
/// own epoch SELECT, it takes the epoch from here. NULL epoch reads as 0 (back-compat).
pub fn tokenKeyAndEpochFor(alloc: std.mem.Allocator, conn: *db.Db, table: []const u8, rid: []const u8) !?KeyEpoch {
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT \"tokenKey\", COALESCE(\"token_epoch\", 0) FROM \"{s}\" WHERE \"id\" = ?1;", .{table}, 0);
    var st = try prep(conn, sql);
    defer st.finalize();
    try st.bindText(1, rid);
    if (!try st.step()) return null;
    return .{ .token_key = try alloc.dupe(u8, st.columnText(0)), .epoch = st.columnInt(1) };
}

/// Read the record's current session epoch (#99), treating a NULL value (back-compat
/// default) as 0; the column itself is guaranteed present by migration 0010. `table` is the
/// physical auth table (collection name, or "_superusers"). Returns null only when no such
/// row exists.
pub fn tokenEpochFor(alloc: std.mem.Allocator, conn: *db.Db, table: []const u8, rid: []const u8) !?i64 {
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT COALESCE(\"token_epoch\", 0) FROM \"{s}\" WHERE \"id\" = ?1;", .{table}, 0);
    var st = try prep(conn, sql);
    defer st.finalize();
    try st.bindText(1, rid);
    if (!try st.step()) return null;
    return st.columnInt(0);
}

/// Bump the record's session epoch by 1 — invalidating EVERY outstanding `.auth` token
/// for the principal ("revoke all sessions"/"log out everywhere", #99 Variant A). Must
/// run under the writer lock. `table` is the physical auth table. Returns the new epoch.
pub fn bumpTokenEpoch(alloc: std.mem.Allocator, conn: *db.Db, table: []const u8, rid: []const u8) !i64 {
    const sql = try std.fmt.allocPrintSentinel(alloc, "UPDATE \"{s}\" SET \"token_epoch\" = COALESCE(\"token_epoch\", 0) + 1 WHERE \"id\" = ?1;", .{table}, 0);
    var st = try prep(conn, sql);
    defer st.finalize();
    try st.bindText(1, rid);
    _ = try st.step();
    return (try tokenEpochFor(alloc, conn, table, rid)) orelse error.NotFound;
}

// ----------------------------------------------------------------------------
// Variant B (#99): server-side `_sessions` store — per-device list/revoke.
// ALL of this runs only in `app.session_store == .table`; epoch mode never touches it.
// ----------------------------------------------------------------------------

/// One active session as surfaced to `listActiveSessions` (sans owner refs).
pub const SessionRow = struct {
    id: []const u8,
    created: []const u8,
    last_seen: []const u8,
    user_agent: []const u8,
    ip: []const u8,
};

/// Insert a `_sessions` row for a freshly minted table-mode token and return its id (the
/// token's `sid`). `conn` must be the WRITER. `exp` is the session expiry (unix secs; the
/// token's own exp). UA/IP are captured from the request. A single INSERT — atomic under the
/// writer's autocommit, or joined to an enclosing txn (refresh/oauth) where one is open.
pub fn recordSession(ctx: *http.RequestCtx, conn: *db.Db, collection: []const u8, rid: []const u8, exp: i64) ![]const u8 {
    const app = ctx.app.?;
    var idbuf: [15]u8 = undefined;
    id_gen.generate(app.io, &idbuf);
    const sid = try ctx.allocator.dupe(u8, &idbuf);
    var st = try prep(conn, 
        \\INSERT INTO "_sessions" ("id","collectionRef","recordRef","created","lastSeen","expires","userAgent","ip")
        \\ VALUES (?1,?2,?3,datetime('now'),datetime('now'),?4,?5,?6);
    );
    defer st.finalize();
    try st.bindText(1, sid);
    try st.bindText(2, collection);
    try st.bindText(3, rid);
    try st.bindInt(4, exp);
    try st.bindText(5, ctx.user_agent);
    try st.bindText(6, ctx.remote_ip);
    _ = try st.step();
    return sid;
}

/// Delete one session row by id. Returns whether a row existed. Writer required.
pub fn deleteSession(conn: *db.Db, sid: []const u8) !bool {
    var st = try prep(conn, "DELETE FROM \"_sessions\" WHERE \"id\" = ?1 RETURNING \"id\";");
    defer st.finalize();
    try st.bindText(1, sid);
    return try st.step();
}

/// Delete a session row AND return its original `created` timestamp (RETURNING). Used by
/// refresh/rotate to carry the true session-start time forward onto the replacement row.
/// Null when no row existed. Writer required.
pub fn deleteSessionReturningCreated(alloc: std.mem.Allocator, conn: *db.Db, sid: []const u8) !?[]const u8 {
    var st = try prep(conn, "DELETE FROM \"_sessions\" WHERE \"id\" = ?1 RETURNING \"created\";");
    defer st.finalize();
    try st.bindText(1, sid);
    if (!try st.step()) return null;
    return try alloc.dupe(u8, st.columnText(0));
}

/// After a refresh/rotate reissue, carry the OLD session's `created` onto the NEW row so
/// `created` = the true session start (not the last refresh), while leaving the new row's
/// freshly-set `lastSeen` = now. `new_token` is the just-issued JWT (its `sid` names the new
/// row). No-op when `old_created` is null or the token carries no `sid`. Writer required.
pub fn carrySessionCreated(alloc: std.mem.Allocator, conn: *db.Db, new_token: []const u8, old_created: ?[]const u8) !void {
    const oc = old_created orelse return;
    const claims = jwt.peekClaims(alloc, new_token) catch return;
    const ns = claims.sid orelse return;
    if (ns.len == 0) return;
    var st = try prep(conn, "UPDATE \"_sessions\" SET \"created\" = ?2 WHERE \"id\" = ?1;");
    defer st.finalize();
    try st.bindText(1, ns);
    try st.bindText(2, oc);
    _ = try st.step();
}

/// Batch size for the expired-session GC sweep (#114): bound each DELETE so a large backlog
/// never holds the single writer for one long statement.
pub const session_gc_batch: usize = 1000;

/// Garbage-collect expired `_sessions` rows (#114), table-mode only. Deletes in bounded
/// batches (`session_gc_batch`) — each batch is its own autocommit `DELETE … RETURNING`, so the
/// writer is never held across the whole sweep. Rows with NULL `expires` (no expiry) or a
/// future `expires` survive. `expires` is unix-seconds (matches `issue()`/`recordSession`), so
/// the cutoff is the parameter-bound `nowUnix(conn)`. Returns the total rows deleted. Writer
/// required (the recurring job acquires it; verify never writes, so GC is the only sweeper).
pub fn gcExpiredSessions(conn: *db.Db) !usize {
    const now = try nowUnix(conn);
    var total: usize = 0;
    while (true) {
        // `session_gc_batch` is the single source of truth for the batch size: it is the SQL
        // LIMIT (interpolated at comptime — a comptime int constant, no injection surface) AND
        // the loop-termination threshold below, so the two can never desync.
        var st = try prep(conn, comptime std.fmt.comptimePrint(
            \\DELETE FROM "_sessions"
            \\ WHERE "id" IN (SELECT "id" FROM "_sessions" WHERE "expires" IS NOT NULL AND "expires" <= ?1 LIMIT {d})
            \\ RETURNING "id";
        , .{session_gc_batch}));
        defer st.finalize();
        try st.bindInt(1, now);
        var batch: usize = 0;
        while (try st.step()) batch += 1;
        total += batch;
        if (batch < session_gc_batch) break; // full batch — may be more; a partial (or zero) batch signals done
    }
    return total;
}

/// Delete EVERY session row for a principal (revoke-all cleanliness). Writer required.
pub fn deleteSessionsForPrincipal(conn: *db.Db, collection: []const u8, rid: []const u8) !void {
    var st = try prep(conn, "DELETE FROM \"_sessions\" WHERE \"collectionRef\" = ?1 AND \"recordRef\" = ?2;");
    defer st.finalize();
    try st.bindText(1, collection);
    try st.bindText(2, rid);
    _ = try st.step();
}

/// The (collection, record) owner of a session row, or null if absent. Used to AUTHORIZE
/// `revoke(sid)`: a non-superuser may only revoke a session they own.
pub fn sessionOwner(alloc: std.mem.Allocator, conn: *db.Db, sid: []const u8) !?struct { collection: []const u8, record: []const u8 } {
    var st = try prep(conn, "SELECT \"collectionRef\", \"recordRef\" FROM \"_sessions\" WHERE \"id\" = ?1;");
    defer st.finalize();
    try st.bindText(1, sid);
    if (!try st.step()) return null;
    return .{ .collection = try alloc.dupe(u8, st.columnText(0)), .record = try alloc.dupe(u8, st.columnText(1)) };
}

/// The monotonic insertion-order column that breaks `created`-timestamp ties deterministically
/// (two logins in the same wall-clock second — `created` is `datetime('now')`, second-resolution).
/// SQLite has the implicit `rowid`; Postgres has none (and the app `id` is a RANDOM base36 string,
/// not monotonic), so migration `0020_sessions_seq` adds an identity column `_seq` that serves the
/// same purpose — mirrors `analytics.seqCol`/`0017_events_seq` for `_events` exactly.
fn sessionSeqCol(conn: *db.Db) []const u8 {
    return switch (db.dbDialect(conn).kind) {
        .sqlite => "\"rowid\"",
        .postgres => "\"_seq\"",
    };
}

/// List a principal's active (unexpired) sessions, newest first. Caller adds `is_current`.
pub fn listSessions(alloc: std.mem.Allocator, conn: *db.Db, collection: []const u8, rid: []const u8) ![]SessionRow {
    const now = try nowUnix(conn);
    var sqlbuf: [320]u8 = undefined;
    const sql = std.fmt.bufPrintZ(&sqlbuf,
        \\SELECT "id","created","lastSeen","userAgent","ip" FROM "_sessions"
        \\ WHERE "collectionRef" = ?1 AND "recordRef" = ?2 AND ("expires" IS NULL OR "expires" > ?3)
        \\ ORDER BY "created" DESC, {s} DESC;
    , .{sessionSeqCol(conn)}) catch unreachable;
    var st = try prep(conn, sql);
    defer st.finalize();
    try st.bindText(1, collection);
    try st.bindText(2, rid);
    try st.bindInt(3, now);
    var out: std.ArrayList(SessionRow) = .empty;
    while (try st.step()) {
        try out.append(alloc, .{
            .id = try alloc.dupe(u8, st.columnText(0)),
            .created = try alloc.dupe(u8, st.columnText(1)),
            .last_seen = try alloc.dupe(u8, st.columnText(2)),
            .user_agent = try alloc.dupe(u8, st.columnText(3)),
            .ip = try alloc.dupe(u8, st.columnText(4)),
        });
    }
    return out.toOwnedSlice(alloc);
}

pub const Issued = struct { token: []const u8, cookies: [2]http.Cookie };

pub fn issue(ctx: *http.RequestCtx, conn: *db.Db, collection: []const u8, rid: []const u8, token_key: []const u8, epoch: i64) !Issued {
    const app = ctx.app.?;
    const csrf = try crypto.genToken(app.io, ctx.allocator, 32);
    const now = try nowUnix(conn);
    const exp = now + app.auth_token_ttl_s;
    // `epoch` (#99) is passed in by the caller, folded into the SAME `tokenKey` SELECT every
    // mint path already does (see `tokenKeyAndEpochFor`) — so epoch-mode login adds NO new
    // query. It is embedded so verify can reject the token once the epoch is bumped ("revoke
    // all sessions"); 0 is the back-compat default that matches a NULL/absent column.
    // Variant B: in TABLE mode only, record a server-side session row and bind its id into
    // the token as `sid`. In epoch mode `sid` stays null — NO session row is written and the
    // token serializes byte-identically (the user's zero-overhead requirement). `conn` must be
    // the writer in table mode (every login path that reaches here holds it; password login
    // upgrades to the writer specifically for this).
    const sid: ?[]const u8 = if (app.session_store == .table)
        try recordSession(ctx, conn, collection, rid, exp)
    else
        null;
    const claims = jwt.Claims{
        .id = rid,
        .collection = collection,
        .type = .auth,
        .csrf = csrf,
        .token_epoch = epoch,
        .sid = sid,
        .iat = now,
        .exp = exp,
    };
    const key = crypto.deriveKey(app.jwt_secret, token_key);
    const token = try jwt.sign(ctx.allocator, claims, &key);
    const max_age: i32 = @intCast(app.auth_token_ttl_s);
    return .{
        .token = token,
        // Built via the shared session-cookie policy (session.zig) so login + logout +
        // clearSession never drift on cookie attributes.
        .cookies = session.sessionCookies(app.cookie_secure, token, csrf, max_age),
    };
}

/// Fire auth.afterAuthSuccess. After-style: never propagates (auth already succeeded).
pub fn emitAuth(ctx: *http.RequestCtx, collection: []const u8, record: ?std.json.Value, method: events.AuthMethod) void {
    const app = ctx.app orelse return;
    const d = app.dispatch orelse return;
    const h = d.on_auth orelse return;
    var rctx = request.RequestContext{ .method = @tagName(ctx.method) };
    var ev = events.AuthEvent{ .app = app, .ctx = &rctx, .collection = collection, .record = record, .method = method };
    h(&ev);
}

/// THE session seam: resolve a collection's table + the record's tokenKey, sign a
/// native `.auth` session via `issue()`, then fire `emitAuth(method)`. Every login —
/// password, refresh, magic-link, custom route — mints through here, so `onAuth`
/// ALWAYS fires. `conn` is the caller's already-acquired connection.
pub fn issueSession(
    ctx: *http.RequestCtx,
    conn: *db.Db,
    collection: []const u8,
    record_id: []const u8,
    method: events.AuthMethod,
) !Issued {
    return issueSessionExt(ctx, conn, collection, record_id, method, null);
}

/// Like `issueSession` but accepts a pre-fetched record (`opt_record`) to avoid a
/// redundant DB read when the caller already holds the record. When `opt_record` is
/// null the record is fetched as usual. `onAuth` still fires exactly once.
pub fn issueSessionExt(
    ctx: *http.RequestCtx,
    conn: *db.Db,
    collection: []const u8,
    record_id: []const u8,
    method: events.AuthMethod,
    opt_record: ?std.json.Value,
) !Issued {
    const col = (try collections.get(ctx.allocator, conn, collection)) orelse return error.NotFound;
    if (col.type != .auth) return error.NotFound;
    // One SELECT for tokenKey + epoch (no separate epoch query) — keeps epoch-mode login at the
    // same query count as before #99.
    const ke = (try tokenKeyAndEpochFor(ctx.allocator, conn, col.name, record_id)) orelse return error.NotFound;
    const issued = try issue(ctx, conn, col.name, record_id, ke.token_key, ke.epoch);
    const rec: ?std.json.Value = if (opt_record) |r| r else try records.get(ctx.allocator, conn, col, record_id);
    emitAuth(ctx, col.name, rec, method);
    return issued;
}

/// Like `issueSessionExt` but does NOT fire `onAuth`. Used by the transactional consume
/// paths (`auth_methods.complete`, `magic_link_consume`) so they can emit the notification
/// AFTER `COMMIT` via `emitAuth`, preserving the invariant that `onAuth` only fires once a
/// session has been durably issued. (`issueSessionExt` keeps emitting inline for the legacy
/// non-transactional callers — `authWithPassword`/`authRefresh`.)
pub fn issueSessionNoEmit(
    ctx: *http.RequestCtx,
    conn: *db.Db,
    collection: []const u8,
    record_id: []const u8,
) !Issued {
    const col = (try collections.get(ctx.allocator, conn, collection)) orelse return error.NotFound;
    if (col.type != .auth) return error.NotFound;
    const ke = (try tokenKeyAndEpochFor(ctx.allocator, conn, col.name, record_id)) orelse return error.NotFound;
    return issue(ctx, conn, col.name, record_id, ke.token_key, ke.epoch);
}

/// Fire the writable, abortable `beforeAuthSuccess` hook (#80) inside the login's write
/// transaction. `conn` is the in-transaction writer; the hook's `*Ctx` is bound to it so
/// its `ctx.records()` writes participate in (and roll back with) the login.
///
/// Returns `null` to proceed (no hook registered, or the hook returned cleanly). When the
/// hook ABORTS (returns any error) it returns a ready-to-send `http.Response` mapped via
/// the `Ctx` error model (`ctx.fail` status / `error.Forbidden`→403 / else 500) — the
/// CALLER must `ROLLBACK` before returning it, so the session is never issued (fail closed).
pub fn fireBeforeAuthSuccess(
    req: *http.RequestCtx,
    conn: *db.Db,
    col_name: []const u8,
    rid: []const u8,
    method: events.AuthMethod,
    rec: std.json.Value,
) !?http.Response {
    const app = req.app orelse return null;
    const d = app.dispatch orelse return null;
    const h = d.before_auth_success orelse return null;
    // Identity context: the hook's ctx.user() reflects the just-authenticated principal.
    const rctx = request.RequestContext{
        .auth = rec,
        .is_superuser = false,
        .collection = col_name,
        .method = @tagName(req.method),
    };
    var cx = Ctx{ .app = app, .arena = req.allocator, .rctx = rctx, .request = req, .bound_conn = conn };
    defer cx.deinit(); // no-op when bound (reads reuse bound_conn), kept for hygiene
    var ev = events.AuthSuccessEvent{
        .app = app,
        .collection = col_name,
        .record_id = rid,
        .method = method,
        .record = rec,
    };
    h(&cx, &ev) catch |e| return cx.errorResponse(e);
    return null;
}

/// True iff an auth-lifecycle hook (#98) is registered. Lets a handler skip the
/// heavier writer-acquiring path (e.g. logout) when no hook would fire.
pub fn hasAuthLifecycle(app: *@import("../app.zig").App) bool {
    const d = app.dispatch orelse return false;
    return d.auth_lifecycle != null;
}

/// True iff a `beforeAuthSuccess` hook (#80) is registered. The legacy password login
/// takes the transactional writer path ONLY then — the hook-free epoch path keeps
/// issuing on the reader (zero writer acquisitions), matching authLogout's
/// `hasAuthLifecycle` fast-path gate.
pub fn hasBeforeAuthSuccess(app: *@import("../app.zig").App) bool {
    const d = app.dispatch orelse return false;
    return d.before_auth_success != null;
}

/// Fire a BEFORE auth-lifecycle hook (#98) — register/logout/refresh/password-change.
/// Mirrors `fireBeforeAuthSuccess`: the hook's `*Ctx` is bound to `conn` (the action's
/// connection; in-transaction for register/refresh/password-change), so its
/// `ctx.records()` writes participate in (and roll back with) the action.
///
/// Returns `null` to proceed (no hook for this phase, or it returned cleanly). On ABORT
/// (the hook returns any error) returns a ready-to-send `http.Response` mapped via the `Ctx`
/// error model — the CALLER must roll back (where a txn exists) before returning it, so the
/// action is blocked (fail closed). `rec` is the writable record pointer where applicable
/// (`before_register` data); `identity` populates `ctx.user()` for the principal.
pub fn fireAuthLifecycleBefore(
    req: *http.RequestCtx,
    conn: *db.Db,
    col_name: []const u8,
    rid: []const u8,
    phase: events.AuthLifecyclePhase,
    rec: ?*std.json.Value,
    identity: ?std.json.Value,
) !?http.Response {
    const app = req.app orelse return null;
    const d = app.dispatch orelse return null;
    const h = d.auth_lifecycle orelse return null;
    const rctx = request.RequestContext{
        .auth = identity,
        .is_superuser = false,
        .collection = col_name,
        .method = @tagName(req.method),
    };
    var cx = Ctx{ .app = app, .arena = req.allocator, .rctx = rctx, .request = req, .bound_conn = conn };
    defer cx.deinit();
    var ev = events.AuthLifecycleEvent{
        .app = app,
        .collection = col_name,
        .record_id = rid,
        .phase = phase,
        .record = rec,
    };
    h(&cx, &ev) catch |e| return cx.errorResponse(e);
    return null;
}

/// Fire an AFTER auth-lifecycle hook (#98). After-style: never propagates — the action
/// already happened; an error is routed to the framework error backstop (parity with
/// after-record hooks). `conn` binds `ctx.records()` (the still-held writer post-commit).
pub fn emitAuthLifecycle(
    req: *http.RequestCtx,
    conn: *db.Db,
    col_name: []const u8,
    rid: []const u8,
    phase: events.AuthLifecyclePhase,
    rec: ?*std.json.Value,
    identity: ?std.json.Value,
) void {
    const app = req.app orelse return;
    const d = app.dispatch orelse return;
    const h = d.auth_lifecycle orelse return;
    const rctx = request.RequestContext{
        .auth = identity,
        .is_superuser = false,
        .collection = col_name,
        .method = @tagName(req.method),
    };
    var cx = Ctx{ .app = app, .arena = req.allocator, .rctx = rctx, .request = req, .bound_conn = conn };
    defer cx.deinit();
    var ev = events.AuthLifecycleEvent{
        .app = app,
        .collection = col_name,
        .record_id = rid,
        .phase = phase,
        .record = rec,
    };
    h(&cx, &ev) catch |e| {
        var err_ev = events.ErrorEvent{ .app = app, .ctx = &rctx, .err = e, .phase = .after_hook, .message = @errorName(e) };
        events.dispatchError(app, app.dispatch, &err_ev);
    };
}

pub fn authWithPassword(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const body = parseBody(ctx) orelse return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator);
    const identity = strField(body, "identity") orelse return ApiError.badRequest("identity is required.").toResponse(ctx.allocator);
    const password = strField(body, "password") orelse return ApiError.badRequest("password is required.").toResponse(ctx.allocator);

    // Rate-limit gate (brute-force defense): per client IP, falling back to identity.
    if (try rateLimited(ctx, "login", identity)) |resp| return resp;

    // Login is read-only (identity lookup, password hash, tokenKey, unixepoch; issue() only
    // reads + signs). Use a READER so the expensive argon2 verify below does NOT run while
    // holding the single global writer lock — otherwise every login serializes all writes.
    var r = try app.pool.acquireReader();
    defer app.pool.releaseReader(&r);
    const col_name = ctx.param("col") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const col = (try collections.get(ctx.allocator, &r, col_name)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    if (col.type != .auth) return ApiError.notFound().toResponse(ctx.allocator);

    const rid = (try findByIdentity(ctx.allocator, &r, col, identity)) orelse {
        // Unknown identity: run identity-independent argon2 work so the response time matches
        // the known-identity path (defeats account enumeration via timing). L1 fix.
        crypto.dummyVerify(app.io, ctx.allocator);
        return ApiError.badRequest("Invalid credentials.").toResponse(ctx.allocator);
    };
    const phc = (try passwordHashFor(ctx.allocator, &r, col.name, rid)) orelse {
        crypto.dummyVerify(app.io, ctx.allocator);
        return ApiError.badRequest("Invalid credentials.").toResponse(ctx.allocator);
    };
    if (!crypto.verifyPassword(app.io, ctx.allocator, phc, password))
        return ApiError.badRequest("Invalid credentials.").toResponse(ctx.allocator);

    const rec = (try records.get(ctx.allocator, &r, col, rid)) orelse
        return ApiError.notFound().toResponse(ctx.allocator);
    // Optional verification gate: refuse to mint a session for an unverified record.
    if (col.options.auth.require_verified and !recordVerified(rec))
        return (ApiError{ .status = 403, .message = "Email not verified." }).toResponse(ctx.allocator);
    // Issuance (three paths):
    //  1. HOOK path (#80, 0.10.0): a registered `beforeAuthSuccess` runs inside a write
    //     transaction so its side-writes commit atomically with issuance and an abort blocks
    //     the session (fail closed) — byte-for-byte the auth_methods.complete discipline.
    //     `onAuth` fires only AFTER the durable commit. Fires for `_superusers` too (the
    //     admin SPA logs in through this route) — an unconditionally-erroring hook locks
    //     superusers out; that is consistent fail-closed behavior (documented Breaking).
    //  2. Hook-free TABLE mode: unchanged — acquire the writer only for the `_sessions`
    //     INSERT (a single autocommit statement), after the costly argon2 verify.
    //  3. Hook-free EPOCH mode (the common case): unchanged — issue on the READER; zero
    //     writer acquisitions (pinned by the writer_acquires test below).
    const issued = blk: {
        if (hasBeforeAuthSuccess(app)) {
            const w = app.pool.acquireWriter();
            defer app.pool.releaseWriter();
            try w.beginImmediate();
            // Safety net for every error-return after begin (the hook can propagate,
            // issueSessionNoEmit, commit); value-returns roll back explicitly — a later
            // double-rollback is a harmless no-op.
            errdefer w.rollback() catch {};
            if (try fireBeforeAuthSuccess(ctx, w, col.name, rid, .password, rec)) |resp| {
                w.rollback() catch {};
                return resp;
            }
            const iss = issueSessionNoEmit(ctx, w, col.name, rid) catch |err| switch (err) {
                error.NotFound => {
                    w.rollback() catch {};
                    return ApiError.badRequest("Invalid credentials.").toResponse(ctx.allocator);
                },
                else => return err, // errdefer rolls back
            };
            w.commit() catch |e| {
                w.rollback() catch {};
                return e;
            };
            emitAuth(ctx, col.name, rec, .password);
            break :blk iss;
        }
        if (app.session_store == .table) {
            const w = app.pool.acquireWriter();
            defer app.pool.releaseWriter();
            break :blk issueSessionExt(ctx, w, col.name, rid, .password, rec) catch |err| switch (err) {
                error.NotFound => return ApiError.badRequest("Invalid credentials.").toResponse(ctx.allocator),
                else => return err,
            };
        }
        break :blk issueSessionExt(ctx, &r, col.name, rid, .password, rec) catch |err| switch (err) {
            error.NotFound => return ApiError.badRequest("Invalid credentials.").toResponse(ctx.allocator),
            else => return err,
        };
    };

    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator, "token", .{ .string = issued.token });
    try root.put(ctx.allocator, "record", rec);
    const cookies = try ctx.allocator.dupe(http.Cookie, &issued.cookies);
    return jsonResponse(ctx, 200, .{ .object = root }, cookies);
}

pub fn authRefresh(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const authed = (try auth.authenticate(app.io, ctx.allocator, app, ctx, w)) orelse
        return (ApiError{ .status = 401, .message = "Not authenticated." }).toResponse(ctx.allocator);
    const col_name = ctx.param("col") orelse return ApiError.notFound().toResponse(ctx.allocator);
    if (!std.mem.eql(u8, authed.collection, col_name))
        return (ApiError{ .status = 401, .message = "Not authenticated." }).toResponse(ctx.allocator);

    const rid = authed.record.object.get("id").?.string;

    // Transactional refresh (#98): a `beforeRefresh` hook's side-writes commit atomically
    // with the new session; an aborting hook rolls back and blocks issuance (fail closed).
    // `onAuth` is emitted only AFTER the durable commit (parity with the consume paths).
    var rec_mut = authed.record;
    try w.beginImmediate();
    // Safety net for every error-return after begin (the hook, issueSessionNoEmit, commit):
    // value-returns below roll back explicitly; a later double-rollback is a harmless no-op.
    errdefer w.rollback() catch {};
    if (try fireAuthLifecycleBefore(ctx, w, col_name, rid, .before_refresh, &rec_mut, authed.record)) |resp| {
        w.rollback() catch {};
        return resp;
    }
    // #80 on the legacy refresh (0.10.0): `beforeAuthSuccess` slots into the SAME
    // transaction, AFTER `before_refresh` (surrounding phase first, then the seam).
    // Either abort rolls back the whole refresh — old session/row intact, fail closed.
    if (try fireBeforeAuthSuccess(ctx, w, col_name, rid, .refresh, rec_mut)) |resp| {
        w.rollback() catch {};
        return resp;
    }
    // Table mode: rotate the session row — drop this token's old `sid` row before issue()
    // inserts the replacement, so a device keeps exactly ONE row across refreshes (no leak).
    // In txn: an error trips the errdefer rollback above (fail closed, session not reissued).
    if (app.session_store == .table and authed.sid.len > 0) _ = try deleteSession(w, authed.sid);
    const issued = issueSessionNoEmit(ctx, w, col_name, rid) catch |err| switch (err) {
        error.NotFound => {
            w.rollback() catch {};
            return (ApiError{ .status = 401, .message = "Not authenticated." }).toResponse(ctx.allocator);
        },
        else => return err, // errdefer rolls back
    };
    w.commit() catch |e| {
        w.rollback() catch {};
        return e;
    };
    emitAuth(ctx, col_name, rec_mut, .refresh);
    emitAuthLifecycle(ctx, w, col_name, rid, .after_refresh, &rec_mut, rec_mut);

    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator, "token", .{ .string = issued.token });
    try root.put(ctx.allocator, "record", rec_mut);
    const cookies = try ctx.allocator.dupe(http.Cookie, &issued.cookies);
    return jsonResponse(ctx, 200, .{ .object = root }, cookies);
}

/// Extract a record's string `id`, or "" when absent/non-string.
fn recordId(rec: std.json.Value) []const u8 {
    if (rec != .object) return "";
    const v = rec.object.get("id") orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

pub fn authLogout(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;

    // The writer path is taken when a `beforeLogout`/`afterLogout` hook is registered (#98) OR
    // in table mode (#99), where logout must DELETE this device's `_sessions` row. The common
    // epoch-mode, hook-free case keeps the no-writer fast path below (zero overhead).
    if (hasAuthLifecycle(app) or app.session_store == .table) {
        const w = app.pool.acquireWriter();
        defer app.pool.releaseWriter();
        var lc_col = ctx.param("col") orelse "";
        // Best-effort identity: an invalid/expired/absent token logs out anonymously (rid="").
        var rid: []const u8 = "";
        var identity: ?std.json.Value = null;
        var sid: []const u8 = "";
        if (auth.authenticate(app.io, ctx.allocator, app, ctx, w) catch null) |a| {
            rid = recordId(a.record);
            identity = a.record;
            sid = a.sid;
            if (lc_col.len == 0) lc_col = a.collection;
        }
        // Logout performs no transactional write, so a `beforeLogout` hook is writable +
        // abortable but NOT transactional — an abort returns the mapped response and the
        // cookies are NOT cleared (and the session row is left intact).
        if (try fireAuthLifecycleBefore(ctx, w, lc_col, rid, .before_logout, null, identity)) |resp| return resp;
        // Table mode: drop this token's server-side session row (per-device logout).
        if (app.session_store == .table and sid.len > 0) _ = try deleteSession(w, sid);
        const cleared = session.clearedCookies(app.cookie_secure);
        const cookies = try ctx.allocator.dupe(http.Cookie, &cleared);
        emitAuthLifecycle(ctx, w, lc_col, rid, .after_logout, null, identity);
        return .{ .status = 204, .body = "", .cookies = cookies };
    }

    // Fast path (no lifecycle hook, epoch mode): just clear the session cookies. Shared
    // policy: the cleared cookies match what `issue()`/`clearSession` produce.
    const cleared = session.clearedCookies(app.cookie_secure);
    const cookies = try ctx.allocator.dupe(http.Cookie, &cleared);
    return .{ .status = 204, .body = "", .cookies = cookies };
}

// ----------------------------------------------------------------------------
// Email verification & password reset
// ----------------------------------------------------------------------------

fn findByEmail(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, email: []const u8) !?[]const u8 {
    // Case-insensitive when `email` is `.nocase`-indexed, mirroring findByIdentity (#159): PG
    // `lower("email") = lower($1)`; SQLite `"email" COLLATE NOCASE = ?1 COLLATE NOCASE` — both use
    // the `.nocase` index. `lhs`/`rhs` allocate only on the `ci` arm; the frees are guarded to it
    // (otherwise they borrow string literals).
    const d = db.dbDialect(conn);
    const ci = ddl.isNocaseField(col, "email");
    const lhs = if (ci) try d.nocaseEqOperand(alloc, "\"email\"") else "\"email\"";
    defer if (ci) alloc.free(lhs);
    const rhs = if (ci) try d.nocaseEqOperand(alloc, "?1") else "?1";
    defer if (ci) alloc.free(rhs);
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT \"id\" FROM \"{s}\" WHERE {s} = {s} AND \"email\" != '' LIMIT 1;", .{ col.name, lhs, rhs }, 0);
    defer alloc.free(sql);
    var st = try prep(conn, sql);
    defer st.finalize();
    try st.bindText(1, email);
    if (try st.step()) return try alloc.dupe(u8, st.columnText(0));
    return null;
}

/// Deliver a verification/reset token to `email` via the configured mailer. The
/// default mailer (LogMailer) logs the message, preserving the pre-mailer dev/CI
/// behavior; with SMTP configured it sends a real email. Falls back to logging
/// when no mailer is wired (tests/CLI). A real SMTP send failure propagates so it
/// is not silently dropped.
pub fn deliverToken(app: *@import("../app.zig").App, alloc: std.mem.Allocator, email: []const u8, subject: []const u8, body: []const u8) !void {
    if (app.mailer) |m| {
        try m.send(app.io, alloc, .{ .to = email, .subject = subject, .text_body = body });
    } else {
        std.log.info("[mail:fallback] to={s} subject={s} body={s}", .{ email, subject, body });
    }
}

/// Mint a single-use token. `payload` binds an opaque value into the signed `pl` claim;
/// it travels in the same token (bound to its `jti`) and is covered by the HMAC signature,
/// so it cannot be tampered with in transit. Pass `""` when the token carries no payload
/// (verification / password-reset).
pub fn mintToken(ctx: *http.RequestCtx, conn: *db.Db, col_name: []const u8, rid: []const u8, token_key: []const u8, tt: jwt.TokenType, ttl: i64, payload: []const u8) ![]const u8 {
    const app = ctx.app.?;
    const now = try nowUnix(conn);
    const key = crypto.deriveKey(app.jwt_secret, token_key);
    // Random jti makes the token single-use (F7): redemption records it in
    // _consumedTokens; a replay is rejected even within the TTL and independent of
    // the tokenKey-rotation side effect.
    const jti = try crypto.genToken(app.io, ctx.allocator, 32);
    return jwt.sign(ctx.allocator, .{ .id = rid, .collection = col_name, .type = tt, .jti = jti, .pl = payload, .iat = now, .exp = now + ttl }, &key);
}

/// Record a single-use token's `jti` as consumed, or return error.AlreadyConsumed if it
/// was already redeemed. Atomic under the writer lock via the _consumedTokens PRIMARY KEY.
/// A token minted before this mechanism (empty jti) is treated as non-replayable-safe only
/// by the legacy rotation path; we reject an empty jti so every single-use redemption is tracked.
pub fn consumeToken(conn: *db.Db, claims: jwt.Claims) !void {
    if (claims.jti.len == 0) return error.AlreadyConsumed; // no jti => cannot guarantee single-use
    // Classify "already consumed" by the jti's PRESENCE, checked first. consumeToken runs
    // under the single writer lock, so this SELECT-then-INSERT is race-free. This is what
    // lets a genuine INSERT failure below (disk-full, I/O error, etc.) PROPAGATE as an
    // internal error instead of masquerading as error.AlreadyConsumed (a 400).
    {
        var sel = try prep(conn, "SELECT 1 FROM \"_consumedTokens\" WHERE \"jti\" = ?1;");
        defer sel.finalize();
        try sel.bindText(1, claims.jti);
        if (try sel.step()) return error.AlreadyConsumed; // a row exists => already redeemed
    }
    var st = try prep(conn, "INSERT INTO \"_consumedTokens\" (\"jti\",\"expires\",\"consumed\") VALUES (?1,?2,datetime('now'));");
    defer st.finalize();
    try st.bindText(1, claims.jti);
    try st.bindInt(2, claims.exp);
    _ = try st.step(); // a real DB failure propagates (500); it is no longer mistaken for a replay
}

fn loadAuthCollection(ctx: *http.RequestCtx, conn: *db.Db) !?schema.Collection {
    const col_name = ctx.param("col") orelse return null;
    const col = (try collections.get(ctx.allocator, conn, col_name)) orelse return null;
    if (col.type != .auth) return null;
    return col;
}

/// Verify a typed token against the record's derived key. Returns claims on success.
pub fn verifyTyped(ctx: *http.RequestCtx, conn: *db.Db, col: schema.Collection, token: []const u8, want: jwt.TokenType) !?jwt.Claims {
    const app = ctx.app.?;
    const claims = jwt.peekClaims(ctx.allocator, token) catch return null;
    if (claims.type != want) return null;
    if (!std.mem.eql(u8, claims.collection, col.name)) return null;
    const tk = (try tokenKeyFor(ctx.allocator, conn, col.name, claims.id)) orelse return null;
    const key = crypto.deriveKey(app.jwt_secret, tk);
    const now = try nowUnix(conn);
    const verified = jwt.verify(ctx.allocator, token, &key, now) catch return null;
    return verified;
}

pub fn requestVerification(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    // Rate-limit gate (email-bombing defense): per client IP, falling back to the
    // submitted email. Gated BEFORE the writer lock so a limited request never holds it.
    const rl_email = if (parseBody(ctx)) |b| (strField(b, "email") orelse "") else "";
    if (try rateLimited(ctx, "verify", rl_email)) |resp| return resp;
    // Strings are arena-allocated (ctx.allocator), so they outlive the scoped
    // writer block below and remain valid for the post-lock SMTP send.
    var pending: ?struct { email: []const u8, mail_body: []const u8 } = null;
    {
        const w = app.pool.acquireWriter();
        defer app.pool.releaseWriter();
        const col = (try loadAuthCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
        const body = parseBody(ctx) orelse return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator);
        if (strField(body, "email")) |email| {
            if (try findByEmail(ctx.allocator, w, col, email)) |rid| {
                if (try tokenKeyFor(ctx.allocator, w, col.name, rid)) |tk| {
                    const token = try mintToken(ctx, w, col.name, rid, tk, .verification, app.verification_ttl_s, "");
                    const mail_body = try std.fmt.allocPrint(ctx.allocator, "Verify your email ({s}). Your verification token:\n\n{s}\n", .{ col.name, token });
                    pending = .{ .email = email, .mail_body = mail_body };
                }
            }
        }
    }
    // Writer lock released: do the blocking SMTP send outside the global lock.
    if (pending) |p| {
        try deliverToken(app, ctx.allocator, p.email, "Verify your email", p.mail_body);
    }
    return .{ .status = 204, .body = "" };
}

pub fn confirmVerification(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col = (try loadAuthCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const body = parseBody(ctx) orelse return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator);
    const token = strField(body, "token") orelse return ApiError.badRequest("token is required.").toResponse(ctx.allocator);
    const claims = (try verifyTyped(ctx, w, col, token, .verification)) orelse
        return ApiError.badRequest("Invalid or expired token.").toResponse(ctx.allocator);
    // Single-use (F7): redeeming the same token twice fails here even within the TTL.
    consumeToken(w, claims) catch
        return ApiError.badRequest("Invalid or expired token.").toResponse(ctx.allocator);
    const sql = try std.fmt.allocPrintSentinel(ctx.allocator, "UPDATE \"{s}\" SET \"verified\" = 1 WHERE \"id\" = ?1;", .{col.name}, 0);
    var st = try prep(w, sql);
    defer st.finalize();
    try st.bindText(1, claims.id);
    _ = try st.step();
    return .{ .status = 200, .body = "{\"verified\":true}" };
}

pub fn requestPasswordReset(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    // Rate-limit gate (email-bombing defense): per client IP, falling back to the
    // submitted email. Gated BEFORE the writer lock so a limited request never holds it.
    const rl_email = if (parseBody(ctx)) |b| (strField(b, "email") orelse "") else "";
    if (try rateLimited(ctx, "reset", rl_email)) |resp| return resp;
    // Strings are arena-allocated (ctx.allocator), so they outlive the scoped
    // writer block below and remain valid for the post-lock SMTP send.
    var pending: ?struct { email: []const u8, mail_body: []const u8 } = null;
    {
        const w = app.pool.acquireWriter();
        defer app.pool.releaseWriter();
        const col = (try loadAuthCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
        const body = parseBody(ctx) orelse return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator);
        if (strField(body, "email")) |email| {
            if (try findByEmail(ctx.allocator, w, col, email)) |rid| {
                if (try tokenKeyFor(ctx.allocator, w, col.name, rid)) |tk| {
                    const token = try mintToken(ctx, w, col.name, rid, tk, .password_reset, app.password_reset_ttl_s, "");
                    const mail_body = try std.fmt.allocPrint(ctx.allocator, "Reset your password ({s}). Your password-reset token:\n\n{s}\n", .{ col.name, token });
                    pending = .{ .email = email, .mail_body = mail_body };
                }
            }
        }
    }
    // Writer lock released: do the blocking SMTP send outside the global lock.
    if (pending) |p| {
        try deliverToken(app, ctx.allocator, p.email, "Reset your password", p.mail_body);
    }
    return .{ .status = 204, .body = "" };
}

pub fn confirmPasswordReset(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col = (try loadAuthCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const body = parseBody(ctx) orelse return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator);
    const token = strField(body, "token") orelse return ApiError.badRequest("token is required.").toResponse(ctx.allocator);
    const password = strField(body, "password") orelse return ApiError.badRequest("password is required.").toResponse(ctx.allocator);
    const claims = (try verifyTyped(ctx, w, col, token, .password_reset)) orelse
        return ApiError.badRequest("Invalid or expired token.").toResponse(ctx.allocator);
    // Validate the new password BEFORE consuming so a too-short password does not burn
    // the (still single-use) token.
    if (password.len < col.options.auth.minPasswordLength)
        return ApiError.badRequest("Password too short.").toResponse(ctx.allocator);
    // Transactional password change (#98): consume + beforePasswordChange + the password
    // UPDATE commit atomically. An aborting `beforePasswordChange` rolls back BOTH the token
    // consumption (the reset link stays usable) and the password update (fail closed).
    try w.beginImmediate();
    // Safety net for every error-return after begin; value-returns below roll back explicitly.
    errdefer w.rollback() catch {};
    // Single-use (F7): consume before applying the change so a replay (even within the
    // TTL, before the tokenKey rotation that records.update triggers) is rejected.
    consumeToken(w, claims) catch {
        w.rollback() catch {};
        return ApiError.badRequest("Invalid or expired token.").toResponse(ctx.allocator);
    };
    // Existing record snapshot for the hook (read on the same in-transaction conn).
    // Use `try` (not `catch null`): a genuine DB failure must propagate so the errdefer
    // rolls back (token un-consumed, password unchanged → clean 500) rather than feeding a
    // null record/identity to a `before_password_change` authorization hook. `records.get`
    // returns null only for genuine not-found, so that path is preserved below.
    var rec_opt = try records.get(ctx.allocator, w, col, claims.id);
    const rec_ptr: ?*std.json.Value = if (rec_opt) |*r| r else null;
    if (try fireAuthLifecycleBefore(ctx, w, col.name, claims.id, .before_password_change, rec_ptr, rec_opt)) |resp| {
        w.rollback() catch {};
        return resp;
    }
    var data: std.json.ObjectMap = .empty;
    try data.put(ctx.allocator, "password", .{ .string = password });
    const updated = auth.applyUpdate(app.io, ctx.allocator, .{ .object = data }, col.options.auth.minPasswordLength) catch {
        w.rollback() catch {};
        return ApiError.badRequest("Invalid password.").toResponse(ctx.allocator);
    };
    _ = records.update(ctx.allocator, w, col, claims.id, updated) catch {
        w.rollback() catch {};
        return ApiError.internal().toResponse(ctx.allocator);
    };
    w.commit() catch |e| {
        w.rollback() catch {};
        return e;
    };
    emitAuthLifecycle(ctx, w, col.name, claims.id, .after_password_change, rec_ptr, rec_opt);
    return .{ .status = 200, .body = "{\"success\":true}" };
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const app_mod = @import("../app.zig");
const migrations = @import("../migrations.zig");

pub const TestEnv = struct {
    tmp: std.testing.TmpDir,
    pool: db.Pool,
    app: app_mod.App,

    pub fn initAuth(name: []const u8) !*TestEnv {
        const env = try std.testing.allocator.create(TestEnv);
        env.tmp = std.testing.tmpDir(.{});
        const dir = try env.tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(dir);
        const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/test.db", .{dir}, 0);
        defer std.testing.allocator.free(path);
        env.pool = try db.Pool.init(std.testing.allocator, std.testing.io, path);
        {
            const w = env.pool.acquireWriter();
            defer env.pool.releaseWriter();
            try migrations.run(w);
            var setup_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer setup_arena.deinit();
            const sa = setup_arena.allocator();
            _ = try collections.create(sa, std.testing.io, w, .{
                .id = "",
                .name = name,
                .type = .auth,
                .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
                .listRule = "",
                .viewRule = "",
                .createRule = "",
                .updateRule = "",
                .deleteRule = "",
            });
        }
        env.app = .{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = &env.pool };
        return env;
    }

    pub fn deinit(env: *TestEnv) void {
        env.pool.deinit();
        env.tmp.cleanup();
        std.testing.allocator.destroy(env);
    }

    /// Create an auth record the same way the records API would (hash password,
    /// gen tokenKey, force verified=false), then insert via the records engine.
    pub fn createUser(env: *TestEnv, a: std.mem.Allocator, col_name: []const u8, email: []const u8, pw: []const u8) !void {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const col = (try collections.get(a, w, col_name)) orelse return error.NoCollection;
        var data: std.json.ObjectMap = .empty;
        try data.put(a, "email", .{ .string = email });
        try data.put(a, "password", .{ .string = pw });
        const prepared = try auth.applyCreate(env.app.io, a, .{ .object = data }, col.options.auth.minPasswordLength);
        _ = try records.create(a, env.app.io, w, col, prepared);
    }

    pub fn ctx(env: *TestEnv, a: std.mem.Allocator, m: http.Method, body: []const u8, params: []const http.Param) http.RequestCtx {
        return .{ .method = m, .path = "/", .body = body, .allocator = a, .app = &env.app, .params = params };
    }

    /// Mint a typed token (verification/password_reset) for the record matching `email`.
    fn mintTyped(self: *TestEnv, a: std.mem.Allocator, col_name: []const u8, email: []const u8, tt: jwt.TokenType) ![]const u8 {
        const w = self.pool.acquireWriter();
        defer self.pool.releaseWriter();
        const col = (try collections.get(a, w, col_name)).?;
        const rid = (try findByIdentity(a, w, col, email)).?;
        const tk = (try tokenKeyFor(a, w, col.name, rid)).?;
        const now = try nowUnix(w);
        const key = crypto.deriveKey(self.app.jwt_secret, tk);
        const jti = try crypto.genToken(self.app.io, a, 32);
        return jwt.sign(a, .{ .id = rid, .collection = col_name, .type = tt, .jti = jti, .iat = now, .exp = now + 100000 }, &key);
    }

    /// Initialize a TestEnv with a webauthn-configured auth collection.
    /// The collection has rp_id="example.test", rp_name="Test App", origin="https://example.test".
    pub fn initWebAuthn(name: []const u8) !*TestEnv {
        const env = try std.testing.allocator.create(TestEnv);
        env.tmp = std.testing.tmpDir(.{});
        const dir = try env.tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(dir);
        const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/test.db", .{dir}, 0);
        defer std.testing.allocator.free(path);
        env.pool = try db.Pool.init(std.testing.allocator, std.testing.io, path);
        {
            const w = env.pool.acquireWriter();
            defer env.pool.releaseWriter();
            try migrations.run(w);
            var setup_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer setup_arena.deinit();
            const sa = setup_arena.allocator();
            _ = try collections.create(sa, std.testing.io, w, .{
                .id = "",
                .name = name,
                .type = .auth,
                .fields = &[_]schema.Field{},
                .listRule = "",
                .viewRule = "",
                .createRule = "",
                .updateRule = "",
                .deleteRule = "",
                .options = .{ .auth = .{ .methods = .{ .webauthn = .{
                    .rp_id = "example.test",
                    .rp_name = "Test App",
                    .origin = "https://example.test",
                } } } },
            });
        }
        env.app = .{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = &env.pool };
        return env;
    }

    fn recordVerified(self: *TestEnv, a: std.mem.Allocator, col_name: []const u8, email: []const u8) bool {
        const w = self.pool.acquireWriter();
        defer self.pool.releaseWriter();
        const col = (collections.get(a, w, col_name) catch return false).?;
        const rid = (findByIdentity(a, w, col, email) catch return false) orelse return false;
        const sql = std.fmt.allocPrintSentinel(a, "SELECT \"verified\" FROM \"{s}\" WHERE \"id\" = ?1;", .{col.name}, 0) catch return false;
        var st = w.prepare(sql) catch return false;
        defer st.finalize();
        st.bindText(1, rid) catch return false;
        if (!(st.step() catch return false)) return false;
        return st.columnInt(0) != 0;
    }
};

test "auth-with-password issues a token + cookies, wrong password 400" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "u@x.io", "longenough");

    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var ok = env.ctx(a, .POST, "{\"identity\":\"u@x.io\",\"password\":\"longenough\"}", &p);
    const res = try authWithPassword(&ok);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"token\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"record\":") != null);
    var saw_auth = false;
    var saw_csrf = false;
    for (res.cookies) |c| {
        if (std.mem.eql(u8, c.name, "zb_auth")) {
            saw_auth = true;
            try std.testing.expect(c.http_only);
        }
        if (std.mem.eql(u8, c.name, "zb_csrf")) {
            saw_csrf = true;
            try std.testing.expect(!c.http_only);
        }
    }
    try std.testing.expect(saw_auth and saw_csrf);

    var bad = env.ctx(a, .POST, "{\"identity\":\"u@x.io\",\"password\":\"wrongwrong\"}", &p);
    try std.testing.expectEqual(@as(u16, 400), (try authWithPassword(&bad)).status);
}

test "auth-logout clears the cookies" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var ctx = env.ctx(a, .POST, "", &p);
    const res = try authLogout(&ctx);
    try std.testing.expectEqual(@as(u16, 204), res.status);
    var cleared: usize = 0;
    for (res.cookies) |c| if (c.max_age_s < 0) {
        cleared += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), cleared);
}

test "auth-with-password then authenticate round-trips the issued token (bearer)" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "rt@x.io", "longenough");
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var login = env.ctx(a, .POST, "{\"identity\":\"rt@x.io\",\"password\":\"longenough\"}", &p);
    const res = try authWithPassword(&login);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, res.body, .{});
    const token = parsed.value.object.get("token").?.string;
    // refresh with the bearer token should succeed (200)
    var refresh = env.ctx(a, .POST, "", &p);
    refresh.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    try std.testing.expectEqual(@as(u16, 200), (try authRefresh(&refresh)).status);
}

test "verification: request always 204; confirm sets verified=true" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "v@x.io", "longenough");
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};

    var req = env.ctx(a, .POST, "{\"email\":\"v@x.io\"}", &p);
    try std.testing.expectEqual(@as(u16, 204), (try requestVerification(&req)).status);
    var req_missing = env.ctx(a, .POST, "{\"email\":\"nobody@x.io\"}", &p);
    try std.testing.expectEqual(@as(u16, 204), (try requestVerification(&req_missing)).status);

    const token = try env.mintTyped(a, "users", "v@x.io", .verification);
    const body = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\"}}", .{token});
    var conf = env.ctx(a, .POST, body, &p);
    try std.testing.expectEqual(@as(u16, 200), (try confirmVerification(&conf)).status);
    try std.testing.expect(env.recordVerified(a, "users", "v@x.io"));
}

test "password reset: confirm changes the password and rotates the token" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "r@x.io", "oldpassword");
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    const token = try env.mintTyped(a, "users", "r@x.io", .password_reset);
    const body = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\",\"password\":\"newpassword\"}}", .{token});
    var conf = env.ctx(a, .POST, body, &p);
    try std.testing.expectEqual(@as(u16, 200), (try confirmPasswordReset(&conf)).status);
    var conf2 = env.ctx(a, .POST, body, &p);
    try std.testing.expectEqual(@as(u16, 400), (try confirmPasswordReset(&conf2)).status);
}

// --- F7: strict single-use tokens (independent of tokenKey rotation) ---

test "F7: consumeToken classifies replay by jti presence, not by any INSERT failure" {
    // Normal ledger: a fresh jti is recorded; an identical second redemption is a replay.
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec("CREATE TABLE \"_consumedTokens\" (\"jti\" TEXT PRIMARY KEY, \"expires\" INTEGER, \"consumed\" TEXT);");
    const claims = jwt.Claims{ .id = "u1", .collection = "users", .type = .verification, .jti = "abc123", .iat = 0, .exp = 9_999_999_999 };
    try consumeToken(&d, claims);
    try std.testing.expectError(error.AlreadyConsumed, consumeToken(&d, claims));

    // Regression: a NON-replay INSERT failure (here a CHECK violation on a fresh jti) must
    // PROPAGATE as a DB error, not be misreported as error.AlreadyConsumed — the old
    // `step() catch return error.AlreadyConsumed` swallowed every failure (disk-full, I/O, …).
    var d2 = try db.Db.openMemory();
    defer d2.close();
    try d2.exec("CREATE TABLE \"_consumedTokens\" (\"jti\" TEXT PRIMARY KEY CHECK(length(\"jti\") < 3), \"expires\" INTEGER, \"consumed\" TEXT);");
    try std.testing.expectError(error.StepFailed, consumeToken(&d2, claims));

    // An empty jti is rejected outright (cannot be tracked single-use).
    const nojti = jwt.Claims{ .id = "u1", .collection = "users", .type = .verification, .jti = "", .iat = 0, .exp = 1 };
    try std.testing.expectError(error.AlreadyConsumed, consumeToken(&d2, nojti));
}

test "F7: a verification token cannot be redeemed twice (single-use)" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "v2@x.io", "longenough");
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    const token = try env.mintTyped(a, "users", "v2@x.io", .verification);
    const body = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\"}}", .{token});
    // First redemption succeeds. Verification does NOT rotate tokenKey, so without the
    // single-use ledger this token would remain replayable for its full TTL.
    var c1 = env.ctx(a, .POST, body, &p);
    try std.testing.expectEqual(@as(u16, 200), (try confirmVerification(&c1)).status);
    try std.testing.expect(env.recordVerified(a, "users", "v2@x.io"));
    // Second redemption of the very same (still-unexpired) token must fail.
    var c2 = env.ctx(a, .POST, body, &p);
    try std.testing.expectEqual(@as(u16, 400), (try confirmVerification(&c2)).status);
}

test "F7: a password-reset token cannot be redeemed twice (single-use)" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "r2@x.io", "oldpassword");
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    const token = try env.mintTyped(a, "users", "r2@x.io", .password_reset);
    const body = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\",\"password\":\"newpassword\"}}", .{token});
    var c1 = env.ctx(a, .POST, body, &p);
    try std.testing.expectEqual(@as(u16, 200), (try confirmPasswordReset(&c1)).status);
    // Replay rejected even though we re-send the identical valid-window token.
    var c2 = env.ctx(a, .POST, body, &p);
    try std.testing.expectEqual(@as(u16, 400), (try confirmPasswordReset(&c2)).status);
}

test "F7: a too-short password does not consume the reset token" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "r3@x.io", "oldpassword");
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    const token = try env.mintTyped(a, "users", "r3@x.io", .password_reset);
    const short = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\",\"password\":\"x\"}}", .{token});
    var bad = env.ctx(a, .POST, short, &p);
    try std.testing.expectEqual(@as(u16, 400), (try confirmPasswordReset(&bad)).status); // too short
    // The token survives the failed attempt and still works once.
    const ok = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\",\"password\":\"newpassword\"}}", .{token});
    var good = env.ctx(a, .POST, ok, &p);
    try std.testing.expectEqual(@as(u16, 200), (try confirmPasswordReset(&good)).status);
}

test "require_verified gates password login: unverified 403, verified 200" {
    var env = try TestEnv.initAuth("gated");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Recreate the collection with require_verified = true (initAuth made a default one).
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const existing = (try collections.get(a, w, "gated")).?;
        try collections.delete(a, w, existing.id);
        _ = try collections.create(a, std.testing.io, w, .{
            .id = "", .name = "gated", .type = .auth,
            .fields = &[_]schema.Field{},
            .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "",
            .options = .{ .auth = .{ .require_verified = true } },
        });
    }
    try env.createUser(a, "gated", "g@x.io", "longenough"); // created verified=false

    const p = [_]http.Param{.{ .key = "col", .value = "gated" }};
    var login = env.ctx(a, .POST, "{\"identity\":\"g@x.io\",\"password\":\"longenough\"}", &p);
    try std.testing.expectEqual(@as(u16, 403), (try authWithPassword(&login)).status);

    // Mark verified, then login succeeds.
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try w.exec("UPDATE \"gated\" SET \"verified\" = 1 WHERE \"email\" = 'g@x.io';");
    }
    var login2 = env.ctx(a, .POST, "{\"identity\":\"g@x.io\",\"password\":\"longenough\"}", &p);
    try std.testing.expectEqual(@as(u16, 200), (try authWithPassword(&login2)).status);
}

test "RouteEvent.issueSession mints a session and fires onAuth(custom)" {
    var env = try TestEnv.initAuth("members");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "members", "r@x.io", "longenough");
    // resolve rid
    const w0 = env.pool.acquireWriter();
    const col = (try collections.get(a, w0, "members")).?;
    const rid = (try findByIdentity(a, w0, col, "r@x.io")).?;
    env.pool.releaseWriter();

    const Counter = struct { var seen: usize = 0; var m: events.AuthMethod = .password;
        fn h(ev: *events.AuthEvent) void { seen += 1; m = ev.method; } };
    Counter.seen = 0;
    var disp = events.Dispatch{ .on_auth = Counter.h };
    env.app.dispatch = &disp;

    var hctx = env.ctx(a, .POST, "", &[_]http.Param{});
    var rctx = events.RouteEvent{ .app = &env.app, .ctx = &hctx, .rctx = .{} };
    const issued = try rctx.issueSession("members", rid);
    try std.testing.expectEqual(@as(usize, 2), issued.cookies.len);
    try std.testing.expectEqual(@as(usize, 1), Counter.seen);
    try std.testing.expectEqual(events.AuthMethod.custom, Counter.m);
}

// --- #99: session epoch revocation (Variant A) ---

/// Resolve a user's row id in `col_name`.
fn ridOf(env: *TestEnv, a: std.mem.Allocator, col_name: []const u8, email: []const u8) ![]const u8 {
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    const col = (try collections.get(a, w, col_name)).?;
    return (try findByIdentity(a, w, col, email)).?;
}

test "#99 epoch bump invalidates outstanding tokens; a freshly issued token verifies (revoke-all)" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "ep@x.io", "longenough");
    const rid = try ridOf(env, a, "users", "ep@x.io");

    var hctx = env.ctx(a, .POST, "", &[_]http.Param{});

    // Issue a session token at epoch 0; it verifies.
    const issued0 = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk try issueSession(&hctx, w, "users", rid, .password);
    };
    {
        var r = try env.pool.acquireReader();
        defer env.pool.releaseReader(&r);
        try std.testing.expect(auth.verifyToken(a, &env.app, &r, issued0.token) != null);
    }

    // "Revoke all sessions": bump the record's epoch (0 -> 1).
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try std.testing.expectEqual(@as(i64, 1), try bumpTokenEpoch(a, w, "users", rid));
    }

    // The previously valid token now FAILS verification (fail closed).
    {
        var r = try env.pool.acquireReader();
        defer env.pool.releaseReader(&r);
        try std.testing.expect(auth.verifyToken(a, &env.app, &r, issued0.token) == null);
    }

    // A token issued AFTER the bump carries epoch 1 and verifies again.
    const issued1 = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk try issueSession(&hctx, w, "users", rid, .password);
    };
    {
        var r = try env.pool.acquireReader();
        defer env.pool.releaseReader(&r);
        try std.testing.expect(auth.verifyToken(a, &env.app, &r, issued1.token) != null);
    }
}

fn loadRecord(env: *TestEnv, a: std.mem.Allocator, col_name: []const u8, rid: []const u8) !std.json.Value {
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    const col = (try collections.get(a, w, col_name)).?;
    return (try records.get(a, w, col, rid)).?;
}

test "#99 ctx.auth().revokeAllSessions invalidates the principal's tokens" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "rv@x.io", "longenough");
    const rid = try ridOf(env, a, "users", "rv@x.io");
    const rec = try loadRecord(env, a, "users", rid);

    var hctx = env.ctx(a, .POST, "", &[_]http.Param{});
    const issued = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk try issueSession(&hctx, w, "users", rid, .password);
    };

    var cx = Ctx{ .app = &env.app, .arena = a, .rctx = .{ .auth = rec, .collection = "users" }, .request = &hctx };
    defer cx.deinit();
    try cx.auth().revokeAllSessions(); // acquires the writer internally

    var r = try env.pool.acquireReader();
    defer env.pool.releaseReader(&r);
    try std.testing.expect(auth.verifyToken(a, &env.app, &r, issued.token) == null);
}

test "#99 ctx.auth().refresh keeps other sessions valid; rotate kills them" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "rr@x.io", "longenough");
    const rid = try ridOf(env, a, "users", "rr@x.io");
    const rec = try loadRecord(env, a, "users", rid);

    var hctx = env.ctx(a, .POST, "", &[_]http.Param{});
    // An existing session token (epoch 0).
    const existing = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk try issueSession(&hctx, w, "users", rid, .password);
    };

    var cx = Ctx{ .app = &env.app, .arena = a, .rctx = .{ .auth = rec, .collection = "users" }, .request = &hctx };
    defer cx.deinit();

    // refresh: a new token is minted AND the existing one stays valid (same epoch).
    const refreshed = try cx.auth().refresh();
    {
        var r = try env.pool.acquireReader();
        defer env.pool.releaseReader(&r);
        try std.testing.expect(auth.verifyToken(a, &env.app, &r, refreshed.token) != null);
        try std.testing.expect(auth.verifyToken(a, &env.app, &r, existing.token) != null);
    }

    // rotate: returns a fresh valid token, but every PRIOR token (existing + refreshed) dies.
    const rotated = try cx.auth().rotate();
    {
        var r = try env.pool.acquireReader();
        defer env.pool.releaseReader(&r);
        try std.testing.expect(auth.verifyToken(a, &env.app, &r, rotated.token) != null);
        try std.testing.expect(auth.verifyToken(a, &env.app, &r, existing.token) == null);
        try std.testing.expect(auth.verifyToken(a, &env.app, &r, refreshed.token) == null);
    }
}

// --- #99: Variant B server-side session store (.table mode) ---

/// COUNT(*) of `_sessions` rows (optionally for one principal).
fn sessionCount(env: *TestEnv) !i64 {
    var r = try env.pool.acquireReader();
    defer env.pool.releaseReader(&r);
    var st = try r.prepare("SELECT COUNT(*) FROM \"_sessions\";");
    defer st.finalize();
    _ = try st.step();
    return st.columnInt(0);
}

test "#99 epoch mode writes NO _sessions row and the token carries no sid (zero overhead)" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "z@x.io", "longenough");
    const rid = try ridOf(env, a, "users", "z@x.io");
    // Default mode is .epoch.
    try std.testing.expectEqual(@import("../app.zig").SessionStore.epoch, env.app.session_store);

    var hctx = env.ctx(a, .POST, "", &[_]http.Param{});
    const issued = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk try issueSession(&hctx, w, "users", rid, .password);
    };
    // No session row was written, and the token has no sid claim.
    try std.testing.expectEqual(@as(i64, 0), try sessionCount(env));
    const claims = try jwt.peekClaims(a, issued.token);
    try std.testing.expect(claims.sid == null);
}

test "#99 table mode: login writes a row, token has sid, verify accepts; revoke -> fail closed" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    env.app.session_store = .table;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "t@x.io", "longenough");
    const rid = try ridOf(env, a, "users", "t@x.io");

    var hctx = env.ctx(a, .POST, "", &[_]http.Param{});
    const issued = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk try issueSession(&hctx, w, "users", rid, .password);
    };
    // A session row exists and the token carries its sid.
    try std.testing.expectEqual(@as(i64, 1), try sessionCount(env));
    const claims = try jwt.peekClaims(a, issued.token);
    const sid = claims.sid.?;
    try std.testing.expect(sid.len > 0);

    // Verify accepts (session present + unexpired).
    {
        var r = try env.pool.acquireReader();
        defer env.pool.releaseReader(&r);
        try std.testing.expect(auth.verifyToken(a, &env.app, &r, issued.token) != null);
    }
    // Revoke the row -> verify now rejects (fail closed) even though epoch is unchanged.
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try std.testing.expect(try deleteSession(w, sid));
    }
    {
        var r = try env.pool.acquireReader();
        defer env.pool.releaseReader(&r);
        try std.testing.expect(auth.verifyToken(a, &env.app, &r, issued.token) == null);
    }
}

test "#99 table mode: authWithPassword (reader->writer) records a session + token carries sid" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    env.app.session_store = .table;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "pw@x.io", "longenough");

    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var login = env.ctx(a, .POST, "{\"identity\":\"pw@x.io\",\"password\":\"longenough\"}", &p);
    const res = try authWithPassword(&login);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    // The full login path (reader for argon2, writer for the session INSERT) wrote one row.
    try std.testing.expectEqual(@as(i64, 1), try sessionCount(env));
    const parsed = try std.json.parseFromSlice(std.json.Value, a, res.body, .{});
    const token = parsed.value.object.get("token").?.string;
    try std.testing.expect((try jwt.peekClaims(a, token)).sid != null);

    // A follow-up write still succeeds — the writer was released after the login INSERT.
    const w = env.pool.acquireWriter();
    env.pool.releaseWriter();
    _ = w;
}

test "#99 table mode: an expired session row is rejected by verify" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    env.app.session_store = .table;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "exp@x.io", "longenough");
    const rid = try ridOf(env, a, "users", "exp@x.io");

    var hctx = env.ctx(a, .POST, "", &[_]http.Param{});
    const issued = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk try issueSession(&hctx, w, "users", rid, .password);
    };
    const sid = (try jwt.peekClaims(a, issued.token)).sid.?;
    // Force the session row to be expired.
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        var st = try w.prepare("UPDATE \"_sessions\" SET \"expires\" = 1 WHERE \"id\" = ?1;");
        defer st.finalize();
        try st.bindText(1, sid);
        _ = try st.step();
    }
    var r = try env.pool.acquireReader();
    defer env.pool.releaseReader(&r);
    try std.testing.expect(auth.verifyToken(a, &env.app, &r, issued.token) == null);
}

test "#99 table mode: listActiveSessions + is_current; revoke authorizes owner-or-superuser" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    env.app.session_store = .table;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "owner@x.io", "longenough");
    try env.createUser(a, "users", "other@x.io", "longenough");
    const rid = try ridOf(env, a, "users", "owner@x.io");
    const other_rid = try ridOf(env, a, "users", "other@x.io");
    const rec = try loadRecord(env, a, "users", rid);

    var hctx = env.ctx(a, .POST, "", &[_]http.Param{});
    // Two sessions for the owner.
    const s1 = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk try issueSession(&hctx, w, "users", rid, .password);
    };
    _ = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk try issueSession(&hctx, w, "users", rid, .password);
    };
    const sid1 = (try jwt.peekClaims(a, s1.token)).sid.?;

    // ctx for the owner, authenticated with session s1.
    var cx = Ctx{ .app = &env.app, .arena = a, .rctx = .{ .auth = rec, .collection = "users", .session_id = sid1 }, .request = &hctx };
    defer cx.deinit();

    const list = try cx.auth().listActiveSessions();
    try std.testing.expectEqual(@as(usize, 2), list.len);
    var current_seen = false;
    for (list) |s| if (std.mem.eql(u8, s.id, sid1)) {
        current_seen = true;
        try std.testing.expect(s.is_current);
    } else try std.testing.expect(!s.is_current);
    try std.testing.expect(current_seen);

    // A DIFFERENT user may not revoke the owner's session (fail closed). The error is
    // NotFound (indistinguishable from an absent id) — no existence oracle on others' sids.
    const other_rec = try loadRecord(env, a, "users", other_rid);
    var other_cx = Ctx{ .app = &env.app, .arena = a, .rctx = .{ .auth = other_rec, .collection = "users" }, .request = &hctx };
    defer other_cx.deinit();
    try std.testing.expectError(error.NotFound, other_cx.auth().revoke(sid1));
    // Probing a non-existent id yields the SAME error (proves indistinguishability).
    try std.testing.expectError(error.NotFound, other_cx.auth().revoke("does-not-exist"));
    try std.testing.expectEqual(@as(i64, 2), try sessionCount(env)); // nothing deleted

    // The owner CAN revoke their own session.
    try cx.auth().revoke(sid1);
    try std.testing.expectEqual(@as(i64, 1), try sessionCount(env));
}

test "#99 table mode: refresh preserves created (session start) and advances last_seen" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    env.app.session_store = .table;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "rs@x.io", "longenough");
    const rid = try ridOf(env, a, "users", "rs@x.io");
    const rec = try loadRecord(env, a, "users", rid);

    var hctx = env.ctx(a, .POST, "", &[_]http.Param{});
    const s1 = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk try issueSession(&hctx, w, "users", rid, .password);
    };
    const sid1 = (try jwt.peekClaims(a, s1.token)).sid.?;
    // Backdate the original session so the carried `created` is distinguishable from `now`.
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        var st = try w.prepare("UPDATE \"_sessions\" SET \"created\"='2020-01-01 00:00:00', \"lastSeen\"='2020-01-01 00:00:00' WHERE \"id\"=?1;");
        defer st.finalize();
        try st.bindText(1, sid1);
        _ = try st.step();
    }

    // Refresh rotates the row (delete old + insert new). created must carry forward; last_seen advances.
    var cx = Ctx{ .app = &env.app, .arena = a, .rctx = .{ .auth = rec, .collection = "users", .session_id = sid1 }, .request = &hctx };
    defer cx.deinit();
    _ = try cx.auth().refresh();

    // Exactly one row remains; read its created + lastSeen.
    try std.testing.expectEqual(@as(i64, 1), try sessionCount(env));
    var r = try env.pool.acquireReader();
    defer env.pool.releaseReader(&r);
    var st = try r.prepare("SELECT \"created\", \"lastSeen\" FROM \"_sessions\" LIMIT 1;");
    defer st.finalize();
    try std.testing.expect(try st.step());
    const created = st.columnText(0);
    const last_seen = st.columnText(1);
    // created carried forward from the original session (true session start).
    try std.testing.expectEqualStrings("2020-01-01 00:00:00", created);
    // last_seen advanced to the refresh time (no longer equal to the backdated created).
    try std.testing.expect(!std.mem.eql(u8, last_seen, "2020-01-01 00:00:00"));
}

test "#99 table mode: logout deletes the current device's session row" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    env.app.session_store = .table;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "lo@x.io", "longenough");
    const rid = try ridOf(env, a, "users", "lo@x.io");

    var hctx = env.ctx(a, .POST, "", &[_]http.Param{});
    const issued = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk try issueSession(&hctx, w, "users", rid, .password);
    };
    try std.testing.expectEqual(@as(i64, 1), try sessionCount(env));

    // Logout with this token (bearer) deletes the row.
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var lo = env.ctx(a, .POST, "", &p);
    lo.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{issued.token});
    try std.testing.expectEqual(@as(u16, 204), (try authLogout(&lo)).status);
    try std.testing.expectEqual(@as(i64, 0), try sessionCount(env));
}

test "#99 table mode: revokeAllSessions clears the principal's rows + bumps epoch" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    env.app.session_store = .table;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "ra@x.io", "longenough");
    const rid = try ridOf(env, a, "users", "ra@x.io");
    const rec = try loadRecord(env, a, "users", rid);

    var hctx = env.ctx(a, .POST, "", &[_]http.Param{});
    var n: usize = 0;
    while (n < 3) : (n += 1) {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        _ = try issueSession(&hctx, w, "users", rid, .password);
    }
    try std.testing.expectEqual(@as(i64, 3), try sessionCount(env));

    var cx = Ctx{ .app = &env.app, .arena = a, .rctx = .{ .auth = rec, .collection = "users" }, .request = &hctx };
    defer cx.deinit();
    try cx.auth().revokeAllSessions();
    try std.testing.expectEqual(@as(i64, 0), try sessionCount(env)); // all rows cleared
}

test "#99 table mode: an unauthorized revoke (error path) does not poison the writer" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    env.app.session_store = .table;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "wl@x.io", "longenough");
    const rid = try ridOf(env, a, "users", "wl@x.io");
    const rec = try loadRecord(env, a, "users", rid);

    var hctx = env.ctx(a, .POST, "", &[_]http.Param{});
    var cx = Ctx{ .app = &env.app, .arena = a, .rctx = .{ .auth = rec, .collection = "users" }, .request = &hctx };
    defer cx.deinit();

    // Error path: revoking a non-existent session id returns NotFound (acquires + releases
    // the writer). It must NOT leave the writer locked/poisoned.
    try std.testing.expectError(error.NotFound, cx.auth().revoke("no-such-session"));

    // A follow-up write must still succeed — proving the writer was released cleanly.
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    const issued = try issueSession(&hctx, w, "users", rid, .password);
    try std.testing.expect(issued.token.len > 0);
}

// --- #114: expired-session GC sweep ---

/// Insert a bare `_sessions` row with a chosen `expires` (null = no expiry). Writer-acquiring.
fn insertSessionRow(env: *TestEnv, id: []const u8, expires: ?i64) !void {
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    var st = try w.prepare(
        \\INSERT INTO "_sessions" ("id","collectionRef","recordRef","created","lastSeen","expires","userAgent","ip")
        \\ VALUES (?1,'users','u1',datetime('now'),datetime('now'),?2,'','');
    );
    defer st.finalize();
    try st.bindText(1, id);
    if (expires) |e| try st.bindInt(2, e) else try st.bindNull(2);
    _ = try st.step();
}

test "#114 gcExpiredSessions deletes expired rows; NULL/future survive" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try insertSessionRow(env, "past", 1); // long-expired (unix secs)
    try insertSessionRow(env, "noexp", null); // never expires
    try insertSessionRow(env, "future", 9_999_999_999); // far future
    try std.testing.expectEqual(@as(i64, 3), try sessionCount(env));

    const deleted = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk try gcExpiredSessions(w);
    };
    try std.testing.expectEqual(@as(usize, 1), deleted);
    try std.testing.expectEqual(@as(i64, 2), try sessionCount(env)); // NULL + future remain

    // Confirm exactly the right rows survived.
    var r = try env.pool.acquireReader();
    defer env.pool.releaseReader(&r);
    var st = try r.prepare("SELECT COUNT(*) FROM \"_sessions\" WHERE \"id\" IN ('noexp','future');");
    defer st.finalize();
    _ = try st.step();
    try std.testing.expectEqual(@as(i64, 2), st.columnInt(0));
}

test "#114 gcExpiredSessions drains a backlog larger than the batch size" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const total: usize = session_gc_batch + 50; // forces >1 batch
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const id = try std.fmt.allocPrint(a, "s{d}", .{i});
        try insertSessionRow(env, id, 1); // all expired
    }
    try std.testing.expectEqual(@as(i64, @intCast(total)), try sessionCount(env));

    const deleted = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk try gcExpiredSessions(w);
    };
    try std.testing.expectEqual(total, deleted);
    try std.testing.expectEqual(@as(i64, 0), try sessionCount(env)); // backlog fully drained
}

test "#99 epoch-mode per-device verbs report SessionStoreNotEnabled" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var hctx = env.ctx(a, .POST, "", &[_]http.Param{});
    var cx = Ctx{ .app = &env.app, .arena = a, .rctx = .{}, .request = &hctx };
    defer cx.deinit();
    // Default app.session_store == .epoch -> no per-session inventory.
    try std.testing.expectError(error.SessionStoreNotEnabled, cx.auth().listActiveSessions());
    try std.testing.expectError(error.SessionStoreNotEnabled, cx.auth().revoke("s1"));
}

test "issueSession is the mint+emit seam: emits onAuth once with the method tag" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "seam@x.io", "longenough");

    // Install a counting onAuth handler on the test app's dispatch.
    const Counter = struct {
        var seen: usize = 0;
        var last_method: events.AuthMethod = .oauth2;
        fn onAuth(ev: *events.AuthEvent) void { seen += 1; last_method = ev.method; }
    };
    Counter.seen = 0;
    var disp = events.Dispatch{ .on_auth = Counter.onAuth };
    env.app.dispatch = &disp;

    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var login = env.ctx(a, .POST, "{\"identity\":\"seam@x.io\",\"password\":\"longenough\"}", &p);
    const res = try authWithPassword(&login);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqual(@as(usize, 1), Counter.seen);
    try std.testing.expectEqual(events.AuthMethod.password, Counter.last_method);
}

// ---------------------------------------------------------------------------
// #98 — auth lifecycle hooks: logout / refresh / password-change
// ---------------------------------------------------------------------------

/// Create a base `posts` collection so a lifecycle hook can do a side-write.
fn createBasePosts(env: *TestEnv, a: std.mem.Allocator) !void {
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    _ = try collections.create(a, std.testing.io, w, .{
        .id = "", .name = "posts", .type = .base,
        .fields = &[_]schema.Field{.{ .id = "t1", .name = "title", .options = .{ .text = .{} } }},
        .listRule = null, .viewRule = null, .createRule = null, .updateRule = null, .deleteRule = null,
    });
}

fn countTable(env: *TestEnv, table: []const u8) !i64 {
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    const sql = try std.fmt.allocPrintSentinel(std.testing.allocator, "SELECT COUNT(*) FROM \"{s}\";", .{table}, 0);
    defer std.testing.allocator.free(sql);
    var st = try w.prepare(sql);
    defer st.finalize();
    _ = try st.step();
    return st.columnInt(0);
}

/// Login and return the issued bearer token (arena-owned).
fn loginToken(env: *TestEnv, a: std.mem.Allocator, col: []const u8, identity: []const u8, pw: []const u8) ![]const u8 {
    const p = [_]http.Param{.{ .key = "col", .value = col }};
    const body = try std.fmt.allocPrint(a, "{{\"identity\":\"{s}\",\"password\":\"{s}\"}}", .{ identity, pw });
    var login = env.ctx(a, .POST, body, &p);
    const res = try authWithPassword(&login);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, res.body, .{});
    return parsed.value.object.get("token").?.string;
}

test "#98 refresh: before/after refresh hooks fire on a valid refresh" {
    var env = try TestEnv.initAuth("refreshu");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "refreshu", "rf@x.io", "longenough");
    const token = try loginToken(env, a, "refreshu", "rf@x.io", "longenough");

    const Hook = struct {
        var before_seen: usize = 0;
        var after_seen: usize = 0;
        var phase_ok = false;
        var rid_seen: []const u8 = "";
        fn before(ctx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
            _ = ctx;
            before_seen += 1;
            if (ev.phase == .before_refresh) phase_ok = true;
            rid_seen = ev.record_id;
        }
        fn after(ctx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
            _ = ctx;
            _ = ev;
            after_seen += 1;
        }
    };
    Hook.before_seen = 0;
    Hook.after_seen = 0;
    var disp = events.Dispatch{ .auth_lifecycle = events.buildAuthLifecycleDispatcher(.{
        .beforeRefresh = Hook.before,
        .afterRefresh = Hook.after,
    }) };
    env.app.dispatch = &disp;

    const p = [_]http.Param{.{ .key = "col", .value = "refreshu" }};
    var refresh = env.ctx(a, .POST, "", &p);
    refresh.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    const res = try authRefresh(&refresh);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqual(@as(usize, 1), Hook.before_seen);
    try std.testing.expectEqual(@as(usize, 1), Hook.after_seen);
    try std.testing.expect(Hook.phase_ok);
    try std.testing.expect(Hook.rid_seen.len > 0);
}

test "#98 refresh: aborting beforeRefresh blocks the session AND rolls back side-writes" {
    var env = try TestEnv.initAuth("refreshb");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "refreshb", "rf@x.io", "longenough");
    try createBasePosts(env, a);
    const token = try loginToken(env, a, "refreshb", "rf@x.io", "longenough");

    const Hook = struct {
        fn writeThenAbort(ctx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
            _ = ev;
            var o: std.json.ObjectMap = .empty;
            try o.put(ctx.arena, "title", .{ .string = "rollme" });
            _ = try ctx.records().create("posts", .{ .object = o });
            return ctx.fail(403, "no refresh");
        }
    };
    var disp = events.Dispatch{ .auth_lifecycle = events.buildAuthLifecycleDispatcher(.{ .beforeRefresh = Hook.writeThenAbort }) };
    env.app.dispatch = &disp;

    const p = [_]http.Param{.{ .key = "col", .value = "refreshb" }};
    var refresh = env.ctx(a, .POST, "", &p);
    refresh.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    const res = try authRefresh(&refresh);
    try std.testing.expectEqual(@as(u16, 403), res.status); // fail closed
    try std.testing.expectEqual(@as(usize, 0), res.cookies.len); // no new session
    try std.testing.expectEqual(@as(i64, 0), try countTable(env, "posts")); // side-write rolled back
}

test "#98 logout: before/after logout hooks fire; session cookies still cleared" {
    var env = try TestEnv.initAuth("logoutu");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "logoutu", "lo@x.io", "longenough");
    const token = try loginToken(env, a, "logoutu", "lo@x.io", "longenough");

    const Hook = struct {
        var before_seen: usize = 0;
        var after_seen: usize = 0;
        var rid_seen: []const u8 = "";
        fn before(ctx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
            _ = ctx;
            before_seen += 1;
            rid_seen = ev.record_id;
        }
        fn after(ctx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
            _ = ctx;
            _ = ev;
            after_seen += 1;
        }
    };
    Hook.before_seen = 0;
    Hook.after_seen = 0;
    var disp = events.Dispatch{ .auth_lifecycle = events.buildAuthLifecycleDispatcher(.{
        .beforeLogout = Hook.before,
        .afterLogout = Hook.after,
    }) };
    env.app.dispatch = &disp;

    const p = [_]http.Param{.{ .key = "col", .value = "logoutu" }};
    var logout = env.ctx(a, .POST, "", &p);
    logout.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    const res = try authLogout(&logout);
    try std.testing.expectEqual(@as(u16, 204), res.status);
    var cleared: usize = 0;
    for (res.cookies) |c| if (c.max_age_s < 0) {
        cleared += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), cleared);
    try std.testing.expectEqual(@as(usize, 1), Hook.before_seen);
    try std.testing.expectEqual(@as(usize, 1), Hook.after_seen);
    try std.testing.expect(Hook.rid_seen.len > 0); // identity resolved from the bearer
}

test "#98 logout: aborting beforeLogout returns the mapped status and does NOT clear cookies" {
    var env = try TestEnv.initAuth("logoutb");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Hook = struct {
        fn abort(ctx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
            _ = ev;
            return ctx.fail(409, "logout blocked");
        }
    };
    var disp = events.Dispatch{ .auth_lifecycle = events.buildAuthLifecycleDispatcher(.{ .beforeLogout = Hook.abort }) };
    env.app.dispatch = &disp;

    const p = [_]http.Param{.{ .key = "col", .value = "logoutb" }};
    var logout = env.ctx(a, .POST, "", &p);
    const res = try authLogout(&logout);
    try std.testing.expectEqual(@as(u16, 409), res.status);
    try std.testing.expectEqual(@as(usize, 0), res.cookies.len); // cookies NOT cleared
}

test "#98 password-change: before/after hooks fire on confirm-password-reset" {
    var env = try TestEnv.initAuth("pcu");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "pcu", "pc@x.io", "oldpassword");
    const token = try env.mintTyped(a, "pcu", "pc@x.io", .password_reset);

    const Hook = struct {
        var before_seen: usize = 0;
        var after_seen: usize = 0;
        var rid_seen: []const u8 = "";
        fn before(ctx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
            _ = ctx;
            before_seen += 1;
            rid_seen = ev.record_id;
        }
        fn after(ctx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
            _ = ctx;
            _ = ev;
            after_seen += 1;
        }
    };
    Hook.before_seen = 0;
    Hook.after_seen = 0;
    var disp = events.Dispatch{ .auth_lifecycle = events.buildAuthLifecycleDispatcher(.{
        .beforePasswordChange = Hook.before,
        .afterPasswordChange = Hook.after,
    }) };
    env.app.dispatch = &disp;

    const p = [_]http.Param{.{ .key = "col", .value = "pcu" }};
    const body = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\",\"password\":\"newpassword\"}}", .{token});
    var conf = env.ctx(a, .POST, body, &p);
    try std.testing.expectEqual(@as(u16, 200), (try confirmPasswordReset(&conf)).status);
    try std.testing.expectEqual(@as(usize, 1), Hook.before_seen);
    try std.testing.expectEqual(@as(usize, 1), Hook.after_seen);
    try std.testing.expect(Hook.rid_seen.len > 0);
}

test "#98 password-change: aborting beforePasswordChange leaves password + reset token intact" {
    var env = try TestEnv.initAuth("pcb");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "pcb", "pc@x.io", "oldpassword");
    const token = try env.mintTyped(a, "pcb", "pc@x.io", .password_reset);

    const Hook = struct {
        fn abort(ctx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
            _ = ev;
            return ctx.fail(403, "password change blocked");
        }
    };
    var disp = events.Dispatch{ .auth_lifecycle = events.buildAuthLifecycleDispatcher(.{ .beforePasswordChange = Hook.abort }) };
    env.app.dispatch = &disp;

    const p = [_]http.Param{.{ .key = "col", .value = "pcb" }};
    const body = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\",\"password\":\"newpassword\"}}", .{token});
    var conf = env.ctx(a, .POST, body, &p);
    try std.testing.expectEqual(@as(u16, 403), (try confirmPasswordReset(&conf)).status);

    // Password unchanged: the old password still authenticates.
    env.app.dispatch = null;
    const old_token = loginToken(env, a, "pcb", "pc@x.io", "oldpassword") catch "";
    try std.testing.expect(old_token.len > 0);

    // Reset token un-consumed: with the hook removed, the SAME token now succeeds.
    var conf2 = env.ctx(a, .POST, body, &p);
    try std.testing.expectEqual(@as(u16, 200), (try confirmPasswordReset(&conf2)).status);
    // And the new password now works.
    const new_token = loginToken(env, a, "pcb", "pc@x.io", "newpassword") catch "";
    try std.testing.expect(new_token.len > 0);
}

test "#80 legacy login: beforeAuthSuccess fires, side-write commits with the session" {
    var env = try TestEnv.initAuth("lg1");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "lg1", "u@x.io", "password123");

    const Hook = struct {
        var seen: usize = 0;
        var method_seen: events.AuthMethod = .custom;
        fn h(cx: *Ctx, ev: *events.AuthSuccessEvent) anyerror!void {
            seen += 1;
            method_seen = ev.method;
            // Side-write through the bound in-transaction connection: commits WITH the login.
            var patch: std.json.ObjectMap = .empty;
            try patch.put(cx.arena, "bio", .{ .string = "logged-in" });
            _ = try cx.records().update("lg1", ev.record_id, .{ .object = patch });
        }
    };
    Hook.seen = 0;
    var disp = events.Dispatch{ .before_auth_success = Hook.h };
    env.app.dispatch = &disp;

    const p = [_]http.Param{.{ .key = "col", .value = "lg1" }};
    var login = env.ctx(a, .POST, "{\"identity\":\"u@x.io\",\"password\":\"password123\"}", &p);
    const res = try authWithPassword(&login);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqual(@as(usize, 1), Hook.seen);
    try std.testing.expectEqual(events.AuthMethod.password, Hook.method_seen);
    // Side-write durably committed.
    {
        var r = try env.pool.acquireReader();
        defer env.pool.releaseReader(&r);
        var st = try r.prepare("SELECT \"bio\" FROM \"lg1\" WHERE \"email\" = 'u@x.io';");
        defer st.finalize();
        try std.testing.expect(try st.step());
        try std.testing.expectEqualStrings("logged-in", st.columnText(0));
    }
}

test "#80 legacy login: aborting beforeAuthSuccess blocks the session and rolls back side-writes" {
    var env = try TestEnv.initAuth("lg2");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "lg2", "u@x.io", "password123");

    const Hook = struct {
        fn h(cx: *Ctx, ev: *events.AuthSuccessEvent) anyerror!void {
            // Side-write FIRST, then abort: the write must be rolled back with the login.
            var patch: std.json.ObjectMap = .empty;
            try patch.put(cx.arena, "bio", .{ .string = "MUST-NOT-PERSIST" });
            _ = try cx.records().update("lg2", ev.record_id, .{ .object = patch });
            return cx.fail(451, "login vetoed");
        }
    };
    var disp = events.Dispatch{ .before_auth_success = Hook.h };
    env.app.dispatch = &disp;

    const p = [_]http.Param{.{ .key = "col", .value = "lg2" }};
    var login = env.ctx(a, .POST, "{\"identity\":\"u@x.io\",\"password\":\"password123\"}", &p);
    const res = try authWithPassword(&login);
    try std.testing.expectEqual(@as(u16, 451), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "token") == null); // no session
    {
        var r = try env.pool.acquireReader();
        defer env.pool.releaseReader(&r);
        var st = try r.prepare("SELECT COALESCE(\"bio\",'') FROM \"lg2\" WHERE \"email\" = 'u@x.io';");
        defer st.finalize();
        try std.testing.expect(try st.step());
        try std.testing.expectEqualStrings("", st.columnText(0)); // rolled back
    }
    // Writer not poisoned: with the hook removed, login succeeds cleanly.
    env.app.dispatch = null;
    const tok = loginToken(env, a, "lg2", "u@x.io", "password123") catch "";
    try std.testing.expect(tok.len > 0);
}

test "#80 hook-free epoch login never acquires the writer" {
    var env = try TestEnv.initAuth("lg3");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "lg3", "u@x.io", "password123");
    // env.app.dispatch == null and session_store == .epoch (defaults): the fast path.
    const before = env.pool.writer_acquires;
    const p = [_]http.Param{.{ .key = "col", .value = "lg3" }};
    var login = env.ctx(a, .POST, "{\"identity\":\"u@x.io\",\"password\":\"password123\"}", &p);
    try std.testing.expectEqual(@as(u16, 200), (try authWithPassword(&login)).status);
    try std.testing.expectEqual(before, env.pool.writer_acquires); // reader-only login
}

test "#80 authRefresh: before_refresh then beforeAuthSuccess(.refresh) in ONE txn; seam abort rolls back both" {
    var env = try TestEnv.initAuth("rf1");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    env.app.session_store = .table; // so we can observe the sid row surviving the rollback
    try env.createUser(a, "rf1", "u@x.io", "password123");
    const tok = try loginToken(env, a, "rf1", "u@x.io", "password123");

    const Order = struct {
        var log: [4]u8 = undefined;
        var n: usize = 0;
        var seam_method: events.AuthMethod = .custom;
        fn lifecycle(cx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
            _ = cx;
            if (ev.phase == .before_refresh) {
                log[n] = 'L';
                n += 1;
            }
        }
        fn seam(cx: *Ctx, ev: *events.AuthSuccessEvent) anyerror!void {
            _ = cx;
            log[n] = 'S';
            n += 1;
            seam_method = ev.method;
            return error.Forbidden; // abort AFTER before_refresh ran → whole refresh rolls back
        }
    };
    Order.n = 0;
    var disp = events.Dispatch{
        .auth_lifecycle = events.buildAuthLifecycleDispatcher(.{ .beforeRefresh = Order.lifecycle }),
        .before_auth_success = Order.seam,
    };
    env.app.dispatch = &disp;

    const p = [_]http.Param{.{ .key = "col", .value = "rf1" }};
    const bearer = try std.fmt.allocPrint(a, "Bearer {s}", .{tok});
    var refresh = env.ctx(a, .POST, "", &p);
    refresh.authorization = bearer;
    const res = try authRefresh(&refresh);
    try std.testing.expectEqual(@as(u16, 403), res.status);
    try std.testing.expectEqual(@as(usize, 2), Order.n);
    try std.testing.expectEqualStrings("LS", Order.log[0..2]); // lifecycle first, then the seam
    try std.testing.expectEqual(events.AuthMethod.refresh, Order.seam_method);
    // Fail closed: the OLD session row is intact (rolled-back delete) and the token still works.
    env.app.dispatch = null;
    var refresh2 = env.ctx(a, .POST, "", &p);
    refresh2.authorization = bearer;
    try std.testing.expectEqual(@as(u16, 200), (try authRefresh(&refresh2)).status);
}

test "#80 onAuth reports .refresh (not .password) on auth-refresh" {
    var env = try TestEnv.initAuth("rf2");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "rf2", "u@x.io", "password123");
    const tok = try loginToken(env, a, "rf2", "u@x.io", "password123");

    const Tag = struct {
        var seen: ?events.AuthMethod = null;
        fn h(ev: *events.AuthEvent) void {
            seen = ev.method;
        }
    };
    Tag.seen = null;
    var disp = events.Dispatch{ .on_auth = Tag.h };
    env.app.dispatch = &disp;

    const p = [_]http.Param{.{ .key = "col", .value = "rf2" }};
    const bearer = try std.fmt.allocPrint(a, "Bearer {s}", .{tok});
    var refresh = env.ctx(a, .POST, "", &p);
    refresh.authorization = bearer;
    try std.testing.expectEqual(@as(u16, 200), (try authRefresh(&refresh)).status);
    try std.testing.expectEqual(events.AuthMethod.refresh, Tag.seen.?);
}
