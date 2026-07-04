//! Live-PostgreSQL end-to-end tests for the auth / oauth / analytics / challenge / session
//! subsystems (issue #159, Wave B — `feat/pg-auth-dialect`). Before this PR these paths emitted
//! raw SQLite `?N` placeholders + `datetime('now')`/`strftime(…)` and called `conn.prepare`
//! directly, so they FAILED at prepare on a Postgres connection. Each test here exercises the
//! dialect-ized data-access functions against a REAL PostgreSQL and asserts the round-trip
//! succeeds (the exact behavior the SQLite unit tests already prove in-process).
//!
//! Gated by `-Dpostgres=true` (wired from `root.zig`) and `ZIGBASE_PG_TEST_URL`; SKIP when no PG
//! is reachable, exactly like the driver's own live tests. Each test runs inside a freshly created
//! per-test SCHEMA dropped CASCADE on teardown.

const std = @import("std");
const db = @import("../../db.zig");
const migrations = @import("../../migrations.zig");
const collections = @import("../../collections.zig");
const records = @import("../../records.zig");
const schema = @import("../../schema.zig");
const auth_core = @import("../../auth.zig");
const auth_api = @import("../../api/auth.zig");
const crypto = @import("../../crypto.zig");
const jwt = @import("../../jwt.zig");
const oauth_api = @import("../../api/oauth.zig");
const analytics = @import("../../analytics/analytics.zig");
const challenge_store = @import("../../auth/challenge_store.zig");
const app_mod = @import("../../app.zig");
const clock = @import("../../clock.zig");

fn testUrlZ() ?[:0]const u8 {
    return std.testing.environ.getPosix("ZIGBASE_PG_TEST_URL");
}

/// A live PG `db.Db` on a private, freshly created schema, or null to skip. `deinit` drops the
/// schema + closes the connection.
const Ctx = struct {
    conn: db.Db,
    drop_sql: [:0]const u8,

    fn open(a: std.mem.Allocator, io: std.Io, comptime tag: []const u8) !?Ctx {
        const url = testUrlZ() orelse return null;
        var conn = db.Db.openPostgres(a, io, url) catch return null;
        errdefer conn.close();
        const sn = "zb_authpg_" ++ tag;
        try conn.exec("DROP SCHEMA IF EXISTS " ++ sn ++ " CASCADE;");
        try conn.exec("CREATE SCHEMA " ++ sn ++ ";");
        try conn.exec("SET search_path TO " ++ sn ++ ";");
        return Ctx{ .conn = conn, .drop_sql = "DROP SCHEMA IF EXISTS " ++ sn ++ " CASCADE;" };
    }

    fn deinit(self: *Ctx) void {
        self.conn.exec(self.drop_sql) catch {};
        self.conn.close();
    }

    fn w(self: *Ctx) *db.Db {
        return &self.conn;
    }
};

fn scalarCount(w: *db.Db, sql: [:0]const u8) !i64 {
    var st = try w.prepare(sql);
    defer st.finalize();
    _ = try st.step();
    return st.columnInt(0);
}

// ---------------------------------------------------------------------------
// Analytics: event insert (strftime->to_char) + `_seq` watermark + rollup UPSERT + `_kv` upsert.
// ---------------------------------------------------------------------------

