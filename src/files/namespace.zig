//! Engine-owned physical prefixes. Reservations outlive collection deletion so
//! orphan objects can never be adopted by a new collection with a reused name.
const std = @import("std");
const db = @import("../db.zig");

pub const Error = db.DbError || std.mem.Allocator.Error || error{StorageNamespaceConflict};
pub const table_sql = "CREATE TABLE \"_storage_namespaces\" (\"collection_id\" TEXT PRIMARY KEY, \"namespace\" TEXT NOT NULL UNIQUE);";
const reservation_sql = "SELECT 1 FROM \"_storage_namespaces\" WHERE \"collection_id\"=?1 OR lower(\"namespace\")=lower(?2) LIMIT 1;";

pub fn migrate(m: *@import("../migrator.zig").Migrator) db.DbError!void {
    // Preserve exact legacy prefixes, but do not seed ambiguous ownership on
    // filesystems that fold case. Operators must resolve these rows explicitly.
    var aliases = try m.db.prepare("SELECT 1 FROM \"_collections\" GROUP BY lower(\"name\") HAVING count(*)>1 LIMIT 1;");
    defer aliases.finalize();
    if (try aliases.step()) {
        std.log.warn("storage namespace upgrade refused: collection names differ only by case; resolve ambiguous legacy ownership before retrying", .{});
        return error.ExecFailed;
    }
    try m.exec(table_sql);
    // Tombstones accumulate: index both reservation probes, while retaining the
    // exact namespace index used by object routing and legacy prefix lookup.
    try m.exec("CREATE UNIQUE INDEX \"_storage_namespaces_folded\" ON \"_storage_namespaces\" (lower(\"namespace\"));");
    try m.exec("INSERT INTO \"_storage_namespaces\" (\"collection_id\",\"namespace\") SELECT \"id\",\"name\" FROM \"_collections\";");
}

fn prepare(alloc: std.mem.Allocator, w: *db.Db, sql: []const u8) (db.DbError || std.mem.Allocator.Error)!db.Stmt {
    const lowered = try db.dbDialect(w).renumberPlaceholders(alloc, sql);
    defer alloc.free(lowered);
    return w.prepare(lowered);
}

/// Self-freeing. Caller owns the schema lock/transaction. Never accepts an
/// override prefix from collection input: only its engine-assigned ID and name.
pub fn reserve(alloc: std.mem.Allocator, w: *db.Db, id: []const u8, name: []const u8) Error!void {
    // Names are ASCII identifiers. Conservatively reject case aliases on every
    // backend: a local filesystem may fold case even when the DB/S3 does not.
    // Keep persisted prefixes and inventory lookups exact, including legacy rows.
    var lookup = try prepare(alloc, w, reservation_sql);
    defer lookup.finalize();
    try lookup.bindText(1, id);
    try lookup.bindText(2, name);
    if (try lookup.step()) return error.StorageNamespaceConflict;
    var insert = try prepare(alloc, w, "INSERT INTO \"_storage_namespaces\" (\"collection_id\",\"namespace\") VALUES (?1,?2);");
    defer insert.finalize();
    try insert.bindText(1, id);
    try insert.bindText(2, name);
    _ = try insert.step();
}

/// Owned result; lookup is exact physical namespace, never an ID/name alias.
pub fn collectionId(alloc: std.mem.Allocator, w: *db.Db, namespace: []const u8) Error!?[]u8 {
    var st = try prepare(alloc, w, "SELECT \"collection_id\" FROM \"_storage_namespaces\" WHERE \"namespace\"=?1;");
    defer st.finalize();
    try st.bindText(1, namespace);
    if (!try st.step()) return null;
    return try alloc.dupe(u8, st.columnText(0));
}

