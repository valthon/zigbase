//! Full-text search (Theme A / #157) — FTS5 external-content index provisioning + the read-path
//! search predicate that composes INTO `records.list`.
//!
//! A collection becomes SEARCHABLE when at least one of its text/editor fields sets the
//! `.searchable` schema flag. At startup `ensureIndex` provisions an **external-content** FTS5
//! shadow table (`"<col>_fts"`, `content='<col>'`) plus AFTER INSERT/UPDATE/DELETE triggers that
//! keep it in lock-step with the base table — so the base table stays the single source of truth
//! and the index storage isn't doubled. The index is (re)populated with the FTS5 `'rebuild'`
//! command on first provision.
//!
//! THE CRITICAL INVARIANT (#157): search is a READ path. `build` returns a JOIN + a bound `MATCH`
//! predicate that `records.list` AND-s into the SAME WHERE composition as filter + listRule +
//! ability + tenant-scope + ttl — never a separate, unscoped query. The user's terms are passed as
//! a BOUND parameter (`?`), never interpolated; `sanitize` additionally lowers them to a
//! guaranteed-valid FTS5 query (quoting each token, preserving the AND/OR/NOT operators and a
//! trailing `*` prefix) so a malformed input can never become a SQLite syntax error (500) or widen
//! visibility. Every identifier (the table name, each searchable column) is gated through
//! `schema.isValidIdentifier` before interpolation.

const std = @import("std");
const schema = @import("../schema.zig");
const db = @import("../db.zig");
const compiler = @import("../query/compiler.zig");

/// Suffix appended to a collection name to form its FTS5 shadow table. Canonical in `schema.zig`
/// (where `schema.validate` reserves it on collection names) — aliased here for the table builder.
pub const suffix = schema.fts_suffix;

/// Defensive cap on a user search term we process (bounds work; longer input is truncated).
pub const max_term_len = 256;

/// The FTS5 shadow-table name for `col_name` (`"<col_name>_fts"`), on `alloc`.
pub fn tableName(alloc: std.mem.Allocator, col_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ col_name, suffix });
}

/// True iff `col` has at least one valid, searchable column AND a valid table identifier — i.e.
/// `ensureIndex` will provision an FTS5 index and `build` can compose a MATCH predicate for it.
pub fn isSearchable(col: schema.Collection) bool {
    if (!schema.isValidIdentifier(col.name)) return false;
    for (col.fields) |f| if (f.searchable and schema.isSearchableType(f.fieldType()) and schema.isValidIdentifier(f.name) and !f.encrypted) return true;
    return false;
}

/// The searchable column names of `col` (valid identifiers, text/editor, non-encrypted), on
/// `alloc`. Empty when the collection is not searchable.
fn searchableColumns(alloc: std.mem.Allocator, col: schema.Collection) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (col.fields) |f| {
        if (f.searchable and schema.isSearchableType(f.fieldType()) and schema.isValidIdentifier(f.name) and !f.encrypted)
            try out.append(alloc, f.name);
    }
    return out.toOwnedSlice(alloc);
}

/// A compiled, parameter-bound full-text search clause AND-ed into the list query by
/// `records.list`. `join_sql` brings the FTS shadow table into the query (no params); `where_sql`
/// is the bound `MATCH` predicate (one trailing `?`); `order_sql` is the bm25 relevance ordering
/// (`"<fts>"."rank"`, best-match-first when sorted ascending). `param` is the SANITIZED, bound term.
pub const Search = struct {
    join_sql: []const u8,
    where_sql: []const u8,
    order_sql: []const u8,
    param: compiler.Param,
};

/// Build the full-text search clause for `raw_term` on `col`, or null when the collection is not
/// searchable OR the term is empty after sanitization. Allocations are on `alloc`. The returned
/// `param.text` is a guaranteed-valid FTS5 query string (see `sanitize`) — bound, never interpolated.
pub fn build(alloc: std.mem.Allocator, col: schema.Collection, raw_term: []const u8) !?Search {
    if (!isSearchable(col)) return null;
    const q = (try sanitize(alloc, raw_term)) orelse return null;
    const ft = try tableName(alloc, col.name);
    return .{
        .join_sql = try std.fmt.allocPrint(alloc, "JOIN \"{s}\" ON \"{s}\".\"rowid\" = \"{s}\".\"rowid\"", .{ ft, ft, col.name }),
        .where_sql = try std.fmt.allocPrint(alloc, "\"{s}\" MATCH ?", .{ft}),
        .order_sql = try std.fmt.allocPrint(alloc, "\"{s}\".\"rank\"", .{ft}),
        .param = .{ .text = q },
    };
}

