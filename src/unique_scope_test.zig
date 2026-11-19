//! Field-level `.unique` on tenant-owned base collections (#498): enforced per owning account
//! by a composite `UNIQUE (<tenant_field>, <field>)`. Auth collections remain table-wide. Every scenario runs
//! on SQLite and, under `-Dpostgres=true` with `ZIGBASE_PG_TEST_URL` set, on PostgreSQL (each PG
//! test in a private, dropped-on-teardown schema). Covers fresh creation, the explicit global
//! `.indexes` escape hatch, the startup upgrade of a pre-#498 table (comptime `.collections` path
//! and the all-collections sweep for runtime-created ones), and the collections-API update path.

const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const migrations = @import("migrations.zig");
const collections = @import("collections.zig");
const provision = @import("provision.zig");
const schema_gen = @import("schema_gen.zig");

const Backend = enum { sqlite, postgres };

const Conn = struct {
    db: db.Db,
    drop_sql: ?[:0]const u8 = null,

    fn open(comptime backend: Backend, comptime tag: []const u8) !Conn {
        switch (backend) {
            .sqlite => {
                var conn = try db.Db.openMemory();
                errdefer conn.close();
                try migrations.run(&conn);
                return .{ .db = conn };
            },
            .postgres => {
                if (comptime !@import("build_options").postgres) return error.SkipZigTest;
                const url = std.testing.environ.getPosix("ZIGBASE_PG_TEST_URL") orelse return error.SkipZigTest;
                var conn = try db.Db.openPostgres(std.testing.allocator, std.testing.io, url);
                errdefer conn.close();
                const sn = "zb_uniq_" ++ tag;
                try conn.exec("DROP SCHEMA IF EXISTS " ++ sn ++ " CASCADE;");
                try conn.exec("CREATE SCHEMA " ++ sn ++ ";");
                try conn.exec("SET search_path TO " ++ sn ++ ";");
                try migrations.run(&conn);
                return .{ .db = conn, .drop_sql = "DROP SCHEMA IF EXISTS " ++ sn ++ " CASCADE;" };
            },
        }
    }

    fn deinit(self: *Conn) void {
        if (self.drop_sql) |sql| self.db.exec(sql) catch {};
        self.db.close();
    }
};

const fields_plain = [_]schema.Field{
    .{ .id = "acct_fid", .name = "account", .options = .{ .text = .{} } },
    .{ .id = "slug_fid", .name = "slug", .unique = true, .options = .{ .text = .{} } },
};

fn slugs(tenant_field: ?[]const u8, indexes: []const schema.Index) schema.Collection {
    return .{ .id = "", .name = "slugs", .fields = &fields_plain, .indexes = indexes, .options = .{ .tenant_field = tenant_field } };
}

fn insert(w: *db.Db, id: []const u8, account: []const u8, slug: []const u8) bool {
    var buf: [256]u8 = undefined;
    const sql = std.mem.printSentinel(&buf, "INSERT INTO slugs (id, created, updated, account, slug) VALUES ('{s}', '', '', '{s}', '{s}');", .{ id, account, slug }, 0) catch unreachable;
    w.exec(sql) catch return false;
    return true;
}

fn expectConstraint(w: *db.Db, sql: [:0]const u8) !void {
    var st = try w.prepare(sql);
    defer st.finalize();
    try std.testing.expectError(error.Constraint, st.step());
}

fn count(w: *db.Db, sql: [:0]const u8) !i64 {
    var st = try w.prepare(sql);
    defer st.finalize();
    try std.testing.expect(try st.step());
    return st.columnInt(0);
}

/// B holds `acme-corp`; A may take it too; A's second `acme-corp` is refused.
fn expectTenantScoped(w: *db.Db, tag: []const u8) !void {
    var a_id: [32]u8 = undefined;
    var b_id: [32]u8 = undefined;
    var a2_id: [32]u8 = undefined;
    try std.testing.expect(insert(w, try std.mem.print(&b_id, "b-{s}", .{tag}), "acct-b", "acme-corp"));
    try std.testing.expect(insert(w, try std.mem.print(&a_id, "a-{s}", .{tag}), "acct-a", "acme-corp"));
    try std.testing.expect(!insert(w, try std.mem.print(&a2_id, "a2-{s}", .{tag}), "acct-a", "acme-corp"));
}

/// Unique constraints/autoindexes over exactly `slug` (table-wide) and `account, slug` (scoped).
fn constraintCounts(w: *db.Db) !struct { global: i64, scoped: i64 } {
    if (db.dbDialect(w).kind == .postgres) {
        const base = "SELECT count(*) FROM pg_constraint c WHERE c.conrelid = to_regclass('slugs') AND c.contype = 'u' AND array_to_string(ARRAY(SELECT a.attname FROM unnest(c.conkey) WITH ORDINALITY k(n, o) JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.n ORDER BY k.o), ',') = ";
        return .{ .global = try count(w, base ++ "'slug';"), .scoped = try count(w, base ++ "'account,slug';") };
    }
    const base = "SELECT count(*) FROM pragma_index_list('slugs') il WHERE il.origin = 'u' AND (SELECT group_concat(name, ',') FROM (SELECT name FROM pragma_index_info(il.name) ORDER BY seqno)) = ";
    return .{ .global = try count(w, base ++ "'slug';"), .scoped = try count(w, base ++ "'account,slug';") };
}

/// Replace the provisioned table with the shape every release before #498 created for a
/// tenant-owned collection: an inline, table-wide `UNIQUE` on the unique field.
fn makeLegacyTable(w: *db.Db) !void {
    try w.exec("DROP TABLE slugs;");
    if (db.dbDialect(w).kind == .postgres) {
        try w.exec("CREATE TABLE slugs (\"id\" TEXT COLLATE \"C\" PRIMARY KEY, \"created\" TEXT COLLATE \"C\", \"updated\" TEXT COLLATE \"C\", \"account\" TEXT COLLATE \"C\", \"slug\" TEXT COLLATE \"C\" UNIQUE);");
    } else {
        try w.exec("CREATE TABLE slugs (\"id\" TEXT PRIMARY KEY, \"created\" TEXT, \"updated\" TEXT, \"account\" TEXT, \"slug\" TEXT UNIQUE);");
    }
    // A migration-owned index the SQLite convergence rebuild must carry across.
    try w.exec("CREATE INDEX migration_owned_slug ON slugs (slug);");
    try std.testing.expect(insert(w, "legacy-b", "acct-b", "acme-corp"));
    try std.testing.expect(!insert(w, "legacy-a", "acct-a", "acme-corp")); // the #498 oracle
}

fn indexExists(w: *db.Db, name: [:0]const u8) !bool {
    var st = try w.prepare(if (db.dbDialect(w).kind == .postgres)
        "SELECT 1 FROM pg_indexes WHERE schemaname = current_schema() AND indexname = $1;"
    else
        "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?1;");
    defer st.finalize();
    try st.bindText(1, name);
    return st.step();
}

fn freshScoped(comptime backend: Backend) !void {
    const a = std.testing.allocator;
    var c = try Conn.open(backend, "fresh");
    defer c.deinit();
    const w = &c.db;
    const col = try collections.create(a, std.testing.io, w, slugs("account", &.{}));
    defer col.deinit(a);
    const counts = try constraintCounts(w);
    try std.testing.expectEqual(@as(i64, 0), counts.global);
    try std.testing.expectEqual(@as(i64, 1), counts.scoped);
    try expectTenantScoped(w, "1");
}

test "fresh tenant-owned collection scopes a unique field to the tenant (sqlite)" {
    try freshScoped(.sqlite);
}
test "fresh tenant-owned collection scopes a unique field to the tenant (postgres)" {
    try freshScoped(.postgres);
}

fn explicitGlobalIndex(comptime backend: Backend) !void {
    const a = std.testing.allocator;
    var c = try Conn.open(backend, "global_index");
    defer c.deinit();
    const w = &c.db;
    const idx = [_]schema.Index{.{ .name = "idx_slugs_slug_global", .fields = &.{"slug"}, .unique = true }};
    const col = try collections.create(a, std.testing.io, w, slugs("account", &idx));
    defer col.deinit(a);
    try std.testing.expect(insert(w, "b1", "acct-b", "acme-corp"));
    // The declared index still answers across tenants: global uniqueness is opt-in, not gone.
    try std.testing.expect(!insert(w, "a1", "acct-a", "acme-corp"));
}

test "an explicit unique index keeps global uniqueness on a tenant-owned collection (sqlite)" {
    try explicitGlobalIndex(.sqlite);
}
test "an explicit unique index keeps global uniqueness on a tenant-owned collection (postgres)" {
    try explicitGlobalIndex(.postgres);
}

fn upgradeComptime(comptime backend: Backend) !void {
    const a = std.testing.allocator;
    var c = try Conn.open(backend, "upgrade_comptime");
    defer c.deinit();
    const w = &c.db;
    const spec = [_]schema.Collection{slugs("account", &.{})};
    try provision.applySpecs(a, std.testing.io, w, &spec);
    try makeLegacyTable(w);

    // The next boot converges the table and keeps every row and the migration's index.
    try provision.applySpecs(a, std.testing.io, w, &spec);
    const counts = try constraintCounts(w);
    try std.testing.expectEqual(@as(i64, 0), counts.global);
    try std.testing.expectEqual(@as(i64, 1), counts.scoped);
    try std.testing.expectEqual(@as(i64, 1), try count(w, "SELECT count(*) FROM slugs WHERE id = 'legacy-b' AND slug = 'acme-corp';"));
    try std.testing.expect(try indexExists(w, "migration_owned_slug"));
    try std.testing.expect(insert(w, "a1", "acct-a", "acme-corp"));
    try std.testing.expect(!insert(w, "a2", "acct-a", "acme-corp"));

    // A converged table is left alone on later boots: no rebuild, no schema generation bump.
    const generation = try schema_gen.read(w);
    try provision.applySpecs(a, std.testing.io, w, &spec);
    try std.testing.expectEqual(generation, try schema_gen.read(w));
}

test "startup converges a pre-#498 comptime collection's table-wide unique (sqlite)" {
    try upgradeComptime(.sqlite);
}
test "startup converges a pre-#498 comptime collection's table-wide unique (postgres)" {
    try upgradeComptime(.postgres);
}

fn upgradeRuntime(comptime backend: Backend) !void {
    const a = std.testing.allocator;
    var c = try Conn.open(backend, "upgrade_runtime");
    defer c.deinit();
    const w = &c.db;
    const col = try collections.create(a, std.testing.io, w, slugs("account", &.{}));
    defer col.deinit(a);
    try makeLegacyTable(w);
    try collections.ensureAllUniqueScopes(a, std.testing.io, w);
    const counts = try constraintCounts(w);
    try std.testing.expectEqual(@as(i64, 0), counts.global);
    try std.testing.expectEqual(@as(i64, 1), counts.scoped);
    try std.testing.expect(try indexExists(w, "migration_owned_slug"));
    try std.testing.expect(insert(w, "a1", "acct-a", "acme-corp"));
    try std.testing.expect(!insert(w, "a2", "acct-a", "acme-corp"));
}

test "the startup sweep converges a runtime-created pre-#498 collection (sqlite)" {
    try upgradeRuntime(.sqlite);
}
test "the startup sweep converges a runtime-created pre-#498 collection (postgres)" {
    try upgradeRuntime(.postgres);
}

