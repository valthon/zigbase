const std = @import("std");
const db = @import("db.zig");

pub const Migration = struct { name: []const u8, up: *const fn (w: *db.Db) db.DbError!void };

fn init_0001(w: *db.Db) db.DbError!void {
    try w.exec(
        \\CREATE TABLE IF NOT EXISTS "_collections" (
        \\  "id" TEXT PRIMARY KEY, "name" TEXT UNIQUE NOT NULL, "type" TEXT NOT NULL DEFAULT 'base',
        \\  "system" INTEGER NOT NULL DEFAULT 0, "schema" TEXT NOT NULL DEFAULT '[]',
        \\  "indexes" TEXT NOT NULL DEFAULT '[]',
        \\  "listRule" TEXT, "viewRule" TEXT, "createRule" TEXT, "updateRule" TEXT, "deleteRule" TEXT,
        \\  "created" TEXT NOT NULL, "updated" TEXT NOT NULL
        \\);
    );
}

fn init_0002(w: *db.Db) db.DbError!void {
    // add the options column (ignore the duplicate-column error if somehow re-run)
    w.exec("ALTER TABLE \"_collections\" ADD COLUMN \"options\" TEXT NOT NULL DEFAULT '{}';") catch {};
    // _superusers system auth collection: its physical table + its _collections row
    try w.exec(
        \\CREATE TABLE IF NOT EXISTS "_superusers" (
        \\  "id" TEXT PRIMARY KEY, "created" TEXT, "updated" TEXT,
        \\  "email" TEXT UNIQUE, "username" TEXT, "passwordHash" TEXT, "tokenKey" TEXT, "verified" INTEGER
        \\);
    );
    try w.exec(
        \\INSERT OR IGNORE INTO "_collections"
        \\  ("id","name","type","system","schema","indexes","options","listRule","viewRule","createRule","updateRule","deleteRule","created","updated")
        \\ VALUES ('_superusers_____','_superusers','auth',1,'[]','[]',
        \\  '{"auth":{"identityFields":["email"],"minPasswordLength":8}}',
        \\  NULL,NULL,NULL,NULL,NULL,datetime('now'),datetime('now'));
    );
}

fn init_0003(w: *db.Db) db.DbError!void {
    try w.exec(
        \\CREATE TABLE IF NOT EXISTS "_externalAuths" (
        \\  "id" TEXT PRIMARY KEY, "collectionRef" TEXT NOT NULL, "recordRef" TEXT NOT NULL,
        \\  "provider" TEXT NOT NULL, "providerId" TEXT NOT NULL,
        \\  "created" TEXT NOT NULL, "updated" TEXT NOT NULL
        \\);
    );
    try w.exec("CREATE UNIQUE INDEX IF NOT EXISTS \"idx_extauth_provider_pid\" ON \"_externalAuths\" (\"provider\",\"providerId\");");
    try w.exec("CREATE UNIQUE INDEX IF NOT EXISTS \"idx_extauth_rec_provider\" ON \"_externalAuths\" (\"collectionRef\",\"recordRef\",\"provider\");");
}

fn init_0004(w: *db.Db) db.DbError!void {
    // Single-use ledger for verification / password-reset tokens (F7). A token's
    // random "jti" claim is recorded here on first redemption; a UNIQUE primary key
    // makes a second redemption fail atomically under the writer lock, independent of
    // any tokenKey-rotation side effect. "expires" is the token's own exp (unix secs)
    // so a sweeper can prune entries once the token could no longer verify anyway.
    try w.exec(
        \\CREATE TABLE IF NOT EXISTS "_consumedTokens" (
        \\  "jti" TEXT PRIMARY KEY, "expires" INTEGER NOT NULL, "consumed" TEXT NOT NULL
        \\);
    );
    try w.exec("CREATE INDEX IF NOT EXISTS \"idx_consumed_expires\" ON \"_consumedTokens\" (\"expires\");");
}

