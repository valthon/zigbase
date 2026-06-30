//! Live field-encryption + key-rotation rewrap verification for the Postgres arm
//! (issue #159, PR-5). Field encryption is pure-Zig AEAD whose ciphertext is stored as a
//! TEXT *envelope* (e.g. `v2:<base64…>`), so the encrypt/decrypt path is backend-NEUTRAL.
//! These tests prove that claim end-to-end on a real PostgreSQL:
//!
//!   1. The `field_cipher` pointer plumbing the foundation threaded (pool → writer → Stmt)
//!      functions on the PG arm, and an AEAD envelope round-trips through the full
//!      `db.Pool`/`db.Db`/`db.Stmt` stack and a Postgres TEXT column.
//!   2. Key-rotation rewrap (`rewrap.rewrapColumn`) re-encrypts an old-generation envelope to
//!      the primary generation on Postgres — this is the one place PR-5 changed: the UPDATE is
//!      keyed by the app-generated string `id` PK (Postgres has no SQLite `rowid`) and its
//!      placeholders flow through the dialect (`?n` → `$n`).
//!   3. Rewrap is idempotent and fails closed (no rows changed) on Postgres, identically to
//!      SQLite, and both old + new key generations decrypt after a rotation.
//!
//! They run only under `-Dpostgres=true` and require a reachable PostgreSQL (connection string
//! `ZIGBASE_PG_TEST_URL`, else the SCRAM+TLS default below). A connectivity/auth failure SKIPS,
//! so the suite still runs where no PG exists; CI's `postgres` job sets the env var. Tables are
//! created `TEMP` on the single test connection, so they need no schema cleanup.

const std = @import("std");
const dbm = @import("../../db.zig");
const field_policy = @import("../../field_policy.zig");
const rewrap = @import("../../rewrap.zig");

// ---- connection plumbing (mirrors crud_tests.zig / tests.zig) ---------------

const default_url = "postgres://zbpg:zbpg_secret_pw@[::1]:5432/zbpgtest?sslmode=require";

fn getEnv(key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const e = std.mem.span(entry);
        if (e.len > key.len and std.mem.startsWith(u8, e, key) and e[key.len] == '=')
            return e[key.len + 1 ..];
    }
    return null;
}

fn testUrl() []const u8 {
    return getEnv("ZIGBASE_PG_TEST_URL") orelse default_url;
}

/// Open a `db.Db` Postgres handle, or null to signal "no reachable PG → skip". Only a
/// connectivity/auth failure (`OpenFailed`) skips; any other error propagates.
fn openOrSkip(a: std.mem.Allocator, io: std.Io) !?dbm.Db {
    return dbm.Db.openPostgres(a, io, testUrl()) catch |e| switch (e) {
        error.OpenFailed => null,
        else => e,
    };
}

// ---- key-ring helpers (mirror rewrap.zig's unit tests) ----------------------

const MapGetter = struct {
    pairs: []const [2][]const u8,
    pub fn get(self: MapGetter, key: []const u8) ?[]const u8 {
        for (self.pairs) |p| if (std.mem.eql(u8, p[0], key)) return p[1];
        return null;
    }
};

/// Rotated key-ring: primary generation 2 ("newkey"), generation 1 ("oldkey") read-only.
fn rotatedRing() field_policy.Cipher {
    const getter = MapGetter{ .pairs = &.{.{ "ZIGBASE_FIELD_KEY_V1", "oldkey" }} };
    return field_policy.Cipher.resolve(std.testing.io, getter, "newkey", 2) catch unreachable;
}

/// Read a column's at-rest TEXT value by the string `id` PK.
fn cellById(a: std.mem.Allocator, d: *dbm.Db, table: []const u8, id: []const u8) ![]u8 {
    const sql = try std.fmt.allocPrintSentinel(a, "SELECT v FROM {s} WHERE \"id\" = $1;", .{table}, 0);
    var s = try d.prepare(sql);
    defer s.finalize();
    try s.bindText(1, id);
    _ = try s.step();
    return a.dupe(u8, s.columnText(0));
}

// ---- tests ------------------------------------------------------------------

test "pg encryption: field_cipher plumbing + AEAD envelope round-trips through the PG pool/Db/Stmt" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();

    const url = try ar.dupeZ(u8, testUrl());
    var pool = dbm.Pool.init(a, io, url) catch |e| switch (e) {
        error.OpenFailed => return error.SkipZigTest,
        else => return e,
    };
    defer pool.deinit();
    try std.testing.expectEqual(dbm.Backend.postgres, dbm.poolBackend(&pool));

    // Stamp the resolved cipher on the pool exactly as `framework.zig` does in production; the
    // pool must propagate the pointer pool → writer → Stmt on the PG arm.
    var cipher = field_policy.Cipher.fromEnv(io, "round-trip-key");
    dbm.poolSetFieldCipher(&pool, @ptrCast(&cipher));

    const w = pool.acquireWriter();
    defer pool.releaseWriter();
    try w.exec("CREATE TEMP TABLE zb_enc (\"id\" TEXT PRIMARY KEY, v TEXT);");

    // The field_cipher pointer reaches the prepared statement on the PG backend.
    {
        var probe = try w.prepare("SELECT 1;");
        defer probe.finalize();
        try std.testing.expect(dbm.stmtFieldCipher(&probe) != null);
    }

    // Seal a value (pure-Zig AEAD) and store the TEXT envelope through the union db.Stmt.
    const secret = "top-secret-pii";
    const envelope = try cipher.seal(ar, secret);
    {
        var ins = try w.prepare("INSERT INTO zb_enc (\"id\", v) VALUES ($1, $2);");
        defer ins.finalize();
        try ins.bindText(1, "r1");
        try ins.bindText(2, envelope);
        try std.testing.expect(!try ins.step());
    }

    // At rest the Postgres column holds the envelope, never the plaintext.
    const stored = try cellById(ar, w, "zb_enc", "r1");
    try std.testing.expect(std.mem.startsWith(u8, stored, "v1:"));
    try std.testing.expect(std.mem.indexOf(u8, stored, secret) == null);
    // …and it decrypts back to the original through the cipher.
    try std.testing.expectEqualStrings(secret, try cipher.open(ar, stored));
}

