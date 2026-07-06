//! Live-PG coverage for `migrate dump` (migrations Piece C). Provisions a throwaway schema with a
//! table (PK + column types + NOT NULL/DEFAULT), a second table with a UNIQUE constraint and a
//! FOREIGN KEY back to the first, plus a secondary index, then runs `schema_dump.schemaDumpForSchema`
//! against that schema and asserts the reconstructed DDL has the right shape: a `CREATE TABLE` with
//! columns, `ALTER TABLE … ADD CONSTRAINT` for the PK/UNIQUE/FK, and a `CREATE INDEX`. It also
//! asserts determinism (two dumps are byte-identical) — proving the catalog reconstruction emits a
//! stable, pg_dump-free `structure.sql`.
//!
//! Runs only under `-Dpostgres=true` with a reachable PostgreSQL; a connectivity/auth failure SKIPS.

const std = @import("std");
const dbm = @import("../../db.zig");
const schema_dump = @import("../../schema_dump.zig");
const pgtests = @import("tests.zig");

fn openOrSkip(a: std.mem.Allocator, io: std.Io) !?dbm.Db {
    return dbm.Db.openPostgres(a, io, pgtests.testUrl()) catch |e| switch (e) {
        error.OpenFailed => null,
        else => e,
    };
}

var schema_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

fn enterTempSchema(a: std.mem.Allocator, d: *dbm.Db) ![:0]const u8 {
    const n = schema_counter.fetchAdd(1, .monotonic);
    const name = try std.fmt.allocPrint(a, "zb_dump_{d}", .{n});
    try d.exec(try std.fmt.allocPrintSentinel(a, "DROP SCHEMA IF EXISTS \"{s}\" CASCADE;", .{name}, 0));
    try d.exec(try std.fmt.allocPrintSentinel(a, "CREATE SCHEMA \"{s}\";", .{name}, 0));
    try d.exec(try std.fmt.allocPrintSentinel(a, "SET search_path TO \"{s}\";", .{name}, 0));
    return std.fmt.allocPrintSentinel(a, "{s}", .{name}, 0);
}

fn dropTempSchema(a: std.mem.Allocator, d: *dbm.Db, name: []const u8) void {
    const sql = std.fmt.allocPrintSentinel(a, "DROP SCHEMA IF EXISTS \"{s}\" CASCADE;", .{name}, 0) catch return;
    d.exec(sql) catch {};
}

test "pg: schemaDump reconstructs CREATE TABLE + ADD CONSTRAINT + CREATE INDEX from catalogs (no pg_dump)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();
    const sname = try enterTempSchema(al, &d);
    defer dropTempSchema(al, &d, sname);

    // A parent table with a PK, a NOT NULL text column, a defaulted column, a bigint, and an
    // integer ARRAY column (exercises the `_int4` → `integer[]` reconstruction path).
    try d.exec("CREATE TABLE \"authors\" (\"id\" TEXT PRIMARY KEY, \"name\" VARCHAR(120) NOT NULL, \"active\" BOOLEAN NOT NULL DEFAULT true, \"rank\" BIGINT, \"scores\" INTEGER[]);");
    // A child table with a UNIQUE constraint and a FK back to authors.
    try d.exec("CREATE TABLE \"posts\" (\"id\" TEXT PRIMARY KEY, \"slug\" TEXT NOT NULL, \"author\" TEXT, CONSTRAINT \"posts_slug_key\" UNIQUE (\"slug\"), CONSTRAINT \"posts_author_fk\" FOREIGN KEY (\"author\") REFERENCES \"authors\"(\"id\"));");
    // A secondary index (NOT constraint-backing) — must appear as a CREATE INDEX.
    try d.exec("CREATE INDEX \"idx_posts_author\" ON \"posts\"(\"author\");");

    const dump = try schema_dump.schemaDumpForSchema(a, &d, dbm.dbDialect(&d), sname);
    defer a.free(dump);

    const has = struct {
        fn f(hay: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, hay, needle) != null;
        }
    }.f;

    // Header, no timestamp.
    try std.testing.expect(std.mem.startsWith(u8, dump, "-- ZigBase schema dump (postgres)\n"));
    // CREATE TABLEs with reconstructed columns/types.
    try std.testing.expect(has(dump, "CREATE TABLE \"authors\" ("));
    try std.testing.expect(has(dump, "CREATE TABLE \"posts\" ("));
    try std.testing.expect(has(dump, "\"name\" character varying(120) NOT NULL"));
    try std.testing.expect(has(dump, "\"active\" boolean"));
    try std.testing.expect(has(dump, "\"rank\" bigint"));
    // Array column reconstructed as `integer[]` (not the raw `_int4` udt name).
    try std.testing.expect(has(dump, "\"scores\" integer[]"));
    // Constraints as ALTER TABLE … ADD CONSTRAINT (PK/UNIQUE/FK via pg_get_constraintdef).
    try std.testing.expect(has(dump, "ALTER TABLE \"authors\" ADD CONSTRAINT"));
    try std.testing.expect(has(dump, "PRIMARY KEY"));
    try std.testing.expect(has(dump, "ALTER TABLE \"posts\" ADD CONSTRAINT \"posts_slug_key\" UNIQUE"));
    try std.testing.expect(has(dump, "ALTER TABLE \"posts\" ADD CONSTRAINT \"posts_author_fk\" FOREIGN KEY"));
    // The secondary index (its backing-constraint indexes were filtered out). `pg_indexes.indexdef`
    // emits identifiers unquoted when they need no quoting, so match the bare name.
    try std.testing.expect(has(dump, "CREATE INDEX idx_posts_author"));
    // Constraint-backing index for the UNIQUE/PK is NOT emitted as a standalone CREATE INDEX.
    try std.testing.expect(!has(dump, "CREATE UNIQUE INDEX posts_slug_key"));

    // Tables come before constraints (so FK ordering never breaks).
    try std.testing.expect(std.mem.indexOf(u8, dump, "CREATE TABLE").? < std.mem.indexOf(u8, dump, "ALTER TABLE").?);

    // Deterministic: a second dump is byte-identical.
    const dump2 = try schema_dump.schemaDumpForSchema(a, &d, dbm.dbDialect(&d), sname);
    defer a.free(dump2);
    try std.testing.expectEqualStrings(dump, dump2);
}
