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

fn init_0008(w: *db.Db) db.DbError!void {
    // Per-credential WebAuthn store. One row per registered authenticator credential.
    // "credentialId" is the base64url of the raw credential id bytes returned by the
    // authenticator; it is the lookup key on every assertion and must be globally unique.
    // "publicKey" stores the COSE_Key bytes (base64-encoded) used to verify assertion
    // signatures. "signCount" is updated after every successful assertion (clone detection).
    // "alg" is the COSE algorithm id (e.g. -7 for ES256). "aaguid" / "transports" are
    // RECOMMENDED for passkey UX but optional; they default to empty string.
    try w.exec(
        \\CREATE TABLE IF NOT EXISTS "_webauthnCredentials" (
        \\  "id" TEXT PRIMARY KEY,
        \\  "collectionRef" TEXT NOT NULL,
        \\  "recordRef" TEXT NOT NULL,
        \\  "credentialId" TEXT NOT NULL UNIQUE,
        \\  "publicKey" TEXT NOT NULL,
        \\  "alg" INTEGER NOT NULL,
        \\  "signCount" INTEGER NOT NULL,
        \\  "aaguid" TEXT NOT NULL DEFAULT '',
        \\  "transports" TEXT NOT NULL DEFAULT '',
        \\  "created" TEXT NOT NULL,
        \\  "updated" TEXT NOT NULL
        \\);
    );
    try w.exec("CREATE INDEX IF NOT EXISTS \"idx_webauthncred_record\" ON \"_webauthnCredentials\" (\"collectionRef\",\"recordRef\");");
}

fn init_0009_kv(w: *db.Db) db.DbError!void {
    // Built-in key→value/settings store (#87). A single internal table holding small,
    // mutable, superuser-managed values keyed by an arbitrary string: feature flags
    // (#88, a typed bool view over this same store), maintenance toggles, cached
    // external tokens, a JSON settings blob the caller (de)serializes, etc. It is NOT a
    // `_collections` row, so it is invisible to the record API, query engine, and
    // access-rule system — settings stay superuser-only by default. "created"/"updated"
    // are ISO-8601 datetimes; an upsert preserves "created" and bumps "updated".
    try w.exec(
        \\CREATE TABLE IF NOT EXISTS "_kv" (
        \\  "key" TEXT PRIMARY KEY,
        \\  "value" TEXT NOT NULL,
        \\  "created" TEXT NOT NULL,
        \\  "updated" TEXT NOT NULL
        \\);
    );
}

fn init_0010_token_epoch(w: *db.Db) db.DbError!void {
    // Session epoch column for Variant A revocation (#99). A per-auth-record integer,
    // default 0, embedded in issued `.auth` tokens; "revoke all sessions" bumps it so
    // every outstanding token for the principal stops verifying. Added here for tables
    // that predate the `token_epoch` auth system field (fresh auth collections get the
    // column from `schema.authSystemFields()` at create time). `NOT NULL DEFAULT 0` so
    // existing rows + omitted inserts read as epoch 0, matching the default JWT claim.
    w.exec("ALTER TABLE \"_superusers\" ADD COLUMN \"token_epoch\" INTEGER NOT NULL DEFAULT 0;") catch {};

    // Collect user auth-collection names FIRST: an ALTER TABLE bumps SQLite's schema
    // version and invalidates any open statement, so we cannot ALTER while iterating the
    // _collections cursor. page_allocator (one-shot, startup) keeps this dependency-free.
    const a = std.heap.page_allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| a.free(n);
        names.deinit(a);
    }
    {
        var st = try w.prepare("SELECT \"name\" FROM \"_collections\" WHERE \"type\"='auth' AND \"name\" != '_superusers';");
        defer st.finalize();
        while (try st.step()) {
            const nm = a.dupe(u8, st.columnText(0)) catch return error.ExecFailed;
            names.append(a, nm) catch {
                a.free(nm);
                return error.ExecFailed;
            };
        }
    }
    for (names.items) |nm| {
        if (!isSafeIdent(nm)) continue; // defensive: never interpolate an unvalidated name
        var buf: [320]u8 = undefined;
        const sql = std.fmt.bufPrintZ(&buf, "ALTER TABLE \"{s}\" ADD COLUMN \"token_epoch\" INTEGER NOT NULL DEFAULT 0;", .{nm}) catch return error.ExecFailed;
        w.exec(sql) catch {}; // ignore "duplicate column" when the column already exists
    }
}

/// Local identifier guard for migration 0010's dynamic ALTER (avoids importing schema.zig).
/// Mirrors `schema.isValidIdentifier`: first char a letter, rest alphanumeric/underscore.
fn isSafeIdent(s: []const u8) bool {
    if (s.len == 0 or s.len > 250) return false;
    if (!std.ascii.isAlphabetic(s[0])) return false;
    for (s) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    return true;
}

fn init_0011_sessions(w: *db.Db) db.DbError!void {
    // Variant B session store (#99), populated only when App(.{ .session_store = .table }).
    // One row per issued session enables per-device listActiveSessions()/revoke(sessionId)
    // on top of revoke-all. In the default `.epoch` mode this table is created but unused
    // (revocation runs via the token epoch). The table shape is locked here so enabling the
    // table variant later needs no further migration. "revoked"/"expires" gate verification;
    // "lastSeen" supports an idle-timeout sweep. See the session-management design spec.
    try w.exec(
        \\CREATE TABLE IF NOT EXISTS "_sessions" (
        \\  "id" TEXT PRIMARY KEY,
        \\  "collectionRef" TEXT NOT NULL,
        \\  "recordRef" TEXT NOT NULL,
        \\  "csrf" TEXT NOT NULL DEFAULT '',
        \\  "userAgent" TEXT NOT NULL DEFAULT '',
        \\  "created" TEXT NOT NULL,
        \\  "lastSeen" TEXT NOT NULL DEFAULT '',
        \\  "revoked" INTEGER NOT NULL DEFAULT 0,
        \\  "expires" INTEGER NOT NULL DEFAULT 0
        \\);
    );
    try w.exec("CREATE INDEX IF NOT EXISTS \"idx_sessions_principal\" ON \"_sessions\" (\"collectionRef\",\"recordRef\");");
    try w.exec("CREATE INDEX IF NOT EXISTS \"idx_sessions_expires\" ON \"_sessions\" (\"expires\");");
}

