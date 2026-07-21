//! Live-PostgreSQL typed-client codegen parity tests (issue #159, PR-8). These run only under
//! `-Dpostgres=true` (gated from `postgres.zig`) and require a reachable PostgreSQL — they read
//! `ZIGBASE_PG_TEST_URL` and SKIP when none is configured, exactly like the other live-PG tests.
//!
//! The point: the `gen-client` codegen reads ZigBase's OWN `_collections` metadata (not
//! `sqlite_master`/PRAGMA), so the generated TypeScript client is backend-NEUTRAL. These tests
//! prove it end-to-end:
//!   1. the data-dir codegen adapter (`acquire_datadir`) opens a `postgres://` source through the
//!      tagged-union `db.Db` and reads `_collections`, and
//!   2. the client generated from a Postgres-backed instance is byte-identical to the one
//!      generated from the same schema on SQLite (so the ts-sdk snapshot is unaffected by backend).

const std = @import("std");
const db = @import("../../db.zig");
const migrations = @import("../../migrations.zig");
const provision = @import("../../provision.zig");
const schema = @import("../../schema.zig");
const acquire_datadir = @import("../../codegen/acquire_datadir.zig");
const gen_client = @import("../../codegen/gen_client.zig");
const typegen_cli = @import("../../codegen/typegen_cli.zig");

fn testUrlZ() ?[:0]const u8 {
    return std.testing.environ.getPosix("ZIGBASE_PG_TEST_URL");
}

/// A representative app surface exercised by both backends: an auth collection + a base collection
/// with text/number/relation/select/file fields (the same shape `typegen_cli`'s SQLite equivalence
/// test uses, so the cross-backend assertion mirrors the in-repo one).
fn demoSpecs() [2]schema.Collection {
    return .{
        .{ .id = "", .name = "users", .type = .auth, .fields = &.{
            .{ .id = "", .name = "displayName", .options = .{ .text = .{} } },
        } },
        .{ .id = "", .name = "posts", .fields = &.{
            .{ .id = "", .name = "title", .options = .{ .text = .{} } },
            .{ .id = "", .name = "rank", .options = .{ .number = .{ .mode = .int } } },
            .{ .id = "", .name = "author", .options = .{ .relation = .{ .targetCollectionId = "users" } } },
            .{ .id = "", .name = "status", .options = .{ .select = .{ .values = &.{ "draft", "published" }, .maxSelect = 1 } } },
            .{ .id = "", .name = "cover", .options = .{ .file = .{ .maxSelect = 1 } } },
        } },
    };
}

fn genFor(a: std.mem.Allocator, cols: []schema.Collection) ![]const u8 {
    return gen_client.generate(a, cols, &.{}, &.{}, &.{}, &.{}, true, typegen_cli.authCollectionName(cols), "ZbClient", "/api");
}

test "pg: typed-client codegen from a Postgres-backed instance matches the SQLite snapshot" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    const url = testUrlZ() orelse return error.SkipZigTest;

    // ---- Postgres path: provision into a private schema, read _collections back, generate. ----
    var pgconn = db.Db.openPostgres(a, io, url) catch return error.SkipZigTest;
    defer pgconn.close();
    pgconn.exec("DROP SCHEMA IF EXISTS zb_pr8_codegen CASCADE;") catch return error.SkipZigTest;
    defer pgconn.exec("DROP SCHEMA IF EXISTS zb_pr8_codegen CASCADE;") catch {};
    try pgconn.exec("CREATE SCHEMA zb_pr8_codegen;");
    try pgconn.exec("SET search_path TO zb_pr8_codegen;");
    try migrations.run(&pgconn);
    const pg_specs = demoSpecs();
    try provision.applySpecs(al, io, &pgconn, &pg_specs);
    const pg_acq = try acquire_datadir.acquireFromDb(al, &pgconn);
    defer pg_acq.deinit();
    const pg_cols = pg_acq.collections;
    const pg_client = try genFor(al, pg_cols);

    // ---- SQLite path: identical schema into in-memory SQLite, same read-back + generate. ----
    var lite = try db.Db.openMemory();
    defer lite.close();
    try migrations.run(&lite);
    const lite_specs = demoSpecs();
    try provision.applySpecs(al, io, &lite, &lite_specs);
    const lite_acq = try acquire_datadir.acquireFromDb(al, &lite);
    defer lite_acq.deinit();
    const lite_cols = lite_acq.collections;
    const lite_client = try genFor(al, lite_cols);

    // The generated client is byte-identical across backends → the ts-sdk snapshot is
    // backend-neutral. (If this ever diverges, the codegen accidentally leaked a backend detail.)
    try std.testing.expectEqualStrings(lite_client, pg_client);
}

test "pg: the data-dir codegen adapter opens a postgres:// source and reads _collections" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    const url = testUrlZ() orelse return error.SkipZigTest;

    // Provision into the default (public) schema so a FRESH `acquire(url)` connection — which lands
    // on the role's default search_path (public) — sees the same `_collections`. This exercises the
    // adapter's postgres:// dispatch end-to-end (open a PG handle through the tagged-union Db).
    var setup = db.Db.openPostgres(a, io, url) catch return error.SkipZigTest;
    defer setup.close();
    setup.exec("SET search_path TO public;") catch return error.SkipZigTest;
    // Clean any leftover demo table from a prior crashed run, then provision fresh.
    setup.exec("DROP TABLE IF EXISTS \"posts\" CASCADE;") catch {};
    setup.exec("DROP TABLE IF EXISTS \"users\" CASCADE;") catch {};
    setup.exec("DELETE FROM \"_collections\" WHERE name IN ('posts','users');") catch {};
    try migrations.run(&setup);
    // Register cleanup BEFORE provisioning so a mid-provision failure still leaves public clean.
    defer {
        setup.exec("DROP TABLE IF EXISTS \"posts\" CASCADE;") catch {};
        setup.exec("DROP TABLE IF EXISTS \"users\" CASCADE;") catch {};
        setup.exec("DELETE FROM \"_collections\" WHERE name IN ('posts','users');") catch {};
    }
    const specs = demoSpecs();
    try provision.applySpecs(al, io, &setup, &specs);

    // The adapter routes the postgres:// target to the PG arm (NOT `<target>/data.db`), opens a
    // fresh connection, and reads the user collections back — name-sorted, system rows excluded.
    const acq = try acquire_datadir.acquire(al, io, url);
    defer acq.deinit();
    const cols = acq.collections;
    try std.testing.expectEqual(@as(usize, 2), cols.len);
    try std.testing.expectEqualStrings("posts", cols[0].name);
    try std.testing.expectEqualStrings("users", cols[1].name);
}