fn apiUpdates(comptime backend: Backend) !void {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var c = try Conn.open(backend, "api_updates");
    defer c.deinit();
    const w = &c.db;

    // Not unique, not tenant-owned.
    var plain = fields_plain;
    plain[1].unique = false;
    const created = try collections.create(a, io, w, .{ .id = "", .name = "slugs", .fields = &plain });
    defer created.deinit(a);
    try std.testing.expect(insert(w, "b1", "acct-b", "acme-corp"));

    // Made unique AND tenant-owned later: scoped, and the existing row does not block A.
    const scoped = try collections.update(a, io, w, "slugs", slugs("account", &.{}));
    defer scoped.deinit(a);
    var counts = try constraintCounts(w);
    try std.testing.expectEqual(@as(i64, 0), counts.global);
    try std.testing.expectEqual(@as(i64, 1), counts.scoped);
    try std.testing.expect(insert(w, "a1", "acct-a", "acme-corp"));
    try std.testing.expect(!insert(w, "a2", "acct-a", "acme-corp"));

    // No longer tenant-owned: uniqueness is table-wide again.
    try w.exec("DELETE FROM slugs WHERE id = 'a1';");
    const global = try collections.update(a, io, w, "slugs", slugs(null, &.{}));
    defer global.deinit(a);
    counts = try constraintCounts(w);
    try std.testing.expectEqual(@as(i64, 1), counts.global);
    try std.testing.expectEqual(@as(i64, 0), counts.scoped);
    try std.testing.expect(!insert(w, "a3", "acct-a", "acme-corp"));

    // Unique dropped altogether: no engine constraint remains.
    const loose = try collections.update(a, io, w, "slugs", .{ .id = "", .name = "slugs", .fields = &plain });
    defer loose.deinit(a);
    counts = try constraintCounts(w);
    try std.testing.expectEqual(@as(i64, 0), counts.global);
    try std.testing.expectEqual(@as(i64, 0), counts.scoped);
    try std.testing.expect(insert(w, "a4", "acct-a", "acme-corp"));
}

test "collection updates move unique enforcement between table-wide and tenant-scoped (sqlite)" {
    try apiUpdates(.sqlite);
}
test "collection updates move unique enforcement between table-wide and tenant-scoped (postgres)" {
    try apiUpdates(.postgres);
}

fn comptimeTenantLater(comptime backend: Backend) !void {
    const a = std.testing.allocator;
    var c = try Conn.open(backend, "comptime_later");
    defer c.deinit();
    const w = &c.db;
    try provision.applySpecs(a, std.testing.io, w, &.{slugs(null, &.{})});
    try std.testing.expect(insert(w, "b1", "acct-b", "acme-corp"));
    try std.testing.expect(!insert(w, "a0", "acct-a", "acme-corp"));
    // `.tenant_field` added to the declaration of an existing collection is persisted and
    // re-scopes its unique fields.
    try provision.applySpecs(a, std.testing.io, w, &.{slugs("account", &.{})});
    const live = (try collections.get(a, w, "slugs")).?;
    defer live.deinit(a);
    try std.testing.expectEqualStrings("account", live.options.tenant_field.?);
    try std.testing.expect(insert(w, "a1", "acct-a", "acme-corp"));
    try std.testing.expect(!insert(w, "a2", "acct-a", "acme-corp"));
}

test "a comptime collection made tenant-owned later is persisted and re-scoped (sqlite)" {
    try comptimeTenantLater(.sqlite);
}
test "a comptime collection made tenant-owned later is persisted and re-scoped (postgres)" {
    try comptimeTenantLater(.postgres);
}

test "SQLite startup refuses migration-added populated columns on both rebuild paths" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |change_tenant| {
        var c = try Conn.open(.sqlite, "physical_column");
        defer c.deinit();
        const initial = slugs(if (change_tenant) null else "account", &.{});
        try provision.applySpecs(a, std.testing.io, &c.db, &.{initial});
        try makeLegacyTable(&c.db);
        try c.db.exec("ALTER TABLE slugs ADD COLUMN internal_note TEXT;");
        try c.db.exec("UPDATE slugs SET internal_note='migration data';");
        const generation = try schema_gen.read(&c.db);
        if (change_tenant) {
            try std.testing.expectError(error.UnsafeSqliteRebuild, provision.applySpecs(a, std.testing.io, &c.db, &.{slugs("account", &.{})}));
        } else {
            try std.testing.expectError(error.UnsafeSqliteRebuild, collections.ensureAllUniqueScopes(a, std.testing.io, &c.db));
        }
        try std.testing.expectEqual(generation, try schema_gen.read(&c.db));
        try std.testing.expectEqual(@as(i64, 1), try count(&c.db, "SELECT count(*) FROM slugs WHERE internal_note='migration data';"));
        try std.testing.expect(try indexExists(&c.db, "migration_owned_slug"));
    }
}

test "SQLite tenant-field change preserves migration indexes and triggers" {
    const a = std.testing.allocator;
    var c = try Conn.open(.sqlite, "objects");
    defer c.deinit();
    try provision.applySpecs(a, std.testing.io, &c.db, &.{slugs(null, &.{})});
    try makeLegacyTable(&c.db);
    try c.db.exec("CREATE TABLE migration_audit (value TEXT);");
    try c.db.exec("CREATE TRIGGER migration_trigger AFTER INSERT ON slugs BEGIN INSERT INTO migration_audit VALUES (NEW.slug); END;");
    try provision.applySpecs(a, std.testing.io, &c.db, &.{slugs("account", &.{})});
    try std.testing.expect(try indexExists(&c.db, "migration_owned_slug"));
    try std.testing.expect(insert(&c.db, "a", "acct-a", "acme-corp"));
    try std.testing.expectEqual(@as(i64, 1), try count(&c.db, "SELECT count(*) FROM migration_audit;"));
}

test "SQLite startup refuses migration table constraints" {
    const a = std.testing.allocator;
    var c = try Conn.open(.sqlite, "check");
    defer c.deinit();
    const col = try collections.create(a, std.testing.io, &c.db, slugs("account", &.{}));
    defer col.deinit(a);
    try c.db.exec("DROP TABLE slugs;");
    try c.db.exec("CREATE TABLE slugs (id TEXT PRIMARY KEY, created TEXT, updated TEXT, account TEXT, slug TEXT UNIQUE CHECK/* migration */(length(slug)>0));");
    try std.testing.expectError(error.UnsafeSqliteRebuild, collections.ensureAllUniqueScopes(a, std.testing.io, &c.db));
    try std.testing.expect(!insert(&c.db, "empty", "acct-a", ""));
}

fn tenantAuthGlobal(comptime backend: Backend) !void {
    const a = std.testing.allocator;
    var c = try Conn.open(backend, "identity");
    defer c.deinit();
    var spec = slugs(null, &.{});
    spec.type = .auth;
    spec.options.auth.identityFields = &.{"slug"};
    const col = try collections.create(a, std.testing.io, &c.db, spec);
    defer col.deinit(a);
    spec.options.tenant_field = "account";
    const updated = try collections.update(a, std.testing.io, &c.db, col.id, spec);
    defer updated.deinit(a);
    try collections.ensureAllUniqueScopes(a, std.testing.io, &c.db);
    try std.testing.expect(insert(&c.db, "a", "acct-a", "shared"));
    try std.testing.expect(!insert(&c.db, "b", "acct-b", "shared"));
    const counts = try constraintCounts(&c.db);
    try std.testing.expectEqual(@as(i64, 1), counts.global);
    try std.testing.expectEqual(@as(i64, 0), counts.scoped);
}

test "tenant auth identity fields are supported and stay global on update and boot (sqlite)" {
    try tenantAuthGlobal(.sqlite);
}
test "tenant auth identity fields are supported and stay global on update and boot (postgres)" {
    try tenantAuthGlobal(.postgres);
}

