//! Conservative ownership checks for objects an offline rename removes or renames.
//! Names alone never establish ownership. Public helpers are self-freeing; private
//! scratch graphs use an explicit offline arena owned by those public helpers.
//! The caller holds the schema transaction through all three rename phases.
const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const ddl = @import("ddl.zig");
const fts = @import("search/fts.zig");

pub const Error = db.DbError || std.mem.Allocator.Error || fts.EnsureIndexError || error{Conflict};

/// Run before touching even the schema-lock table: temporary metadata tables
/// can shadow that lookup too. Offline renames require a clean migration session.
pub fn rejectTemporaryRelations(w: *db.Db) Error!void {
    var st = try w.prepare(if (db.dbDialect(w).kind == .sqlite)
        "SELECT 1 FROM sqlite_temp_schema LIMIT 1;"
    else
        "SELECT 1 FROM pg_class WHERE relnamespace=pg_my_temp_schema() LIMIT 1;");
    defer st.finalize();
    if (try st.step()) return error.Conflict;
}

pub fn preflight(alloc: std.mem.Allocator, w: *db.Db, old: schema.Collection, to: []const u8) Error!void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    if (db.dbDialect(w).kind == .sqlite) {
        try sqliteSearch(&arena, w, old, to);
        return sqliteAuthIndexes(&arena, w, old, to, false);
    }
    const a = arena.allocator();
    // All existing engine DDL resolves unqualified identifiers. Pin that scope
    // to the registry's current persistent schema rather than accept a table
    // reached only through a later search_path entry.
    var scope = try prepare(a, w, "SELECT 1 FROM pg_class t JOIN pg_class registry ON registry.oid=to_regclass('_collections') WHERE t.oid=to_regclass(?1) AND t.relkind IN ('r','p') AND t.relnamespace=registry.relnamespace AND t.relnamespace=current_schema()::regnamespace;");
    defer scope.finalize();
    try scope.bindText(1, try ddl.quoteIdent(a, old.name));
    if (!try scope.step()) return error.Conflict;
    {
        // Reserve the destination-derived name even before search is enabled:
        // later provisioning must not adopt a pre-existing user-data column.
        var destination = try prepare(a, w, "SELECT 1 FROM pg_attribute WHERE attrelid=to_regclass(?1) AND attname=?2 AND attnum>0 AND NOT attisdropped;");
        defer destination.finalize();
        try destination.bindText(1, try ddl.quoteIdent(a, old.name));
        try destination.bindText(2, try fts.tableName(a, to));
        if (try destination.step()) return error.Conflict;
    }
    try postgresSearch(&arena, w, old);
    try authIndexes(&arena, w, old, to, false);
}

pub fn renameAuthIndexes(alloc: std.mem.Allocator, w: *db.Db, old: schema.Collection, to: []const u8) Error!void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    if (db.dbDialect(w).kind == .sqlite) return sqliteAuthIndexes(&arena, w, old, to, true);
    try authIndexes(&arena, w, old, to, true);
}

fn prepare(a: std.mem.Allocator, w: *db.Db, sql: []const u8) Error!db.Stmt {
    const lowered = try db.dbDialect(w).renumberPlaceholders(a, sql);
    defer a.free(lowered);
    return w.prepare(lowered);
}

fn sqliteObjects(a: std.mem.Allocator, w: *db.Db, ft: []const u8) Error!db.Stmt {
    var st = try prepare(a, w, "SELECT name,type,tbl_name,sql FROM sqlite_schema WHERE name=?1 COLLATE NOCASE OR substr(name,1,length(?1)+1)=?1||'_' COLLATE NOCASE OR tbl_name=?1 COLLATE NOCASE OR substr(tbl_name,1,length(?1)+1)=?1||'_' COLLATE NOCASE ORDER BY name;");
    errdefer st.finalize();
    try st.bindText(1, ft);
    return st;
}

