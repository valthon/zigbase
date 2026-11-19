//! Verify identity enforcement before adopting a name owned by a migration.
const std = @import("std");
const db = @import("db.zig");
const ddl = @import("ddl.zig");

pub const Error = db.DbError || std.mem.Allocator.Error || error{AuthIdentityIndexConflict};
threadlocal var message_buf: [2048]u8 = undefined;
pub threadlocal var last_error: []const u8 = "";

fn refuse(table: []const u8, field: []const u8, name: []const u8) error{AuthIdentityIndexConflict} {
    last_error = std.mem.print(&message_buf, "Collection '{s}', identity field '{s}': index '{s}' has an incompatible or unreadable definition; refusing identity enforcement. Object preserved; explicitly migrate it to a unique index on exactly this field WHERE the field != '', then retry.", .{ table[0..@min(table.len, 256)], field[0..@min(field.len, 256)], name[0..@min(name.len, 768)] }) catch unreachable;
    std.log.warn("{s}", .{last_error});
    return error.AuthIdentityIndexConflict;
}

/// Self-freeing. Missing indexes are allowed during preflight; existing ones must match.
pub fn verify(alloc: std.mem.Allocator, w: *db.Db, table: []const u8, field: []const u8) Error!bool {
    const full_name = try ddl.authIdentityIndexName(alloc, table, field);
    defer alloc.free(full_name);
    return verifyNamed(alloc, w, table, field, full_name);
}

/// Self-freeing. Rename checks an old index name after the table itself has moved.
pub fn verifyNamed(alloc: std.mem.Allocator, w: *db.Db, table: []const u8, field: []const u8, full_name: []const u8) Error!bool {
    const pg = db.dbDialect(w).kind == .postgres;
    const name = ddl.physicalIdentifier(full_name, pg);
    const matches = (if (pg) matchesPg(alloc, w, table, field, name) else matchesSqlite(alloc, w, table, field, name)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return refuse(table, field, name),
    };
    return matches orelse return refuse(table, field, name);
}

/// Self-freeing ownership probe: absent or incompatible objects are not ours.
/// Catalog errors propagate so callers cannot destroy an unreadable object.
pub fn owns(alloc: std.mem.Allocator, w: *db.Db, table: []const u8, field: []const u8) Error!bool {
    const full_name = try ddl.authIdentityIndexName(alloc, table, field);
    defer alloc.free(full_name);
    const pg = db.dbDialect(w).kind == .postgres;
    const name = ddl.physicalIdentifier(full_name, pg);
    return (try (if (pg) matchesPg(alloc, w, table, field, name) else matchesSqlite(alloc, w, table, field, name))) orelse false;
}

/// Self-freeing. Caller holds the schema transaction/lock through verification and DDL.
pub fn ensure(alloc: std.mem.Allocator, w: *db.Db, table: []const u8, field: []const u8) Error!void {
    if (try verify(alloc, w, table, field)) return;
    const sql = try ddl.authIdentityIndexSql(alloc, table, field);
    defer alloc.free(sql);
    const sql_z = try alloc.dupeSentinel(u8, sql, 0);
    defer alloc.free(sql_z);
    try w.exec(sql_z);
    // Also refuse a concurrent same-name creation rather than trust IF NOT EXISTS.
    if (!try verify(alloc, w, table, field)) {
        const name = try ddl.authIdentityIndexName(alloc, table, field);
        defer alloc.free(name);
        return refuse(table, field, name);
    }
}

