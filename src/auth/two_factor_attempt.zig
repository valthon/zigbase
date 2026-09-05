//! Restricted authentication attempts. No value produced here is an auth token.
const std = @import("std");
const db = @import("../db.zig");
const sink = @import("../sql/param_sink.zig");
const clock = @import("../clock.zig");
const Migrator = @import("../migrator.zig").Migrator;

pub const ttl_seconds = 300;
pub const max_attempts = 5;
pub const Purpose = enum { login, enrollment, management };

/// Borrowed bindings supplied only after primary authentication. generation is
/// an opaque fingerprint of the record token key and session epoch; callers
/// recompute it on each use so password reset and revocation invalidate attempts.
pub const Binding = struct {
    collection: []const u8,
    principal: []const u8,
    generation: []const u8,
    purpose: Purpose,
};

pub fn migrate(m: *Migrator) db.DbError!void {
    try m.execLowered(
        \\CREATE TABLE IF NOT EXISTS "_twoFactorAttempts" (
        \\ "digest" TEXT PRIMARY KEY, "collectionRef" TEXT NOT NULL,
        \\ "recordRef" TEXT NOT NULL, "generation" TEXT NOT NULL,
        \\ "purpose" TEXT NOT NULL, "payload" TEXT NOT NULL,
        \\ "expires" INTEGER NOT NULL, "remaining" INTEGER NOT NULL,
        \\ "consumed" INTEGER NOT NULL DEFAULT 0
        \\);
    );
    try m.execLowered("CREATE INDEX IF NOT EXISTS \"idx_twofactor_expiry\" ON \"_twoFactorAttempts\" (\"expires\");");
}

fn prepare(alloc: std.mem.Allocator, conn: *db.Db, sql: [:0]const u8) !db.Stmt {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    return conn.prepare(try sink.lowerStmtZ(scratch.allocator(), db.dbDialect(conn), sql));
}