fn sqliteSearch(scratch: *std.heap.ArenaAllocator, w: *db.Db, old: schema.Collection, to: []const u8) Error!void {
    const a = scratch.allocator();
    // sqlite_schema reports virtual tables as 'table'. table_list distinguishes
    // ordinary engine tables from extension-owned virtual and shadow tables.
    var source = try prepare(a, w, "SELECT 1 FROM pragma_table_list WHERE schema='main' AND type='table' AND name=?1;");
    defer source.finalize();
    try source.bindText(1, old.name);
    if (!try source.step()) return error.Conflict;
    const ft = try fts.tableName(a, old.name);
    // SQLite rewrites references to the renamed *base* table, not references
    // to the FTS table we drop and rebuild. Conservatively reject mentions in
    // arbitrary SQL definitions, including quoted names, comments and literals:
    // proving arbitrary user SQL's dependency semantics is not this helper's job.
    // Destination mentions can be dangling today; creating that generated
    // table would silently attach application SQL to the engine's new index.
    var dependent = try prepare(a, w, "SELECT 1 FROM main.sqlite_schema WHERE type IN ('trigger','view') AND name NOT IN (?1||'_ai',?1||'_ad',?1||'_au') AND (instr(lower(sql),lower(?1))>0 OR instr(lower(sql),lower(?2))>0) LIMIT 1;");
    defer dependent.finalize();
    try dependent.bindText(1, ft);
    try dependent.bindText(2, try fts.tableName(a, to));
    if (try dependent.step()) return error.Conflict;
    var actual = try sqliteObjects(a, w, ft);
    defer actual.finalize();
    if (!try actual.step()) return;
    if (!fts.enabled or !fts.isSearchable(old)) return error.Conflict;

    // Generate the expected catalog with the engine itself, on an empty private
    // database. This includes the FTS5 shadow tables and exact trigger bodies,
    // without duplicating their DDL here or treating an ordinary table as FTS.
    var model = try db.Db.openMemory();
    defer model.close();
    try model.exec(try a.dupeZ(u8, try ddl.createTableSql(a, old, null, db.dbDialect(&model), &.{})));
    try fts.ensureIndex(a, &model, old);
    var expected = try sqliteObjects(a, &model, ft);
    defer expected.finalize();
    while (true) {
        if (!try expected.step()) return error.Conflict;
        for (0..4) |i| {
            const n: c_int = @intCast(i);
            if (actual.isNull(n) != expected.isNull(n) or !std.mem.eql(u8, actual.columnText(n), expected.columnText(n))) return error.Conflict;
        }
        if (!try actual.step()) break;
    }
    if (try expected.step()) return error.Conflict;
}

fn sqliteAuthIndexes(scratch: *std.heap.ArenaAllocator, w: *db.Db, old: schema.Collection, to: []const u8, mutate: bool) Error!void {
    if (old.type != .auth) return;
    const a = scratch.allocator();
    // Compare catalog SQL generated by SQLite itself, including its rewrite of
    // the table reference during ALTER TABLE. No textual SQL normalization or
    // ownership-by-name can accidentally adopt a migration-owned index.
    var model = try db.Db.openMemory();
    defer model.close();
    try model.exec(try a.dupeZ(u8, try ddl.createTableSql(a, old, null, db.dbDialect(&model), &.{})));
    for (old.options.auth.identityFields) |field| try model.exec(try a.dupeZ(u8, try ddl.authIdentityIndexSql(a, old.name, field)));
    if (mutate) try model.exec(try std.fmt.allocPrintSentinel(a, "ALTER TABLE {s} RENAME TO {s};", .{ try ddl.quoteIdent(a, old.name), try ddl.quoteIdent(a, to) }, 0));
    for (old.options.auth.identityFields) |field| {
        const source_name = try std.fmt.allocPrint(a, "idx_auth_{s}_{s}", .{ old.name, field });
        const destination_name = try std.fmt.allocPrint(a, "idx_auth_{s}_{s}", .{ to, field });
        const exists = check_source: {
            var source = try prepare(a, w, "SELECT type,tbl_name,sql FROM main.sqlite_schema WHERE name=?1 COLLATE NOCASE;");
            defer source.finalize();
            try source.bindText(1, source_name);
            if (!try source.step()) break :check_source false;
            var expected = try prepare(a, &model, "SELECT type,tbl_name,sql FROM main.sqlite_schema WHERE name=?1;");
            defer expected.finalize();
            try expected.bindText(1, source_name);
            if (!try expected.step()) return error.Conflict;
            for (0..3) |i| {
                const column: c_int = @intCast(i);
                if (source.isNull(column) != expected.isNull(column) or !std.mem.eql(u8, source.columnText(column), expected.columnText(column))) return error.Conflict;
            }
            break :check_source true;
        };
        {
            var destination = try prepare(a, w, "SELECT 1 FROM main.sqlite_schema WHERE name=?1 COLLATE NOCASE;");
            defer destination.finalize();
            try destination.bindText(1, destination_name);
            if (try destination.step()) return error.Conflict;
        }
        if (mutate) {
            try w.exec(try a.dupeZ(u8, try ddl.authIdentityIndexSql(a, to, field)));
            if (exists) try w.exec(try std.fmt.allocPrintSentinel(a, "DROP INDEX main.{s};", .{try ddl.quoteIdent(a, source_name)}, 0));
        }
    }
}