pub const all = [_]Migration{
    .{ .name = "0001_init", .up = init_0001 },
    .{ .name = "0002_auth", .up = init_0002 },
    .{ .name = "0003_external_auths", .up = init_0003 },
    .{ .name = "0004_consumed_tokens", .up = init_0004 },
    .{ .name = "0005_oauth_states", .up = init_0005 },
    .{ .name = "0006_cursor_states", .up = init_0006 },
    .{ .name = "0007_auth_challenges", .up = init_0007 },
    .{ .name = "0008_webauthn_credentials", .up = init_0008 },
    .{ .name = "0009_kv", .up = init_0009_kv },
    .{ .name = "0010_token_epoch", .up = init_0010_token_epoch },
    .{ .name = "0011_sessions", .up = init_0011_sessions },
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

test "0009 creates _kv settings table with key/value/created/updated columns" {
    var d = try db.Db.openMemory();
    defer d.close();
    try run(&d);
    var t = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('_kv');");
    defer t.finalize();
    _ = try t.step();
    try std.testing.expectEqual(@as(i64, 4), t.columnInt(0));
    // key is the primary key.
    var pk = try d.prepare("SELECT pk FROM pragma_table_info('_kv') WHERE name='key';");
    defer pk.finalize();
    _ = try pk.step();
    try std.testing.expectEqual(@as(i64, 1), pk.columnInt(0));
}

test "0010 adds token_epoch to _superusers (default 0, idempotent)" {
    var d = try db.Db.openMemory();
    defer d.close();
    try run(&d);
    var c = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('_superusers') WHERE name='token_epoch';");
    defer c.finalize();
    _ = try c.step();
    try std.testing.expectEqual(@as(i64, 1), c.columnInt(0));
    // A row inserted without token_epoch reads back as 0 (NOT NULL DEFAULT 0).
    try d.exec("INSERT INTO \"_superusers\" (\"id\",\"created\",\"updated\",\"email\") VALUES ('s1','','','a@b.c');");
    var e = try d.prepare("SELECT token_epoch FROM \"_superusers\" WHERE id='s1';");
    defer e.finalize();
    _ = try e.step();
    try std.testing.expectEqual(@as(i64, 0), e.columnInt(0));
    // Re-running migrations does not fail on the already-present column.
    try run(&d);
}

test "0010 backfills token_epoch onto a pre-existing user auth table" {
    var d = try db.Db.openMemory();
    defer d.close();
    // Simulate an OLD database: the migrations table is current up to 0009 but a user auth
    // collection's physical table predates the token_epoch column.
    try d.exec(
        \\CREATE TABLE "_migrations" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT UNIQUE NOT NULL, "applied_at" TEXT NOT NULL);
    );
    inline for (.{ "0001_init", "0002_auth", "0003_external_auths", "0004_consumed_tokens", "0005_oauth_states", "0006_cursor_states", "0007_auth_challenges", "0008_webauthn_credentials", "0009_kv" }) |name| {
        try d.exec("INSERT INTO \"_migrations\" (\"name\",\"applied_at\") VALUES ('" ++ name ++ "', datetime('now'));");
    }
    try d.exec("CREATE TABLE \"_collections\" (\"id\" TEXT PRIMARY KEY, \"name\" TEXT UNIQUE NOT NULL, \"type\" TEXT NOT NULL DEFAULT 'base');");
    try d.exec("CREATE TABLE \"_superusers\" (\"id\" TEXT PRIMARY KEY, \"email\" TEXT);");
    try d.exec("INSERT INTO \"_collections\" (\"id\",\"name\",\"type\") VALUES ('c1','members','auth');");
    try d.exec("CREATE TABLE \"members\" (\"id\" TEXT PRIMARY KEY, \"email\" TEXT, \"tokenKey\" TEXT);");
    try d.exec("INSERT INTO \"members\" (\"id\",\"email\",\"tokenKey\") VALUES ('m1','m@x.io','tk');");

    try run(&d); // applies 0010 + 0011

    var c = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('members') WHERE name='token_epoch';");
    defer c.finalize();
    _ = try c.step();
    try std.testing.expectEqual(@as(i64, 1), c.columnInt(0));
    // The pre-existing row gets epoch 0 (data preserved).
    var e = try d.prepare("SELECT token_epoch, tokenKey FROM \"members\" WHERE id='m1';");
    defer e.finalize();
    _ = try e.step();
    try std.testing.expectEqual(@as(i64, 0), e.columnInt(0));
    try std.testing.expectEqualStrings("tk", e.columnText(1));
}

test "0011 creates the _sessions store with its indexes" {
    var d = try db.Db.openMemory();
    defer d.close();
    try run(&d);
    var t = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('_sessions');");
    defer t.finalize();
    _ = try t.step();
    try std.testing.expectEqual(@as(i64, 9), t.columnInt(0));
    var idx = try d.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name IN ('idx_sessions_principal','idx_sessions_expires');");
    defer idx.finalize();
    _ = try idx.step();
    try std.testing.expectEqual(@as(i64, 2), idx.columnInt(0));
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