test "pg: analytics insertEvent + incremental rollup (rowid->_seq watermark) on Postgres" {
    const a = std.testing.allocator;
    var ctx = (try Ctx.open(a, std.testing.io, "rollup")) orelse return error.SkipZigTest;
    defer ctx.deinit();
    const w = ctx.w();
    try migrations.run(w);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    // The PG-only monotonic insertion column the watermark advances over really exists.
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(w, "SELECT count(*) FROM information_schema.columns WHERE table_schema=current_schema() AND table_name='_events' AND column_name='_seq';"));

    // Three signups (2x acc1, 1x acc2) + one unrelated event.
    try analytics.insertEvent(w, std.testing.io, .{ .name = "user.signup", .payload_json = "{}", .account = "acc1" });
    try analytics.insertEvent(w, std.testing.io, .{ .name = "user.signup", .payload_json = "{}", .account = "acc1" });
    try analytics.insertEvent(w, std.testing.io, .{ .name = "user.signup", .payload_json = "{}", .account = "acc2" });
    try analytics.insertEvent(w, std.testing.io, .{ .name = "other.event", .payload_json = "{}", .account = "acc1" });
    try std.testing.expectEqual(@as(i64, 4), try scalarCount(w, "SELECT count(*) FROM \"_events\";"));

    const spec = analytics.RollupSpec{
        .name = "signups_daily",
        .event = "user.signup",
        .every = .{ .interval = .hourly },
        .group_account = true,
        .group_actor = false,
        .time_bucket = .day,
        .metric = .count,
    };
    try analytics.runRollup(w, al, spec);

    try std.testing.expectEqual(@as(i64, 2), try scalarCount(w, "SELECT value FROM \"_rollup_signups_daily\" WHERE account='acc1';"));
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(w, "SELECT value FROM \"_rollup_signups_daily\" WHERE account='acc2';"));

    // Re-run with no new events: the `_seq` watermark guards an exact no-op (acc1 stays 2).
    try analytics.runRollup(w, al, spec);
    try std.testing.expectEqual(@as(i64, 2), try scalarCount(w, "SELECT value FROM \"_rollup_signups_daily\" WHERE account='acc1';"));

    // A NEW signup after the first pass is picked up next pass (the watermark advances, never drops).
    try analytics.insertEvent(w, std.testing.io, .{ .name = "user.signup", .payload_json = "{}", .account = "acc1" });
    try analytics.runRollup(w, al, spec);
    try std.testing.expectEqual(@as(i64, 3), try scalarCount(w, "SELECT value FROM \"_rollup_signups_daily\" WHERE account='acc1';"));
}

// ---------------------------------------------------------------------------
// Challenge store: insert (datetime->now) + guarded single-use UPDATE + changesCount on Postgres.
// ---------------------------------------------------------------------------

test "pg: challenge store put/take single-use + replay returns null on Postgres" {
    const a = std.testing.allocator;
    var ctx = (try Ctx.open(a, std.testing.io, "challenge")) orelse return error.SkipZigTest;
    defer ctx.deinit();
    const w = ctx.w();
    try migrations.run(w);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    const store = challenge_store.ChallengeStore{ .conn = w };
    const cid = try store.put(al, std.testing.io, "users", "otp", "alice@example.com", "secret-payload", 3600);
    try std.testing.expectEqual(@as(usize, 32), cid.len);

    const p1 = try store.take(al, cid, "otp");
    try std.testing.expect(p1 != null);
    try std.testing.expectEqualStrings("secret-payload", p1.?);
    // Replay -> consumed -> null (the guarded UPDATE matched 0 rows: changesCount() != 1).
    try std.testing.expect((try store.take(al, cid, "otp")) == null);

    // takeByIdentity newest-wins + single-use.
    _ = try store.put(al, std.testing.io, "users", "magic", "bob@example.com", "mp", 3600);
    const m = try store.takeByIdentity(al, "users", "magic", "bob@example.com");
    try std.testing.expect(m != null);
    try std.testing.expectEqualStrings("mp", m.?);
    try std.testing.expect((try store.takeByIdentity(al, "users", "magic", "bob@example.com")) == null);
}

// ---------------------------------------------------------------------------
// OAuth: server-side `state` consume (DELETE … RETURNING + $n) + external-auth link round-trip.
// ---------------------------------------------------------------------------