fn postgresSearch(scratch: *std.heap.ArenaAllocator, w: *db.Db, old: schema.Collection) Error!void {
    const a = scratch.allocator();
    const table = try ddl.quoteIdent(a, old.name);
    const ft = try fts.tableName(a, old.name);
    const index = try std.fmt.allocPrint(a, "{s}_idx", .{ft});
    var column = try prepare(a, w, "SELECT a.attnum,a.attgenerated='s' AND a.atttypid='pg_catalog.tsvector'::regtype,col_description(a.attrelid,a.attnum),d.oid " ++
        "FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum " ++
        "WHERE a.attrelid=to_regclass(?1) AND a.attname=?2 AND a.attnum>0 AND NOT a.attisdropped;");
    defer column.finalize();
    try column.bindText(1, table);
    try column.bindText(2, ft);
    const present = try column.step();
    const idx = try indexOid(a, w, table, index);
    var visible = try prepare(a, w, "SELECT to_regclass(?1)::oid;");
    defer visible.finalize();
    try visible.bindText(1, try ddl.quoteIdent(a, index));
    if (!try visible.step()) return error.Conflict;
    // DROP INDEX resolves through search_path even when this table's expected
    // index is absent. A visible unrelated relation must never be dropped.
    if (!visible.isNull(0) and (idx == null or visible.columnInt(0) != idx.?)) return error.Conflict;
    if (!present) {
        if (idx != null) return error.Conflict;
        return;
    }
    if (!fts.isSearchable(old) or column.columnInt(1) != 1 or column.isNull(3)) return error.Conflict;
    var names: std.ArrayList([]const u8) = .empty;
    for (old.fields) |field| if (field.searchable and schema.isSearchableType(field.fieldType()) and schema.isValidIdentifier(field.name) and !field.encrypted) try names.append(a, field.name);
    // Expression order is declaration order. Only sort after it has been
    // verified: the separate marker intentionally represents an unordered set.
    try postgresExpression(scratch, w, table, column.columnInt(0), names.items);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    const marker = try std.fmt.allocPrint(a, "zbfts:{s}", .{try std.mem.join(a, ",", names.items)});
    if (!std.mem.eql(u8, column.columnText(2), marker)) return error.Conflict;
    if (idx) |oid| {
        var check = try prepare(a, w, "SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid JOIN pg_am am ON am.oid=c.relam " ++
            "JOIN pg_opclass op ON op.oid=i.indclass[0] WHERE i.indexrelid=?1 AND i.indrelid=to_regclass(?2) " ++
            "AND NOT i.indisunique AND i.indisvalid AND i.indnatts=1 AND i.indnkeyatts=1 AND i.indkey[0]=?3 " ++
            "AND i.indexprs IS NULL AND i.indpred IS NULL AND am.amname='gin' AND op.opcname='tsvector_ops' AND op.opcnamespace='pg_catalog'::regnamespace;");
        defer check.finalize();
        try check.bindInt(1, oid);
        try check.bindText(2, table);
        try check.bindInt(3, column.columnInt(0));
        if (!try check.step()) return error.Conflict;
    }
    // DROP COLUMN implicitly drops dependent indexes/constraints, even without
    // CASCADE. Only its own generated expression and the validated engine GIN
    // may depend on this column; migration-owned dependents must survive.
    var deps = try prepare(a, w, "SELECT 1 FROM pg_depend WHERE refclassid='pg_class'::regclass AND refobjid=to_regclass(?1) AND refobjsubid=?2 " ++
        "AND NOT (classid='pg_attrdef'::regclass AND objid=?3) AND NOT (classid='pg_class'::regclass AND objid=?4) LIMIT 1;");
    defer deps.finalize();
    try deps.bindText(1, table);
    try deps.bindInt(2, column.columnInt(0));
    try deps.bindInt(3, column.columnInt(3));
    try deps.bindInt(4, idx orelse 0);
    if (try deps.step()) return error.Conflict;
}

