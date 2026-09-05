const std = @import("std");
const db = @import("../db.zig");
const sink = @import("../sql/param_sink.zig");
const Migrator = @import("../migrator.zig").Migrator;

pub fn migrate(m: *Migrator) db.DbError!void {
    try m.execLowered(
        \\CREATE TABLE IF NOT EXISTS "_twoFactorRates" (
        \\ "collectionRef" TEXT NOT NULL, "recordRef" TEXT NOT NULL,
        \\ "windowStart" INTEGER NOT NULL, "used" INTEGER NOT NULL,
        \\ PRIMARY KEY ("collectionRef","recordRef")
        \\);
    );
    try m.execLowered(
        \\CREATE TABLE IF NOT EXISTS "_twoFactorCredentials" (
        \\ "collectionRef" TEXT NOT NULL, "recordRef" TEXT NOT NULL,
        \\ "kind" TEXT NOT NULL, "id" TEXT NOT NULL, "payload" TEXT NOT NULL,
        \\ "counter" INTEGER NOT NULL DEFAULT -1,
        \\ PRIMARY KEY ("collectionRef","recordRef","kind","id")
        \\);
    );
}

/// Durable per-account budget, independent of global limiter configuration and
/// client IP. Call outside the session transaction so failed proofs spend budget.
pub fn allowAttempt(alloc: std.mem.Allocator, conn: *db.Db, collection: []const u8, principal: []const u8) !bool {
    var st = try prepare(alloc, conn,
        \\INSERT INTO "_twoFactorRates" ("collectionRef","recordRef","windowStart","used") VALUES (?1,?2,?3,1)
        \\ ON CONFLICT ("collectionRef","recordRef") DO UPDATE SET
        \\ "used"=CASE WHEN "_twoFactorRates"."windowStart"<=?3-300 THEN 1 ELSE "_twoFactorRates"."used"+1 END,
        \\ "windowStart"=CASE WHEN "_twoFactorRates"."windowStart"<=?3-300 THEN ?3 ELSE "_twoFactorRates"."windowStart" END
        \\ RETURNING "used";
    );
    defer st.finalize();
    try st.bindText(1, collection);
    try st.bindText(2, principal);
    try st.bindInt(3, try @import("../clock.zig").sqlNowUnix(conn));
    if (!try st.step()) return false;
    const allowed = st.columnInt(0) <= 10;
    _ = try st.step();
    return allowed;
}

pub fn prepare(alloc: std.mem.Allocator, conn: *db.Db, sql: [:0]const u8) !db.Stmt {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    return conn.prepare(try sink.lowerStmtZ(scratch.allocator(), db.dbDialect(conn), sql));
}

/// Call after BEGIN IMMEDIATE. SQLite already owns its writer lock; PostgreSQL
/// must also lock the principal across processes before checking generation.
pub fn lockPrincipal(alloc: std.mem.Allocator, conn: *db.Db, collection: []const u8, principal: []const u8) !bool {
    const table = try @import("../ddl.zig").quoteIdent(alloc, collection);
    defer alloc.free(table);
    const suffix = if (db.dbDialect(conn).kind == .postgres) " FOR UPDATE" else "";
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT \"id\" FROM {s} WHERE \"id\"=?1{s};", .{ table, suffix }, 0);
    defer alloc.free(sql);
    var st = try prepare(alloc, conn, sql);
    defer st.finalize();
    try st.bindText(1, principal);
    const found = try st.step();
    if (found) _ = try st.step();
    return found;
}

pub const Key = struct {
    collection: []const u8,
    principal: []const u8,
    kind: []const u8,
    id: []const u8 = "default",

    fn bind(self: Key, st: *db.Stmt) !void {
        try st.bindText(1, self.collection);
        try st.bindText(2, self.principal);
        try st.bindText(3, self.kind);
        try st.bindText(4, self.id);
    }
};

pub const Credential = struct {
    payload: []const u8,
    counter: i64,

    pub fn deinit(self: Credential, alloc: std.mem.Allocator) void {
        alloc.free(self.payload);
    }
};