test "pg: oauth state single-use consume + external-auth link round-trip on Postgres" {
    const a = std.testing.allocator;
    var ctx = (try Ctx.open(a, std.testing.io, "oauth")) orelse return error.SkipZigTest;
    defer ctx.deinit();
    const w = ctx.w();
    try migrations.run(w);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    // Seed a state row (the issueState INSERT shape) with a far-future expiry, then consume it.
    try w.exec("INSERT INTO \"_oauthStates\" (\"state\",\"collectionRef\",\"provider\",\"expires\",\"created\") VALUES ('st1','users','google',9999999999,'');");
    // First consume succeeds (matching, unexpired row deleted via DELETE … RETURNING + $n).
    try std.testing.expect(try oauth_api.consumeState(w, "users", "google", "st1"));
    // Replay finds no row -> false (single-use).
    try std.testing.expect(!try oauth_api.consumeState(w, "users", "google", "st1"));
    // Wrong provider never matches.
    try w.exec("INSERT INTO \"_oauthStates\" (\"state\",\"collectionRef\",\"provider\",\"expires\",\"created\") VALUES ('st2','users','google',9999999999,'');");
    try std.testing.expect(!try oauth_api.consumeState(w, "users", "github", "st2"));

    // External-auth link insert (datetime->now ×2) + lookup.
    try oauth_api.insertLink(std.testing.io, al, w, "users", "rec1", "google", "GID-1");
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(w, "SELECT count(*) FROM \"_externalAuths\" WHERE \"provider\"='google' AND \"providerId\"='GID-1';"));
    const link = try oauth_api.findLink(al, w, "google", "GID-1");
    try std.testing.expect(link != null);
    try std.testing.expectEqualStrings("users", link.?.collectionRef);
    try std.testing.expectEqualStrings("rec1", link.?.recordRef);
}

// ---------------------------------------------------------------------------
// Auth: user record login lookup + single-use token consume + session row list/delete on Postgres.
// ---------------------------------------------------------------------------