fn postgresExpression(scratch: *std.heap.ArenaAllocator, w: *db.Db, table: []const u8, attnum: i64, names: []const []const u8) Error!void {
    const a = scratch.allocator();
    // Ask this server to canonicalize the engine expression, rather than bake in
    // pg_get_expr whitespace/cast/parenthesis formatting across server versions.
    // No rows are copied. A name collision fails CREATE without touching that
    // object; any failure is rolled back by the caller's schema transaction.
    var create: std.ArrayList(u8) = .empty;
    try create.appendSlice(a, "CREATE TEMP TABLE zb_rename_fts_probe (");
    var expr: std.ArrayList(u8) = .empty;
    try expr.appendSlice(a, "to_tsvector('simple', ");
    for (names, 0..) |name, i| {
        try create.appendSlice(a, try std.fmt.allocPrint(a, "{s} TEXT,", .{try ddl.quoteIdent(a, name)}));
        if (i > 0) try expr.appendSlice(a, " || ' ' || ");
        try expr.appendSlice(a, try std.fmt.allocPrint(a, "coalesce({s},'')", .{try ddl.quoteIdent(a, name)}));
    }
    try expr.appendSlice(a, ")");
    // The engine reserves underscore-prefixed field names, avoiding collision
    // with any searchable field copied into this private probe table.
    try create.appendSlice(a, try std.fmt.allocPrint(a, "_expected TSVECTOR GENERATED ALWAYS AS ({s}) STORED) ON COMMIT DROP;", .{expr.items}));
    try w.exec(try a.dupeZ(u8, create.items));
    var compare = try prepare(a, w, "SELECT pg_get_expr(actual.adbin,actual.adrelid)=pg_get_expr(expected.adbin,expected.adrelid) " ++
        "FROM pg_attrdef actual,pg_attrdef expected WHERE actual.adrelid=to_regclass(?1) AND actual.adnum=?2 " ++
        "AND expected.adrelid='pg_temp.zb_rename_fts_probe'::regclass;");
    defer compare.finalize();
    try compare.bindText(1, table);
    try compare.bindInt(2, attnum);
    const matches = try compare.step() and compare.columnInt(0) == 1;
    try w.exec("DROP TABLE pg_temp.zb_rename_fts_probe;");
    if (!matches) return error.Conflict;
}

fn indexOid(a: std.mem.Allocator, w: *db.Db, table: []const u8, name: []const u8) Error!?i64 {
    var st = try prepare(a, w, "SELECT c.oid FROM pg_class c JOIN pg_class t ON t.relnamespace=c.relnamespace WHERE t.oid=to_regclass(?1) AND c.relname=?2;");
    defer st.finalize();
    try st.bindText(1, table);
    try st.bindText(2, name);
    if (!try st.step()) return null;
    return st.columnInt(0);
}

/// Borrowed arena slice, including when PostgreSQL truncates the allocation.
fn authName(scratch: *std.heap.ArenaAllocator, table: []const u8, field: []const u8) Error![]const u8 {
    const name = try std.fmt.allocPrint(scratch.allocator(), "idx_auth_{s}_{s}", .{ table, field });
    // Collection/field names are ASCII identifiers. PostgreSQL truncates the
    // *whole composite identifier*, not either constituent, to 63 bytes.
    return name[0..@min(name.len, 63)];
}

fn authIndexes(scratch: *std.heap.ArenaAllocator, w: *db.Db, old: schema.Collection, to: []const u8, mutate: bool) Error!void {
    const a = scratch.allocator();
    if (old.type != .auth) return;
    const table = try ddl.quoteIdent(a, if (mutate) to else old.name);
    for (old.options.auth.identityFields, 0..) |field, i| {
        const from_idx = try authName(scratch, old.name, field);
        const to_idx = try authName(scratch, to, field);
        // A distinct old name must become free for a future auth collection;
        // retaining its truncated index name would steal that collection's
        // CREATE INDEX IF NOT EXISTS and silently omit identity uniqueness.
        if (!std.mem.eql(u8, old.name, to) and std.mem.eql(u8, from_idx, to_idx)) return error.Conflict;
        // Distinct identities must not collapse onto one truncated name.
        for (old.options.auth.identityFields[0..i]) |prior| {
            if (std.mem.eql(u8, to_idx, try authName(scratch, to, prior)) or std.mem.eql(u8, from_idx, try authName(scratch, old.name, prior))) return error.Conflict;
        }
        const oid = try indexOid(a, w, table, from_idx);
        const destination = try indexOid(a, w, table, to_idx);
        if (destination != null and (oid == null or destination.? != oid.?)) return error.Conflict;
        if (oid == null) continue; // Provisioning may restore a missing index.
        var check = try prepare(a, w, "SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid JOIN pg_am am ON am.oid=c.relam " ++
            "JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=i.indkey[0] " ++
            "WHERE i.indexrelid=?1 AND i.indrelid=to_regclass(?2) AND a.attname=?3 AND i.indisunique AND i.indisvalid " ++
            "AND i.indnatts=1 AND i.indnkeyatts=1 AND i.indexprs IS NULL AND am.amname='btree' " ++
            "AND pg_get_expr(i.indpred,i.indrelid)=format('(%I <> %L::text)',a.attname,'') " ++
            "AND NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conindid=i.indexrelid);");
        defer check.finalize();
        try check.bindInt(1, oid.?);
        try check.bindText(2, table);
        try check.bindText(3, field);
        if (!try check.step()) return error.Conflict;
        if (mutate and !std.mem.eql(u8, from_idx, to_idx)) {
            // Resolve the index's schema explicitly; search_path may contain an
            // unrelated same-name index before the collection's own schema.
            var ns = try prepare(a, w, "SELECT n.nspname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.oid=?1;");
            defer ns.finalize();
            try ns.bindInt(1, oid.?);
            if (!try ns.step()) return error.Conflict;
            try w.exec(try std.fmt.allocPrintSentinel(a, "ALTER INDEX {s}.{s} RENAME TO {s};", .{ try ddl.quoteIdent(a, ns.columnText(0)), try ddl.quoteIdent(a, from_idx), try ddl.quoteIdent(a, to_idx) }, 0));
        }
    }
}