test "pg rewrap: rewrapColumn re-encrypts an old-generation envelope keyed by id (rowid→id fix)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();
    try std.testing.expectEqual(dbm.Backend.postgres, dbm.dbBackend(&d));

    try d.exec("CREATE TEMP TABLE t (\"id\" TEXT PRIMARY KEY, v TEXT);");

    // Seed a generation-1 envelope (as an old single-key build wrote it).
    const old = field_policy.Cipher.fromEnv(io, "oldkey");
    {
        var ins = try d.prepare("INSERT INTO t (\"id\", v) VALUES ('r1', $1);");
        defer ins.finalize();
        try ins.bindText(1, try old.seal(ar, "the-secret"));
        try std.testing.expect(!try ins.step());
    }

    // Rotate: rewrap under the new primary generation. This UPDATEs by the string `id` PK and
    // renumbers `?n`→`$n` via the dialect — the whole point of PR-5 on Postgres.
    const ring = rotatedRing();
    const cs = try rewrap.rewrapColumn(ar, &d, &ring, "t", "v", false, null);
    try std.testing.expectEqual(@as(usize, 1), cs.rewrapped);
    try std.testing.expectEqual(@as(usize, 0), cs.plaintext_migrated);

    // The cell is now a v2 envelope, the plaintext never appears, and it decrypts under the
    // rotated ring (old + new generations both resolvable).
    const after = try cellById(ar, &d, "t", "r1");
    try std.testing.expect(std.mem.startsWith(u8, after, "v2:"));
    try std.testing.expect(std.mem.indexOf(u8, after, "the-secret") == null);
    try std.testing.expectEqualStrings("the-secret", try ring.open(ar, after));
}

test "pg rewrap: legacy plaintext migrated, idempotent re-run, and fail-closed on Postgres" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();

    try d.exec("CREATE TEMP TABLE t (\"id\" TEXT PRIMARY KEY, v TEXT);");
    // A legacy plaintext cell and an old-gen envelope cell.
    try d.exec("INSERT INTO t (\"id\", v) VALUES ('r1', 'plain-value');");
    const old = field_policy.Cipher.fromEnv(io, "oldkey");
    {
        var ins = try d.prepare("INSERT INTO t (\"id\", v) VALUES ('r2', $1);");
        defer ins.finalize();
        try ins.bindText(1, try old.seal(ar, "enc-value"));
        try std.testing.expect(!try ins.step());
    }

    const ring = rotatedRing();
    const first = try rewrap.rewrapColumn(ar, &d, &ring, "t", "v", false, null);
    try std.testing.expectEqual(@as(usize, 1), first.plaintext_migrated);
    try std.testing.expectEqual(@as(usize, 1), first.rewrapped);
    try std.testing.expectEqualStrings("plain-value", try ring.open(ar, try cellById(ar, &d, "t", "r1")));
    try std.testing.expectEqualStrings("enc-value", try ring.open(ar, try cellById(ar, &d, "t", "r2")));

    // Idempotent: a second pass skips everything (both already at the primary generation).
    const second = try rewrap.rewrapColumn(ar, &d, &ring, "t", "v", false, null);
    try std.testing.expectEqual(@as(usize, 2), second.skipped);
    try std.testing.expectEqual(@as(usize, 0), second.rewrapped + second.plaintext_migrated);

    // Fail-closed: a ring with NO generation-1 key cannot decrypt a fresh v1 envelope, so the
    // run aborts and the offending row is reported by its string id (not a rowid).
    try d.exec("CREATE TEMP TABLE t2 (\"id\" TEXT PRIMARY KEY, v TEXT);");
    {
        var ins = try d.prepare("INSERT INTO t2 (\"id\", v) VALUES ('x9', $1);");
        defer ins.finalize();
        try ins.bindText(1, try old.seal(ar, "unreadable"));
        try std.testing.expect(!try ins.step());
    }
    const no_gen1 = try field_policy.Cipher.resolve(io, MapGetter{ .pairs = &.{} }, "newkey", 2);
    var failure: rewrap.Failure = .{};
    try std.testing.expectError(
        error.RewrapDecryptFailed,
        rewrap.rewrapColumn(ar, &d, &no_gen1, "t2", "v", false, &failure),
    );
    try std.testing.expectEqualStrings("x9", failure.id);
    // The cell is untouched — still the original v1 envelope (no data loss).
    try std.testing.expect(std.mem.startsWith(u8, try cellById(ar, &d, "t2", "x9"), "v1:"));
}