pub fn insert(alloc: std.mem.Allocator, conn: *db.Db, key: Key, payload: []const u8, counter: i64) !void {
    var st = try prepare(alloc, conn,
        \\INSERT INTO "_twoFactorCredentials" ("collectionRef","recordRef","kind","id","payload","counter")
        \\ VALUES (?1,?2,?3,?4,?5,?6);
    );
    defer st.finalize();
    try key.bind(&st);
    try st.bindText(5, payload);
    try st.bindInt(6, counter);
    _ = try st.step();
}

/// Owned result, freed with Credential.deinit.
pub fn get(alloc: std.mem.Allocator, conn: *db.Db, key: Key) !?Credential {
    var st = try prepare(alloc, conn,
        \\SELECT "payload","counter" FROM "_twoFactorCredentials"
        \\ WHERE "collectionRef"=?1 AND "recordRef"=?2 AND "kind"=?3 AND "id"=?4;
    );
    defer st.finalize();
    try key.bind(&st);
    if (!try st.step()) return null;
    return .{ .payload = try alloc.dupe(u8, st.columnText(0)), .counter = st.columnInt(1) };
}

pub fn enrolled(alloc: std.mem.Allocator, conn: *db.Db, collection: []const u8, principal: []const u8) !bool {
    var st = try prepare(alloc, conn,
        \\SELECT 1 FROM "_twoFactorCredentials"
        \\ WHERE "collectionRef"=?1 AND "recordRef"=?2 AND "kind"<>'recovery' LIMIT 1;
    );
    defer st.finalize();
    try st.bindText(1, collection);
    try st.bindText(2, principal);
    return st.step();
}

/// Atomic replay gate. The caller commits this in the session transaction.
pub fn advance(alloc: std.mem.Allocator, conn: *db.Db, key: Key, counter: i64) !bool {
    var st = try prepare(alloc, conn,
        \\UPDATE "_twoFactorCredentials" SET "counter"=?5
        \\ WHERE "collectionRef"=?1 AND "recordRef"=?2 AND "kind"=?3 AND "id"=?4
        \\ AND "counter"<?5 RETURNING "id";
    );
    defer st.finalize();
    try key.bind(&st);
    try st.bindInt(5, counter);
    if (!try st.step()) return false;
    _ = try st.step();
    return true;
}

pub fn remove(alloc: std.mem.Allocator, conn: *db.Db, key: Key) !bool {
    var st = try prepare(alloc, conn,
        \\DELETE FROM "_twoFactorCredentials"
        \\ WHERE "collectionRef"=?1 AND "recordRef"=?2 AND "kind"=?3 AND "id"=?4 RETURNING "id";
    );
    defer st.finalize();
    try key.bind(&st);
    if (!try st.step()) return false;
    _ = try st.step();
    return true;
}

test "factor credentials isolate owners and prevent counter and recovery replay" {
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try @import("../migrations.zig").run(&conn);
    const key = Key{ .collection = "users", .principal = "alice", .kind = "totp" };
    try insert(a, &conn, key, "encrypted-secret", 100);
    try std.testing.expect(try enrolled(a, &conn, "users", "alice"));
    try std.testing.expect(!try enrolled(a, &conn, "admins", "alice"));
    try std.testing.expect(!try enrolled(a, &conn, "users", "bob"));
    const credential = (try get(a, &conn, key)).?;
    defer credential.deinit(a);
    try std.testing.expectEqualStrings("encrypted-secret", credential.payload);
    try std.testing.expect(!try advance(a, &conn, key, 100));
    try std.testing.expect(try advance(a, &conn, key, 101));
    try std.testing.expect(!try advance(a, &conn, key, 101));
    const recovery = Key{ .collection = "users", .principal = "bob", .kind = "recovery", .id = "code-digest" };
    try insert(a, &conn, recovery, "", -1);
    try std.testing.expect(!try enrolled(a, &conn, "users", "bob"));
    try std.testing.expect(try remove(a, &conn, recovery));
    try std.testing.expect(!try remove(a, &conn, recovery));
}
