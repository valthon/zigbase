//! Shared catalog ownership checks before search objects are adopted or removed.
const std = @import("std");
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const ddl = @import("../ddl.zig");
const fts = @import("fts.zig");

pub const Error = db.DbError || std.mem.Allocator.Error || error{ Conflict, SearchDisabled };

/// Self-freeing. A rename destination requires the current declared shape and
/// checks dangling destination references; null verifies the old physical shape
/// for ordinary provisioning before reconciling a new spec.
pub fn verify(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection, rename_to: ?[]const u8) Error!void {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const a = scratch.allocator();
    // Destructive DDL is unqualified. A temporary object must not shadow the
    // persistent table/index whose ownership the catalog checks establish.
    if (db.dbDialect(w).kind == .sqlite) {
        var temporary = try prepare(a, w, "SELECT 1 FROM sqlite_temp_schema WHERE name=?1 COLLATE NOCASE OR name=?2 COLLATE NOCASE OR substr(name,1,length(?2)+1)=?2||'_' COLLATE NOCASE OR (type IN ('trigger','view') AND (instr(lower(sql),lower(?2))>0 OR instr(lower(sql),lower(?3))>0)) LIMIT 1;");
        defer temporary.finalize();
        try temporary.bindText(1, col.name);
        try temporary.bindText(2, try fts.tableName(a, col.name));
        try temporary.bindText(3, try fts.tableName(a, rename_to orelse col.name));
        if (try temporary.step()) return error.Conflict;
    } else {
        var source = try prepare(a, w, "SELECT 1 FROM pg_class t LEFT JOIN pg_class registry ON registry.oid=to_regclass('_collections') " ++
            "WHERE t.oid=to_regclass(?1) AND t.relkind IN ('r','p') AND t.relpersistence<>'t' " ++
            "AND t.relnamespace=current_schema()::regnamespace AND (registry.oid IS NULL OR registry.relnamespace=t.relnamespace);");
        defer source.finalize();
        try source.bindText(1, try ddl.quoteIdent(a, col.name));
        if (!try source.step()) return error.Conflict;
        // Serialize provisioners and structural DDL without blocking ordinary
        // record reads/writes. The caller retains this lock until its schema
        // transaction ends, so a proved column cannot be replaced before DROP.
        try w.exec(try std.fmt.allocPrintSentinel(a, "LOCK TABLE {s} IN SHARE UPDATE EXCLUSIVE MODE;", .{try ddl.quoteIdent(a, col.name)}, 0));
    }
    if (db.dbDialect(w).kind == .sqlite) return sqliteSearch(&scratch, w, col, rename_to);
    return postgresSearch(&scratch, w, col, rename_to != null);
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

fn sqliteSearch(scratch: *std.heap.ArenaAllocator, w: *db.Db, old: schema.Collection, rename_to: ?[]const u8) Error!void {
    const a = scratch.allocator();
    const exact = rename_to != null;
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
    // Destination references can be dangling today. Exclude old engine sync
    // triggers from both checks, including shortening names such as foobar→bar.
    var dependent = try prepare(a, w, "SELECT 1 FROM main.sqlite_schema WHERE type IN ('trigger','view') AND name NOT IN (?1||'_ai',?1||'_ad',?1||'_au') AND (instr(lower(sql),lower(?1))>0 OR instr(lower(sql),lower(?2))>0) LIMIT 1;");
    defer dependent.finalize();
    try dependent.bindText(1, ft);
    try dependent.bindText(2, try fts.tableName(a, rename_to orelse old.name));
    if (try dependent.step()) return error.Conflict;
    var actual = try sqliteObjects(a, w, ft);
    defer actual.finalize();
    if (!try actual.step()) return;
    if (!fts.enabled or (exact and !fts.isSearchable(old))) return error.Conflict;
    var physical = old;
    if (!exact) {
        var fields: std.ArrayList(schema.Field) = .empty;
        var columns = try prepare(a, w, try std.fmt.allocPrint(a, "PRAGMA main.table_info({s});", .{try ddl.quoteIdent(a, ft)}));
        defer columns.finalize();
        var base_column = try prepare(a, w, "SELECT 1 FROM pragma_table_info(?1,'main') WHERE name=?2 AND upper(type)='TEXT' LIMIT 1;");
        defer base_column.finalize();
        while (try columns.step()) {
            const name = columns.columnText(1);
            if (!schema.isValidIdentifier(name)) return error.Conflict;
            // The external-content table is not proof that its operands exist.
            // Infer old search flags only for real engine text-storage columns;
            // a missing or numeric base operand cannot be an owned search shape.
            base_column.reset();
            try base_column.clearBindings();
            try base_column.bindText(1, old.name);
            try base_column.bindText(2, name);
            if (!try base_column.step()) return error.Conflict;
            try fields.append(a, .{ .id = "", .name = try a.dupe(u8, name), .searchable = true, .options = .{ .text = .{} } });
        }
        if (fields.items.len == 0) return error.Conflict;
        physical.fields = fields.items;
        physical.indexes = &.{};
        physical.type = .base;
    }

    // Generate the expected catalog with the engine itself, on an empty private
    // database. This includes the FTS5 shadow tables and exact trigger bodies,
    // without duplicating their DDL here or treating an ordinary table as FTS.
    var model = try db.Db.openMemory();
    defer model.close();
    try model.exec(try a.dupeZ(u8, try ddl.createTableSql(a, physical, null, db.dbDialect(&model), &.{})));
    try fts.ensureIndex(a, &model, physical);
    var expected = try sqliteObjects(a, &model, ft);
    defer expected.finalize();
    var has_actual = true;
    while (try expected.step()) {
        if (!has_actual or !std.mem.eql(u8, actual.columnText(0), expected.columnText(0))) {
            // An additive table rebuild can remove just engine sync triggers.
            if (!exact and std.mem.eql(u8, expected.columnText(1), "trigger")) continue;
            return error.Conflict;
        }
        for (0..4) |i| {
            const n: c_int = @intCast(i);
            if (actual.isNull(n) != expected.isNull(n) or !std.mem.eql(u8, actual.columnText(n), expected.columnText(n))) return error.Conflict;
        }
        has_actual = try actual.step();
    }
    if (has_actual) return error.Conflict;
}

fn postgresSearch(scratch: *std.heap.ArenaAllocator, w: *db.Db, old: schema.Collection, exact: bool) Error!void {
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
    if ((exact and !fts.isSearchable(old)) or column.columnInt(1) != 1 or column.isNull(3)) return error.Conflict;
    var names: std.ArrayList([]const u8) = .empty;
    if (exact) {
        for (old.fields) |field| if (field.searchable and schema.isSearchableType(field.fieldType()) and schema.isValidIdentifier(field.name) and !field.encrypted) try names.append(a, field.name);
    } else {
        const marker = column.columnText(2);
        if (!std.mem.startsWith(u8, marker, "zbfts:")) return error.Conflict;
        var parts = std.mem.splitScalar(u8, marker[6..], ',');
        while (parts.next()) |name| {
            if (!schema.isValidIdentifier(name)) return error.Conflict;
            for (names.items) |existing| if (std.mem.eql(u8, existing, name)) return error.Conflict;
            try names.append(a, name);
        }
        var expression = try prepare(a, w, "SELECT pg_get_expr(adbin,adrelid) FROM pg_attrdef WHERE oid=?1;");
        defer expression.finalize();
        try expression.bindInt(1, column.columnInt(3));
        if (!try expression.step()) return error.Conflict;
        names = try expressionOrder(scratch, expression.columnText(0), names.items);
    }
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

// Arena-scoped scratch: infer only operand order, never ownership, from tokens.
// The server-canonicalized full expression comparison below is authoritative.
fn expressionOrder(scratch: *std.heap.ArenaAllocator, sql: []const u8, names: []const []const u8) Error!std.ArrayList([]const u8) {
    const a = scratch.allocator();
    var ordered: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < sql.len) {
        if (sql[i] == '\'') {
            i += 1;
            while (i < sql.len) : (i += 1) {
                if (sql[i] != '\'') continue;
                if (i + 1 < sql.len and sql[i + 1] == '\'') {
                    i += 1;
                    continue;
                }
                i += 1;
                break;
            }
            continue;
        }
        const quoted = sql[i] == '"';
        if (!quoted and !std.ascii.isAlphabetic(sql[i]) and sql[i] != '_') {
            i += 1;
            continue;
        }
        if (quoted) i += 1;
        const begin = i;
        while (i < sql.len and (if (quoted) sql[i] != '"' else std.ascii.isAlphanumeric(sql[i]) or sql[i] == '_')) : (i += 1) {}
        const token = sql[begin..i];
        if (quoted and i < sql.len) i += 1;
        var after = i;
        while (after < sql.len and std.ascii.isWhitespace(sql[after])) : (after += 1) {}
        if (!quoted and ((after < sql.len and sql[after] == '(') or (begin > 0 and sql[begin - 1] == ':'))) continue;
        for (names) |name| {
            if (!std.mem.eql(u8, token, name)) continue;
            for (ordered.items) |seen| if (std.mem.eql(u8, seen, name)) return error.Conflict;
            try ordered.append(a, name);
        }
    }
    if (ordered.items.len != names.len) return error.Conflict;
    return ordered;
}

fn postgresExpression(scratch: *std.heap.ArenaAllocator, w: *db.Db, table: []const u8, attnum: i64, names: []const []const u8) Error!void {
    const a = scratch.allocator();
    var occupied = try prepare(a, w, "SELECT 1 FROM pg_class WHERE relnamespace=pg_my_temp_schema() AND relname='zb_rename_fts_probe';");
    defer occupied.finalize();
    if (try occupied.step()) return error.Conflict;
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