// Self-freeing. null = conflicting, false = absent, true = matching.
fn matchesPg(a: std.mem.Allocator, w: *db.Db, table: []const u8, field: []const u8, name: []const u8) Error!?bool {
    const quoted_table = try ddl.quoteIdent(a, ddl.physicalIdentifier(table, true));
    defer a.free(quoted_table);
    // Unqualified DDL must never adopt or create enforcement on a temporary shadow.
    var shadow = try w.prepare("SELECT 1 FROM pg_class WHERE oid=to_regclass($1) AND relpersistence='t';");
    defer shadow.finalize();
    try shadow.bindText(1, quoted_table);
    if (try shadow.step()) return null;
    var st = try w.prepare("SELECT (i.indrelid=to_regclass($2) AND t.relnamespace=n.relnamespace AND i.indisunique AND i.indisvalid AND i.indisready AND i.indislive " ++
        "AND i.indnatts=1 AND i.indnkeyatts=1 AND i.indexprs IS NULL AND am.amname='btree' AND att.attname=$3 " ++
        "AND i.indoption[0]=0 AND op.opcdefault AND i.indcollation[0]=att.attcollation " ++
        "AND NOT COALESCE((to_jsonb(i)->>'indnullsnotdistinct')::boolean,false) " ++
        "AND pg_get_expr(i.indpred,i.indrelid)=format('(%I <> %L::text)',att.attname,'') " ++
        "AND NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conindid=n.oid))::int " ++
        "FROM pg_class n LEFT JOIN pg_index i ON i.indexrelid=n.oid LEFT JOIN pg_class t ON t.oid=i.indrelid " ++
        "LEFT JOIN pg_am am ON am.oid=n.relam LEFT JOIN pg_attribute att ON att.attrelid=t.oid AND att.attnum=i.indkey[0] " ++
        "LEFT JOIN pg_opclass op ON op.oid=i.indclass[0] WHERE n.relnamespace=(SELECT relnamespace FROM pg_class WHERE oid=to_regclass($2)) AND n.relname=$1;");
    defer st.finalize();
    try st.bindText(1, name);
    try st.bindText(2, quoted_table);
    try st.bindText(3, ddl.physicalIdentifier(field, true));
    if (!try st.step()) return false;
    if (st.isNull(0) or st.columnInt(0) != 1) return null;
    if (try st.step()) return null;
    return true;
}

fn matchesSqlite(a: std.mem.Allocator, w: *db.Db, table: []const u8, field: []const u8, name: []const u8) Error!?bool {
    var shadow = try w.prepare("SELECT 1 FROM sqlite_temp_schema WHERE type IN ('table','view','index') AND (name=?1 COLLATE NOCASE OR name=?2 COLLATE NOCASE);");
    defer shadow.finalize();
    try shadow.bindText(1, table);
    try shadow.bindText(2, name);
    if (try shadow.step()) return null;
    var st = try w.prepare("SELECT type,tbl_name,sql FROM main.sqlite_schema WHERE type IN ('table','view','index') AND name=?1 COLLATE NOCASE;");
    defer st.finalize();
    try st.bindText(1, name);
    if (!try st.step()) return false;
    if (!std.mem.eql(u8, st.columnText(0), "index") or !std.mem.eql(u8, st.columnText(1), table) or st.isNull(2)) return null;
    const sql = st.columnText(2);
    const where = @import("sql/schema_check.zig").firstKeyword(sql, &.{"WHERE"}) orelse return null;
    const offset = @intFromPtr(where.ptr) - @intFromPtr(sql.ptr) + where.len;
    if (!try nonEmptyPredicate(a, sql[offset..], field)) return null;
    if (try st.step()) return null;
    // Same catalog checks as ordinary-index adoption, with partial=1.
    var props = try w.prepare("SELECT \"unique\",origin,partial FROM pragma_index_list(?1,'main') WHERE name=?2 COLLATE NOCASE;");
    defer props.finalize();
    try props.bindText(1, table);
    try props.bindText(2, name);
    if (!try props.step() or props.columnInt(0) != 1 or !std.mem.eql(u8, props.columnText(1), "c") or props.columnInt(2) != 1) return null;
    var cols = try w.prepare("SELECT name,\"desc\",coll FROM pragma_index_xinfo(?1,'main') WHERE key=1 ORDER BY seqno;");
    defer cols.finalize();
    try cols.bindText(1, name);
    if (!try cols.step() or !std.mem.eql(u8, cols.columnText(0), field) or cols.columnInt(1) != 0 or !std.ascii.eqlIgnoreCase(cols.columnText(2), "binary")) return null;
    if (try cols.step()) return null;
    // Authentication's ordinary equality and non-empty guard inherit the column
    // collation. BINARY uniqueness cannot protect a NOCASE/RTRIM comparison.
    // Keep .nocase opt-in on BINARY columns, where a separate declared unique
    // index supplies the stronger uniqueness used by findByField.
    const table_z = try a.dupeSentinel(u8, table, 0);
    defer a.free(table_z);
    const field_z = try a.dupeSentinel(u8, field, 0);
    defer a.free(field_z);
    const c = @import("c.zig").c;
    var collation: [*c]const u8 = null;
    if (c.sqlite3_table_column_metadata(db.sqliteHandle(w), "main", table_z, field_z, null, &collation, null, null, null) != c.SQLITE_OK or collation == null) return null;
    if (!std.ascii.eqlIgnoreCase(std.mem.span(collation), "binary")) return null;
    return true;
}