test "pg: auth identity lookup + login credential check + consumeToken + session store on Postgres" {
    const a = std.testing.allocator;
    var ctx = (try Ctx.open(a, std.testing.io, "auth")) orelse return error.SkipZigTest;
    defer ctx.deinit();
    const w = ctx.w();
    try migrations.run(w);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    // Create a real `users` auth collection + one record (PR-3 CRUD path on PG).
    _ = try collections.create(al, std.testing.io, w, .{
        .id = "",
        .name = "users",
        .type = .auth,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "name", .options = .{ .text = .{} } }},
        .listRule = "",
        .viewRule = "",
        .createRule = "",
        .updateRule = "",
        .deleteRule = "",
    });
    const col = (try collections.get(al, w, "users")).?;
    var data: std.json.ObjectMap = .empty;
    try data.put(al, "email", .{ .string = "alice@example.com" });
    try data.put(al, "password", .{ .string = "correct horse battery" });
    const prepared = try auth_core.applyCreate(std.testing.io, al, .{ .object = data }, col.options.auth.minPasswordLength);
    const rec = try records.create(al, std.testing.io, w, col, prepared);
    const rid = rec.object.get("id").?.string;

    // identityFields lookup resolves the record by email.
    const found = (try auth_api.findByIdentity(al, w, col, "alice@example.com")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(rid, found);

    // Login credential check: the stored argon2id hash verifies the right password and rejects a wrong one.
    const hash = (try auth_api.passwordHashFor(al, w, col.name, rid)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(crypto.verifyPassword(std.testing.io, al, hash, "correct horse battery"));
    try std.testing.expect(!crypto.verifyPassword(std.testing.io, al, hash, "wrong password"));

    // tokenKey + epoch read back in one SELECT (the mint path's single read).
    const ke = (try auth_api.tokenKeyAndEpochFor(al, w, col.name, rid)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(ke.token_key.len > 0);
    try std.testing.expectEqual(@as(i64, 0), ke.epoch);

    // Single-use token consume: first redeem records the jti (_consumedTokens INSERT, datetime->now);
    // a replay is rejected.
    const claims = jwt.Claims{ .id = rid, .collection = col.name, .type = .verification, .jti = "jti-pg-1", .iat = 0, .exp = 9999999999 };
    try auth_api.consumeToken(w, claims);
    try std.testing.expectError(error.AlreadyConsumed, auth_api.consumeToken(w, claims));

    // Server-side session store: insert a row (recordSession INSERT shape) for this record, then
    // list it and delete it.
    try w.exec(try std.fmt.allocPrintSentinel(al, "INSERT INTO \"_sessions\" (\"id\",\"collectionRef\",\"recordRef\",\"created\",\"lastSeen\",\"expires\",\"userAgent\",\"ip\") VALUES ('sid1','users','{s}','','',9999999999,'ua','ip');", .{rid}, 0));
    const sessions = try auth_api.listSessions(al, w, "users", rid);
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("sid1", sessions[0].id);
    try std.testing.expect(try auth_api.deleteSession(w, "sid1"));
    try std.testing.expect(!try auth_api.deleteSession(w, "sid1")); // already gone
}

test "pg: .nocase identity — case-insensitive lookup + case-variant duplicate rejected (#159)" {
    const a = std.testing.allocator;
    var ctx = (try Ctx.open(a, std.testing.io, "nocase_id")) orelse return error.SkipZigTest;
    defer ctx.deinit();
    const w = ctx.w();
    try migrations.run(w);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    // A users auth collection whose `email` carries a `.nocase` UNIQUE index — the documented
    // email-uniqueness pattern the example apps use. On PG this provisions as `lower(email)`.
    _ = try collections.create(al, std.testing.io, w, .{
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
    const col = (try collections.get(al, w, "users")).?;

    // Store one record with a MIXED-CASE email.
    var data: std.json.ObjectMap = .empty;
    try data.put(al, "email", .{ .string = "Bob@x.com" });
    try data.put(al, "password", .{ .string = "correct horse battery" });
    const prepared = try auth_core.applyCreate(std.testing.io, al, .{ .object = data }, col.options.auth.minPasswordLength);
    const rec = try records.create(al, std.testing.io, w, col, prepared);
    const rid = rec.object.get("id").?.string;

    // Case-INSENSITIVE lookup: finding by a DIFFERENT case (lower, UPPER) resolves the same record,
    // because findByIdentity lowers both sides on PG to match the `lower(email)` index (#159).
    try std.testing.expectEqualStrings(rid, (try auth_api.findByIdentity(al, w, col, "bob@x.com")).?);
    try std.testing.expectEqualStrings(rid, (try auth_api.findByIdentity(al, w, col, "BOB@X.COM")).?);
    try std.testing.expectEqualStrings(rid, (try auth_api.findByIdentity(al, w, col, "Bob@x.com")).?);
    // A non-matching identity still returns null.
    try std.testing.expect((try auth_api.findByIdentity(al, w, col, "carol@x.com")) == null);

    // Case-variant uniqueness: creating a second record with a case-variant email is REJECTED by
    // the `lower(email)` unique index (duplicate identity), exactly like SQLite's COLLATE NOCASE.
    var data2: std.json.ObjectMap = .empty;
    try data2.put(al, "email", .{ .string = "bob@x.com" });
    try data2.put(al, "password", .{ .string = "another good passphrase" });
    const prepared2 = try auth_core.applyCreate(std.testing.io, al, .{ .object = data2 }, col.options.auth.minPasswordLength);
    // The INSERT … RETURNING is a PREPARED statement, so the unique violation surfaces at step().
    try std.testing.expectError(error.StepFailed, records.create(al, std.testing.io, w, col, prepared2));
}

// ---------------------------------------------------------------------------
// Auth VERIFY path (src/auth.zig) on Postgres — the core middleware hit on EVERY authenticated
// request. Its three reads (tokenKeyEpochFor / sessionActive / superuserRecord) emitted raw `?N`
// before this fix, so on PG they failed at prepare → `verifyToken` returned null → a user could
// log in but no token could be verified. This mints a token AND round-trips it through
// `auth.verifyToken` for epoch mode, table-mode session gating, and superuser auth.
// FAILS-BEFORE (verify returns null on PG), PASSES-AFTER the `src/auth.zig` lowering.

/// Mint a signed `.auth` token for (collection, rid, token_key) with the given sid/epoch.
fn mintAuth(al: std.mem.Allocator, secret: []const u8, collection: []const u8, rid: []const u8, token_key: []const u8, sid: ?[]const u8, epoch: i64) ![]u8 {
    const key = crypto.deriveKey(secret, token_key);
    return jwt.sign(al, .{
        .id = rid,
        .collection = collection,
        .type = .auth,
        .token_epoch = epoch,
        .sid = sid,
        .iat = 1,
        .exp = 9999999999,
    }, &key);
}

test "pg: token mint + VERIFY round-trip (epoch, table-session, superuser) on Postgres" {
    const a = std.testing.allocator;
    var ctx = (try Ctx.open(a, std.testing.io, "verify")) orelse return error.SkipZigTest;
    defer ctx.deinit();
    const w = ctx.w();
    try migrations.run(w);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    const secret = "pg-verify-test-secret-0123456789";

    // A real users record + its server-generated tokenKey (the signing-key material).
    _ = try collections.create(al, std.testing.io, w, .{
        .id = "",
        .name = "users",
        .type = .auth,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "name", .options = .{ .text = .{} } }},
        .listRule = "",
        .viewRule = "",
        .createRule = "",
        .updateRule = "",
        .deleteRule = "",
    });
    const col = (try collections.get(al, w, "users")).?;
    var data: std.json.ObjectMap = .empty;
    try data.put(al, "email", .{ .string = "verify@example.com" });
    try data.put(al, "password", .{ .string = "correct horse battery" });
    const prepared = try auth_core.applyCreate(std.testing.io, al, .{ .object = data }, col.options.auth.minPasswordLength);
    const rec = try records.create(al, std.testing.io, w, col, prepared);
    const rid = rec.object.get("id").?.string;
    const ke = (try auth_api.tokenKeyAndEpochFor(al, w, "users", rid)).?;

    // (1) EPOCH MODE: verifyToken reads tokenKeyEpochFor("users") on PG and accepts the token.
    const app_epoch = .{ .jwt_secret = @as([]const u8, secret), .session_store = app_mod.SessionStore.epoch };
    const tok_epoch = try mintAuth(al, secret, "users", rid, ke.token_key, null, 0);
    const v1 = auth_core.verifyToken(al, app_epoch, w, tok_epoch) orelse return error.TestUnexpectedResult; // null BEFORE fix
    try std.testing.expectEqualStrings(rid, v1.record.object.get("id").?.string);
    try std.testing.expect(!v1.is_superuser);

    // (2) TABLE MODE: a token carrying a `sid` must reference a live `_sessions` row — verify calls
    // sessionActive on PG. Present+unexpired → accept; missing → fail-closed (null).
    const app_table = .{ .jwt_secret = @as([]const u8, secret), .session_store = app_mod.SessionStore.table };
    try w.exec(try std.fmt.allocPrintSentinel(al, "INSERT INTO \"_sessions\" (\"id\",\"collectionRef\",\"recordRef\",\"created\",\"lastSeen\",\"expires\",\"userAgent\",\"ip\") VALUES ('sidLive','users','{s}','','',9999999999,'ua','ip');", .{rid}, 0));
    const tok_live = try mintAuth(al, secret, "users", rid, ke.token_key, "sidLive", 0);
    const v2 = auth_core.verifyToken(al, app_table, w, tok_live) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("sidLive", v2.sid);
    // A token whose sid has no `_sessions` row is rejected (sessionActive ran and gated → fail-closed).
    const tok_dead = try mintAuth(al, secret, "users", rid, ke.token_key, "sidGONE", 0);
    try std.testing.expect(auth_core.verifyToken(al, app_table, w, tok_dead) == null);

    // (3) SUPERUSER: verify resolves the principal via superuserRecord("_superusers") on PG.
    try w.exec("INSERT INTO \"_superusers\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('su1','','','root@example.com','su-token-key',1);");
    const tok_super = try mintAuth(al, secret, "_superusers", "su1", "su-token-key", null, 0);
    const v3 = auth_core.verifyToken(al, app_epoch, w, tok_super) orelse return error.TestUnexpectedResult;
    try std.testing.expect(v3.is_superuser);
    try std.testing.expectEqualStrings("root@example.com", v3.record.object.get("email").?.string);
}