test "namespace is engine-owned and tombstones prevent prefix reuse" {
    const collections = @import("../collections.zig");
    const schema = @import("../schema.zig");
    var w = try db.Db.openMemory();
    defer w.close();
    try @import("../migrations.zig").run(&w);
    const a = std.testing.allocator;
    const old = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "photos", .fields = &.{}, .storage_namespace = "victim" });
    defer old.deinit(a);
    try std.testing.expectEqualStrings("photos", old.storage_namespace);
    var def = old;
    def.storage_namespace = "victim";
    const updated = try collections.update(a, std.testing.io, &w, old.id, def);
    defer updated.deinit(a);
    try std.testing.expectEqualStrings("photos", updated.storage_namespace);
    const json = try schema.collectionToJson(a, updated);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "storage_namespace") == null);
    const input = try schema.parseCollectionInput(a, "{\"name\":\"fresh\",\"fields\":[],\"options\":{},\"storage_namespace\":\"photos\"}");
    defer input.deinit(a);
    try std.testing.expectEqualStrings("", input.storage_namespace);
    const imported = try collections.create(a, std.testing.io, &w, input);
    defer imported.deinit(a);
    try std.testing.expectEqualStrings("fresh", imported.storage_namespace);
    try @import("../collection_rename.zig").rename(a, std.testing.io, &w, "photos", "pictures");
    const renamed = (try collections.get(a, &w, "pictures")).?;
    defer renamed.deinit(a);
    try std.testing.expectEqualStrings("photos", renamed.storage_namespace);
    try std.testing.expectError(error.StorageNamespaceConflict, collections.create(a, std.testing.io, &w, .{ .id = "", .name = "photos", .fields = &.{} }));
    try std.testing.expectError(error.StorageNamespaceConflict, collections.create(a, std.testing.io, &w, .{ .id = "", .name = "PHOTOS", .fields = &.{} }));
    try collections.delete(a, &w, "pictures");
    try std.testing.expectError(error.StorageNamespaceConflict, collections.create(a, std.testing.io, &w, .{ .id = "", .name = "photos", .fields = &.{} }));
    const before = try @import("../schema_gen.zig").read(&w);
    try std.testing.expectError(error.StorageNamespaceConflict, collections.create(a, std.testing.io, &w, .{ .id = "", .name = "PHOTOS", .fields = &.{} }));
    try std.testing.expectEqual(before, try @import("../schema_gen.zig").read(&w));
    try std.testing.expect((try collections.getByName(a, &w, "PHOTOS")) == null);
    try std.testing.expect((try collectionId(a, &w, "PHOTOS")) == null);
    const owner = (try collectionId(a, &w, "photos")).?;
    defer a.free(owner);
    try std.testing.expectEqualStrings(old.id, owner);
    try std.testing.expect((try collectionId(a, &w, old.id)) == null);
    try std.testing.expect((try collectionId(a, &w, "pictures")) == null);
}

test "namespace migration preserves legacy prefixes and rolls back reservations" {
    const collections = @import("../collections.zig");
    var w = try db.Db.openMemory();
    defer w.close();
    try @import("../migrations.zig").run(&w);
    const a = std.testing.allocator;
    const old = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "photos", .fields = &.{} });
    defer old.deinit(a);
    try w.exec("DROP TABLE _storage_namespaces;");
    try w.exec("DELETE FROM _migrations WHERE name='0028_storage_namespaces';");
    try @import("../migrations.zig").run(&w);
    const migrated = (try collections.get(a, &w, "photos")).?;
    defer migrated.deinit(a);
    try std.testing.expectEqualStrings("photos", migrated.storage_namespace);
    try w.begin();
    const temporary = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "temporary", .fields = &.{} });
    defer temporary.deinit(a);
    try w.rollback();
    try std.testing.expect((try collectionId(a, &w, "temporary")) == null);
}

fn migrationAliasRegression(w: *db.Db) !void {
    const a = std.testing.allocator;
    const collections = @import("../collections.zig");
    const migrations = @import("../migrations.zig");
    try migrations.run(w);
    const first = try collections.create(a, std.testing.io, w, .{ .id = "", .name = "Photos", .fields = &.{} });
    defer first.deinit(a);
    const second = try collections.create(a, std.testing.io, w, .{ .id = "", .name = "Other", .fields = &.{} });
    defer second.deinit(a);
    // Reconstruct a pre-upgrade registry whose names are distinct in the DB
    // but ambiguous on a case-insensitive local storage backend.
    try w.exec("DROP TABLE _storage_namespaces; DELETE FROM _migrations WHERE name='0028_storage_namespaces'; UPDATE _collections SET name='photos' WHERE name='Other';");
    try std.testing.expectError(error.ExecFailed, migrations.run(w));
    {
        var pending = try w.prepare("SELECT count(*) FROM _migrations WHERE name='0028_storage_namespaces';");
        defer pending.finalize();
        try std.testing.expect(try pending.step());
        try std.testing.expectEqual(@as(i64, 0), pending.columnInt(0));
    }
    // Operator repair is explicit; migration never lowercases stored prefixes.
    try w.exec("UPDATE _collections SET name='Other' WHERE name='photos';");
    try migrations.run(w);
    const owner = (try collectionId(a, w, "Photos")).?;
    defer a.free(owner);
    try std.testing.expectEqualStrings(first.id, owner);
    try std.testing.expect((try collectionId(a, w, "photos")) == null);
}