fn init_0005(w: *db.Db) db.DbError!void {
    // Optional server-side OAuth `state` store (F11). When server-side CSRF protection
    // is enabled, auth-init mints a random state here; the callback verifies and deletes
    // it (single-use). "expires" is a unix-seconds TTL; a missing/mismatched/expired/reused
    // state is rejected. Unused when server-side state is disabled (client-driven flow).
    try w.exec(
        \\CREATE TABLE IF NOT EXISTS "_oauthStates" (
        \\  "state" TEXT PRIMARY KEY, "collectionRef" TEXT NOT NULL, "provider" TEXT NOT NULL,
        \\  "expires" INTEGER NOT NULL, "created" TEXT NOT NULL
        \\);
    );
    try w.exec("CREATE INDEX IF NOT EXISTS \"idx_oauthstate_expires\" ON \"_oauthStates\" (\"expires\");");
}

fn init_0006(w: *db.Db) db.DbError!void {
    // Server-side keyset-cursor state store for the STATEFUL token format
    // (App(.{ .pagination = .{ .cursor_token = .stateful } })). A minted cursor stores its
    // opaque keyset payload here keyed by a random "id"; the client receives only the id.
    // On use the payload is looked up (if unexpired) and decoded. "expires" is a unix-seconds
    // TTL; a periodic GC (records.gcCursorStates) prunes expired rows, and an index on
    // "expires" keeps that sweep cheap. Unused entirely in the stateless/signed modes.
    try w.exec(
        \\CREATE TABLE IF NOT EXISTS "_cursorStates" (
        \\  "id" TEXT PRIMARY KEY, "collectionRef" TEXT NOT NULL, "payload" TEXT NOT NULL,
        \\  "expires" INTEGER NOT NULL, "created" TEXT NOT NULL
        \\);
    );
    try w.exec("CREATE INDEX IF NOT EXISTS \"idx_cursorstate_expires\" ON \"_cursorStates\" (\"expires\");");
}

fn init_0007(w: *db.Db) db.DbError!void {
    // Server-side challenge store for pluggable auth methods (OTP, magic-link, FIDO2, etc.).
    // A challenge is minted by `put`, returned to the client as an opaque id (or embedded in
    // a URL), and redeemed exactly once by `take`/`takeByIdentity`. "consumed" tracks
    // single-use semantics atomically under the writer lock; "expires" is a unix-seconds TTL.
    // A periodic GC (auth/challenge_store.gcAuthChallenges) prunes consumed/expired rows.
    try w.exec(
        \\CREATE TABLE IF NOT EXISTS "_authChallenges" (
        \\  "id" TEXT PRIMARY KEY, "collectionRef" TEXT NOT NULL, "method" TEXT NOT NULL,
        \\  "identity" TEXT NOT NULL, "payload" TEXT NOT NULL, "expires" INTEGER NOT NULL,
        \\  "consumed" INTEGER NOT NULL DEFAULT 0, "created" TEXT NOT NULL
        \\);
    );
    try w.exec("CREATE INDEX IF NOT EXISTS \"idx_authchallenge_expires\" ON \"_authChallenges\" (\"expires\");");
    try w.exec("CREATE INDEX IF NOT EXISTS \"idx_authchallenge_lookup\" ON \"_authChallenges\" (\"collectionRef\",\"method\",\"identity\");");
}

pub const all = [_]Migration{
    .{ .name = "0001_init", .up = init_0001 },
    .{ .name = "0002_auth", .up = init_0002 },
    .{ .name = "0003_external_auths", .up = init_0003 },
    .{ .name = "0004_consumed_tokens", .up = init_0004 },
    .{ .name = "0005_oauth_states", .up = init_0005 },
    .{ .name = "0006_cursor_states", .up = init_0006 },
    .{ .name = "0007_auth_challenges", .up = init_0007 },
};

