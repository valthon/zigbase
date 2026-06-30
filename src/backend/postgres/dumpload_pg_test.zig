//! Live SQLite → PostgreSQL dump/load round-trip (issue #159, PR-9).
//!
//! Builds a small SQLite instance (two related collections + a system table + an *encrypted*
//! field), migrates it into a fresh Postgres schema via `dumpload.run`, and asserts the Postgres
//! side ends up with identical per-table row counts, that the encrypted-field envelope was carried
//! VERBATIM (still decrypts), and that record ids / a relation FK survived.
//!
//! Runs only under `-Dpostgres=true` and requires a reachable PostgreSQL (connection string
//! `ZIGBASE_PG_TEST_URL`, else the SCRAM+TLS default in `tests.zig`). A connectivity/auth failure
//! SKIPS. Each run provisions into a throwaway `CREATE SCHEMA` (dropped on teardown) so it never
//! collides with the other live-PG test files.

const std = @import("std");
const dbm = @import("../../db.zig");
const dumpload = @import("../../dumpload.zig");
const migrations = @import("../../migrations.zig");
const collections = @import("../../collections.zig");
const schema = @import("../../schema.zig");
const field_policy = @import("../../field_policy.zig");
const pgtests = @import("tests.zig");

fn openTargetOrSkip(a: std.mem.Allocator, io: std.Io) !?dbm.Db {
    return dbm.Db.openPostgres(a, io, pgtests.testUrl()) catch |e| switch (e) {
        error.OpenFailed => null,
        else => e,
    };
}

var schema_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

fn enterTempSchema(a: std.mem.Allocator, d: *dbm.Db) ![:0]const u8 {
    const n = schema_counter.fetchAdd(1, .monotonic);
    const name = try std.fmt.allocPrint(a, "zb_dl_{d}", .{n});
    try d.exec(try std.fmt.allocPrintSentinel(a, "DROP SCHEMA IF EXISTS \"{s}\" CASCADE;", .{name}, 0));
    try d.exec(try std.fmt.allocPrintSentinel(a, "CREATE SCHEMA \"{s}\";", .{name}, 0));
    try d.exec(try std.fmt.allocPrintSentinel(a, "SET search_path TO \"{s}\";", .{name}, 0));
    return std.fmt.allocPrintSentinel(a, "{s}", .{name}, 0);
}

fn dropTempSchema(a: std.mem.Allocator, d: *dbm.Db, name: []const u8) void {
    const sql = std.fmt.allocPrintSentinel(a, "DROP SCHEMA IF EXISTS \"{s}\" CASCADE;", .{name}, 0) catch return;
    d.exec(sql) catch {};
}

fn countPg(a: std.mem.Allocator, d: *dbm.Db, table: []const u8) !i64 {
    const sql = try std.fmt.allocPrintSentinel(a, "SELECT COUNT(*) FROM \"{s}\";", .{table}, 0);
    var st = try d.prepare(sql);
    defer st.finalize();
    if (!try st.step()) return 0;
    return st.columnInt(0);
}

fn countSqlite(a: std.mem.Allocator, d: *dbm.Db, table: []const u8) !i64 {
    return countPg(a, d, table); // identical SQL on SQLite
}