fn digest(token: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

fn bind(st: *db.Stmt, token: []const u8, binding: Binding, now: i64) !void {
    const hashed = digest(token);
    try st.bindText(1, &hashed);
    try st.bindText(2, binding.collection);
    try st.bindText(3, binding.principal);
    try st.bindText(4, binding.generation);
    try st.bindText(5, @tagName(binding.purpose));
    try st.bindInt(6, now);
}

/// Caller owns the returned 64-byte capability. Only its digest is persisted.
pub fn create(alloc: std.mem.Allocator, io: std.Io, conn: *db.Db, binding: Binding, payload: []const u8) ![]u8 {
    var random: [32]u8 = undefined;
    io.random(&random);
    const encoded = std.fmt.bytesToHex(random, .lower);
    const token = try alloc.dupe(u8, &encoded);
    errdefer alloc.free(token);
    var st = try prepare(alloc, conn,
        \\INSERT INTO "_twoFactorAttempts"
        \\ ("digest","collectionRef","recordRef","generation","purpose","expires","payload","remaining")
        \\ VALUES (?1,?2,?3,?4,?5,?6,?7,?8);
    );
    defer st.finalize();
    try bind(&st, token, binding, (try clock.sqlNowUnix(conn)) + ttl_seconds);
    try st.bindText(7, payload);
    try st.bindInt(8, max_attempts);
    _ = try st.step();
    return token;
}

/// Reserve one verification attempt BEFORE verifying an untrusted proof. This
/// update must commit even on invalid proof. Returned payload is caller-owned.
/// A successful proof must still call consume, atomically with session issuance.
pub fn reserve(alloc: std.mem.Allocator, conn: *db.Db, token: []const u8, binding: Binding) !?[]u8 {
    if (token.len != 64) return null;
    var st = try prepare(alloc, conn,
        \\UPDATE "_twoFactorAttempts" SET "remaining"="remaining"-1
        \\ WHERE "digest"=?1 AND "collectionRef"=?2 AND "recordRef"=?3
        \\ AND "generation"=?4 AND "purpose"=?5 AND "expires">?6
        \\ AND "consumed"=0 AND "remaining">0 RETURNING "payload";
    );
    defer st.finalize();
    try bind(&st, token, binding, try clock.sqlNowUnix(conn));
    if (!try st.step()) return null;
    const payload = try alloc.dupe(u8, st.columnText(0));
    errdefer alloc.free(payload);
    _ = try st.step();
    return payload;
}

/// Inspect server-owned attempt metadata to resolve its principal before
/// recomputing the current generation and reserving a proof attempt. This grants
/// no authentication or verification authority. Returned payload is owned.
pub fn inspect(alloc: std.mem.Allocator, conn: *db.Db, token: []const u8, collection: []const u8) !?[]u8 {
    if (token.len != 64) return null;
    var st = try prepare(alloc, conn,
        \\SELECT "payload" FROM "_twoFactorAttempts" WHERE "digest"=?1
        \\ AND "collectionRef"=?2 AND "expires">?3 AND "consumed"=0 AND "remaining">0;
    );
    defer st.finalize();
    const hashed = digest(token);
    try st.bindText(1, &hashed);
    try st.bindText(2, collection);
    try st.bindInt(3, try clock.sqlNowUnix(conn));
    if (!try st.step()) return null;
    return try alloc.dupe(u8, st.columnText(0));
}

/// Under the same writer transaction as the factor's replay update and session
/// issuance, claim the attempt exactly once. The final reserved try may succeed
/// when remaining == 0. Caller must have obtained and verified a reserved proof.
pub fn consume(alloc: std.mem.Allocator, conn: *db.Db, token: []const u8, binding: Binding) !bool {
    if (token.len != 64) return false;
    var st = try prepare(alloc, conn,
        \\UPDATE "_twoFactorAttempts" SET "consumed"=1
        \\ WHERE "digest"=?1 AND "collectionRef"=?2 AND "recordRef"=?3
        \\ AND "generation"=?4 AND "purpose"=?5 AND "expires">?6
        \\ AND "consumed"=0 AND "remaining"<5 RETURNING "digest";
    );
    defer st.finalize();
    try bind(&st, token, binding, try clock.sqlNowUnix(conn));
    if (!try st.step()) return false;
    _ = try st.step();
    return true;
}

pub fn gc(alloc: std.mem.Allocator, conn: *db.Db) !void {
    var st = try prepare(alloc, conn,
        \\DELETE FROM "_twoFactorAttempts" WHERE "expires"<=?1 OR "consumed"=1;
    );
    defer st.finalize();
    try st.bindInt(1, try clock.sqlNowUnix(conn));
    _ = try st.step();
}

test "pending attempts bind principal, collection, generation and purpose and are single-use" {
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try @import("../migrations.zig").run(&conn);
    const binding = Binding{ .collection = "users", .principal = "alice", .generation = "key-epoch", .purpose = .login };
    const token = try create(a, std.testing.io, &conn, binding, "opaque factor context");
    defer a.free(token);
    try std.testing.expect(!try consume(a, &conn, token, binding));
    var wrong = binding;
    wrong.principal = "bob";
    try std.testing.expectEqual(null, try reserve(a, &conn, token, wrong));
    wrong = binding;
    wrong.collection = "admins";
    try std.testing.expectEqual(null, try reserve(a, &conn, token, wrong));
    wrong = binding;
    wrong.generation = "rotated";
    try std.testing.expectEqual(null, try reserve(a, &conn, token, wrong));
    wrong = binding;
    wrong.purpose = .enrollment;
    try std.testing.expectEqual(null, try reserve(a, &conn, token, wrong));
    const payload = (try reserve(a, &conn, token, binding)).?;
    defer a.free(payload);
    try std.testing.expectEqualStrings("opaque factor context", payload);
    try std.testing.expect(try consume(a, &conn, token, binding));
    try std.testing.expect(!try consume(a, &conn, token, binding));
    try std.testing.expectEqual(null, try reserve(a, &conn, token, binding));
}

test "pending attempt budget, expiry, and atomic rollback" {
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try @import("../migrations.zig").run(&conn);
    const binding = Binding{ .collection = "users", .principal = "alice", .generation = "key", .purpose = .login };
    const token = try create(a, std.testing.io, &conn, binding, "");
    defer a.free(token);
    for (0..max_attempts) |_| {
        const payload = (try reserve(a, &conn, token, binding)).?;
        a.free(payload);
    }
    try std.testing.expectEqual(null, try reserve(a, &conn, token, binding));
    try conn.beginImmediate();
    try std.testing.expect(try consume(a, &conn, token, binding));
    try conn.rollback();
    try std.testing.expect(try consume(a, &conn, token, binding));
    const expired = try create(a, std.testing.io, &conn, binding, "");
    defer a.free(expired);
    try conn.exec("UPDATE \"_twoFactorAttempts\" SET \"expires\"=0;");
    try std.testing.expectEqual(null, try reserve(a, &conn, expired, binding));
    try std.testing.expect(!try consume(a, &conn, expired, binding));
    try gc(a, &conn);
}