/// Lower an arbitrary user search string into a GUARANTEED-VALID FTS5 query, or null if it carries
/// no searchable tokens. Each whitespace-delimited token is wrapped in double quotes (an embedded
/// `"` is doubled to escape it), which neutralizes any FTS5-special characters inside the token, so
/// no input can become a syntax error. The boolean operators `AND`/`OR`/`NOT` are preserved between
/// terms (leading, trailing and doubled operators are dropped so the query is always well-formed),
/// and a trailing `*` keeps prefix-search working. Space-separated terms default to FTS5's implicit
/// AND. This is defense-in-depth ON TOP OF parameter binding (which already prevents injection).
pub fn sanitize(alloc: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const capped = if (trimmed.len > max_term_len) trimmed[0..max_term_len] else trimmed;

    var out: std.ArrayList(u8) = .empty;
    var emitted_term = false;
    var pending_op: ?[]const u8 = null; // an operator seen AFTER a term, applied to the next term
    var it = std.mem.tokenizeAny(u8, capped, " \t\r\n");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "AND") or std.mem.eql(u8, tok, "OR") or std.mem.eql(u8, tok, "NOT")) {
            if (emitted_term) pending_op = tok; // a leading operator is ignored (no term yet)
            continue;
        }
        // Prefix search: a single trailing '*' is kept as an operator after the quoted token.
        var word = tok;
        var prefix = false;
        if (word.len > 1 and word[word.len - 1] == '*') {
            prefix = true;
            word = word[0 .. word.len - 1];
        }
        if (word.len == 0) continue;

        if (emitted_term) {
            // Implicit AND between adjacent terms; an explicit operator overrides it.
            if (pending_op) |op| {
                try out.append(alloc, ' ');
                try out.appendSlice(alloc, op);
                try out.append(alloc, ' ');
            } else {
                try out.append(alloc, ' ');
            }
        }
        pending_op = null;
        try out.append(alloc, '"');
        for (word) |ch| {
            if (ch == '"') try out.append(alloc, '"'); // double to escape inside an FTS5 string
            try out.append(alloc, ch);
        }
        try out.append(alloc, '"');
        if (prefix) try out.append(alloc, '*');
        emitted_term = true;
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(alloc);
}

// ---- Provisioning ----------------------------------------------------------