test "SQLite rebuild regenerates engine FTS triggers after a searchable field rename" {
    if (!@import("search/fts.zig").enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    var c = try Conn.open(.sqlite, "fts_objects");
    defer c.deinit();
    var old_fields = fields_plain;
    old_fields[1].searchable = true;
    var spec = slugs("account", &.{});
    spec.fields = &old_fields;
    try provision.applySpecs(a, std.testing.io, &c.db, &.{spec});
    try std.testing.expect(insert(&c.db, "kept", "acct-a", "acme-corp"));
    // Migration objects must survive even when they mention FTS or use an FTS-style name.
    try c.db.exec("CREATE TABLE migration_search_audit (n INTEGER);");
    try c.db.exec("CREATE INDEX slugs_fts_custom ON slugs(account);");
    try c.db.exec("CREATE TRIGGER migration_search_probe AFTER INSERT ON slugs BEGIN INSERT INTO migration_search_audit VALUES ((SELECT count(*) FROM slugs_fts)); END;");
    try c.db.exec("CREATE TRIGGER migration_shadow_probe AFTER INSERT ON slugs BEGIN INSERT INTO migration_search_audit VALUES ((SELECT count(*) FROM slugs_fts_data)); END;");
    var new_fields = old_fields;
    new_fields[1].name = "label";
    spec.fields = &new_fields;
    const updated = try collections.update(a, std.testing.io, &c.db, "slugs", spec);
    defer updated.deinit(a);
    try std.testing.expectEqual(@as(i64, 1), try count(&c.db, "SELECT count(*) FROM slugs WHERE label='acme-corp';"));
    try std.testing.expectEqual(@as(i64, 1), try count(&c.db, "SELECT count(*) FROM slugs_fts WHERE slugs_fts MATCH 'acme';"));
    try c.db.exec("INSERT INTO slugs(id,account,label) VALUES('new','acct-a','freshterm');");
    try std.testing.expectEqual(@as(i64, 1), try count(&c.db, "SELECT count(*) FROM slugs_fts WHERE slugs_fts MATCH 'freshterm';"));
    try std.testing.expect(try indexExists(&c.db, "slugs_fts_custom"));
    try std.testing.expectEqual(@as(i64, 2), try count(&c.db, "SELECT count(*) FROM migration_search_audit;"));
    new_fields[1].searchable = false;
    try std.testing.expectError(error.MigrationObjectConflict, collections.update(a, std.testing.io, &c.db, "slugs", spec));
    // Explicitly migrating the dependent object permits the search state to be removed.
    try c.db.exec("DROP TRIGGER migration_search_probe;");
    try std.testing.expectError(error.MigrationObjectConflict, collections.update(a, std.testing.io, &c.db, "slugs", spec));
    try c.db.exec("DROP TRIGGER migration_shadow_probe;");
    const unsearchable = try collections.update(a, std.testing.io, &c.db, "slugs", spec);
    defer unsearchable.deinit(a);
    try std.testing.expectEqual(@as(i64, 0), try count(&c.db, "SELECT count(*) FROM sqlite_master WHERE name='slugs_fts' OR name LIKE 'slugs_fts_a%';"));
    try std.testing.expect(try indexExists(&c.db, "slugs_fts_custom"));
}

// The lock's UPDATE is the deterministic interleaving point: emulate the competing
// metadata writer immediately before lock acquisition returns to startup convergence.
test "startup convergence uses metadata reloaded after the lock (postgres)" {
    const a = std.testing.allocator;
    var c = try Conn.open(.postgres, "locked_reload");
    defer c.deinit();
    const w = &c.db;
    const col = try collections.create(a, std.testing.io, w, slugs("account", &.{}));
    defer col.deinit(a);
    try w.exec(
        \\CREATE FUNCTION remove_tenancy_on_lock() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
        \\ UPDATE _collections SET options='{}' WHERE name='slugs';
        \\ ALTER TABLE slugs DROP CONSTRAINT slugs_account_slug_key;
        \\ ALTER TABLE slugs ADD UNIQUE(slug);
        \\ RETURN NEW;
        \\END $$;
    );
    try w.exec("CREATE TRIGGER interleave_metadata BEFORE UPDATE ON _schema_state FOR EACH ROW EXECUTE FUNCTION remove_tenancy_on_lock();");
    try collections.ensureUniqueScopes(a, std.testing.io, w, col.id);
    const counts = try constraintCounts(w);
    try std.testing.expectEqual(@as(i64, 1), counts.global);
    try std.testing.expectEqual(@as(i64, 0), counts.scoped);
    const live = (try collections.get(a, w, col.id)).?;
    defer live.deinit(a);
    try std.testing.expect(live.options.tenant_field == null);
}

test "auth identity changes retain engine indexes and custom replacements (postgres)" {
    const a = std.testing.allocator;
    // Both a generated index and a same-name migration replacement are exercised.
    inline for (.{ false, true }) |custom| {
        var c = try Conn.open(.postgres, if (custom) "identity_custom" else "identity_removed");
        defer c.deinit();
        const w = &c.db;
        var def = slugs(null, &.{});
        def.type = .auth;
        def.options.auth.identityFields = &.{"slug"};
        const col = try collections.create(a, std.testing.io, w, def);
        defer col.deinit(a);
        if (custom) {
            try w.exec("DROP INDEX idx_auth_slugs_slug;");
            try w.exec("CREATE INDEX idx_auth_slugs_slug ON slugs(account);");
        }
        try w.exec("CREATE INDEX idx_auth_slugs_migration ON slugs(slug);");
        var loose_fields = fields_plain;
        loose_fields[1].unique = false;
        def.fields = &loose_fields;
        def.options.tenant_field = "account";
        def.options.auth.identityFields = &.{"email"};
        const changed = try collections.update(a, std.testing.io, w, col.id, def);
        defer changed.deinit(a);
        try std.testing.expect(try indexExists(w, "idx_auth_slugs_slug"));
        try std.testing.expect(try indexExists(w, "idx_auth_slugs_migration"));
        try std.testing.expect(insert(w, "a", "acct-a", "shared"));
        // main leaves the original global field constraint in place on PostgreSQL.
        try std.testing.expect(!insert(w, "b", "acct-b", "shared"));
        // Email identity uniqueness remains when tenancy is removed.
        try w.exec("DELETE FROM slugs;");
        def.options.tenant_field = null;
        def.options.auth.identityFields = &.{"email"};
        const unscoped = try collections.update(a, std.testing.io, w, col.id, def);
        defer unscoped.deinit(a);
        try std.testing.expect(try indexExists(w, "idx_auth_slugs_email"));
    }
}

const IdentityObject = struct {
    oid: i64,
    definition: []const u8,

    fn read(a: std.mem.Allocator, w: *db.Db) !IdentityObject {
        return readNamed(a, w, "idx_auth_slugs_slug");
    }

    fn readNamed(a: std.mem.Allocator, w: *db.Db, name: []const u8) !IdentityObject {
        var st = try w.prepare(if (db.dbDialect(w).kind == .postgres)
            "SELECT oid,CASE WHEN relkind='i' THEN pg_get_indexdef(oid) WHEN relkind='v' THEN pg_get_viewdef(oid) ELSE relkind::text END FROM pg_class WHERE relnamespace=current_schema()::regnamespace AND relname=$1;"
        else
            "SELECT rootpage,sql FROM main.sqlite_schema WHERE name=?1;");
        defer st.finalize();
        try st.bindText(1, @import("ddl.zig").physicalIdentifier(name, db.dbDialect(w).kind == .postgres));
        try std.testing.expect(try st.step());
        return .{ .oid = st.columnInt(0), .definition = try a.dupe(u8, st.columnText(1)) };
    }

    fn deinit(self: IdentityObject, a: std.mem.Allocator) void {
        a.free(self.definition);
    }

    fn expectUnchanged(self: IdentityObject, a: std.mem.Allocator, w: *db.Db) !void {
        const after = try read(a, w);
        defer after.deinit(a);
        try std.testing.expectEqual(self.oid, after.oid);
        try std.testing.expectEqualStrings(self.definition, after.definition);
    }
};

fn identityIndexDefinitions(comptime backend: Backend) !void {
    const a = std.testing.allocator;
    const identity = @import("auth_identity_index.zig");
    const cases = [_][:0]const u8{
        "CREATE UNIQUE INDEX idx_auth_slugs_slug ON slugs(slug) WHERE ((slug) <> (''));",
        "CREATE INDEX idx_auth_slugs_slug ON slugs(slug) WHERE slug != '';",
        "CREATE UNIQUE INDEX idx_auth_slugs_slug ON slugs(account) WHERE slug != '';",
        "CREATE UNIQUE INDEX idx_auth_slugs_slug ON slugs(slug,account) WHERE slug != '';",
        "CREATE UNIQUE INDEX idx_auth_slugs_slug ON slugs(slug) WHERE slug != 'excluded';",
        "CREATE UNIQUE INDEX idx_auth_slugs_slug ON slugs(slug);",
        "CREATE UNIQUE INDEX idx_auth_slugs_slug ON slugs(slug) WHERE slug != '' AND account != '';",
        "CREATE UNIQUE INDEX idx_auth_slugs_slug ON migration_identities(slug) WHERE slug != '';",
        "CREATE TABLE idx_auth_slugs_slug(note TEXT); INSERT INTO idx_auth_slugs_slug VALUES('keep');",
        "CREATE VIEW idx_auth_slugs_slug AS SELECT 'keep' AS note;",
        "CREATE UNIQUE INDEX idx_auth_slugs_slug ON slugs(lower(slug)) WHERE slug != '';",
        "CREATE UNIQUE INDEX idx_auth_slugs_slug ON slugs(slug DESC) WHERE slug != '';",
    };
    for (cases, 0..) |sql, i| {
        var c = try Conn.open(backend, "identity_definitions");
        defer c.deinit();
        const w = &c.db;
        var def = slugs(null, &.{});
        def.type = .auth;
        def.options.auth.identityFields = &.{"slug"};
        var identity_fields = fields_plain;
        identity_fields[1].unique = false;
        def.fields = &identity_fields;
        const col = try collections.create(a, std.testing.io, w, def);
        defer col.deinit(a);
        try w.exec("DROP INDEX idx_auth_slugs_slug; CREATE TABLE migration_identities(slug TEXT);");
        try w.exec(sql);
        const before = try IdentityObject.read(a, w);
        defer before.deinit(a);
        if (i == 0) {
            try collections.ensureAllUniqueScopes(a, std.testing.io, w);
            try before.expectUnchanged(a, w); // adoption does not replace the migration's index
            const updated = try collections.update(a, std.testing.io, w, col.id, def);
            defer updated.deinit(a);
            try std.testing.expect(try identity.verify(a, w, "slugs", "slug"));
            try w.exec("INSERT INTO slugs(id,slug) VALUES('first','same');");
            try std.testing.expectError(error.ExecFailed, w.exec("INSERT INTO slugs(id,slug) VALUES('duplicate','same');"));
            try w.exec("INSERT INTO slugs(id,slug) VALUES('empty1',''),('empty2','');");
            continue;
        }
        try std.testing.expectError(error.AuthIdentityIndexConflict, collections.ensureAllUniqueScopes(a, std.testing.io, w));
        try std.testing.expect(std.mem.indexOf(u8, identity.last_error, "Collection 'slugs', identity field 'slug'") != null);
        try std.testing.expect(std.mem.indexOf(u8, identity.last_error, "idx_auth_slugs_slug") != null);
        try before.expectUnchanged(a, w);
        try std.testing.expectError(error.AuthIdentityIndexConflict, collections.update(a, std.testing.io, w, col.id, def));
        try before.expectUnchanged(a, w);
        // Removing the identity preserves incompatible migration objects without
        // trusting them. Re-adding it must still refuse.
        def.options.auth.identityFields = &.{"email"};
        const removed = try collections.update(a, std.testing.io, w, col.id, def);
        defer removed.deinit(a);
        const after = try IdentityObject.read(a, w);
        defer after.deinit(a);
        try std.testing.expectEqualStrings(before.definition, after.definition);
        if (backend == .postgres) try std.testing.expectEqual(before.oid, after.oid);
        try std.testing.expect(try identity.verify(a, w, "slugs", "email"));
        def.options.auth.identityFields = &.{"slug"};
        try std.testing.expectError(error.AuthIdentityIndexConflict, collections.update(a, std.testing.io, w, col.id, def));
        try after.expectUnchanged(a, w);
        if (i == 8 or i == 9) try std.testing.expectEqual(@as(i64, 1), try count(w, "SELECT count(*) FROM idx_auth_slugs_slug WHERE note='keep';"));
    }
}

test "auth identity index definitions are verified before startup and update (sqlite)" {
    try identityIndexDefinitions(.sqlite);
}

test "auth identity index definitions are verified before startup and update (postgres)" {
    try identityIndexDefinitions(.postgres);
}

fn identityCreateCollisions(comptime backend: Backend) !void {
    const a = std.testing.allocator;
    inline for (.{
        "CREATE INDEX idx_auth_slugs_slug ON migration_identities(slug);",
        "CREATE UNIQUE INDEX idx_auth_slugs_slug ON migration_identities(slug) WHERE slug != '';",
        "CREATE TABLE idx_auth_slugs_slug(note TEXT); INSERT INTO idx_auth_slugs_slug VALUES('keep');",
        "CREATE VIEW idx_auth_slugs_slug AS SELECT 'keep' AS note;",
    }) |sql| {
        var c = try Conn.open(backend, "identity_create");
        defer c.deinit();
        const w = &c.db;
        try w.exec("CREATE TABLE migration_identities(slug TEXT);");
        try w.exec(sql);
        const before = try IdentityObject.read(a, w);
        defer before.deinit(a);
        var def = slugs(null, &.{});
        def.type = .auth;
        def.options.auth.identityFields = &.{"slug"};
        try std.testing.expectError(error.AuthIdentityIndexConflict, collections.create(a, std.testing.io, w, def));
        try before.expectUnchanged(a, w);
        try std.testing.expect((try collections.get(a, w, "slugs")) == null);
    }
}

test "auth identity index create refuses migration name collisions (sqlite)" {
    try identityCreateCollisions(.sqlite);
}

test "auth identity index create refuses migration name collisions (postgres)" {
    try identityCreateCollisions(.postgres);
}

fn declaredIdentityAdoption(comptime backend: Backend) !void {
    const a = std.testing.allocator;
    var c = try Conn.open(backend, "identity_declared");
    defer c.deinit();
    const w = &c.db;
    var def = slugs(null, &.{.{ .name = "idx_auth_slugs_slug", .fields = &.{"slug"}, .unique = true, .where = "slug <> ''" }});
    var identity_fields = fields_plain;
    identity_fields[1].unique = false;
    def.fields = &identity_fields;
    def.type = .auth;
    def.options.auth.identityFields = &.{"slug"};
    // The declared matching index exists before auth provisioning reaches it.
    const col = try collections.create(a, std.testing.io, w, def);
    defer col.deinit(a);
    const before = try IdentityObject.read(a, w);
    defer before.deinit(a);
    try collections.ensureAllUniqueScopes(a, std.testing.io, w);
    try before.expectUnchanged(a, w);
    def.indexes = &.{};
    try provision.applySpecs(a, std.testing.io, w, &.{def});
    try std.testing.expect(try @import("auth_identity_index.zig").verify(a, w, "slugs", "slug"));
    try w.exec("DROP INDEX idx_auth_slugs_slug;");
    try collections.ensureAllUniqueScopes(a, std.testing.io, w);
    try std.testing.expect(try @import("auth_identity_index.zig").verify(a, w, "slugs", "slug"));
    try w.exec("INSERT INTO slugs(id,slug) VALUES('first','same');");
    try std.testing.expectError(error.ExecFailed, w.exec("INSERT INTO slugs(id,slug) VALUES('duplicate','same');"));
    try w.exec("INSERT INTO slugs(id,slug) VALUES('empty1',''),('empty2','');");
}

test "matching declared auth identity index is adopted and missing indexes restored (sqlite)" {
    try declaredIdentityAdoption(.sqlite);
}

test "matching declared auth identity index is adopted and missing indexes restored (postgres)" {
    try declaredIdentityAdoption(.postgres);
}

fn provisioningIdentityReplacement(comptime backend: Backend) !void {
    const a = std.testing.allocator;
    for ([_][:0]const u8{
        "CREATE INDEX idx_auth_slugs_slug ON slugs(account);",
        "CREATE UNIQUE INDEX idx_auth_slugs_slug ON slugs(slug);",
        "CREATE UNIQUE INDEX idx_auth_slugs_slug ON slugs(slug) WHERE slug != 'excluded';",
    }) |replacement| {
        var c = try Conn.open(backend, "identity_provision_replacement");
        defer c.deinit();
        const w = &c.db;
        var def = slugs(null, &.{.{ .name = "idx_auth_slugs_slug", .fields = &.{"slug"}, .unique = true, .where = "slug <> ''" }});
        def.type = .auth;
        def.options.auth.identityFields = &.{"slug"};
        const col = try collections.create(a, std.testing.io, w, def);
        defer col.deinit(a);
        try w.exec("DROP INDEX idx_auth_slugs_slug;");
        try w.exec(replacement);
        const before = try IdentityObject.read(a, w);
        defer before.deinit(a);
        const generation = try schema_gen.read(w);
        // The next deployment removes the declaration, while auth still relies
        // on the same name. Reconciliation must not drop the migration's object.
        def.indexes = &.{};
        try std.testing.expectError(error.AuthIdentityIndexConflict, provision.applySpecs(a, std.testing.io, w, &.{def}));
        try before.expectUnchanged(a, w);
        try std.testing.expectEqual(generation, try schema_gen.read(w));
        const stored = (try collections.get(a, w, col.id)).?;
        defer stored.deinit(a);
        try std.testing.expectEqual(@as(usize, 1), stored.indexes.len);
        try std.testing.expectEqualStrings("idx_auth_slugs_slug", stored.indexes[0].name);
        // Removing both the identity and its declaration preserves the replacement.
        // applySpecs retains stored auth options; exercise the metadata API directly.
        var desired = stored;
        desired.options.auth.identityFields = &.{"email"};
        desired.indexes = &.{};
        try collections.provisionMetadata(a, w, stored, desired);
        try before.expectUnchanged(a, w);
        const removed = (try collections.get(a, w, col.id)).?;
        defer removed.deinit(a);
        try std.testing.expectEqual(@as(usize, 0), removed.indexes.len);
        try std.testing.expectEqualStrings("email", removed.options.auth.identityFields[0]);
        try std.testing.expect(try @import("auth_identity_index.zig").verify(a, w, "slugs", "email"));
        try collections.ensureAllUniqueScopes(a, std.testing.io, w);
        try before.expectUnchanged(a, w);
    }
}

test "provisioning preserves replacements and refuses only desired identities (sqlite)" {
    try provisioningIdentityReplacement(.sqlite);
}

test "provisioning preserves replacements and refuses only desired identities (postgres)" {
    try provisioningIdentityReplacement(.postgres);
}

test "provisioning preserves PostgreSQL identity replacements with truncated declared names" {
    const a = std.testing.allocator;
    const identity = @import("auth_identity_index.zig");
    inline for (.{
        .{ "identity_collection_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "slug" },
        .{ "slugs", "identity_field_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" },
    }) |names| {
        var c = try Conn.open(.postgres, "identity_long_name");
        defer c.deinit();
        const w = &c.db;
        const table = names[0];
        const field = names[1];
        const name = "idx_auth_" ++ table ++ "_" ++ field;
        try std.testing.expect(name.len > 63);
        var fields = fields_plain;
        fields[1].name = field;
        fields[1].unique = false;
        var def = slugs(null, &.{.{ .name = name, .fields = &.{field}, .unique = true, .where = field ++ " <> ''" }});
        def.name = table;
        def.fields = &fields;
        def.type = .auth;
        def.options.auth.identityFields = &.{field};
        const col = try collections.create(a, std.testing.io, w, def);
        defer col.deinit(a);
        try std.testing.expect(try identity.verify(a, w, table, field));
        try w.exec("DROP INDEX " ++ name ++ "; CREATE INDEX " ++ name ++ " ON " ++ table ++ "(account);");
        const before = try IdentityObject.readNamed(a, w, name);
        defer before.deinit(a);
        var desired = col;
        desired.indexes = &.{};
        try std.testing.expectError(error.AuthIdentityIndexConflict, collections.provisionMetadata(a, w, col, desired));
        desired.options.auth.identityFields = &.{"email"};
        try collections.provisionMetadata(a, w, col, desired);
        const after = try IdentityObject.readNamed(a, w, name);
        defer after.deinit(a);
        try std.testing.expectEqual(before.oid, after.oid);
        try std.testing.expectEqualStrings(before.definition, after.definition);
        const stored = (try collections.get(a, w, col.id)).?;
        defer stored.deinit(a);
        try std.testing.expectEqual(@as(usize, 0), stored.indexes.len);
        try std.testing.expectEqualStrings("email", stored.options.auth.identityFields[0]);
        try std.testing.expect(try identity.verify(a, w, table, "email"));
        // Both verification entry points must find the same truncated object.
        try std.testing.expect(!try identity.owns(a, w, table, field));
        desired.options.auth.identityFields = &.{field};
        try std.testing.expectError(error.AuthIdentityIndexConflict, collections.provisionMetadata(a, w, stored, desired));
        // Ordinary-index adoption also compares metadata against catalog names.
        const ordinary = "declared_index_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
        try w.exec("CREATE INDEX " ++ ordinary ++ " ON " ++ table ++ "(" ++ field ++ ");");
        const adopted_before = try IdentityObject.readNamed(a, w, ordinary);
        defer adopted_before.deinit(a);
        desired = stored;
        desired.indexes = &.{.{ .name = ordinary, .fields = &.{field} }};
        try collections.provisionMetadata(a, w, stored, desired);
        const adopted_after = try IdentityObject.readNamed(a, w, ordinary);
        defer adopted_after.deinit(a);
        try std.testing.expectEqual(adopted_before.oid, adopted_after.oid);
        try std.testing.expectEqualStrings(adopted_before.definition, adopted_after.definition);
    }
}

fn identityProbeCollectionName(comptime backend: Backend) !void {
    const a = std.testing.allocator;
    var c = try Conn.open(backend, "identity_probe_name");
    defer c.deinit();
    const w = &c.db;
    var def = slugs(null, &.{});
    var loose_fields = fields_plain;
    loose_fields[1].unique = false;
    def.fields = &loose_fields;
    def.name = "zb_identity_probe";
    def.type = .auth;
    def.options.auth.identityFields = &.{"slug"};
    const col = try collections.create(a, std.testing.io, w, def);
    defer col.deinit(a);
    try w.exec("INSERT INTO zb_identity_probe(id,account,slug) VALUES('before','acct-a','shared');");
    try w.exec("CREATE INDEX migration_identity_probe ON zb_identity_probe(account);");
    def.options.tenant_field = "account";
    def.options.auth.identityFields = &.{"email"};
    const changed = try collections.update(a, std.testing.io, w, col.id, def);
    defer changed.deinit(a);
    try std.testing.expectEqualStrings("zb_identity_probe", changed.name);
    try std.testing.expectEqual(@as(usize, 1), changed.options.auth.identityFields.len);
    try std.testing.expectEqualStrings("email", changed.options.auth.identityFields[0]);
    try std.testing.expectEqual(backend == .postgres, try indexExists(w, "idx_auth_zb_identity_probe_slug"));
    try std.testing.expect(try indexExists(w, "migration_identity_probe"));
    const duplicate = "INSERT INTO zb_identity_probe(id,account,slug) VALUES('after','acct-b','shared');";
    if (backend == .postgres) {
        // main's in-place ALTER retains the former identity index.
        try std.testing.expectError(error.ExecFailed, w.exec(duplicate));
    } else {
        try w.exec(duplicate);
    }
    try std.testing.expectEqual(@as(i64, if (backend == .postgres) 1 else 2), try count(w, "SELECT count(*) FROM zb_identity_probe WHERE slug='shared';"));
}

test "auth identity change preserves the former index on PostgreSQL" {
    try identityProbeCollectionName(.postgres);
}

test "identity probe name is isolated in the SQLite model" {
    try identityProbeCollectionName(.sqlite);
}

test "PostgreSQL long column uniqueness converges once" {
    const a = std.testing.allocator;
    var c = try Conn.open(.postgres, "long_column");
    defer c.deinit();
    const long_name = "slugslugslugslugslugslugslugslugslugslugslugslugslugslugslugslugslugslugslugslug";
    const long_tenant = "accountaccountaccountaccountaccountaccountaccountaccountaccountaccount";
    var fields = fields_plain;
    fields[0].name = long_tenant;
    fields[1].name = long_name;
    var spec = slugs(long_tenant, &.{});
    spec.fields = &fields;
    const col = try collections.create(a, std.testing.io, &c.db, spec);
    defer col.deinit(a);
    try c.db.exec("DROP TABLE slugs;");
    try c.db.exec("CREATE TABLE slugs(id TEXT PRIMARY KEY, created TEXT, updated TEXT, " ++ long_tenant ++ " TEXT, " ++ long_name ++ " TEXT UNIQUE);");
    try collections.ensureAllUniqueScopes(a, std.testing.io, &c.db);
    try c.db.exec("INSERT INTO slugs(id," ++ long_tenant ++ "," ++ long_name ++ ") VALUES('a','acct-a','shared');");
    try c.db.exec("INSERT INTO slugs(id," ++ long_tenant ++ "," ++ long_name ++ ") VALUES('b','acct-b','shared');");
    try expectConstraint(&c.db, "INSERT INTO slugs(id," ++ long_tenant ++ "," ++ long_name ++ ") VALUES('c','acct-a','shared');");
    try collections.ensureAllUniqueScopes(a, std.testing.io, &c.db);
    try std.testing.expectEqual(@as(i64, 1), try count(&c.db, "SELECT count(*) FROM pg_constraint WHERE conrelid='slugs'::regclass AND contype='u';"));
}

test "SQLite rebuild refuses attached TEMP triggers before DDL" {
    const a = std.testing.allocator;
    var c = try Conn.open(.sqlite, "temp_trigger");
    defer c.deinit();
    const col = try collections.create(a, std.testing.io, &c.db, slugs("account", &.{}));
    defer col.deinit(a);
    try makeLegacyTable(&c.db);
    try c.db.exec("CREATE TEMP TABLE migration_audit(value TEXT);");
    try c.db.exec("CREATE TEMP TRIGGER migration_audit AFTER INSERT ON main.slugs BEGIN INSERT INTO migration_audit VALUES(NEW.slug); END;");
    const generation = try schema_gen.read(&c.db);
    try std.testing.expectError(error.UnsafeSqliteRebuild, collections.ensureAllUniqueScopes(a, std.testing.io, &c.db));
    try std.testing.expectEqual(generation, try schema_gen.read(&c.db));
    try std.testing.expectEqual(@as(i64, 1), try count(&c.db, "SELECT count(*) FROM sqlite_temp_schema WHERE type='trigger' AND name='migration_audit';"));
    try std.testing.expect(insert(&c.db, "new", "acct-a", "new"));
    try std.testing.expectEqual(@as(i64, 1), try count(&c.db, "SELECT count(*) FROM migration_audit;"));
    try std.testing.expect(!insert(&c.db, "blocked", "acct-a", "acme-corp"));
}

test "issue 523 quoted comma constraint is not a tenant composite (postgres)" {
    const a = std.testing.allocator;
    var c = try Conn.open(.postgres, "quoted_comma");
    defer c.deinit();
    const col = try collections.create(a, std.testing.io, &c.db, slugs("account", &.{}));
    defer col.deinit(a);
    try makeLegacyTable(&c.db);
    try c.db.exec("ALTER TABLE slugs ADD COLUMN \"account,slug\" TEXT UNIQUE;");
    try collections.ensureAllUniqueScopes(a, std.testing.io, &c.db);
    try std.testing.expect(insert(&c.db, "comma-a", "acct-a", "acme-corp"));
    try expectConstraint(&c.db, "INSERT INTO slugs(id,account,slug) VALUES ('comma-a2','acct-a','acme-corp');");
    try c.db.exec("INSERT INTO slugs(id, \"account,slug\") VALUES ('quoted-one','value');");
    try expectConstraint(&c.db, "INSERT INTO slugs(id, \"account,slug\") VALUES ('quoted-two','value');");
    // Repeat convergence: hasConstraint must find the real two-column key.
    try collections.ensureAllUniqueScopes(a, std.testing.io, &c.db);
    try std.testing.expectEqual(@as(i64, 1), try count(&c.db, "SELECT count(*) FROM pg_constraint WHERE conrelid='slugs'::regclass AND contype='u' AND cardinality(conkey)=2;"));
}

test "issue 523 SQLite refuses TEMP rebuild name shadows before DDL" {
    const a = std.testing.allocator;
    const shadows = [_][:0]const u8{
        "CREATE TEMP TABLE slugs__new(id TEXT PRIMARY KEY, created TEXT, updated TEXT, account TEXT, slug TEXT, extra TEXT);",
        "CREATE TEMP VIEW slugs__new AS SELECT * FROM main.slugs;",
        "CREATE TEMP TABLE slugs(id TEXT PRIMARY KEY, created TEXT, updated TEXT, account TEXT, slug TEXT);",
        "CREATE TEMP VIEW slugs AS SELECT * FROM main.slugs;",
        "CREATE TEMP TABLE unrelated(value TEXT); CREATE INDEX temp.slugs__new ON unrelated(value);",
        "CREATE TEMP TABLE unrelated(value TEXT); CREATE INDEX temp.slugs ON unrelated(value);",
    };
    for (shadows) |sql| {
        var c = try Conn.open(.sqlite, "temp_shadow");
        defer c.deinit();
        const col = try collections.create(a, std.testing.io, &c.db, slugs(null, &.{}));
        defer col.deinit(a);
        try std.testing.expect(insert(&c.db, "kept", "acct-a", "value"));
        try c.db.exec(sql);
        const generation = try schema_gen.read(&c.db);
        var desired = col;
        desired.fields = &.{ col.fields[0], col.fields[1], .{ .id = "extra_id", .name = "extra", .options = .{ .text = .{} } } };
        const result = collections.update(a, std.testing.io, &c.db, col.id, desired);
        if (result) |updated| {
            updated.deinit(a);
            return error.TestUnexpectedResult;
        } else |err| try std.testing.expectEqual(error.UnsafeSqliteRebuild, err);
        try std.testing.expectEqual(generation, try schema_gen.read(&c.db));
        try std.testing.expectEqual(@as(i64, 1), try count(&c.db, "SELECT count(*) FROM main.slugs WHERE id='kept';"));
    }
}

test "issue 523 SQLite refuses trigger INDEXED BY removed engine index" {
    const a = std.testing.allocator;
    var c = try Conn.open(.sqlite, "indexed_by");
    defer c.deinit();
    const col = try collections.create(a, std.testing.io, &c.db, slugs(null, &.{.{ .name = "idx_slugs_account", .fields = &.{"account"} }}));
    defer col.deinit(a);
    try c.db.exec("CREATE TRIGGER migration_indexed AFTER INSERT ON slugs BEGIN SELECT account FROM slugs INDEXED /* migration */ BY \"idx_slugs_account\" WHERE account=NEW.account; END;");
    try std.testing.expect(insert(&c.db, "before", "acct-a", "before"));
    const generation = try schema_gen.read(&c.db);
    var desired = col;
    desired.indexes = &.{};
    const result = collections.update(a, std.testing.io, &c.db, col.id, desired);
    if (result) |updated| {
        updated.deinit(a);
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.MigrationObjectConflict, err);
    try std.testing.expect(std.mem.indexOf(u8, collections.last_rebuild_error, "migration_indexed") != null);
    try std.testing.expectEqual(generation, try schema_gen.read(&c.db));
    try std.testing.expect(try indexExists(&c.db, "idx_slugs_account"));
    try std.testing.expect(insert(&c.db, "after", "acct-b", "after"));
}

test "SQLite refuses trigger INDEXED BY an engine index whose definition changes" {
    const a = std.testing.allocator;
    var c = try Conn.open(.sqlite, "indexed_by_changed");
    defer c.deinit();
    const col = try collections.create(a, std.testing.io, &c.db, slugs(null, &.{.{ .name = "idx_slugs_account", .fields = &.{"account"} }}));
    defer col.deinit(a);
    try c.db.exec("CREATE TRIGGER migration_indexed AFTER INSERT ON slugs BEGIN SELECT account FROM slugs INDEXED BY \"idx_slugs_account\" WHERE account=NEW.account; END;");
    const generation = try schema_gen.read(&c.db);
    var desired = col;
    desired.indexes = &.{.{ .name = "idx_slugs_account", .fields = &.{"account"}, .where = "slug IS NOT NULL" }};
    const result = collections.update(a, std.testing.io, &c.db, col.id, desired);
    if (result) |updated| {
        updated.deinit(a);
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.MigrationObjectConflict, err);
    try std.testing.expect(std.mem.indexOf(u8, collections.last_rebuild_error, "migration_indexed") != null);
    try std.testing.expectEqual(generation, try schema_gen.read(&c.db));
    try std.testing.expect(insert(&c.db, "after", "acct-b", "after"));
}

test "SQLite refuses trigger INDEXED BY a constraint autoindex before a rebuild" {
    const a = std.testing.allocator;
    var c = try Conn.open(.sqlite, "indexed_by_autoindex");
    defer c.deinit();
    // slug is UNIQUE on a non-tenant table: an inline constraint backed by an autoindex.
    const col = try collections.create(a, std.testing.io, &c.db, slugs(null, &.{}));
    defer col.deinit(a);
    var auto = try c.db.prepare("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='slugs' AND name LIKE 'sqlite_autoindex_slugs_%' LIMIT 1;");
    defer auto.finalize();
    try std.testing.expect(try auto.step());
    const trigger = try a.printSentinel("CREATE TRIGGER migration_auto AFTER INSERT ON slugs BEGIN SELECT 1 FROM slugs INDEXED BY \"{s}\" WHERE slug=NEW.slug; END;", .{auto.columnText(0)}, 0);
    defer a.free(trigger);
    try c.db.exec(trigger);
    const generation = try schema_gen.read(&c.db);
    var desired = col;
    var cleared = [_]schema.Field{ col.fields[0], col.fields[1] };
    cleared[1].unique = false;
    desired.fields = &cleared;
    const result = collections.update(a, std.testing.io, &c.db, col.id, desired);
    if (result) |updated| {
        updated.deinit(a);
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.MigrationObjectConflict, err);
    try std.testing.expect(std.mem.indexOf(u8, collections.last_rebuild_error, "migration_auto") != null);
    try std.testing.expectEqual(generation, try schema_gen.read(&c.db));
}

test "SQLite rebuild keeps each row's rowid for restored triggers" {
    const a = std.testing.allocator;
    var c = try Conn.open(.sqlite, "rowid_preserved");
    defer c.deinit();
    const col = try collections.create(a, std.testing.io, &c.db, slugs(null, &.{}));
    defer col.deinit(a);
    try std.testing.expect(insert(&c.db, "first", "acct-a", "one"));
    try std.testing.expect(insert(&c.db, "second", "acct-a", "two"));
    try c.db.exec("DELETE FROM slugs WHERE id='first';");
    const before = try count(&c.db, "SELECT rowid FROM slugs WHERE id='second';");
    var desired = col;
    var cleared = [_]schema.Field{ col.fields[0], col.fields[1] };
    cleared[1].unique = false;
    desired.fields = &cleared;
    const updated = try collections.update(a, std.testing.io, &c.db, col.id, desired);
    defer updated.deinit(a);
    try std.testing.expectEqual(before, try count(&c.db, "SELECT rowid FROM slugs WHERE id='second';"));
    try std.testing.expect(before != 1);
}

test "SQLite rebuild keeps the hidden rowid separate from a field named rowid" {
    const a = std.testing.allocator;
    var c = try Conn.open(.sqlite, "rowid_field");
    defer c.deinit();
    const col = try collections.create(a, std.testing.io, &c.db, slugs(null, &.{}));
    defer col.deinit(a);
    try std.testing.expect(insert(&c.db, "first", "acct-a", "one"));
    try std.testing.expect(insert(&c.db, "second", "acct-a", "two"));
    try c.db.exec("DELETE FROM slugs WHERE id='first';");
    const before = try count(&c.db, "SELECT _rowid_ FROM slugs WHERE id='second';");
    var desired = col;
    const added = [_]schema.Field{ col.fields[0], col.fields[1], .{ .id = "rowid_fid", .name = "rowid", .options = .{ .text = .{} } } };
    desired.fields = &added;
    const updated = try collections.update(a, std.testing.io, &c.db, col.id, desired);
    defer updated.deinit(a);
    try std.testing.expectEqual(before, try count(&c.db, "SELECT _rowid_ FROM slugs WHERE id='second';"));
    try std.testing.expectEqual(@as(i64, 1), try count(&c.db, "SELECT \"rowid\" IS NULL FROM slugs WHERE id='second';"));
}

test "SQLite refuses a wildcard trigger on a search table whose columns change" {
    if (comptime !@import("search/fts.zig").enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    var c = try Conn.open(.sqlite, "fts_layout");
    defer c.deinit();
    const fields = [_]schema.Field{
        .{ .id = "t1", .name = "title", .searchable = true, .options = .{ .text = .{} } },
        .{ .id = "b1", .name = "body", .searchable = true, .options = .{ .text = .{} } },
    };
    const col = try collections.create(a, std.testing.io, &c.db, .{ .id = "", .name = "docs", .fields = &fields });
    defer col.deinit(a);
    try c.db.exec("CREATE TABLE audit_fts AS SELECT * FROM docs_fts;");
    try c.db.exec("CREATE TRIGGER migration_fts_copy AFTER INSERT ON docs BEGIN INSERT INTO audit_fts SELECT * FROM docs_fts WHERE rowid=NEW.rowid; END;");
    try c.db.exec("CREATE TABLE audit_body(value TEXT);");
    try c.db.exec("CREATE TRIGGER migration_fts_named AFTER UPDATE ON docs BEGIN INSERT INTO audit_body SELECT body FROM docs_fts WHERE rowid=NEW.rowid; END;");
    const generation = try schema_gen.read(&c.db);
    var desired = col;
    var fewer = [_]schema.Field{ col.fields[0], col.fields[1] };
    fewer[1].searchable = false;
    desired.fields = &fewer;
    const result = collections.update(a, std.testing.io, &c.db, col.id, desired);
    if (result) |updated| {
        updated.deinit(a);
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.MigrationObjectConflict, err);
    // Either trigger refuses; the first one checked is named.
    try std.testing.expect(std.mem.indexOf(u8, collections.last_rebuild_error, "migration_fts_") != null);
    try std.testing.expectEqual(generation, try schema_gen.read(&c.db));
}

test "issue 523 SQLite rebuild SQL stays in main despite TEMP copy" {
    var c = try Conn.open(.sqlite, "qualified_rebuild");
    defer c.deinit();
    const a = std.testing.allocator;
    const ddl = @import("ddl.zig");
    const old = slugs(null, &.{});
    const sql = try ddl.createTableSql(a, old, null, .sqlite, &.{});
    defer a.free(sql);
    const sql_z = try a.dupeSentinel(u8, sql, 0);
    defer a.free(sql_z);
    try c.db.exec(sql_z);
    try std.testing.expect(insert(&c.db, "kept", "acct-a", "value"));
    try c.db.exec("CREATE TEMP TABLE slugs__new(id TEXT PRIMARY KEY, created TEXT, updated TEXT, account TEXT, slug TEXT);");
    const plan = try ddl.rebuildPlan(a, old, old, .sqlite);
    defer {
        for (plan) |stmt| a.free(stmt);
        a.free(plan);
    }
    for (plan) |stmt| {
        const stmt_z = try a.dupeSentinel(u8, stmt, 0);
        defer a.free(stmt_z);
        try c.db.exec(stmt_z);
    }
    try std.testing.expectEqual(@as(i64, 1), try count(&c.db, "SELECT count(*) FROM main.sqlite_schema WHERE name='slugs' AND type='table';"));
    try std.testing.expectEqual(@as(i64, 1), try count(&c.db, "SELECT count(*) FROM main.slugs WHERE id='kept';"));
    try std.testing.expectEqual(@as(i64, 0), try count(&c.db, "SELECT count(*) FROM temp.slugs__new;"));
}

test "SQLite refuses a named-column trigger on a search table whose columns change" {
    if (comptime !@import("search/fts.zig").enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    var c = try Conn.open(.sqlite, "fts_named");
    defer c.deinit();
    const fields = [_]schema.Field{
        .{ .id = "t1", .name = "title", .searchable = true, .options = .{ .text = .{} } },
        .{ .id = "b1", .name = "body", .searchable = true, .options = .{ .text = .{} } },
    };
    const col = try collections.create(a, std.testing.io, &c.db, .{ .id = "", .name = "docs", .fields = &fields });
    defer col.deinit(a);
    try c.db.exec("CREATE TABLE audit_body(value TEXT);");
    try c.db.exec("CREATE TRIGGER migration_fts_named AFTER INSERT ON docs BEGIN INSERT INTO audit_body SELECT body FROM docs_fts WHERE rowid=NEW.rowid; END;");
    const generation = try schema_gen.read(&c.db);
    var desired = col;
    var fewer = [_]schema.Field{ col.fields[0], col.fields[1] };
    fewer[1].searchable = false;
    desired.fields = &fewer;
    const result = collections.update(a, std.testing.io, &c.db, col.id, desired);
    if (result) |updated| {
        updated.deinit(a);
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.MigrationObjectConflict, err);
    try std.testing.expect(std.mem.indexOf(u8, collections.last_rebuild_error, "migration_fts_named") != null);
    try std.testing.expectEqual(generation, try schema_gen.read(&c.db));
}

test "SQLite refuses a trigger reading a rowid alias that a new field would shadow" {
    const a = std.testing.allocator;
    var c = try Conn.open(.sqlite, "rowid_alias_shadow");
    defer c.deinit();
    const col = try collections.create(a, std.testing.io, &c.db, slugs(null, &.{}));
    defer col.deinit(a);
    try c.db.exec("CREATE TABLE audit_rowid(value INTEGER);");
    try c.db.exec("CREATE TRIGGER migration_rowid_audit AFTER INSERT ON slugs BEGIN INSERT INTO audit_rowid VALUES (NEW.rowid); END;");
    const generation = try schema_gen.read(&c.db);
    for ([_][]const u8{ "rowid", "OID" }) |name| {
        var desired = col;
        const added = [_]schema.Field{ col.fields[0], col.fields[1], .{ .id = "alias_fid", .name = name, .options = .{ .text = .{} } } };
        desired.fields = &added;
        const result = collections.update(a, std.testing.io, &c.db, col.id, desired);
        if (std.ascii.eqlIgnoreCase(name, "rowid")) {
            if (result) |updated| {
                updated.deinit(a);
                return error.TestUnexpectedResult;
            } else |err| try std.testing.expectEqual(error.MigrationObjectConflict, err);
            try std.testing.expect(std.mem.indexOf(u8, collections.last_rebuild_error, "migration_rowid_audit") != null);
            try std.testing.expectEqual(generation, try schema_gen.read(&c.db));
        } else {
            // The trigger does not read `oid`, so adding an `oid` field is not refused.
            const updated = try result;
            updated.deinit(a);
        }
    }
}

test "SQLite refuses a trigger that mentions a field name the update adds" {
    const a = std.testing.allocator;
    var c = try Conn.open(.sqlite, "new_field_ambiguous");
    defer c.deinit();
    const col = try collections.create(a, std.testing.io, &c.db, slugs(null, &.{}));
    defer col.deinit(a);
    try c.db.exec("CREATE TABLE migration_labels(id TEXT, label TEXT);");
    try c.db.exec("CREATE TABLE audit_label(value TEXT);");
    try c.db.exec("CREATE TRIGGER migration_label AFTER INSERT ON slugs BEGIN INSERT INTO audit_label SELECT label FROM slugs JOIN migration_labels ON slugs.id=migration_labels.id; END;");
    const generation = try schema_gen.read(&c.db);
    var desired = col;
    const added = [_]schema.Field{ col.fields[0], col.fields[1], .{ .id = "label_fid", .name = "label", .options = .{ .text = .{} } } };
    desired.fields = &added;
    const result = collections.update(a, std.testing.io, &c.db, col.id, desired);
    if (result) |updated| {
        updated.deinit(a);
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.MigrationObjectConflict, err);
    try std.testing.expect(std.mem.indexOf(u8, collections.last_rebuild_error, "migration_label") != null);
    try std.testing.expectEqual(generation, try schema_gen.read(&c.db));
}

test "SQLite unique-scope drift reads main, not a TEMP table of the same name" {
    const a = std.testing.allocator;
    var c = try Conn.open(.sqlite, "temp_drift_mask");
    defer c.deinit();
    const col = try collections.create(a, std.testing.io, &c.db, slugs("account", &.{}));
    defer col.deinit(a);
    // Make main.slugs legacy (global UNIQUE(slug)) and mask it with a TEMP table that looks converged.
    try c.db.exec("DROP TABLE main.slugs;");
    try c.db.exec("CREATE TABLE main.slugs(id TEXT PRIMARY KEY, created TEXT, updated TEXT, account TEXT, slug TEXT UNIQUE);");
    try c.db.exec("CREATE TEMP TABLE slugs(id TEXT PRIMARY KEY, created TEXT, updated TEXT, account TEXT, slug TEXT, UNIQUE(account, slug));");
    // Drift must be detected on main; the TEMP shadow then refuses the rebuild before DDL.
    try std.testing.expectError(error.UnsafeSqliteRebuild, collections.ensureAllUniqueScopes(a, std.testing.io, &c.db));
}

test "PostgreSQL identity lookup follows the resolved table namespace and rejects temp shadows" {
    var c = try Conn.open(.postgres, "identity_search_path");
    defer c.deinit();
    const w = &c.db;
    const a = std.testing.allocator;
    const identity = @import("auth_identity_index.zig");
    try w.exec("CREATE TABLE path_members(email TEXT);");
    try identity.ensure(a, w, "path_members", "email");
    // The first schema exists but the table resolves in the second schema.
    try w.exec("SET search_path TO public, zb_uniq_identity_search_path;");
    try std.testing.expect(try identity.verify(a, w, "path_members", "email"));
    try identity.ensure(a, w, "path_members", "email");
    try w.exec("DROP INDEX zb_uniq_identity_search_path.idx_auth_path_members_email;");
    try identity.ensure(a, w, "path_members", "email");
    try std.testing.expect(try identity.verify(a, w, "path_members", "email"));
    try w.exec("CREATE TEMP TABLE path_members(email TEXT);");
    try std.testing.expectError(error.AuthIdentityIndexConflict, identity.ensure(a, w, "path_members", "email"));
    try w.exec("CREATE UNIQUE INDEX idx_auth_path_members_email ON path_members(email) WHERE email != '';");
    try std.testing.expectError(error.AuthIdentityIndexConflict, identity.ensure(a, w, "path_members", "email"));
}

test "PostgreSQL updates preserve removed identity migration replacements" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |keep_declaration| {
        var c = try Conn.open(.postgres, "identity_update_replacement");
        defer c.deinit();
        const w = &c.db;
        var def = slugs(null, &.{.{ .name = "idx_auth_slugs_slug", .fields = &.{"slug"}, .unique = true, .where = "slug <> ''" }});
        def.type = .auth;
        def.options.auth.identityFields = &.{"slug"};
        const col = try collections.create(a, std.testing.io, w, def);
        defer col.deinit(a);
        try w.exec("DROP INDEX idx_auth_slugs_slug;");
        try w.exec("CREATE INDEX idx_auth_slugs_slug ON slugs(account);");
        const before = try IdentityObject.read(a, w);
        defer before.deinit(a);
        def.options.auth.identityFields = &.{"email"};
        if (!keep_declaration) def.indexes = &.{};
        const updated = try collections.update(a, std.testing.io, w, col.id, def);
        defer updated.deinit(a);
        try before.expectUnchanged(a, w);
        try std.testing.expect(try @import("auth_identity_index.zig").verify(a, w, "slugs", "email"));
    }
}

const CrossSchemaOperation = enum { update, update_remove, provision_remove, provision_create, plan_remove, plan_recreate };

fn crossSchemaChange(comptime operation: CrossSchemaOperation, a: std.mem.Allocator, w: *db.Db, created: schema.Collection, definition: schema.Collection) !void {
    switch (operation) {
        .plan_remove, .plan_recreate => {
            const ddl = @import("ddl.zig");
            var desired = created;
            if (operation == .plan_remove) desired.indexes = &.{};
            const plan = try ddl.rebuildPlanInSchema(a, created, desired, .postgres, "public");
            defer {
                for (plan) |stmt| a.free(stmt);
                a.free(plan);
            }
            try w.begin();
            errdefer w.rollback() catch |err| std.debug.panic("planner test rollback: {s}", .{@errorName(err)});
            try schema_gen.lock(w);
            for (plan) |stmt| {
                const sql = try a.dupeSentinel(u8, stmt, 0);
                defer a.free(sql);
                try w.exec(sql);
            }
            try @import("auth_identity_index.zig").ensure(a, w, "users", "email");
            try w.commit();
        },
        .update, .update_remove => {
            var def = definition;
            def.indexes = if (operation == .update_remove) &.{} else definition.indexes[0..1];
            const updated = try collections.update(a, std.testing.io, w, created.id, def);
            defer updated.deinit(a);
        },
        .provision_remove, .provision_create => {
            const old = (try collections.get(a, w, created.id)).?;
            defer old.deinit(a);
            var desired = old;
            desired.indexes = if (operation == .provision_create) &.{
                definition.indexes[0], .{ .name = "idx_users_nickname", .fields = &.{"nickname"} },
            } else &.{};
            try collections.provisionMetadata(a, w, old, desired);
        },
    }
}

fn crossSchemaIndexDdl(comptime operation: CrossSchemaOperation) !void {
    if (comptime !@import("build_options").postgres) return error.SkipZigTest;
    const a = std.testing.allocator;
    const url = std.testing.environ.getPosix("ZIGBASE_PG_TEST_URL") orelse return error.SkipZigTest;
    var w = try db.Db.openPostgres(a, std.testing.io, url);
    defer w.close();
    // CREATE without IF NOT EXISTS: teardown only owns a schema created by this test.
    try w.exec("CREATE SCHEMA app;");
    defer w.exec("DROP SCHEMA app CASCADE;") catch |err| std.log.warn("cross-schema cleanup: {s}", .{@errorName(err)});
    try w.exec("SET search_path TO app,public;");
    try migrations.run(&w);
    const identity_decl = schema.Index{ .name = "idx_auth_users_email", .fields = &.{"email"}, .unique = true, .where = "email <> ''" };
    const ordinary_decl = schema.Index{ .name = "idx_users_nickname", .fields = &.{"nickname"} };
    const def = schema.Collection{
        .id = "",
        .name = "users",
        .type = .auth,
        .fields = &.{.{ .id = "nickname", .name = "nickname", .options = .{ .text = .{} } }},
        .indexes = if (operation == .provision_create) &.{identity_decl} else &.{ identity_decl, ordinary_decl },
    };
    const created = try collections.create(a, std.testing.io, &w, def);
    defer created.deinit(a);
    try w.exec("ALTER TABLE app.users SET SCHEMA public;");
    defer w.exec("DROP TABLE public.users CASCADE;") catch |err| std.log.warn("cross-schema table cleanup: {s}", .{@errorName(err)});
    try w.exec("CREATE TABLE app.migration_holder(email TEXT, nickname TEXT);");
    try w.exec("CREATE UNIQUE INDEX idx_auth_users_email ON app.migration_holder(email);");
    try w.exec("CREATE UNIQUE INDEX idx_users_nickname ON app.migration_holder(nickname);");
    const identity_oid = try count(&w, "SELECT 'app.idx_auth_users_email'::regclass::oid::bigint;");
    const ordinary_oid = try count(&w, "SELECT 'app.idx_users_nickname'::regclass::oid::bigint;");
    // Search ownership refuses a table outside the first schema on PostgreSQL,
    // independently of the SQLite FTS flag. Index DDL must not hit another schema
    // or return an unrelated name-collision error before that guard runs.
    if (operation == .plan_remove or operation == .plan_recreate) {
        // Exercise the planner independently of the later search-ownership refusal.
        try crossSchemaChange(operation, a, &w, created, def);
    } else {
        try std.testing.expectError(error.Conflict, crossSchemaChange(operation, a, &w, created, def));
    }
    try std.testing.expectEqual(identity_oid, try count(&w, "SELECT 'app.idx_auth_users_email'::regclass::oid::bigint;"));
    try std.testing.expectEqual(ordinary_oid, try count(&w, "SELECT 'app.idx_users_nickname'::regclass::oid::bigint;"));
    try std.testing.expect(try @import("auth_identity_index.zig").verify(a, &w, "users", "email"));
    try w.exec("INSERT INTO app.migration_holder VALUES('keep', 'keep');");
    try expectConstraint(&w, "INSERT INTO app.migration_holder VALUES('keep', 'other');");
    try expectConstraint(&w, "INSERT INTO app.migration_holder VALUES('other', 'keep');");
    const expected: i64 = if (operation == .provision_create or operation == .plan_remove) 0 else 1;
    try std.testing.expectEqual(expected, try count(&w, "SELECT count(*) FROM pg_class WHERE relnamespace='public'::regnamespace AND relname='idx_users_nickname';"));
}

test "PostgreSQL update preserves same-name indexes in an earlier search schema" {
    try crossSchemaIndexDdl(.update);
}

test "PostgreSQL provisioning drops indexes only in the collection schema" {
    try crossSchemaIndexDdl(.provision_remove);
}

test "PostgreSQL provisioning creates declared indexes despite earlier-schema names" {
    try crossSchemaIndexDdl(.provision_create);
}

test "PostgreSQL update drops declarations only in the collection schema" {
    try crossSchemaIndexDdl(.update_remove);
}

test "SQLite provisioning preserves a temporary same-name declared index" {
    const a = std.testing.allocator;
    var c = try Conn.open(.sqlite, "declared_temp_shadow");
    defer c.deinit();
    const w = &c.db;
    const declaration = schema.Index{ .name = "idx_slugs_account", .fields = &.{"account"} };
    const created = try collections.create(a, std.testing.io, w, slugs(null, &.{declaration}));
    defer created.deinit(a);
    try w.exec("CREATE TEMP TABLE migration_holder(value TEXT); CREATE INDEX idx_slugs_account ON migration_holder(value);");
    var desired = created;
    desired.indexes = &.{};
    try collections.provisionMetadata(a, w, created, desired);
    try std.testing.expectEqual(@as(i64, 1), try count(w, "SELECT count(*) FROM sqlite_temp_schema WHERE name='idx_slugs_account';"));
    try std.testing.expectEqual(@as(i64, 0), try count(w, "SELECT count(*) FROM main.sqlite_schema WHERE name='idx_slugs_account';"));
    const old = (try collections.get(a, w, created.id)).?;
    defer old.deinit(a);
    desired.indexes = &.{declaration};
    try collections.provisionMetadata(a, w, old, desired);
    try std.testing.expectEqual(@as(i64, 1), try count(w, "SELECT count(*) FROM main.sqlite_schema WHERE name='idx_slugs_account';"));
    try std.testing.expectEqual(@as(i64, 1), try count(w, "SELECT count(*) FROM sqlite_temp_schema WHERE name='idx_slugs_account';"));
}

test "SQLite provisioning adopts a main declared index despite a temporary shadow" {
    const a = std.testing.allocator;
    var c = try Conn.open(.sqlite, "declared_temp_adoption");
    defer c.deinit();
    const w = &c.db;
    const created = try collections.create(a, std.testing.io, w, slugs(null, &.{}));
    defer created.deinit(a);
    try w.exec("CREATE INDEX main.idx_slugs_account ON slugs(account);");
    try w.exec("CREATE TEMP TABLE migration_holder(value TEXT); CREATE INDEX idx_slugs_account ON migration_holder(value);");
    var desired = created;
    desired.indexes = &.{.{ .name = "idx_slugs_account", .fields = &.{"account"} }};
    try collections.provisionMetadata(a, w, created, desired);
    try std.testing.expectEqual(@as(i64, 1), try count(w, "SELECT count(*) FROM main.sqlite_schema WHERE name='idx_slugs_account';"));
    try std.testing.expectEqual(@as(i64, 1), try count(w, "SELECT count(*) FROM sqlite_temp_schema WHERE name='idx_slugs_account';"));
}

test "PostgreSQL scoped planner drops only the collection schema indexes" {
    try crossSchemaIndexDdl(.plan_remove);
}

test "PostgreSQL scoped planner recreates only the collection schema indexes" {
    try crossSchemaIndexDdl(.plan_recreate);
}

test "SQLite identity predicates require quoted keywords and literals" {
    const a = std.testing.allocator;
    const identity = @import("auth_identity_index.zig");
    for ([_][]const u8{ "null", "NULL", "true", "false", "current_time", "current_date", "current_timestamp" }) |field| {
        var w = try db.Db.openMemory();
        defer w.close();
        const table_sql = try a.printSentinel("CREATE TABLE members(\"{s}\" TEXT);", .{field}, 0);
        defer a.free(table_sql);
        try w.exec(table_sql);
        const index_sql = try a.printSentinel("CREATE UNIQUE INDEX idx_auth_members_{s} ON members(\"{s}\") WHERE {s} != '';", .{ field, field, field }, 0);
        defer a.free(index_sql);
        if (std.mem.startsWith(u8, field, "current_")) {
            // SQLite itself rejects non-deterministic functions in index predicates.
            try std.testing.expectError(error.ExecFailed, w.exec(index_sql));
            try std.testing.expect(!try identity.verify(a, &w, "members", field));
        } else {
            try w.exec(index_sql);
            try std.testing.expectError(error.AuthIdentityIndexConflict, identity.verify(a, &w, "members", field));
        }
        if (std.ascii.eqlIgnoreCase(field, "null")) {
            try w.exec("INSERT INTO members(\"null\") VALUES('duplicate'),('duplicate');");
            try w.exec("DELETE FROM members;");
        }
        const drop_sql = try a.printSentinel("DROP INDEX IF EXISTS idx_auth_members_{s};", .{field}, 0);
        defer a.free(drop_sql);
        try w.exec(drop_sql);
        try identity.ensure(a, &w, "members", field);
        try std.testing.expect(try identity.verify(a, &w, "members", field));
        const insert_sql = try a.printSentinel("INSERT INTO members(\"{s}\") VALUES('duplicate');", .{field}, 0);
        defer a.free(insert_sql);
        try w.exec(insert_sql);
        try expectConstraint(&w, insert_sql);
    }
}

test "SQLite identity indexes coexist with main and temporary namesake triggers" {
    const a = std.testing.allocator;
    var c = try Conn.open(.sqlite, "identity_trigger");
    defer c.deinit();
    const w = &c.db;
    var def = slugs(null, &.{});
    def.type = .auth;
    def.options.auth.identityFields = &.{"slug"};
    const col = try collections.create(a, std.testing.io, w, def);
    defer col.deinit(a);
    try w.exec("CREATE TRIGGER idx_auth_slugs_slug AFTER INSERT ON slugs BEGIN SELECT 1; END;");
    try collections.ensureAllUniqueScopes(a, std.testing.io, w);
    try w.exec("CREATE TEMP TRIGGER idx_auth_slugs_slug AFTER INSERT ON main.slugs BEGIN SELECT 1; END;");
    try w.exec("CREATE TEMP TRIGGER slugs AFTER UPDATE ON main.slugs BEGIN SELECT 1; END;");
    try collections.ensureAllUniqueScopes(a, std.testing.io, w);
    try std.testing.expect(try @import("auth_identity_index.zig").verify(a, w, "slugs", "slug"));
    try w.exec("INSERT INTO slugs(id,slug) VALUES('first','shared');");
    try expectConstraint(w, "INSERT INTO slugs(id,slug) VALUES('second','shared');");
}

test "PostgreSQL removed identity replacements do not preserve differently cased declarations" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |provisioning| {
        var c = try Conn.open(.postgres, "identity_case");
        defer c.deinit();
        const w = &c.db;
        var def = slugs(null, &.{.{ .name = "IDX_AUTH_slugs_slug", .fields = &.{"account"}, .unique = true }});
        def.type = .auth;
        def.options.auth.identityFields = &.{"slug"};
        const col = try collections.create(a, std.testing.io, w, def);
        defer col.deinit(a);
        try w.exec("DROP INDEX idx_auth_slugs_slug;");
        try w.exec("CREATE INDEX idx_auth_slugs_slug ON slugs(slug);");
        def.indexes = &.{};
        def.options.auth.identityFields = &.{"email"};
        if (provisioning) {
            try collections.provisionMetadata(a, w, col, def);
        } else {
            const updated = try collections.update(a, std.testing.io, w, col.id, def);
            defer updated.deinit(a);
        }
        try std.testing.expect(!try indexExists(w, "IDX_AUTH_slugs_slug"));
        try std.testing.expect(try indexExists(w, "idx_auth_slugs_slug"));
        try w.exec("INSERT INTO slugs(id,account,slug) VALUES('first','shared','one'),('second','shared','two');");
    }
}

test "SQLite index adoption and identity rename ignore namesake triggers" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |rename| {
        var c = try Conn.open(.sqlite, "identity_trigger_catalog");
        defer c.deinit();
        const w = &c.db;
        var def = slugs(null, &.{});
        def.type = .auth;
        def.options.auth.identityFields = &.{"slug"};
        const col = try collections.create(a, std.testing.io, w, def);
        defer col.deinit(a);
        if (rename) {
            try w.exec("CREATE TRIGGER idx_auth_members_slug AFTER INSERT ON slugs BEGIN SELECT 1; END;");
            try @import("collection_rename.zig").rename(a, std.testing.io, w, "slugs", "members");
            try std.testing.expect(try @import("auth_identity_index.zig").verify(a, w, "members", "slug"));
            try std.testing.expectEqual(@as(i64, 1), try count(w, "SELECT count(*) FROM sqlite_schema WHERE type='trigger' AND name='idx_auth_members_slug';"));
        } else {
            // A trigger on another table can precede the index's catalog row.
            try w.exec("CREATE TABLE other(value TEXT);");
            try w.exec("CREATE TRIGGER declared_account AFTER INSERT ON other BEGIN SELECT 1; END;");
            try w.exec("CREATE INDEX declared_account ON slugs(account);");
            def.indexes = &.{.{ .name = "declared_account", .fields = &.{"account"} }};
            try provision.applySpecs(a, std.testing.io, w, &.{def});
            try std.testing.expect(try indexExists(w, "declared_account"));
        }
    }
}

test "SQLite identity adoption rejects column comparisons broader than BINARY uniqueness" {
    const a = std.testing.allocator;
    const identity = @import("auth_identity_index.zig");
    for ([_][]const u8{ "NOCASE", "RTRIM" }) |collation| {
        var c = try Conn.open(.sqlite, "identity_column_collation");
        defer c.deinit();
        const w = &c.db;
        const sql = try a.printSentinel("CREATE TABLE members(id TEXT, email TEXT COLLATE {s});", .{collation}, 0);
        defer a.free(sql);
        try w.exec(sql);
        try w.exec("CREATE UNIQUE INDEX idx_auth_members_email ON members(email COLLATE BINARY) WHERE \"email\" != '';");
        try w.exec("INSERT INTO members VALUES('a','Alice@example.com');");
        try w.exec(if (std.mem.eql(u8, collation, "NOCASE")) "INSERT INTO members VALUES('b','alice@example.com');" else "INSERT INTO members VALUES('b','Alice@example.com ');");
        try std.testing.expectEqual(@as(i64, 2), try count(w, "SELECT count(*) FROM members WHERE email='Alice@example.com' AND email!='';"));
        try std.testing.expectError(error.AuthIdentityIndexConflict, identity.verify(a, w, "members", "email"));
        try std.testing.expectEqual(@as(i64, 2), try count(w, "SELECT count(*) FROM members;"));
    }
}

fn legacyIdentityDeclaration(comptime backend: Backend) !void {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |keep_declaration| {
        var c = try Conn.open(backend, "legacy_identity_declaration");
        defer c.deinit();
        const w = &c.db;
        var def = slugs(null, &.{});
        def.type = .auth;
        def.options.auth.identityFields = &.{"slug"};
        const col = try collections.create(a, std.testing.io, w, def);
        defer col.deinit(a);
        // Releases before identity verification could store this incompatible declaration.
        def.indexes = &.{.{ .name = "idx_auth_slugs_slug", .fields = &.{"account"} }};
        const json = try schema.indexesToJson(a, def.indexes);
        defer a.free(json);
        var st = try w.prepare(if (backend == .postgres) "UPDATE _collections SET indexes=$1 WHERE name='slugs';" else "UPDATE _collections SET indexes=?1 WHERE name='slugs';");
        defer st.finalize();
        try st.bindText(1, json);
        _ = try st.step();
        try w.exec("DROP INDEX idx_auth_slugs_slug;");
        const index_sql = try @import("ddl.zig").createIndexSql(a, "slugs", def.indexes[0], db.dbDialect(w));
        defer a.free(index_sql);
        const index_sql_z = try a.dupeSentinel(u8, index_sql, 0);
        defer a.free(index_sql_z);
        try w.exec(index_sql_z);
        const before = try IdentityObject.read(a, w);
        defer before.deinit(a);
        def.options.auth.identityFields = &.{"email"};
        if (!keep_declaration) def.indexes = &.{};
        const updated = try collections.update(a, std.testing.io, w, col.id, def);
        defer updated.deinit(a);
        const after = try IdentityObject.read(a, w);
        defer after.deinit(a);
        try std.testing.expectEqualStrings(before.definition, after.definition);
        if (backend == .postgres) try std.testing.expectEqual(before.oid, after.oid);
        try std.testing.expect(try @import("auth_identity_index.zig").verify(a, w, "slugs", "email"));
    }
}

test "legacy incompatible identity declarations survive removal and retention (sqlite)" {
    try legacyIdentityDeclaration(.sqlite);
}

test "legacy incompatible identity declarations survive removal and retention (postgres)" {
    try legacyIdentityDeclaration(.postgres);
}

/// A preserved former-identity object cannot carry a new or changed declaration: making the
/// legacy non-unique `idx_auth_slugs_slug` unique while removing the identity must be refused,
/// never recorded as `unique` over the still non-unique index. A preserved object that already
/// matches the changed declaration is adopted instead.
fn changedLegacyIdentityDeclaration(comptime backend: Backend) !void {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |provisioning| for ([_]bool{ false, true }) |matching| {
        var c = try Conn.open(backend, "changed_identity_declaration");
        defer c.deinit();
        const w = &c.db;
        var def = slugs(null, &.{});
        def.type = .auth;
        def.options.auth.identityFields = &.{"slug"};
        const created = try collections.create(a, std.testing.io, w, def);
        defer created.deinit(a);
        // Releases before identity verification could store this incompatible declaration.
        def.indexes = &.{.{ .name = "idx_auth_slugs_slug", .fields = &.{"account"} }};
        const json = try schema.indexesToJson(a, def.indexes);
        defer a.free(json);
        var st = try w.prepare(if (backend == .postgres) "UPDATE _collections SET indexes=$1 WHERE name='slugs';" else "UPDATE _collections SET indexes=?1 WHERE name='slugs';");
        defer st.finalize();
        try st.bindText(1, json);
        _ = try st.step();
        try w.exec("DROP INDEX idx_auth_slugs_slug;");
        const changed: schema.Index = .{ .name = "idx_auth_slugs_slug", .fields = &.{"account"}, .unique = true };
        // `matching`: a migration already rebuilt the object to the changed definition.
        const index_sql = try @import("ddl.zig").createIndexSql(a, "slugs", if (matching) changed else def.indexes[0], db.dbDialect(w));
        defer a.free(index_sql);
        const index_sql_z = try a.dupeSentinel(u8, index_sql, 0);
        defer a.free(index_sql_z);
        try w.exec(index_sql_z);
        const before = try IdentityObject.read(a, w);
        defer before.deinit(a);
        const col = (try collections.get(a, w, "slugs")).?;
        defer col.deinit(a);
        // Provisioning persists the desired definition by its id.
        def.id = col.id;
        def.options.auth.identityFields = &.{"email"};
        def.indexes = &.{changed};
        if (matching) {
            if (provisioning) {
                try collections.provisionMetadata(a, w, col, def);
            } else {
                const updated = try collections.update(a, std.testing.io, w, col.id, def);
                defer updated.deinit(a);
            }
        } else if (provisioning) {
            try std.testing.expectError(error.MigrationObjectConflict, collections.provisionMetadata(a, w, col, def));
        } else {
            try std.testing.expectError(error.MigrationObjectConflict, collections.update(a, std.testing.io, w, col.id, def));
        }
        if (!matching) try std.testing.expect(std.mem.indexOf(u8, collections.last_rebuild_error, "idx_auth_slugs_slug") != null);
        const after = try IdentityObject.read(a, w);
        defer after.deinit(a);
        try std.testing.expectEqualStrings(before.definition, after.definition);
        if (backend == .postgres) try std.testing.expectEqual(before.oid, after.oid);
        const stored = (try collections.get(a, w, "slugs")).?;
        defer stored.deinit(a);
        try std.testing.expectEqual(@as(usize, 1), stored.indexes.len);
        try std.testing.expectEqual(matching, stored.indexes[0].unique);
        try std.testing.expectEqualStrings(if (matching) "email" else "slug", stored.options.auth.identityFields[0]);
        try w.exec("INSERT INTO slugs(id,account,slug) VALUES('first','shared','one');");
        if (matching) {
            try expectConstraint(w, "INSERT INTO slugs(id,account,slug) VALUES('second','shared','two');");
        } else {
            try w.exec("INSERT INTO slugs(id,account,slug) VALUES('second','shared','two');");
        }
    };
}

test "changed legacy identity declarations are refused, not recorded (sqlite)" {
    try changedLegacyIdentityDeclaration(.sqlite);
}

test "changed legacy identity declarations are refused, not recorded (postgres)" {
    try changedLegacyIdentityDeclaration(.postgres);
}

test "PostgreSQL identity uniqueness follows column collation including nondeterministic ICU" {
    const a = std.testing.allocator;
    var c = try Conn.open(.postgres, "identity_column_collation");
    defer c.deinit();
    const w = &c.db;
    const identity = @import("auth_identity_index.zig");
    try w.exec("CREATE COLLATION identity_ci (provider=icu, locale='und-u-ks-level2', deterministic=false);");
    try w.exec("CREATE TABLE members(id TEXT, email TEXT COLLATE identity_ci);");
    try identity.ensure(a, w, "members", "email");
    try w.exec("INSERT INTO members VALUES('alice','Alice@example.com');");
    try expectConstraint(w, "INSERT INTO members VALUES('other','alice@example.com');");
    const col = schema.Collection{ .id = "", .name = "members", .type = .auth, .fields = &.{} };
    const found = (try @import("api/auth.zig").findByIdentity(a, w, col, "alice@example.com")).?;
    defer a.free(found);
    try std.testing.expectEqualStrings("alice", found);
    try std.testing.expect(try identity.verify(a, w, "members", "email"));
    try w.exec("DROP INDEX idx_auth_members_email;");
    try w.exec("CREATE UNIQUE INDEX idx_auth_members_email ON members(email COLLATE \"C\") WHERE email != '';");
    try w.exec("INSERT INTO members VALUES('other','alice@example.com');");
    try std.testing.expectEqual(@as(i64, 2), try count(w, "SELECT count(*) FROM members WHERE email='Alice@example.com' AND email!='';"));
    try std.testing.expectError(error.AuthIdentityIndexConflict, identity.verify(a, w, "members", "email"));
}
