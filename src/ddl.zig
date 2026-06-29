//! Pure SQL string generation from schema types.
//!
//! All functions allocate into the supplied `alloc` and assume it is an
//! arena: intermediate fragments (quoted idents, column defs, allocPrint
//! results) are appended into the returned buffer but not individually freed.
//! The engine creates one arena per operation, so this is leak-free in
//! practice. Identifiers come from names already validated by
//! `schema.isValidIdentifier` (letters/digits/underscore only), so inline
//! `"{s}"` interpolation is injection-safe; `quoteIdent` is available for
//! defensive quoting where escaping might matter.

const std = @import("std");
const schema = @import("schema.zig");
const dialect = @import("sql/dialect.zig");

pub fn quoteIdent(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '"');
    for (name) |ch| {
        if (ch == '"') try out.append(alloc, '"');
        try out.append(alloc, ch);
    }
    try out.append(alloc, '"');
    return out.toOwnedSlice(alloc);
}

pub fn columnDef(alloc: std.mem.Allocator, f: schema.Field, d: dialect.Dialect) ![]u8 {
    const ty = d.sqlType(f.storageClass());
    if (f.unique) return std.fmt.allocPrint(alloc, "\"{s}\" {s} UNIQUE", .{ f.name, ty });
    return std.fmt.allocPrint(alloc, "\"{s}\" {s}", .{ f.name, ty });
}

pub fn createTableSql(alloc: std.mem.Allocator, c: schema.Collection, single_rel_target: ?[]const u8, d: dialect.Dialect) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "CREATE TABLE ");
    const tbl = try quoteIdent(alloc, c.name);
    try out.appendSlice(alloc, tbl);
    try out.appendSlice(alloc, " (\"id\" TEXT PRIMARY KEY, \"created\" TEXT, \"updated\" TEXT");
    for (c.fields) |f| {
        try out.appendSlice(alloc, ", ");
        try out.appendSlice(alloc, try columnDef(alloc, f, d));
    }
    for (c.fields) |f| {
        switch (f.options) {
            .relation => |r| if (r.maxSelect == 1) {
                const target = single_rel_target orelse r.targetCollectionId;
                const on_delete = if (r.cascadeDelete) "CASCADE" else "SET NULL";
                try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, ", FOREIGN KEY (\"{s}\") REFERENCES \"{s}\" (\"id\") ON DELETE {s}", .{ f.name, target, on_delete }));
            },
            else => {},
        }
    }
    try out.appendSlice(alloc, ");");
    return out.toOwnedSlice(alloc);
}

pub fn createIndexSql(alloc: std.mem.Allocator, table: []const u8, idx: schema.Index, d: dialect.Dialect) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    // Case-insensitive collation routes through the dialect: SQLite ` COLLATE NOCASE`; Postgres
    // has no built-in NOCASE collation, so the suffix is "" there (a `citext`/`lower()` expression
    // index is the portable route — a documented PR-10/follow-up; PR-2 keeps the index valid).
    const collate = switch (idx.collation) {
        .binary => "",
        .nocase => d.collateNocase(),
    };
    try out.appendSlice(alloc, if (idx.unique) "CREATE UNIQUE INDEX " else "CREATE INDEX ");
    try out.appendSlice(alloc, try quoteIdent(alloc, idx.name));
    try out.appendSlice(alloc, " ON ");
    try out.appendSlice(alloc, try quoteIdent(alloc, table));
    try out.append(alloc, ' ');
    try out.append(alloc, '(');
    for (idx.fields, 0..) |fname, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, try quoteIdent(alloc, fname));
        try out.appendSlice(alloc, collate);
    }
    try out.append(alloc, ')');
    if (idx.where) |w| {
        const trimmed = std.mem.trim(u8, w, " \t\r\n");
        if (trimmed.len > 0) {
            try out.appendSlice(alloc, " WHERE ");
            try out.appendSlice(alloc, trimmed);
        }
    }
    try out.append(alloc, ';');
    return out.toOwnedSlice(alloc);
}

/// A partial UNIQUE index enforcing identity uniqueness only over non-empty values:
///   CREATE UNIQUE INDEX IF NOT EXISTS "idx_auth_<table>_<field>" ON "<table>" ("<field>") WHERE "<field>" != '';
/// `table` and `field` are validated schema identifiers (injection-safe), but we quote them anyway.
pub fn authIdentityIndexSql(alloc: std.mem.Allocator, table: []const u8, field: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "CREATE UNIQUE INDEX IF NOT EXISTS \"idx_auth_{s}_{s}\" ON \"{s}\" (\"{s}\") WHERE \"{s}\" != '';",
        .{ table, field, table, field, field },
    );
}