/// Provision (idempotently) the FTS5 external-content index + sync triggers for `col`, repopulating
/// it on first build. A no-op when `col` has no searchable fields (any stale index from a previous
/// schema is dropped). Re-creates the index when its column set drifts OR its sync triggers are
/// missing (e.g. after an additive table rebuild dropped them). Called from `provision.ensureCollection`
/// at startup — NOT a numbered migration. Identifiers are gated through `schema.isValidIdentifier`.
pub fn ensureIndex(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection) !void {
    if (!schema.isValidIdentifier(col.name)) return;
    const ft = try tableName(alloc, col.name);
    const cols = try searchableColumns(alloc, col);

    if (cols.len == 0) {
        // Not searchable: only touch the DB if a stale index actually exists (so a non-searchable
        // collection costs one cheap existence check, not four DROPs, at every startup).
        if (try tableExists(alloc, w, ft)) try dropIndex(alloc, w, col.name, ft);
        return;
    }

    if (try tableExists(alloc, w, ft)) {
        if ((try columnsMatch(alloc, w, ft, cols)) and (try triggersPresent(alloc, w, col.name)))
            return; // up to date — idempotent no-op
        try dropIndex(alloc, w, col.name, ft); // drift / missing triggers — rebuild from scratch
    }

    // CREATE VIRTUAL TABLE "<col>_fts" USING fts5(c1, c2, …, content='<col>');
    var create: std.ArrayList(u8) = .empty;
    try create.appendSlice(alloc, try std.fmt.allocPrint(alloc, "CREATE VIRTUAL TABLE \"{s}\" USING fts5(", .{ft}));
    for (cols, 0..) |cn, i| {
        if (i > 0) try create.appendSlice(alloc, ", ");
        try create.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\"{s}\"", .{cn}));
    }
    try create.appendSlice(alloc, try std.fmt.allocPrint(alloc, ", content=\"{s}\");", .{col.name}));
    try w.exec(try toZ(alloc, create.items));

    // Sync triggers (FTS5 external-content pattern). On delete/update we issue the special 'delete'
    // command so the index discards the old terms before re-indexing the new row.
    const col_list = try columnList(alloc, cols, null);
    const new_list = try columnList(alloc, cols, "new");
    const old_list = try columnList(alloc, cols, "old");

    try w.exec(try toZ(alloc, try std.fmt.allocPrint(alloc,
        "CREATE TRIGGER \"{s}_ai\" AFTER INSERT ON \"{s}\" BEGIN INSERT INTO \"{s}\"(rowid, {s}) VALUES (new.rowid, {s}); END;",
        .{ ft, col.name, ft, col_list, new_list })));
    try w.exec(try toZ(alloc, try std.fmt.allocPrint(alloc,
        "CREATE TRIGGER \"{s}_ad\" AFTER DELETE ON \"{s}\" BEGIN INSERT INTO \"{s}\"(\"{s}\", rowid, {s}) VALUES ('delete', old.rowid, {s}); END;",
        .{ ft, col.name, ft, ft, col_list, old_list })));
    try w.exec(try toZ(alloc, try std.fmt.allocPrint(alloc,
        "CREATE TRIGGER \"{s}_au\" AFTER UPDATE ON \"{s}\" BEGIN INSERT INTO \"{s}\"(\"{s}\", rowid, {s}) VALUES ('delete', old.rowid, {s}); INSERT INTO \"{s}\"(rowid, {s}) VALUES (new.rowid, {s}); END;",
        .{ ft, col.name, ft, ft, col_list, old_list, ft, col_list, new_list })));

    // Repopulate from the content table (no-op on an empty table).
    try w.exec(try toZ(alloc, try std.fmt.allocPrint(alloc, "INSERT INTO \"{s}\"(\"{s}\") VALUES ('rebuild');", .{ ft, ft })));

    std.log.info("provision: ensured FTS5 search index '{s}' on '{s}' ({d} field(s))", .{ ft, col.name, cols.len });
}

/// A comma-separated quoted column list, optionally prefixed (`new.`/`old.`) for trigger bodies.
fn columnList(alloc: std.mem.Allocator, cols: []const []const u8, comptime prefix: ?[]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (cols, 0..) |cn, i| {
        if (i > 0) try out.appendSlice(alloc, ", ");
        if (prefix) |p| {
            try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, p ++ ".\"{s}\"", .{cn}));
        } else {
            try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\"{s}\"", .{cn}));
        }
    }
    return out.toOwnedSlice(alloc);
}

/// DROP the FTS shadow table + its three sync triggers if present (idempotent).
fn dropIndex(alloc: std.mem.Allocator, w: *db.Db, col_name: []const u8, ft: []const u8) !void {
    try w.exec(try toZ(alloc, try std.fmt.allocPrint(alloc, "DROP TRIGGER IF EXISTS \"{s}_ai\";", .{ft})));
    try w.exec(try toZ(alloc, try std.fmt.allocPrint(alloc, "DROP TRIGGER IF EXISTS \"{s}_ad\";", .{ft})));
    try w.exec(try toZ(alloc, try std.fmt.allocPrint(alloc, "DROP TRIGGER IF EXISTS \"{s}_au\";", .{ft})));
    try w.exec(try toZ(alloc, try std.fmt.allocPrint(alloc, "DROP TABLE IF EXISTS \"{s}\";", .{ft})));
    _ = col_name;
}