test "SQLite namespace seeding rejects ambiguous legacy case aliases" {
    var w = try db.Db.openMemory();
    defer w.close();
    try migrationAliasRegression(&w);
    try reservationPlanRegression(&w);
}

fn reservationPlanRegression(w: *db.Db) !void {
    const a = std.testing.allocator;
    // Model a growing tombstone ledger without creating thousands of schemas.
    try w.exec("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<4096) INSERT INTO _storage_namespaces(collection_id,namespace) SELECT 'retired_id_' || CAST(i AS TEXT),'retired_prefix_' || CAST(i AS TEXT) FROM n;");
    try w.exec("ANALYZE _storage_namespaces;");
    const pg = db.dbDialect(w).kind == .postgres;
    if (pg) {
        var definition = try w.prepare("SELECT indexdef FROM pg_indexes WHERE schemaname=current_schema() AND indexname='_storage_namespaces_folded';");
        defer definition.finalize();
        try std.testing.expect(try definition.step());
        try std.testing.expect(std.mem.indexOf(u8, definition.columnText(0), "UNIQUE INDEX") != null);
        try std.testing.expect(std.mem.indexOf(u8, definition.columnText(0), "lower(namespace)") != null);
    }
    const sql = try std.fmt.allocPrint(a, "{s}{s}", .{ if (pg) "EXPLAIN " else "EXPLAIN QUERY PLAN ", reservation_sql });
    defer a.free(sql);
    var plan = try prepare(a, w, sql);
    defer plan.finalize();
    try plan.bindText(1, "missing_id");
    try plan.bindText(2, "missing_prefix");
    var folded = false;
    var identity = false;
    while (try plan.step()) {
        const detail = plan.columnText(if (pg) 0 else 3);
        try std.testing.expect(std.mem.indexOf(u8, detail, if (pg) "Seq Scan" else "SCAN ") == null);
        folded = folded or std.mem.indexOf(u8, detail, "_storage_namespaces_folded") != null;
        identity = identity or std.mem.indexOf(u8, detail, if (pg) "_storage_namespaces_pkey" else "sqlite_autoindex__storage_namespaces_1") != null;
    }
    try std.testing.expect(folded);
    try std.testing.expect(identity);
    try std.testing.expectError(error.StorageNamespaceConflict, reserve(a, w, "unused_id", "RETIRED_PREFIX_4096"));
    try std.testing.expectError(error.StorageNamespaceConflict, reserve(a, w, "retired_id_4096", "unused_prefix"));
}

test "pg namespace seeding rejects aliases and reservations share the schema lock" {
    if (comptime !@import("build_options").postgres) return error.SkipZigTest;
    const url = std.testing.environ.getPosix("ZIGBASE_PG_TEST_URL") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    var w = try db.Db.openPostgres(a, std.testing.io, url);
    defer w.close();
    try w.exec("CREATE SCHEMA zb_namespace_aliases;");
    defer w.exec("DROP SCHEMA zb_namespace_aliases CASCADE;") catch |err| std.debug.panic("namespace test schema cleanup failed: {s}", .{@errorName(err)});
    try w.exec("SET search_path TO zb_namespace_aliases;");
    try migrationAliasRegression(&w);
    try reservationPlanRegression(&w);
    var other = try db.Db.openPostgres(a, std.testing.io, url);
    defer other.close();
    try other.exec("SET search_path TO zb_namespace_aliases; SET lock_timeout='200ms';");
    try w.begin();
    var transaction_open = true;
    errdefer if (transaction_open) w.rollback() catch |err| std.debug.panic("namespace test rollback failed: {s}", .{@errorName(err)});
    const collections = @import("../collections.zig");
    const created = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "fresh", .fields = &.{} });
    defer created.deinit(a);
    // The second process cannot get past Tx.begin/schema_gen.lock to perform
    // its lower(namespace) pre-check while the first reservation is uncommitted.
    try std.testing.expectError(error.ExecFailed, collections.create(a, std.testing.io, &other, .{ .id = "", .name = "FRESH", .fields = &.{} }));
    try w.commit();
    transaction_open = false;
    try std.testing.expectError(error.StorageNamespaceConflict, collections.create(a, std.testing.io, &other, .{ .id = "", .name = "FRESH", .fields = &.{} }));
    try std.testing.expect((try collections.getByName(a, &other, "FRESH")) == null);
}
