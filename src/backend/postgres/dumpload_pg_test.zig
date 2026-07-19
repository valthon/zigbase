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

/// The suite URL with the userinfo swapped for `user:pass` (fixture credentials are
/// URL-safe ASCII; the rest of the URL — host/port/db/sslmode — is spliced verbatim so
/// the test works under both CI jobs' sslmodes).
fn urlAs(a: std.mem.Allocator, user: []const u8, pass: []const u8) ![]const u8 {
    const base = pgtests.testUrl();
    const scheme_end = (std.mem.indexOf(u8, base, "://") orelse return error.TestUnexpectedResult) + 3;
    const at = std.mem.indexOfScalarPos(u8, base, scheme_end, '@') orelse return error.TestUnexpectedResult;
    return std.fmt.allocPrint(a, "{s}{s}:{s}@{s}", .{ base[0..scheme_end], user, pass, base[at + 1 ..] });
}

/// Create a NOSUPERUSER login role + a schema it owns; connect as it; pin search_path.
/// Caller must run `dropNosuper(admin, al, schema_name, role)` in a defer.
///
/// Returns `null` (caller should SKIP) when the admin connection itself lacks CREATEROLE —
/// e.g. a local dev Postgres where the configured admin role isn't a real superuser (`DROP
/// ROLE`/`CREATE ROLE` check the privilege before existence, so even the idempotent `DROP
/// ROLE IF EXISTS` fails "permission denied"). CI's `postgres` job runs as the bootstrap
/// superuser and always has this privilege; only a permission-shaped local environment
/// falls back to skipping, not a hard failure.
fn openNosuperTarget(al: std.mem.Allocator, admin: *dbm.Db, io: std.Io, schema_name: []const u8, role: []const u8) !?dbm.Db {
    try admin.exec(try std.fmt.allocPrintSentinel(al, "DROP SCHEMA IF EXISTS \"{s}\" CASCADE;", .{schema_name}, 0));
    admin.exec(try std.fmt.allocPrintSentinel(al, "DROP ROLE IF EXISTS \"{s}\";", .{role}, 0)) catch |e| switch (e) {
        error.ExecFailed => return null,
        else => return e,
    };
    admin.exec(try std.fmt.allocPrintSentinel(al, "CREATE ROLE \"{s}\" LOGIN PASSWORD 'zb_dl_pw' NOSUPERUSER;", .{role}, 0)) catch |e| switch (e) {
        error.ExecFailed => return null,
        else => return e,
    };
    try admin.exec(try std.fmt.allocPrintSentinel(al, "CREATE SCHEMA \"{s}\" AUTHORIZATION \"{s}\";", .{ schema_name, role }, 0));
    const url = try urlAs(al, role, "zb_dl_pw");
    var target = try dbm.Db.openPostgres(std.testing.allocator, io, url);
    errdefer target.close();
    try target.exec(try std.fmt.allocPrintSentinel(al, "SET search_path TO \"{s}\";", .{schema_name}, 0));
    return target;
}

fn dropNosuper(admin: *dbm.Db, al: std.mem.Allocator, schema_name: []const u8, role: []const u8) void {
    // Schema (owned objects) must go before the role.
    const s1 = std.fmt.allocPrintSentinel(al, "DROP SCHEMA IF EXISTS \"{s}\" CASCADE;", .{schema_name}, 0) catch return;
    admin.exec(s1) catch {};
    const s2 = std.fmt.allocPrintSentinel(al, "DROP ROLE IF EXISTS \"{s}\";", .{role}, 0) catch return;
    admin.exec(s2) catch {};
}