fn tableExists(alloc: std.mem.Allocator, w: *db.Db, ft: []const u8) !bool {
    var st = try w.prepare(try toZ(alloc, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1;"));
    defer st.finalize();
    try st.bindText(1, ft);
    return st.step();
}

/// True iff the existing FTS table's indexed columns equal `want` (same set + order).
fn columnsMatch(alloc: std.mem.Allocator, w: *db.Db, ft: []const u8, want: []const []const u8) !bool {
    var st = try w.prepare(try toZ(alloc, try std.fmt.allocPrint(alloc, "PRAGMA table_info(\"{s}\");", .{ft})));
    defer st.finalize();
    var i: usize = 0;
    while (try st.step()) : (i += 1) {
        const name = st.columnText(1); // (cid, name, type, …)
        if (i >= want.len or !std.mem.eql(u8, name, want[i])) return false;
    }
    return i == want.len;
}

/// True iff all three sync triggers (`_ai`, `_ad`, `_au`) currently exist for `col_name`.
fn triggersPresent(alloc: std.mem.Allocator, w: *db.Db, col_name: []const u8) !bool {
    const ft = try tableName(alloc, col_name);
    var st = try w.prepare(try toZ(alloc, "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name IN (?1,?2,?3);"));
    defer st.finalize();
    try st.bindText(1, try std.fmt.allocPrint(alloc, "{s}_ai", .{ft}));
    try st.bindText(2, try std.fmt.allocPrint(alloc, "{s}_ad", .{ft}));
    try st.bindText(3, try std.fmt.allocPrint(alloc, "{s}_au", .{ft}));
    _ = try st.step();
    return st.columnInt(0) == 3;
}

/// allocPrint helpers hand us `[]u8`; `db.exec`/`db.prepare` want a sentinel-terminated slice.
fn toZ(alloc: std.mem.Allocator, s: []const u8) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(alloc, "{s}", .{s}, 0);
}

// ---- Tests -----------------------------------------------------------------

const collections = @import("../collections.zig");
const migrations = @import("../migrations.zig");
const records = @import("../records.zig");

test "sanitize quotes tokens, preserves operators, drops dangling ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("\"foo\" \"bar\"", (try sanitize(a, "foo bar")).?);
    try std.testing.expectEqualStrings("\"alpha\" OR \"gamma\"", (try sanitize(a, "alpha OR gamma")).?);
    try std.testing.expectEqualStrings("\"foo\"*", (try sanitize(a, "foo*")).?);
    // Leading/trailing/doubled operators are dropped so the query is always well-formed.
    try std.testing.expectEqualStrings("\"foo\"", (try sanitize(a, "OR foo OR")).?);
    // Consecutive operators collapse to the last one seen (always well-formed, never doubled).
    try std.testing.expectEqualStrings("\"a\" AND \"b\"", (try sanitize(a, "a OR AND b")).?);
    // A double-quote injection attempt is escaped into a literal token, never a syntax break.
    try std.testing.expectEqualStrings("\"a\"\"b\"", (try sanitize(a, "a\"b")).?);
    // Empty / operator-only input yields no query.
    try std.testing.expect((try sanitize(a, "   ")) == null);
    try std.testing.expect((try sanitize(a, "AND OR")) == null);
}

test "ensureIndex provisions FTS5, triggers keep it in sync, MATCH search returns rows" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try migrations.run(&d);
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .searchable = true, .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "body", .searchable = true, .options = .{ .editor = .{} } },
        .{ .id = "f3", .name = "slug", .options = .{ .text = .{} } },
    };
    const col = try collections.create(a, io, &d, .{ .id = "", .name = "articles", .fields = &fields });

    try ensureIndex(a, &d, col); // first provision
    try ensureIndex(a, &d, col); // idempotent second call is a no-op (no error)

    // Insert through the records layer so the AFTER INSERT trigger populates the index.
    inline for (.{
        .{ "zig programming language", "a fast systems language" },
        .{ "cooking pasta", "boil water and add salt" },
    }) |row| {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(a, "title", .{ .string = row[0] });
        try obj.put(a, "body", .{ .string = row[1] });
        _ = try records.create(a, io, &d, col, .{ .object = obj });
    }

    const s = (try build(a, col, "zig")).?;
    const sql = try std.fmt.allocPrintSentinel(a, "SELECT \"articles\".\"title\" FROM \"articles\" {s} WHERE {s};", .{ s.join_sql, s.where_sql }, 0);
    var st = try d.prepare(sql);
    defer st.finalize();
    try st.bindText(1, s.param.text);
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("zig programming language", st.columnText(0));
    try std.testing.expect(!try st.step()); // only the one matching row
}