pub fn run(w: *db.Db) db.DbError!void {
    try w.exec(
        \\CREATE TABLE IF NOT EXISTS "_migrations" (
        \\  "id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT UNIQUE NOT NULL, "applied_at" TEXT NOT NULL
        \\);
    );
    for (all) |m| {
        if (try isApplied(w, m.name)) continue;
        try w.begin();
        errdefer w.rollback() catch {};
        try m.up(w);
        try recordApplied(w, m.name);
        try w.commit();
    }
}

fn isApplied(w: *db.Db, name: []const u8) db.DbError!bool {
    var st = try w.prepare("SELECT 1 FROM \"_migrations\" WHERE \"name\" = ?1;");
    defer st.finalize();
    try st.bindText(1, name);
    return try st.step();
}

fn recordApplied(w: *db.Db, name: []const u8) db.DbError!void {
    var st = try w.prepare("INSERT INTO \"_migrations\" (\"name\", \"applied_at\") VALUES (?1, datetime('now'));");
    defer st.finalize();
    try st.bindText(1, name);
    _ = try st.step();
}

test "migrations apply once and are idempotent" {
    var d = try db.Db.openMemory();
    defer d.close();
    try run(&d);
    try run(&d);
    var st = try d.prepare("SELECT COUNT(*) FROM \"_migrations\";");
    defer st.finalize();
    try std.testing.expect((try st.step()));
    try std.testing.expectEqual(@as(i64, all.len), st.columnInt(0));
    var c = try d.prepare("SELECT COUNT(*) FROM \"_collections\";");
    defer c.finalize();
    try std.testing.expect((try c.step()));
}

test "0002 adds options column and seeds _superusers" {
    var d = try db.Db.openMemory();
    defer d.close();
    try run(&d);
    var st = try d.prepare("SELECT type, system FROM \"_collections\" WHERE name='_superusers';");
    defer st.finalize();
    try std.testing.expect((try st.step()));
    try std.testing.expectEqualStrings("auth", st.columnText(0));
    try std.testing.expectEqual(@as(i64, 1), st.columnInt(1)); // system=1
    // re-running migrations does not duplicate the seed
    try run(&d);
    var dup = try d.prepare("SELECT COUNT(*) FROM \"_collections\" WHERE name='_superusers';");
    defer dup.finalize();
    _ = try dup.step();
    try std.testing.expectEqual(@as(i64, 1), dup.columnInt(0));
    var c = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('_collections') WHERE name='options';");
    defer c.finalize();
    _ = try c.step();
    try std.testing.expectEqual(@as(i64, 1), c.columnInt(0));
}

test "0003 creates _externalAuths with unique provider/providerId and per-record indexes" {
    var d = try db.Db.openMemory();
    defer d.close();
    try run(&d);
    var t = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('_externalAuths');");
    defer t.finalize();
    _ = try t.step();
    try std.testing.expect(t.columnInt(0) >= 7);
    try d.exec("INSERT INTO \"_externalAuths\" (\"id\",\"collectionRef\",\"recordRef\",\"provider\",\"providerId\",\"created\",\"updated\") VALUES ('e1','users','r1','google','G1','','');");
    try std.testing.expectError(error.ExecFailed, d.exec("INSERT INTO \"_externalAuths\" (\"id\",\"collectionRef\",\"recordRef\",\"provider\",\"providerId\",\"created\",\"updated\") VALUES ('e2','users','r2','google','G1','','');"));
    try d.exec("INSERT INTO \"_externalAuths\" (\"id\",\"collectionRef\",\"recordRef\",\"provider\",\"providerId\",\"created\",\"updated\") VALUES ('e3','users','r1','github','H1','','');");
    try std.testing.expectError(error.ExecFailed, d.exec("INSERT INTO \"_externalAuths\" (\"id\",\"collectionRef\",\"recordRef\",\"provider\",\"providerId\",\"created\",\"updated\") VALUES ('e4','users','r1','github','H2','','');"));
}