/// Produce the ordered DDL statements that migrate a collection's physical table from `old` to
/// `new`, matching retained columns by **stable field id** (`of.id == nf.id`) so data survives a
/// rename/retype. SQLite (which cannot drop/retype a column in place pre-3.35) does this via a
/// table rebuild — create `<name>__new`, copy, drop, rename, reindex. Postgres does it with
/// targeted `ALTER TABLE ADD/RENAME/ALTER TYPE/DROP COLUMN` against the live table (no rebuild),
/// keyed off the same id matching — see `rebuildPlanPg`.
pub fn rebuildPlan(alloc: std.mem.Allocator, old: schema.Collection, new: schema.Collection, d: dialect.Dialect) ![]const []u8 {
    if (d.kind == .postgres) return rebuildPlanPg(alloc, old, new, d);

    var stmts: std.ArrayList([]u8) = .empty;
    errdefer stmts.deinit(alloc);

    const tmp = try std.fmt.allocPrint(alloc, "{s}__new", .{new.name});
    var tmp_col = new;
    tmp_col.name = tmp;
    try stmts.append(alloc, try createTableSql(alloc, tmp_col, null, d));

    var new_cols: std.ArrayList(u8) = .empty;
    var src_cols: std.ArrayList(u8) = .empty;
    try new_cols.appendSlice(alloc, "\"id\",\"created\",\"updated\"");
    try src_cols.appendSlice(alloc, "\"id\",\"created\",\"updated\"");
    for (new.fields) |nf| {
        try new_cols.append(alloc, ',');
        try new_cols.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\"{s}\"", .{nf.name}));
        try src_cols.append(alloc, ',');
        const old_match = blk: {
            for (old.fields) |of| {
                if (std.mem.eql(u8, of.id, nf.id)) break :blk of;
            }
            break :blk null;
        };
        if (old_match) |of| {
            if (of.storageClass() == nf.storageClass()) {
                try src_cols.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\"{s}\"", .{of.name}));
            } else {
                try src_cols.appendSlice(alloc, try std.fmt.allocPrint(alloc, "CAST(\"{s}\" AS {s})", .{ of.name, d.sqlType(nf.storageClass()) }));
            }
        } else {
            try src_cols.appendSlice(alloc, "NULL");
        }
    }
    try stmts.append(alloc, try std.fmt.allocPrint(alloc, "INSERT INTO \"{s}\" ({s}) SELECT {s} FROM \"{s}\";", .{ tmp, new_cols.items, src_cols.items, old.name }));
    try stmts.append(alloc, try std.fmt.allocPrint(alloc, "DROP TABLE \"{s}\";", .{old.name}));
    try stmts.append(alloc, try std.fmt.allocPrint(alloc, "ALTER TABLE \"{s}\" RENAME TO \"{s}\";", .{ tmp, new.name }));
    for (new.indexes) |idx| try stmts.append(alloc, try createIndexSql(alloc, new.name, idx, d));
    return stmts.toOwnedSlice(alloc);
}