// Keywords can denote literals or other expressions rather than column references.
// Require quoting for every SQLite keyword, plus its non-keyword boolean literals.
fn bareSqliteIdentifier(field: []const u8) bool {
    if (!@import("schema.zig").isValidIdentifier(field)) return false;
    const len = std.math.cast(c_int, field.len) orelse return false;
    return @import("c.zig").c.sqlite3_keyword_check(field.ptr, len) == 0 and
        !std.ascii.eqlIgnoreCase(field, "true") and !std.ascii.eqlIgnoreCase(field, "false");
}

/// A deliberately narrow equivalence check: identifier !=/<> empty string,
/// allowing whitespace, identifier quoting and redundant parentheses. Catalog SQL
/// has already been parsed by SQLite. Every other token (including comments) refuses.
fn nonEmptyPredicate(a: std.mem.Allocator, text: []const u8, field: []const u8) std.mem.Allocator.Error!bool {
    const quoted = try ddl.quoteIdent(a, field);
    defer a.free(quoted);
    const backtick = try a.print("`{s}`", .{field});
    defer a.free(backtick);
    const bracket = try a.print("[{s}]", .{field});
    defer a.free(bracket);
    var rest = text;
    var token: usize = 0;
    var depth: usize = 0;
    while (rest.len != 0) {
        if (std.ascii.isWhitespace(rest[0])) {
            rest = rest[1..];
            continue;
        }
        if (rest[0] == '(') {
            // Parentheses may wrap operands/the comparison, but cannot call
            // a function with the same name as the identity column.
            if (token == 1 or token == 3) return false;
            depth += 1;
            rest = rest[1..];
            continue;
        }
        if (rest[0] == ')') {
            if (depth == 0 or token == 0 or token == 2) return false;
            depth -= 1;
            rest = rest[1..];
            continue;
        }
        const len: usize = switch (token) {
            0 => blk: {
                for ([_][]const u8{ quoted, backtick, bracket }) |candidate| {
                    if (std.mem.startsWith(u8, rest, candidate)) break :blk candidate.len;
                }
                if (bareSqliteIdentifier(field) and std.mem.startsWith(u8, rest, field)) break :blk field.len;
                return false;
            },
            1 => if (std.mem.startsWith(u8, rest, "!=") or std.mem.startsWith(u8, rest, "<>")) 2 else return false,
            2 => if (std.mem.startsWith(u8, rest, "''")) 2 else return false,
            else => return std.mem.eql(u8, std.mem.trim(u8, rest, " \t\r\n"), ";") and depth == 0,
        };
        rest = rest[len..];
        token += 1;
    }
    return token == 3 and depth == 0;
}

test "identity predicate equivalence refuses function calls and extra SQL" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "email != ''", " ((\"email\") <> ('')) ;", "[email] != ''", "`email` != ''" }) |predicate| {
        try std.testing.expect(try nonEmptyPredicate(a, predicate, "email"));
    }
    for ([_][]const u8{ "email() != ''", "(email)() != ''", "email != '' OR 1", "email != 'x'", "other != ''", "email != '' -- comment", "email != '' COLLATE NOCASE", "email != '' AND email IS NOT NULL" }) |predicate| {
        try std.testing.expect(!try nonEmptyPredicate(a, predicate, "email"));
    }
}

test "SQLite identity predicate keywords and literal names require quoting" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "null", "NULL", "true", "FALSE", "current_time", "CURRENT_DATE", "current_timestamp", "select" }) |field| {
        const bare = try a.print("{s} != ''", .{field});
        defer a.free(bare);
        try std.testing.expect(!try nonEmptyPredicate(a, bare, field));
        for ([_][]const u8{ "\"{s}\" != ''", "`{s}` != ''", "[{s}] != ''" }) |fmt| {
            const quoted = try std.mem.replaceOwned(u8, a, fmt, "{s}", field);
            defer a.free(quoted);
            try std.testing.expect(try nonEmptyPredicate(a, quoted, field));
        }
    }
}