/// Source SQLite with a self-referential collection ("nodes": r1.parent -> r2) and a
/// mutual 2-cycle ("alpha" <-> "beta": a1.buddy -> b1, b1.buddy -> a1 — both non-NULL,
/// which NULL-then-UPDATE could never load). `dangling` additionally points a1.buddy at
/// a missing id to exercise the COMMIT-time rollback.
///
/// The mutual cycle cannot be created in a single pass — a relation field's target must
/// already exist when the collection is created (`resolveRelations` rejects a forward
/// reference). So we mirror how a real app builds a cycle: create `alpha` without its
/// back-edge, create `beta` (buddy -> alpha, which now exists), then ADD `alpha.buddy`
/// -> beta as an additive field update. (`nodes.parent` is a self-relation, resolved
/// without a lookup, so it creates in one pass.)
fn buildCyclicSource(al: std.mem.Allocator, io: std.Io, dangling: bool) !dbm.Db {
    var source = try dbm.Db.openMemory();
    errdefer source.close();
    try migrations.run(&source);

    const nodes = schema.Collection{ .id = "_", .name = "nodes", .fields = &[_]schema.Field{
        .{ .id = "n1", .name = "parent", .options = .{ .relation = .{ .targetCollectionId = "nodes", .maxSelect = 1 } } },
    } };
    _ = try collections.create(al, io, &source, nodes);
    const alpha = schema.Collection{ .id = "_", .name = "alpha", .fields = &[_]schema.Field{} };
    const created_alpha = try collections.create(al, io, &source, alpha);
    const beta = schema.Collection{ .id = "_", .name = "beta", .fields = &[_]schema.Field{
        .{ .id = "b1", .name = "buddy", .options = .{ .relation = .{ .targetCollectionId = created_alpha.id, .maxSelect = 1 } } },
    } };
    const created_beta = try collections.create(al, io, &source, beta);
    // Now that beta exists, add the alpha -> beta back-edge to close the cycle.
    const alpha_closed = schema.Collection{ .id = created_alpha.id, .name = "alpha", .fields = &[_]schema.Field{
        .{ .id = "a1", .name = "buddy", .options = .{ .relation = .{ .targetCollectionId = created_beta.id, .maxSelect = 1 } } },
    } };
    _ = try collections.update(al, io, &source, created_alpha.id, alpha_closed);

    // The cyclic rows below are intentionally unsatisfiable under immediate FK checks (r1
    // points at r2 before it exists; alpha<->beta reference each other) — that is exactly
    // what the deferred-FK target load exists to handle. collections.update re-enables
    // SQLite's foreign_keys pragma, so turn it back off to seed the source cycle.
    try source.exec("PRAGMA foreign_keys=OFF;");
    try source.exec("INSERT INTO \"nodes\" (\"id\",\"created\",\"updated\",\"parent\") VALUES ('r1','t','t','r2');");
    try source.exec("INSERT INTO \"nodes\" (\"id\",\"created\",\"updated\",\"parent\") VALUES ('r2','t','t',NULL);");
    if (dangling) {
        try source.exec("INSERT INTO \"alpha\" (\"id\",\"created\",\"updated\",\"buddy\") VALUES ('a1','t','t','b_missing');");
    } else {
        try source.exec("INSERT INTO \"alpha\" (\"id\",\"created\",\"updated\",\"buddy\") VALUES ('a1','t','t','b1');");
    }
    try source.exec("INSERT INTO \"beta\" (\"id\",\"created\",\"updated\",\"buddy\") VALUES ('b1','t','t','a1');");
    return source;
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
    defer report.deinit(a);
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
        // A foreign-key violation is SQLSTATE class 23 → error.Constraint (prepared-statement path).
        try std.testing.expectError(error.Constraint, bad.step());
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
        r.deinit(a);
    }
    // A second run without --force is refused…
    try std.testing.expectError(dumpload.Error.TargetNotEmpty, dumpload.run(a, &source, &target, .{}));
    // …and accepted with --force.
    const r2 = try dumpload.run(a, &source, &target, .{ .force = true });
    defer r2.deinit(a);
    try std.testing.expect(r2.total_rows > 0);
}

test "pg dumpload: a mid-load failure rolls the whole load back to zero migrated rows (M2 atomicity)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var target = (try openTargetOrSkip(a, io)) orelse return error.SkipZigTest;
    defer target.close();
    const sname = try enterTempSchema(al, &target);
    defer dropTempSchema(al, &target, sname);

    // Source with a `notes` collection whose SECOND row has a NULL id. SQLite tolerates a NULL in a
    // TEXT PRIMARY KEY; Postgres (NOT NULL PK) rejects it on INSERT — an injected mid-load failure.
    var source = try dbm.Db.openMemory();
    defer source.close();
    try migrations.run(&source);
    const col = schema.Collection{ .id = "_", .name = "notes", .fields = &[_]schema.Field{
        .{ .id = "n1", .name = "title", .options = .{ .text = .{} } },
    } };
    _ = try collections.create(al, io, &source, col);
    try source.exec("INSERT INTO \"notes\" (\"id\",\"created\",\"updated\",\"title\") VALUES ('ok','t','t','good');");
    try source.exec("INSERT INTO \"notes\" (\"id\",\"created\",\"updated\",\"title\") VALUES (NULL,'t','t','bad');");

    // The load fails partway (the NULL-id INSERT) and the whole transaction rolls back. The
    // per-row INSERTs are prepared statements, so the NOT NULL violation (SQLSTATE 23502) on the
    // target surfaces as error.Constraint.
    try std.testing.expectError(error.Constraint, dumpload.run(a, &source, &target, .{}));

    // The target is left CLEAN: the provisioned `notes` table exists but holds ZERO rows (the
    // committed-before-failure `ok` row was rolled back), and the verbatim `_collections` copy was
    // rolled back too (no user `notes` metadata persisted — only the migration-seeded system rows).
    try std.testing.expectEqual(@as(i64, 0), try countPg(al, &target, "notes"));
    {
        var st = try target.prepare("SELECT COUNT(*) FROM \"_collections\" WHERE \"name\"='notes';");
        defer st.finalize();
        try std.testing.expect(try st.step());
        try std.testing.expectEqual(@as(i64, 0), st.columnInt(0));
    }
}

/// Collect `(id, _seq)` for every `_events` row on the target, ordered by id, as `"id=seq"` strings.
fn eventSeqsById(al: std.mem.Allocator, d: *dbm.Db) ![]const []const u8 {
    var st = try d.prepare("SELECT \"id\", \"_seq\" FROM \"_events\" ORDER BY \"id\";");
    defer st.finalize();
    var out: std.ArrayList([]const u8) = .empty;
    while (try st.step())
        try out.append(al, try std.fmt.allocPrint(al, "{s}={d}", .{ st.columnText(0), st.columnInt(1) }));
    return out.toOwnedSlice(al);
}