test "pg dumpload: SQLite -> Postgres round-trips records, an encrypted field, and a relation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    // ---- Target Postgres in a throwaway schema --------------------------------------------
    var target = (try openTargetOrSkip(a, io)) orelse return error.SkipZigTest;
    defer target.close();
    try std.testing.expectEqual(dbm.Backend.postgres, dbm.dbBackend(&target));
    const sname = try enterTempSchema(al, &target);
    defer dropTempSchema(al, &target, sname);

    // ---- Source SQLite: two related collections + an encrypted field + a system-table row ---
    var source = try dbm.Db.openMemory();
    defer source.close();
    try migrations.run(&source);

    // `authors` (parent), then `notes` (child) with a single-relation FK to authors + an
    // `.encrypted` field whose at-rest value is an AEAD envelope.
    const authors = schema.Collection{ .id = "_", .name = "authors", .fields = &[_]schema.Field{
        .{ .id = "a1", .name = "name", .options = .{ .text = .{} } },
    } };
    const created_authors = try collections.create(al, io, &source, authors);

    const notes = schema.Collection{ .id = "_", .name = "notes", .fields = &[_]schema.Field{
        .{ .id = "n1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "n2", .name = "secret", .encrypted = true, .options = .{ .text = .{} } },
        .{ .id = "n3", .name = "author", .options = .{ .relation = .{ .targetCollectionId = created_authors.id, .cascadeDelete = false } } },
    } };
    _ = try collections.create(al, io, &source, notes);

    // Seed rows. The encrypted cell stores a real AEAD envelope (carried verbatim by the tool).
    const cipher = field_policy.Cipher.fromEnv(io, "dumpload-test-key");
    const envelope = try cipher.seal(al, "classified-note-body");

    try source.exec("INSERT INTO \"authors\" (\"id\",\"created\",\"updated\",\"name\") VALUES ('au1','t0','t0','Ada');");
    {
        var ins = try source.prepare("INSERT INTO \"notes\" (\"id\",\"created\",\"updated\",\"title\",\"secret\",\"author\") VALUES ('no1','t1','t1','first',?1,'au1');");
        defer ins.finalize();
        try ins.bindText(1, envelope);
        try std.testing.expect(!try ins.step());
    }
    // A system-table row (an analytics event) to prove system tables migrate too. The Postgres
    // `_events._seq` IDENTITY column is server-generated and excluded from the copy automatically.
    try source.exec("INSERT INTO \"_events\" (\"id\",\"created\",\"updated\",\"name\",\"occurred_at\") VALUES ('ev1','t2','t2','test.event','t2');");

    const src_authors = try countSqlite(al, &source, "authors");
    const src_notes = try countSqlite(al, &source, "notes");
    const src_events = try countSqlite(al, &source, "_events");

    // ---- Migrate ---------------------------------------------------------------------------
    const report = try dumpload.run(a, &source, &target, .{});
    defer {
        for (report.tables) |t| a.free(t.name);
        a.free(report.tables);
    }
    // Two user record tables (authors, notes) provisioned; system tables came from migrations.
    try std.testing.expectEqual(@as(usize, 2), report.collections_provisioned);

    // ---- Identical per-table row counts on Postgres ----------------------------------------
    try std.testing.expectEqual(src_authors, try countPg(al, &target, "authors"));
    try std.testing.expectEqual(src_notes, try countPg(al, &target, "notes"));
    try std.testing.expectEqual(src_events, try countPg(al, &target, "_events"));

    // ---- The encrypted envelope was carried VERBATIM (and still decrypts) ------------------
    {
        var st = try target.prepare("SELECT \"secret\",\"author\",\"title\" FROM \"notes\" WHERE \"id\"=$1;");
        defer st.finalize();
        try st.bindText(1, "no1");
        try std.testing.expect(try st.step());
        const stored = st.columnText(0);
        // The plaintext never appears at rest; the stored value equals the source envelope and
        // decrypts back to the original secret.
        try std.testing.expect(std.mem.indexOf(u8, stored, "classified-note-body") == null);
        try std.testing.expectEqualStrings(envelope, stored);
        try std.testing.expectEqualStrings("classified-note-body", try cipher.open(al, stored));
        // The relation FK value survived (record ids preserved).
        try std.testing.expectEqualStrings("au1", st.columnText(1));
        try std.testing.expectEqualStrings("first", st.columnText(2));
    }

    // ---- The relation is enforceable on Postgres: inserting a note with a dangling author
    //      FK is rejected (proves the FK constraint provisioned, not just the column). --------
    {
        var bad = try target.prepare("INSERT INTO \"notes\" (\"id\",\"created\",\"updated\",\"title\",\"author\") VALUES ('no2','t','t','x','MISSING');");
        defer bad.finalize();
        try std.testing.expectError(error.StepFailed, bad.step());
    }

    // ---- _collections metadata copied verbatim: the authors id is preserved -----------------
    {
        var st = try target.prepare("SELECT \"id\" FROM \"_collections\" WHERE \"name\"='authors';");
        defer st.finalize();
        try std.testing.expect(try st.step());
        try std.testing.expectEqualStrings(created_authors.id, st.columnText(0));
    }
}

test "pg dumpload: refuses a non-empty Postgres target without --force, proceeds with it" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var target = (try openTargetOrSkip(a, io)) orelse return error.SkipZigTest;
    defer target.close();
    const sname = try enterTempSchema(al, &target);
    defer dropTempSchema(al, &target, sname);

    var source = try dbm.Db.openMemory();
    defer source.close();
    try migrations.run(&source);

    // First migration provisions the schema → target now non-empty.
    {
        const r = try dumpload.run(a, &source, &target, .{});
        for (r.tables) |t| a.free(t.name);
        a.free(r.tables);
    }
    // A second run without --force is refused…
    try std.testing.expectError(dumpload.Error.TargetNotEmpty, dumpload.run(a, &source, &target, .{}));
    // …and accepted with --force.
    const r2 = try dumpload.run(a, &source, &target, .{ .force = true });
    defer {
        for (r2.tables) |t| a.free(t.name);
        a.free(r2.tables);
    }
    try std.testing.expect(r2.total_rows > 0);
}