test "rename preflight refuses a migration-owned search table without deleting data" {
    var w = try db.Db.openMemory();
    defer w.close();
    try w.exec("CREATE TABLE posts(id TEXT); CREATE TABLE posts_fts(note TEXT); INSERT INTO posts_fts VALUES('keep');");
    const col = schema.Collection{ .id = "p", .name = "posts", .fields = &.{} };
    try std.testing.expectError(error.Conflict, preflight(std.testing.allocator, &w, col, "articles"));
    var row = try w.prepare("SELECT note FROM posts_fts;");
    defer row.finalize();
    try std.testing.expect(try row.step());
    try std.testing.expectEqualStrings("keep", row.columnText(0));
}

test "rename preflight recognizes engine FTS and rejects an extra dependent trigger" {
    if (!fts.enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    var w = try db.Db.openMemory();
    defer w.close();
    const col = schema.Collection{ .id = "p", .name = "posts", .fields = &.{.{ .id = "t", .name = "title", .searchable = true, .options = .{ .text = .{} } }} };
    try w.exec("CREATE TABLE posts(id TEXT PRIMARY KEY,title TEXT);");
    try fts.ensureIndex(a, &w, col);
    try preflight(a, &w, col, "articles");
    try w.exec("CREATE VIEW future_search AS SELECT rowid FROM [ARTICLES_FTS];");
    try std.testing.expectError(error.Conflict, preflight(a, &w, col, "articles"));
    try w.exec("DROP VIEW future_search; CREATE TRIGGER future_sync AFTER INSERT ON posts BEGIN INSERT INTO articles_fts(rowid,title) VALUES(new.rowid,new.title); END;");
    try std.testing.expectError(error.Conflict, preflight(a, &w, col, "articles"));
    try w.exec("DROP TRIGGER future_sync;");
    try preflight(a, &w, col, "articles");
    try w.exec("CREATE VIEW custom_search AS SELECT rowid FROM \"posts_fts\";");
    try std.testing.expectError(error.Conflict, preflight(a, &w, col, "articles"));
    try w.exec("DROP VIEW custom_search; CREATE TRIGGER custom_sync AFTER INSERT ON posts BEGIN SELECT count(*) FROM [POSTS_FTS]; END;");
    try std.testing.expectError(error.Conflict, preflight(a, &w, col, "articles"));
    try w.exec("DROP TRIGGER custom_sync;");
    try w.exec("CREATE TRIGGER keep_data AFTER INSERT ON posts_fts_data BEGIN SELECT 1; END;");
    try std.testing.expectError(error.Conflict, preflight(a, &w, col, "articles"));
    try w.exec("DROP TRIGGER keep_data; CREATE INDEX keep_shadow_index ON posts_fts_data(block);");
    try std.testing.expectError(error.Conflict, preflight(a, &w, col, "articles"));
    try w.exec("DROP INDEX keep_shadow_index; DROP TRIGGER posts_fts_ai; CREATE TRIGGER posts_fts_ai AFTER INSERT ON posts BEGIN SELECT 1; END;");
    try std.testing.expectError(error.Conflict, preflight(a, &w, col, "articles"));
}

test "SQLite auth rename moves only verified engine indexes and preserves uniqueness" {
    const a = std.testing.allocator;
    var w = try db.Db.openMemory();
    defer w.close();
    try @import("migrations.zig").run(&w);
    const collections = @import("collections.zig");
    const rename = @import("collection_rename.zig").rename;
    const users = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "users", .type = .auth, .fields = &.{} });
    defer users.deinit(a);
    try w.exec("INSERT INTO users(id,email) VALUES('u1','first@example.com'); CREATE INDEX keep_user_index ON users(email);");
    try w.exec("CREATE TABLE IDX_AUTH_PEOPLE_EMAIL(note TEXT);");
    try std.testing.expectError(error.Conflict, rename(a, std.testing.io, &w, "users", "people"));
    try w.exec("DROP TABLE idx_auth_people_email; DROP INDEX idx_auth_users_email; CREATE UNIQUE INDEX idx_auth_users_email ON users(email);");
    try std.testing.expectError(error.Conflict, rename(a, std.testing.io, &w, "users", "people"));
    try w.exec("DROP INDEX idx_auth_users_email;");
    const restore = try ddl.authIdentityIndexSql(a, "users", "email");
    defer a.free(restore);
    const restore_z = try a.dupeZ(u8, restore);
    defer a.free(restore_z);
    try w.exec(restore_z);
    try rename(a, std.testing.io, &w, "users", "people");
    try std.testing.expectError(error.ExecFailed, w.exec("INSERT INTO people(id,email) VALUES('u2','first@example.com');"));
    {
        var indexes = try w.prepare("SELECT name FROM sqlite_schema WHERE type='index' AND tbl_name='people' AND name LIKE 'idx_auth_%';");
        defer indexes.finalize();
        try std.testing.expect(try indexes.step());
        try std.testing.expectEqualStrings("idx_auth_people_email", indexes.columnText(0));
        try std.testing.expect(!try indexes.step());
    }
    // Immutable namespace reservations forbid a fresh owner adopting the old
    // prefix, but no obsolete auth index may remain attached to the live table.
    try std.testing.expectError(error.StorageNamespaceConflict, collections.create(a, std.testing.io, &w, .{ .id = "", .name = "users", .type = .auth, .fields = &.{} }));
    {
        var old_index = try w.prepare("SELECT 1 FROM sqlite_schema WHERE name='idx_auth_users_email';");
        defer old_index.finalize();
        try std.testing.expect(!try old_index.step());
    }
    try rename(a, std.testing.io, &w, "people", "accounts");
    var indexes = try w.prepare("SELECT name FROM sqlite_schema WHERE type='index' AND tbl_name='accounts' AND name NOT LIKE 'sqlite_%' ORDER BY name;");
    defer indexes.finalize();
    try std.testing.expect(try indexes.step());
    try std.testing.expectEqualStrings("idx_auth_accounts_email", indexes.columnText(0));
    try std.testing.expect(try indexes.step());
    try std.testing.expectEqualStrings("keep_user_index", indexes.columnText(0));
    try std.testing.expect(!try indexes.step());
}