/// Postgres rebuild via in-place `ALTER TABLE`. Statement order is significant:
///   1. DROP every column whose old field id is absent from `new` (data loss matches the SQLite
///      rebuild, which simply does not copy it).
///   2. For each new field, keyed by id: RENAME a retained-but-renamed column, then ALTER its TYPE
///      (`USING` cast) if the storage class changed; ADD a brand-new column (with `USING`-free
///      default NULL), wiring a FK for an added single relation.
///   3. DROP-and-recreate every declared index (covers renamed columns + new indexes; the live
///      table's pre-existing indexes are dropped IF EXISTS first so re-running is safe).
/// Retained columns keep their data; the table is never dropped.
fn rebuildPlanPg(alloc: std.mem.Allocator, old: schema.Collection, new: schema.Collection, d: dialect.Dialect) ![]const []u8 {
    var stmts: std.ArrayList([]u8) = .empty;
    errdefer stmts.deinit(alloc);
    const tbl = new.name;

    // 1. Drops: an old field whose id is not present in `new`.
    for (old.fields) |of| {
        const kept = blk: {
            for (new.fields) |nf| if (std.mem.eql(u8, of.id, nf.id)) break :blk true;
            break :blk false;
        };
        if (!kept) try stmts.append(alloc, try std.fmt.allocPrint(alloc, "ALTER TABLE \"{s}\" DROP COLUMN IF EXISTS \"{s}\";", .{ tbl, of.name }));
    }

    // 2. Adds / renames / type changes, keyed by stable field id.
    for (new.fields) |nf| {
        const ty = d.sqlType(nf.storageClass());
        const old_match = blk: {
            for (old.fields) |of| if (std.mem.eql(u8, of.id, nf.id)) break :blk of;
            break :blk null;
        };
        if (old_match) |of| {
            if (!std.mem.eql(u8, of.name, nf.name))
                try stmts.append(alloc, try std.fmt.allocPrint(alloc, "ALTER TABLE \"{s}\" RENAME COLUMN \"{s}\" TO \"{s}\";", .{ tbl, of.name, nf.name }));
            if (of.storageClass() != nf.storageClass())
                try stmts.append(alloc, try std.fmt.allocPrint(alloc, "ALTER TABLE \"{s}\" ALTER COLUMN \"{s}\" TYPE {s} USING (\"{s}\"::{s});", .{ tbl, nf.name, ty, nf.name, ty }));
        } else {
            const uniq = if (nf.unique) " UNIQUE" else "";
            try stmts.append(alloc, try std.fmt.allocPrint(alloc, "ALTER TABLE \"{s}\" ADD COLUMN IF NOT EXISTS \"{s}\" {s}{s};", .{ tbl, nf.name, ty, uniq }));
            switch (nf.options) {
                .relation => |r| if (r.maxSelect == 1) {
                    const on_delete = if (r.cascadeDelete) "CASCADE" else "SET NULL";
                    // `new` is relation-resolved by the caller: targetCollectionId is the table name.
                    try stmts.append(alloc, try std.fmt.allocPrint(alloc, "ALTER TABLE \"{s}\" ADD CONSTRAINT \"fk_{s}_{s}\" FOREIGN KEY (\"{s}\") REFERENCES \"{s}\" (\"id\") ON DELETE {s};", .{ tbl, tbl, nf.name, nf.name, r.targetCollectionId, on_delete }));
                },
                else => {},
            }
        }
    }

    // 3. Indexes: drop-if-exists + recreate so they track renamed columns and new declarations.
    for (new.indexes) |idx| {
        try stmts.append(alloc, try std.fmt.allocPrint(alloc, "DROP INDEX IF EXISTS \"{s}\";", .{idx.name}));
        try stmts.append(alloc, try createIndexSql(alloc, tbl, idx, d));
    }
    return stmts.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "createTableSql includes system columns, field columns, and FK for single relation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fields = [_]schema.Field{
        .{ .id = "a", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "b", .name = "price", .options = .{ .number = .{ .mode = .float } } },
        .{ .id = "c", .name = "author", .options = .{ .relation = .{ .targetCollectionId = "users", .cascadeDelete = true, .maxSelect = 1 } } },
    };
    const col = schema.Collection{ .id = "c1", .name = "posts", .fields = &fields };
    const sql = try createTableSql(a, col, "users", .sqlite);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"id\" TEXT PRIMARY KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"created\" TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"title\" TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"price\" REAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "FOREIGN KEY (\"author\") REFERENCES \"users\" (\"id\") ON DELETE CASCADE") != null);
}

test "createIndexSql builds unique and non-unique" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try createIndexSql(a, "posts", .{ .name = "idx_title", .fields = &.{"title"}, .unique = true }, .sqlite);
    try std.testing.expectEqualStrings("CREATE UNIQUE INDEX \"idx_title\" ON \"posts\" (\"title\");", u);
    const n = try createIndexSql(a, "posts", .{ .name = "idx_ab", .fields = &.{ "a", "b" }, .unique = false }, .sqlite);
    try std.testing.expectEqualStrings("CREATE INDEX \"idx_ab\" ON \"posts\" (\"a\",\"b\");", n);
}