test "pg dumpload: a --force re-migration regenerates IDENTITY densely (RESTART IDENTITY determinism)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var target = (try openTargetOrSkip(a, io)) orelse return error.SkipZigTest;
    defer target.close();
    const sname = try enterTempSchema(al, &target);
    defer dropTempSchema(al, &target, sname);

    // Source with three `_events` rows. On the target, `_events._seq` is a GENERATED ALWAYS AS
    // IDENTITY column regenerated during the load (the source has no `_seq`).
    var source = try dbm.Db.openMemory();
    defer source.close();
    try migrations.run(&source);
    try source.exec(
        \\INSERT INTO "_events" ("id","created","updated","name","payload","account","occurred_at") VALUES
        \\ ('e1','t','t','x','{}','acc1','2026-01-01T08:00:00Z'),
        \\ ('e2','t','t','x','{}','acc1','2026-01-01T09:00:00Z'),
        \\ ('e3','t','t','x','{}','acc1','2026-01-01T10:00:00Z');
    );

    // First migration → capture the assigned `_seq` per event id.
    {
        const r = try dumpload.run(a, &source, &target, .{});
        r.deinit(a);
    }
    const first = try eventSeqsById(al, &target);
    // Dense from 1: the three rows get _seq 1..3 (deterministic, source rowid order).
    try std.testing.expectEqual(@as(usize, 3), first.len);

    // A `--force` re-migration must produce the IDENTICAL `_seq` mapping — TRUNCATE … RESTART
    // IDENTITY resets the sequence so it regenerates 1..N rather than continuing 4..6.
    {
        const r2 = try dumpload.run(a, &source, &target, .{ .force = true });
        r2.deinit(a);
    }
    const second = try eventSeqsById(al, &target);
    try std.testing.expectEqual(first.len, second.len);
    for (first, second) |x, y| try std.testing.expectEqualStrings(x, y);
}

test "pg dumpload: NOSUPERUSER target loads self-referential + mutual non-nullable cycles via deferred FKs" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var admin = (try openTargetOrSkip(a, io)) orelse return error.SkipZigTest;
    defer admin.close();

    var target = (try openNosuperTarget(al, &admin, io, "zb_dl_ns1", "zb_dl_nosuper1")) orelse return error.SkipZigTest;
    defer target.close();
    defer dropNosuper(&admin, al, "zb_dl_ns1", "zb_dl_nosuper1");

    var source = try buildCyclicSource(al, io, false);
    defer source.close();

    // As NOSUPERUSER, `SET session_replication_role = replica` fails -> the deferred path
    // runs (a warning is logged; the report is the observable contract here).
    const report = try dumpload.run(a, &source, &target, .{});
    defer report.deinit(a);

    try std.testing.expectEqual(@as(i64, 2), try countPg(al, &target, "nodes"));
    try std.testing.expectEqual(@as(i64, 1), try countPg(al, &target, "alpha"));
    try std.testing.expectEqual(@as(i64, 1), try countPg(al, &target, "beta"));

    // The cycle-edge constraints exist AND are deferrable…
    var st = try target.prepare("SELECT count(*) FROM pg_constraint WHERE conname IN ('fk_alpha_buddy','fk_beta_buddy','fk_nodes_parent') AND condeferrable;");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 3), st.columnInt(0));

    // …and INITIALLY IMMEDIATE: outside the load transaction they enforce like plain FKs.
    try std.testing.expectError(
        dbm.DbError.ExecFailed,
        target.exec("INSERT INTO \"alpha\" (\"id\",\"created\",\"updated\",\"buddy\") VALUES ('a2','t','t','nope');"),
    );
}

test "pg dumpload: a dangling cyclic reference rolls the whole load back at COMMIT" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var admin = (try openTargetOrSkip(a, io)) orelse return error.SkipZigTest;
    defer admin.close();

    var target = (try openNosuperTarget(al, &admin, io, "zb_dl_ns2", "zb_dl_nosuper2")) orelse return error.SkipZigTest;
    defer target.close();
    defer dropNosuper(&admin, al, "zb_dl_ns2", "zb_dl_nosuper2");

    var source = try buildCyclicSource(al, io, true);
    defer source.close();

    // a1.buddy -> 'b_missing': every INSERT succeeds (deferred), COMMIT fails, run() logs
    // the actionable cycle message and propagates the DbError.
    try std.testing.expectError(dbm.DbError.ExecFailed, dumpload.run(a, &source, &target, .{}));

    // Rolled back: schema provisioned (pre-transaction), zero migrated rows.
    try std.testing.expectEqual(@as(i64, 0), try countPg(al, &target, "alpha"));
    try std.testing.expectEqual(@as(i64, 0), try countPg(al, &target, "beta"));
    try std.testing.expectEqual(@as(i64, 0), try countPg(al, &target, "nodes"));
}