test "SQLite rename rejects registered virtual table sources without module mutation" {
    if (!fts.enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    var w = try db.Db.openMemory();
    defer w.close();
    try @import("migrations.zig").run(&w);
    const collections = @import("collections.zig");
    const docs = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "docs", .fields = &.{} });
    defer docs.deinit(a);
    try w.exec("DROP TABLE docs; CREATE VIRTUAL TABLE docs USING fts5(id,title); INSERT INTO docs(id,title) VALUES('r1','keep');");
    const before = try @import("schema_gen.zig").read(&w);
    try std.testing.expectError(error.Conflict, @import("collection_rename.zig").rename(a, std.testing.io, &w, "docs", "articles"));
    try std.testing.expectEqual(before, try @import("schema_gen.zig").read(&w));
    var kept = try w.prepare("SELECT title FROM docs WHERE id='r1';");
    defer kept.finalize();
    try std.testing.expect(try kept.step());
    try std.testing.expectEqualStrings("keep", kept.columnText(0));
    const unchanged = (try collections.getByName(a, &w, "docs")).?;
    defer unchanged.deinit(a);
    try std.testing.expectEqualStrings(docs.id, unchanged.id);
    try std.testing.expectEqual(@as(i64, 0), unchanged.rename_epoch);
}

test "SQLite searchable rename can shorten a name contained in its old engine triggers" {
    if (!fts.enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    var w = try db.Db.openMemory();
    defer w.close();
    try @import("migrations.zig").run(&w);
    const col = try @import("collections.zig").create(a, std.testing.io, &w, .{ .id = "", .name = "foobar", .fields = &.{.{ .id = "titleid", .name = "title", .searchable = true, .options = .{ .text = .{} } }} });
    defer col.deinit(a);
    try fts.ensureIndex(a, &w, col);
    try w.exec("INSERT INTO foobar(id,title) VALUES('r1','kept');");
    try @import("collection_rename.zig").rename(a, std.testing.io, &w, "foobar", "bar");
    var found = try w.prepare("SELECT title FROM bar_fts WHERE bar_fts MATCH 'kept';");
    defer found.finalize();
    try std.testing.expect(try found.step());
    try std.testing.expectEqualStrings("kept", found.columnText(0));
}

test "pg: rename provenance preserves identity index OID and refuses owned-data collisions" {
    if (comptime !@import("build_options").postgres) return error.SkipZigTest;
    const url = std.testing.environ.getPosix("ZIGBASE_PG_TEST_URL") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    var w = try db.Db.openPostgres(a, std.testing.io, url);
    defer w.close();
    try w.exec("CREATE SCHEMA zb_rename_index_tests;");
    defer w.exec("DROP SCHEMA zb_rename_index_tests CASCADE;") catch |err| std.log.err("rename index test schema cleanup failed: {s}", .{@errorName(err)});
    try w.exec("SET search_path TO zb_rename_index_tests;");
    try @import("migrations.zig").run(&w);
    try w.begin();
    defer w.rollback() catch |err| std.log.err("rename index test rollback failed: {s}", .{@errorName(err)});
    const collections = @import("collections.zig");
    const long_source = "x" ** 54 ++ "a";
    const long_destination = "x" ** 54 ++ "b";
    const long_auth = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = long_source, .type = .auth, .fields = &.{} });
    defer long_auth.deinit(a);
    const before_long = try @import("schema_gen.zig").read(&w);
    try std.testing.expectError(error.Conflict, @import("collection_rename.zig").rename(a, std.testing.io, &w, long_source, long_destination));
    try std.testing.expectEqual(before_long, try @import("schema_gen.zig").read(&w));
    const retained = (try collections.getByName(a, &w, long_source)).?;
    defer retained.deinit(a);
    try std.testing.expectEqualStrings(long_auth.id, retained.id);
    try std.testing.expectEqual(@as(i64, 0), retained.rename_epoch);
    try std.testing.expect((try collections.getByName(a, &w, long_destination)) == null);
    const plain = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "plain", .fields = &.{.{ .id = "userfield", .name = "future_fts", .options = .{ .text = .{} } }} });
    defer plain.deinit(a);
    try w.exec("INSERT INTO plain(id,future_fts) VALUES('p1','user data');");
    const before_plain = try @import("schema_gen.zig").read(&w);
    try std.testing.expectError(error.Conflict, @import("collection_rename.zig").rename(a, std.testing.io, &w, "plain", "future"));
    try std.testing.expectEqual(before_plain, try @import("schema_gen.zig").read(&w));
    {
        var kept = try w.prepare("SELECT future_fts FROM plain WHERE id='p1';");
        defer kept.finalize();
        try std.testing.expect(try kept.step());
        try std.testing.expectEqualStrings("user data", kept.columnText(0));
    }
    const users = try collections.create(a, std.testing.io, &w, .{
        .id = "",
        .name = "users",
        .type = .auth,
        .fields = &.{.{ .id = "handleid", .name = "handle", .options = .{ .text = .{} } }},
        .options = .{ .auth = .{ .identityFields = &.{ "email", "handle" } } },
    });
    defer users.deinit(a);
    const original = (try indexOid(a, &w, "users", "idx_auth_users_email")).?;
    try std.testing.expectError(error.Conflict, preflight(a, &w, users, "x" ** 55));
    try w.exec("CREATE TABLE idx_auth_people_email(note TEXT); INSERT INTO idx_auth_people_email VALUES('keep');");
    try std.testing.expectError(error.Conflict, preflight(a, &w, users, "people"));
    try w.exec("DROP TABLE idx_auth_people_email;");
    try preflight(a, &w, users, "people");
    try w.exec("ALTER TABLE users RENAME TO people;");
    try renameAuthIndexes(a, &w, users, "people");
    try std.testing.expectEqual(original, (try indexOid(a, &w, "people", "idx_auth_people_email")).?);
    try std.testing.expect((try indexOid(a, &w, "people", "idx_auth_users_email")) == null);
    const ensure = try ddl.authIdentityIndexSql(a, "people", "email");
    defer a.free(ensure);
    const ensure_z = try a.dupeZ(u8, ensure);
    defer a.free(ensure_z);
    try w.exec(ensure_z);
    try std.testing.expectEqual(original, (try indexOid(a, &w, "people", "idx_auth_people_email")).?);
    // A same-name but differently defined unique index is not engine-owned.
    try w.exec("DROP INDEX idx_auth_people_handle; CREATE UNIQUE INDEX idx_auth_people_handle ON people(handle);");
    var people = users;
    people.name = "people";
    try std.testing.expectError(error.Conflict, preflight(a, &w, people, "accounts"));

    const posts = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "posts", .fields = &.{.{ .id = "titleid", .name = "title", .searchable = true, .options = .{ .text = .{} } }} });
    defer posts.deinit(a);
    try w.exec("ALTER TABLE posts ADD COLUMN posts_fts TEXT; INSERT INTO posts(id,posts_fts) VALUES('r1','keep');");
    try std.testing.expectError(error.Conflict, preflight(a, &w, posts, "articles"));
    var saved = try w.prepare("SELECT posts_fts FROM posts;");
    defer saved.finalize();
    try std.testing.expect(try saved.step());
    try std.testing.expectEqualStrings("keep", saved.columnText(0));
    try w.exec("ALTER TABLE posts DROP COLUMN posts_fts;");
    try fts.ensureIndex(a, &w, posts);
    try preflight(a, &w, posts, "articles");
    try w.exec("ALTER TABLE posts ADD COLUMN articles_fts TEXT; UPDATE posts SET articles_fts='destination data';");
    try std.testing.expectError(error.Conflict, preflight(a, &w, posts, "articles"));
    var preserved = try w.prepare("SELECT articles_fts FROM posts;");
    defer preserved.finalize();
    try std.testing.expect(try preserved.step());
    try std.testing.expectEqualStrings("destination data", preserved.columnText(0));
    try w.exec("ALTER TABLE posts DROP COLUMN articles_fts;");
    // PostgreSQL transactionally rolls back CREATE TEMP TABLE, including after
    // a later error aborts the subtransaction. No ON COMMIT action is needed.
    try w.exec("SAVEPOINT probe_error; CREATE TEMP TABLE zb_rename_fts_probe(v INT) ON COMMIT DROP;");
    try std.testing.expectError(error.ExecFailed, w.exec("SELECT 1/0;"));
    try w.exec("ROLLBACK TO SAVEPOINT probe_error; RELEASE SAVEPOINT probe_error;");
    var absent = try w.prepare("SELECT 1 FROM pg_class WHERE relnamespace=pg_my_temp_schema() AND relname='zb_rename_fts_probe';");
    defer absent.finalize();
    try std.testing.expect(!try absent.step());
    try preflight(a, &w, posts, "articles");
    // Temporary source/destination/metadata names are rejected before any DDL.
    try w.exec("CREATE TEMP TABLE posts(note TEXT);");
    try std.testing.expectError(error.Conflict, @import("collection_rename.zig").rename(a, std.testing.io, &w, "posts", "articles"));
    try w.exec("DROP TABLE pg_temp.posts; CREATE TEMP TABLE articles(note TEXT);");
    try std.testing.expectError(error.Conflict, @import("collection_rename.zig").rename(a, std.testing.io, &w, "posts", "articles"));
    try w.exec("DROP TABLE pg_temp.articles; CREATE TEMP TABLE _schema_state(note TEXT);");
    try std.testing.expectError(error.Conflict, @import("collection_rename.zig").rename(a, std.testing.io, &w, "posts", "articles"));
    try w.exec("DROP TABLE pg_temp._schema_state;");
    // The actual engine GIN is missing, but an unrelated index is visible.
    try w.exec("DROP INDEX posts_fts_idx; CREATE TEMP TABLE shadow_holder(v INT); CREATE INDEX posts_fts_idx ON shadow_holder(v);");
    try std.testing.expectError(error.Conflict, preflight(a, &w, posts, "articles"));
    try w.exec("DROP TABLE pg_temp.shadow_holder;");
    try fts.ensureIndex(a, &w, posts);
    try w.exec("CREATE INDEX migration_search ON posts USING gin(posts_fts);");
    try std.testing.expectError(error.Conflict, preflight(a, &w, posts, "articles"));
    try w.exec("DROP INDEX migration_search; DROP INDEX posts_fts_idx; CREATE INDEX posts_fts_idx ON posts(title);");
    try std.testing.expectError(error.Conflict, preflight(a, &w, posts, "articles"));
    try w.exec("DROP INDEX posts_fts_idx; ALTER TABLE posts DROP COLUMN posts_fts; ALTER TABLE posts ADD COLUMN posts_fts TSVECTOR GENERATED ALWAYS AS (to_tsvector('simple','custom')) STORED; COMMENT ON COLUMN posts.posts_fts IS 'zbfts:title';");
    try std.testing.expectError(error.Conflict, preflight(a, &w, posts, "articles"));
    try w.exec("CREATE VIEW view_source AS SELECT 1 AS id; CREATE SEQUENCE sequence_source;");
    for ([_][]const u8{ "view_source", "sequence_source" }) |name| {
        const invalid = schema.Collection{ .id = "invalid", .name = name, .fields = &.{} };
        try std.testing.expectError(error.Conflict, preflight(a, &w, invalid, "renamed_source"));
    }
    const ordered = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "ordered", .fields = &.{
        .{ .id = "zfield", .name = "z", .searchable = true, .options = .{ .text = .{} } },
        .{ .id = "afield", .name = "a", .searchable = true, .options = .{ .text = .{} } },
    } });
    defer ordered.deinit(a);
    try fts.ensureIndex(a, &w, ordered);
    try w.exec("INSERT INTO ordered(id,z,a) VALUES('r1','zeta','alpha');");
    try @import("collection_rename.zig").rename(a, std.testing.io, &w, "ordered", "renamed_ordered");
    var search = try w.prepare("SELECT id FROM renamed_ordered WHERE renamed_ordered_fts @@ plainto_tsquery('simple','zeta alpha');");
    defer search.finalize();
    try std.testing.expect(try search.step());
    try std.testing.expectEqualStrings("r1", search.columnText(0));
}