test "createIndexSql emits COLLATE NOCASE and a partial WHERE predicate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ci = try createIndexSql(a, "customers", .{ .name = "idx_email", .fields = &.{"email"}, .unique = true, .collation = .nocase }, .sqlite);
    try std.testing.expectEqualStrings("CREATE UNIQUE INDEX \"idx_email\" ON \"customers\" (\"email\" COLLATE NOCASE);", ci);
    const partial = try createIndexSql(a, "posts", .{ .name = "idx_active", .fields = &.{"slug"}, .unique = true, .where = "deleted_at IS NULL" }, .sqlite);
    try std.testing.expectEqualStrings("CREATE UNIQUE INDEX \"idx_active\" ON \"posts\" (\"slug\") WHERE deleted_at IS NULL;", partial);
    // collation applies per-column, predicate follows the column list
    const both = try createIndexSql(a, "t", .{ .name = "idx_both", .fields = &.{ "a", "b" }, .collation = .nocase, .where = "a IS NOT NULL" }, .sqlite);
    try std.testing.expectEqualStrings("CREATE INDEX \"idx_both\" ON \"t\" (\"a\" COLLATE NOCASE,\"b\" COLLATE NOCASE) WHERE a IS NOT NULL;", both);
    // an empty or whitespace-only predicate emits no WHERE clause (not "WHERE ;")
    const empty = try createIndexSql(a, "t", .{ .name = "idx_e", .fields = &.{"a"}, .where = "" }, .sqlite);
    try std.testing.expectEqualStrings("CREATE INDEX \"idx_e\" ON \"t\" (\"a\");", empty);
    const ws = try createIndexSql(a, "t", .{ .name = "idx_w", .fields = &.{"a"}, .where = "  \t\n" }, .sqlite);
    try std.testing.expectEqualStrings("CREATE INDEX \"idx_w\" ON \"t\" (\"a\");", ws);
    // Postgres: no built-in NOCASE collation, so the suffix is dropped (index stays valid).
    const pg_ci = try createIndexSql(a, "customers", .{ .name = "idx_email", .fields = &.{"email"}, .unique = true, .collation = .nocase }, .postgres);
    try std.testing.expectEqualStrings("CREATE UNIQUE INDEX \"idx_email\" ON \"customers\" (\"email\");", pg_ci);
}

test "rebuildPlan copies retained columns by field id, adds new, drops removed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old_fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "old_price", .options = .{ .number = .{ .mode = .float } } },
    };
    const new_fields = [_]schema.Field{
        .{ .id = "f1", .name = "headline", .options = .{ .text = .{} } },
        .{ .id = "f3", .name = "views", .options = .{ .number = .{ .mode = .int } } },
    };
    const old = schema.Collection{ .id = "c1", .name = "posts", .fields = &old_fields };
    const new = schema.Collection{ .id = "c1", .name = "posts", .fields = &new_fields };
    const plan = try rebuildPlan(a, old, new, .sqlite);
    // No indexes in the fixture, so the plan is exactly: create, insert, drop, rename.
    try std.testing.expectEqual(@as(usize, 4), plan.len);
    try std.testing.expect(std.mem.indexOf(u8, plan[0], "\"posts__new\"") != null);
    const insert = plan[1];
    try std.testing.expect(std.mem.indexOf(u8, insert, "INSERT INTO \"posts__new\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, insert, "\"headline\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, insert, "\"title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan[2], "DROP TABLE \"posts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan[3], "RENAME TO \"posts\"") != null);
}

test "rebuildPlan (Postgres) emits in-place ALTERs keyed by field id (rename, add, drop)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old_fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "old_price", .options = .{ .number = .{ .mode = .float } } },
    };
    const new_fields = [_]schema.Field{
        .{ .id = "f1", .name = "headline", .options = .{ .text = .{} } }, // retained, renamed
        .{ .id = "f3", .name = "views", .options = .{ .number = .{ .mode = .int } } }, // added
    };
    const old = schema.Collection{ .id = "c1", .name = "posts", .fields = &old_fields };
    const new = schema.Collection{ .id = "c1", .name = "posts", .fields = &new_fields };
    const plan = try rebuildPlan(a, old, new, .postgres);
    // No table rebuild: targeted ALTERs only — drop old_price, rename title->headline, add views.
    var saw_drop = false;
    var saw_rename = false;
    var saw_add = false;
    for (plan) |s| {
        if (std.mem.indexOf(u8, s, "DROP COLUMN IF EXISTS \"old_price\"") != null) saw_drop = true;
        if (std.mem.indexOf(u8, s, "RENAME COLUMN \"title\" TO \"headline\"") != null) saw_rename = true;
        if (std.mem.indexOf(u8, s, "ADD COLUMN IF NOT EXISTS \"views\" BIGINT") != null) saw_add = true;
        // never a destructive table rebuild on Postgres
        try std.testing.expect(std.mem.indexOf(u8, s, "DROP TABLE") == null);
        try std.testing.expect(std.mem.indexOf(u8, s, "__new") == null);
    }
    try std.testing.expect(saw_drop and saw_rename and saw_add);
}

test "authIdentityIndexSql builds a partial unique index over non-empty values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sql = try authIdentityIndexSql(a, "users", "email");
    try std.testing.expectEqualStrings(
        "CREATE UNIQUE INDEX IF NOT EXISTS \"idx_auth_users_email\" ON \"users\" (\"email\") WHERE \"email\" != '';",
        sql,
    );
}
