//! Pure SQL string generation from schema types.
//!
//! Every public function is self-freeing (allocator ownership contract 1): intermediate
//! fragments (quoted idents, column defs, allocPrint results) are scratch, built on a
//! function-local arena and copied into the returned buffer; only the final result (a `[]u8`,
//! or — for `rebuildPlan`/`rebuildPlanPg` — the returned `[]const []u8` and each of its
//! individually `alloc`-owned statements) escapes on the caller's allocator. The engine still
//! calls these under a per-operation arena in production, so this is correctness/contract only,
//! not a perf change.
//!
//! EVERY identifier is escaped through `quoteIdent` — there are no bare `"{s}"` interpolations
//! left. Most names here did arrive pre-validated by `schema.isValidIdentifier`, which made raw
//! interpolation safe in practice, but relying on that meant this file defined `quoteIdent` and
//! then mostly did not use it: a reader could not tell which sites were safe by construction and
//! which merely happened to be. It also does not hold for the `_`-prefixed system collections,
//! whose leading underscore that validator rejects by design. One rule, no exceptions.
//! A COMPOSITE name (`fk_<table>_<field>`, `idx_auth_<table>_<field>`) is assembled first and
//! escaped as one unit via `quoteComposite`, so the name a `CREATE` emits is byte-identical to the
//! one a later `DROP` looks for.

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

/// Assemble a COMPOSITE identifier (an index or constraint name built from parts, e.g.
/// `fk_<table>_<field>`) and escape it as ONE unit. Escaping the assembled name rather than each
/// part is what keeps the name a `CREATE` emits byte-identical to the one a later `DROP` looks for.
pub fn quoteComposite(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    const raw = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(raw);
    return quoteIdent(alloc, raw);
}

/// True when `name` is a column covered by a `.nocase` index on `c`. Such a column is matched
/// case-insensitively (SQLite via the COLLATE NOCASE index, Postgres via a `lower()` functional
/// index — see `createIndexSql` / `dialect.nocaseEqOperand`), so the byte-order `COLLATE "C"`
/// parity pin is NOT applied to it.
pub fn isNocaseField(c: schema.Collection, name: []const u8) bool {
    for (c.indexes) |ix| {
        if (ix.collation != .nocase) continue;
        for (ix.fields) |fname| if (std.mem.eql(u8, fname, name)) return true;
    }
    return false;
}

pub fn columnDef(alloc: std.mem.Allocator, f: schema.Field, d: dialect.Dialect, collate: []const u8) ![]u8 {
    const ty = d.sqlType(f.storageClass());
    const q = try quoteIdent(alloc, f.name);
    defer alloc.free(q); // copied into the result; freed on both branches and on an alloc failure
    if (f.unique) return std.fmt.allocPrint(alloc, "{s} {s}{s} UNIQUE", .{ q, ty, collate });
    return std.fmt.allocPrint(alloc, "{s} {s}{s}", .{ q, ty, collate });
}

/// The byte-order collation suffix to attach to field `f`'s column DDL: `d.textCollate()` for a
/// plain TEXT column (so PG matches SQLite's BINARY ordering), or "" for non-text storage or a
/// `.nocase`-indexed column (see `isNocaseField`).
///
/// DO NOT pin a `.nocase` column to `COLLATE "C"` (#159): its `lower()` functional index (PG) /
/// COLLATE NOCASE index (SQLite) and the matching `lower()`/`COLLATE NOCASE` *lookups* must agree
/// to keep case-insensitive uniqueness ⇔ lookup consistent. A `COLLATE "C"` byte-order pin on the
/// column would not break the functional index itself, but it signals the WRONG intent for a
/// case-insensitive column — so the `.nocase` guard below stays even if a future change pins ALL
/// other text columns to "C".
fn fieldCollate(c: schema.Collection, f: schema.Field, d: dialect.Dialect) []const u8 {
    if (f.storageClass() != .text) return "";
    if (isNocaseField(c, f.name)) return ""; // .nocase column: never pinned to COLLATE "C" (see above)
    return d.textCollate();
}

fn nameIn(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

pub fn createTableSql(alloc: std.mem.Allocator, c: schema.Collection, single_rel_target: ?[]const u8, d: dialect.Dialect, skip_fk_fields: []const []const u8) ![]u8 {
    // Self-freeing (contract 1): every intermediate fragment (quoted idents, column defs,
    // allocPrint'd clauses) is scratch, built on a function-local arena and copied into `out`
    // via `appendSlice`; only `out`'s final `toOwnedSlice` escapes on `alloc`.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "CREATE TABLE ");
    const tbl = try quoteIdent(sa, c.name);
    try out.appendSlice(alloc, tbl);
    // The base text columns (incl. the `id` keyset tiebreaker) get the byte-order collation pin so
    // text ORDER BY / keyset pagination produces the SAME order on Postgres as on SQLite (BINARY).
    const tc = d.textCollate();
    try out.appendSlice(alloc, try std.fmt.allocPrint(sa, " (\"id\" TEXT{s} PRIMARY KEY, \"created\" TEXT{s}, \"updated\" TEXT{s}", .{ tc, tc, tc }));
    for (c.fields) |f| {
        try out.appendSlice(alloc, ", ");
        try out.appendSlice(alloc, try columnDef(sa, f, d, fieldCollate(c, f, d)));
    }
    for (c.fields) |f| {
        switch (f.options) {
            // skip_fk_fields (migrate-db cycle edges, Postgres target): the COLUMN was
            // already emitted above — only the inline FK clause is omitted; the caller
            // adds it back post-creation via `addDeferrableFkSql`.
            .relation => |r| if (r.maxSelect == 1 and !nameIn(skip_fk_fields, f.name)) {
                const target = single_rel_target orelse r.targetCollectionId;
                const on_delete = if (r.cascadeDelete) "CASCADE" else "SET NULL";
                try out.appendSlice(alloc, try std.fmt.allocPrint(sa, ", FOREIGN KEY ({s}) REFERENCES {s} (\"id\") ON DELETE {s}", .{ try quoteIdent(sa, f.name), try quoteIdent(sa, target), on_delete }));
            },
            else => {},
        }
    }
    try out.appendSlice(alloc, ");");
    return out.toOwnedSlice(alloc);
}

pub fn createIndexSql(alloc: std.mem.Allocator, table: []const u8, idx: schema.Index, d: dialect.Dialect) ![]u8 {
    // Self-freeing (contract 1): see `createTableSql`.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    // Case-insensitive collation routes through the dialect (#159): SQLite collates each column
    // in place (`"col" COLLATE NOCASE`); Postgres has no built-in NOCASE collation, so it indexes
    // the LOWER-cased value (`lower("col")`) — a built-in functional index (no citext extension),
    // and a UNIQUE one over `lower("col")` rejects case-variant duplicates just like SQLite's. A
    // `.binary` index is the plain quoted column on both backends.
    try out.appendSlice(alloc, if (idx.unique) "CREATE UNIQUE INDEX " else "CREATE INDEX ");
    try out.appendSlice(alloc, try quoteIdent(sa, idx.name));
    try out.appendSlice(alloc, " ON ");
    try out.appendSlice(alloc, try quoteIdent(sa, table));
    try out.append(alloc, ' ');
    try out.append(alloc, '(');
    for (idx.fields, 0..) |fname, i| {
        if (i > 0) try out.append(alloc, ',');
        const col_quoted = try quoteIdent(sa, fname);
        switch (idx.collation) {
            .binary => try out.appendSlice(alloc, col_quoted),
            .nocase => try out.appendSlice(alloc, try d.nocaseIndexExpr(sa, col_quoted)),
        }
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
/// Every identifier is escaped — the comment here used to claim quoting the code did not do.
pub fn authIdentityIndexSql(alloc: std.mem.Allocator, table: []const u8, field: []const u8) ![]u8 {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();
    return std.fmt.allocPrint(
        alloc,
        "CREATE UNIQUE INDEX IF NOT EXISTS {s} ON {s} ({s}) WHERE {s} != '';",
        .{ try quoteComposite(sa, "idx_auth_{s}_{s}", .{ table, field }), try quoteIdent(sa, table), try quoteIdent(sa, field), try quoteIdent(sa, field) },
    );
}

/// A deferrable FK added AFTER table creation for a relation edge that participates in a
/// dependency cycle (migrate-db, Postgres target — cyclic inline REFERENCES cannot be
/// created in any order there). `DEFERRABLE INITIALLY IMMEDIATE` behaves identically to a
/// plain FK outside an explicit `SET CONSTRAINTS`, so the running server sees no semantic
/// drift; it exists purely so the load transaction can defer it to COMMIT. The constraint
/// name matches `rebuildPlanPg`'s `fk_<table>_<field>` convention.
pub fn addDeferrableFkSql(alloc: std.mem.Allocator, table: []const u8, field: []const u8, target: []const u8, cascade_delete: bool) ![]u8 {
    const on_delete = if (cascade_delete) "CASCADE" else "SET NULL";
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();
    return std.fmt.allocPrint(
        alloc,
        "ALTER TABLE {s} ADD CONSTRAINT {s} FOREIGN KEY ({s}) REFERENCES {s} (\"id\") ON DELETE {s} DEFERRABLE INITIALLY IMMEDIATE;",
        .{ try quoteIdent(sa, table), try quoteComposite(sa, "fk_{s}_{s}", .{ table, field }), try quoteIdent(sa, field), try quoteIdent(sa, target), on_delete },
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

    // Self-freeing (contract 1): `tmp`/`new_cols`/`src_cols` and every column-fragment allocPrint
    // are scratch (consumed to build one of the returned statements, then discarded) — built on
    // a function-local arena. Only the statements themselves (each individually `alloc`-owned,
    // matching `stmts`' backing array) escape.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    var stmts: std.ArrayList([]u8) = .empty;
    // `stmts.items` reflects exactly the statements successfully appended so far (append only
    // grows `.len` on success), so an OOM anywhere below frees exactly what's already owned —
    // no separate bookkeeping needed.
    errdefer {
        for (stmts.items) |s| alloc.free(s);
        stmts.deinit(alloc);
    }

    const tmp = try std.fmt.allocPrint(sa, "{s}__new", .{new.name});
    var tmp_col = new;
    tmp_col.name = tmp;
    try stmts.append(alloc, try createTableSql(alloc, tmp_col, null, d, &.{}));

    var new_cols: std.ArrayList(u8) = .empty;
    var src_cols: std.ArrayList(u8) = .empty;
    try new_cols.appendSlice(sa, "\"id\",\"created\",\"updated\"");
    try src_cols.appendSlice(sa, "\"id\",\"created\",\"updated\"");
    for (new.fields) |nf| {
        try new_cols.append(sa, ',');
        try new_cols.appendSlice(sa, try quoteIdent(sa, nf.name));
        try src_cols.append(sa, ',');
        const old_match = blk: {
            for (old.fields) |of| {
                if (std.mem.eql(u8, of.id, nf.id)) break :blk of;
            }
            break :blk null;
        };
        if (old_match) |of| {
            if (of.storageClass() == nf.storageClass()) {
                try src_cols.appendSlice(sa, try quoteIdent(sa, of.name));
            } else {
                try src_cols.appendSlice(sa, try std.fmt.allocPrint(sa, "CAST({s} AS {s})", .{ try quoteIdent(sa, of.name), d.sqlType(nf.storageClass()) }));
            }
        } else {
            try src_cols.appendSlice(sa, "NULL");
        }
    }
    try stmts.append(alloc, try std.fmt.allocPrint(alloc, "INSERT INTO {s} ({s}) SELECT {s} FROM {s};", .{ try quoteIdent(sa, tmp), new_cols.items, src_cols.items, try quoteIdent(sa, old.name) }));
    try stmts.append(alloc, try std.fmt.allocPrint(alloc, "DROP TABLE {s};", .{try quoteIdent(sa, old.name)}));
    try stmts.append(alloc, try std.fmt.allocPrint(alloc, "ALTER TABLE {s} RENAME TO {s};", .{ try quoteIdent(sa, tmp), try quoteIdent(sa, new.name) }));
    for (new.indexes) |idx| try stmts.append(alloc, try createIndexSql(alloc, new.name, idx, d));
    return stmts.toOwnedSlice(alloc);
}

/// Postgres rebuild via in-place `ALTER TABLE`. Statement order is significant:
///   1. DROP the FK constraint of every OLD single relation field (so a renamed/retyped/dropped
///      relation, an option change, or a relation↔non-relation flip never leaves a stale FK); then
///      DROP every column whose old field id is absent from `new` (data loss matches the SQLite
///      rebuild, which simply does not copy it).
///   2. For each new field, keyed by id: RENAME a retained-but-renamed column, then ALTER its TYPE
///      (`USING` cast) if the storage class changed; ADD a brand-new column (default NULL, with the
///      byte-order text collation).
///   3. RECREATE the FK constraint for every NEW single relation field (by its current name) — so
///      adds/renames/retypes/option-updates all converge to the correct FK.
///   4. DROP every index present in `old` but absent from `new` (the SQLite rebuild destroys them;
///      PG's in-place ALTER would leave them stale), then DROP-and-recreate every declared `new`
///      index (covers renamed columns + new declarations; idempotent via DROP IF EXISTS).
/// Retained columns keep their data; the table is never dropped.
fn rebuildPlanPg(alloc: std.mem.Allocator, old: schema.Collection, new: schema.Collection, d: dialect.Dialect) ![]const []u8 {
    var stmts: std.ArrayList([]u8) = .empty;
    // See `rebuildPlan`: `stmts.items` is exactly what's been successfully appended so far.
    errdefer {
        for (stmts.items) |s| alloc.free(s);
        stmts.deinit(alloc);
    }
    // Scratch for the escaped identifier fragments (mirrors `rebuildPlan`): their bytes are copied
    // into each statement, and only the statements escape on `alloc`.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const tbl = new.name;
    const qtbl = try quoteIdent(sa, tbl);

    // 1a. Drop the FK of every old single relation field (converges all relation changes; gemini #2).
    for (old.fields) |of| switch (of.options) {
        .relation => |r| if (r.maxSelect == 1) {
            try stmts.append(alloc, try std.fmt.allocPrint(alloc, "ALTER TABLE {s} DROP CONSTRAINT IF EXISTS {s};", .{ qtbl, try quoteComposite(sa, "fk_{s}_{s}", .{ tbl, of.name }) }));
        },
        else => {},
    };

    // 1b. Drop columns: an old field whose id is not present in `new`.
    for (old.fields) |of| {
        const kept = blk: {
            for (new.fields) |nf| if (std.mem.eql(u8, of.id, nf.id)) break :blk true;
            break :blk false;
        };
        if (!kept) try stmts.append(alloc, try std.fmt.allocPrint(alloc, "ALTER TABLE {s} DROP COLUMN IF EXISTS {s};", .{ qtbl, try quoteIdent(sa, of.name) }));
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
                try stmts.append(alloc, try std.fmt.allocPrint(alloc, "ALTER TABLE {s} RENAME COLUMN {s} TO {s};", .{ qtbl, try quoteIdent(sa, of.name), try quoteIdent(sa, nf.name) }));
            if (of.storageClass() != nf.storageClass())
                try stmts.append(alloc, try std.fmt.allocPrint(alloc, "ALTER TABLE {s} ALTER COLUMN {s} TYPE {s} USING ({s}::{s});", .{ qtbl, try quoteIdent(sa, nf.name), ty, try quoteIdent(sa, nf.name), ty }));
        } else {
            const uniq = if (nf.unique) " UNIQUE" else "";
            try stmts.append(alloc, try std.fmt.allocPrint(alloc, "ALTER TABLE {s} ADD COLUMN IF NOT EXISTS {s} {s}{s}{s};", .{ qtbl, try quoteIdent(sa, nf.name), ty, fieldCollate(new, nf, d), uniq }));
        }
    }

    // 3. Recreate the FK for every new single relation field (by its current name).
    for (new.fields) |nf| switch (nf.options) {
        .relation => |r| if (r.maxSelect == 1) {
            const on_delete = if (r.cascadeDelete) "CASCADE" else "SET NULL";
            // `new` is relation-resolved by the caller: targetCollectionId is the table name.
            try stmts.append(alloc, try std.fmt.allocPrint(alloc, "ALTER TABLE {s} ADD CONSTRAINT {s} FOREIGN KEY ({s}) REFERENCES {s} (\"id\") ON DELETE {s};", .{ qtbl, try quoteComposite(sa, "fk_{s}_{s}", .{ tbl, nf.name }), try quoteIdent(sa, nf.name), try quoteIdent(sa, r.targetCollectionId), on_delete }));
        },
        else => {},
    };

    // 4a. Drop indexes present in `old` but absent from `new` (PG leaves them stale otherwise).
    for (old.indexes) |oix| {
        const kept = blk: {
            for (new.indexes) |nix| if (std.mem.eql(u8, oix.name, nix.name)) break :blk true;
            break :blk false;
        };
        if (!kept) try stmts.append(alloc, try std.fmt.allocPrint(alloc, "DROP INDEX IF EXISTS {s};", .{try quoteIdent(sa, oix.name)}));
    }
    // 4b. Drop-if-exists + recreate every declared index.
    for (new.indexes) |idx| {
        try stmts.append(alloc, try std.fmt.allocPrint(alloc, "DROP INDEX IF EXISTS {s};", .{try quoteIdent(sa, idx.name)}));
        try stmts.append(alloc, try createIndexSql(alloc, tbl, idx, d));
    }
    return stmts.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "createTableSql includes system columns, field columns, and FK for single relation" {
    const a = std.testing.allocator;
    const fields = [_]schema.Field{
        .{ .id = "a", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "b", .name = "price", .options = .{ .number = .{ .mode = .float } } },
        .{ .id = "c", .name = "author", .options = .{ .relation = .{ .targetCollectionId = "users", .cascadeDelete = true, .maxSelect = 1 } } },
    };
    const col = schema.Collection{ .id = "c1", .name = "posts", .fields = &fields };
    const sql = try createTableSql(a, col, "users", .sqlite, &.{});
    defer a.free(sql);
    // SQLite is byte-identical: textCollate() is "" so no COLLATE clauses appear.
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"id\" TEXT PRIMARY KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"created\" TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"title\" TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"price\" REAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "COLLATE") == null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "FOREIGN KEY (\"author\") REFERENCES \"users\" (\"id\") ON DELETE CASCADE") != null);
}

test "createTableSql (Postgres) pins TEXT columns to COLLATE \"C\" except .nocase-indexed ones" {
    const a = std.testing.allocator;
    const fields = [_]schema.Field{
        .{ .id = "a", .name = "title", .options = .{ .text = .{} } }, // plain text -> COLLATE "C"
        .{ .id = "b", .name = "email", .options = .{ .text = .{} } }, // covered by a .nocase index -> no COLLATE
        .{ .id = "c", .name = "price", .options = .{ .number = .{ .mode = .float } } }, // non-text -> no COLLATE
    };
    const idx = [_]schema.Index{.{ .name = "idx_email", .fields = &.{"email"}, .unique = true, .collation = .nocase }};
    const col = schema.Collection{ .id = "c1", .name = "posts", .fields = &fields, .indexes = &idx };
    const sql = try createTableSql(a, col, null, .postgres, &.{});
    defer a.free(sql);
    // System tiebreaker columns + plain text field get the byte-order collation.
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"id\" TEXT COLLATE \"C\" PRIMARY KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"created\" TEXT COLLATE \"C\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"title\" TEXT COLLATE \"C\"") != null);
    // The .nocase-indexed column is left WITHOUT COLLATE "C" (the case-insensitive follow-up owns it).
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"email\" TEXT COLLATE") == null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"email\" TEXT,") != null or std.mem.indexOf(u8, sql, "\"email\" TEXT UNIQUE") != null or std.mem.indexOf(u8, sql, "\"email\" TEXT)") != null);
    // Non-text column never gets a collation.
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"price\" DOUBLE PRECISION") != null);
}

test "createTableSql omits the FK clause for skip_fk_fields (cycle edges) but keeps the column" {
    const a = std.testing.allocator;
    const fields = [_]schema.Field{
        .{ .id = "a", .name = "author", .options = .{ .relation = .{ .targetCollectionId = "users", .maxSelect = 1 } } },
        .{ .id = "b", .name = "pair", .options = .{ .relation = .{ .targetCollectionId = "twins", .maxSelect = 1 } } },
    };
    const col = schema.Collection{ .id = "c1", .name = "posts", .fields = &fields };
    const sql = try createTableSql(a, col, null, .postgres, &.{"pair"});
    defer a.free(sql);
    // The skipped edge keeps its COLUMN (data still loads) but loses the inline FK.
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"pair\" TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "FOREIGN KEY (\"pair\")") == null);
    // The non-cycle FK is unchanged.
    try std.testing.expect(std.mem.indexOf(u8, sql, "FOREIGN KEY (\"author\") REFERENCES \"users\" (\"id\") ON DELETE SET NULL") != null);
}

test "addDeferrableFkSql matches rebuildPlanPg naming and emits DEFERRABLE INITIALLY IMMEDIATE" {
    const a = std.testing.allocator;
    const s1 = try addDeferrableFkSql(a, "posts", "pair", "twins", false);
    defer a.free(s1);
    try std.testing.expectEqualStrings(
        "ALTER TABLE \"posts\" ADD CONSTRAINT \"fk_posts_pair\" FOREIGN KEY (\"pair\") REFERENCES \"twins\" (\"id\") ON DELETE SET NULL DEFERRABLE INITIALLY IMMEDIATE;",
        s1,
    );
    const s2 = try addDeferrableFkSql(a, "posts", "pair", "twins", true);
    defer a.free(s2);
    try std.testing.expectEqualStrings(
        "ALTER TABLE \"posts\" ADD CONSTRAINT \"fk_posts_pair\" FOREIGN KEY (\"pair\") REFERENCES \"twins\" (\"id\") ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE;",
        s2,
    );
}

test "every generated statement ESCAPES its identifiers (embedded-quote probe)" {
    // The discriminating probe for the escaping sweep. `quoteIdent` and a bare `"{s}"` emit
    // BYTE-IDENTICAL SQL for every name that can be created, so a dropped or mis-ordered
    // conversion is invisible on ordinary names; only a name containing a `"` separates them.
    // Each assertion below fails if its statement regressed to raw interpolation.
    const a = std.testing.allocator;
    const d: dialect.Dialect = .sqlite;
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "ti\"tle", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "au\"thor", .options = .{ .relation = .{ .targetCollectionId = "us\"ers", .maxSelect = 1 } } },
    };
    const c = schema.Collection{ .id = "c", .name = "po\"sts", .fields = &fields };

    const create = try createTableSql(a, c, null, d, &.{});
    defer a.free(create);
    try std.testing.expect(std.mem.startsWith(u8, create, "CREATE TABLE \"po\"\"sts\" ("));
    try std.testing.expect(std.mem.indexOf(u8, create, "\"ti\"\"tle\" TEXT") != null);
    // The FK clause escapes BOTH the column and the referenced table.
    try std.testing.expect(std.mem.indexOf(u8, create, "FOREIGN KEY (\"au\"\"thor\") REFERENCES \"us\"\"ers\" (\"id\")") != null);

    // A COMPOSITE name (index/constraint) is assembled first, then escaped as ONE unit — so what
    // CREATE emits is exactly what a later DROP looks for.
    const auth_idx = try authIdentityIndexSql(a, "us\"ers", "em\"ail");
    defer a.free(auth_idx);
    try std.testing.expectEqualStrings(
        "CREATE UNIQUE INDEX IF NOT EXISTS \"idx_auth_us\"\"ers_em\"\"ail\" ON \"us\"\"ers\" (\"em\"\"ail\") WHERE \"em\"\"ail\" != '';",
        auth_idx,
    );
    const fk = try addDeferrableFkSql(a, "po\"sts", "au\"thor", "us\"ers", true);
    defer a.free(fk);
    try std.testing.expect(std.mem.indexOf(u8, fk, "ALTER TABLE \"po\"\"sts\" ADD CONSTRAINT \"fk_po\"\"sts_au\"\"thor\"") != null);

    const idx = try createIndexSql(a, "po\"sts", .{ .name = "ix\"1", .fields = &.{"ti\"tle"}, .unique = true }, d);
    defer a.free(idx);
    try std.testing.expectEqualStrings(
        "CREATE UNIQUE INDEX \"ix\"\"1\" ON \"po\"\"sts\" (\"ti\"\"tle\");",
        idx,
    );

    // The SQLite rebuild path: copy/drop/rename all escape the table names.
    const old_c = schema.Collection{ .id = "c", .name = "po\"sts", .fields = &.{fields[0]} };
    const plan = try rebuildPlan(a, old_c, c, d);
    defer {
        for (plan) |s| a.free(s);
        a.free(plan);
    }
    var saw_insert = false;
    var saw_drop = false;
    var saw_rename = false;
    for (plan) |stmt| {
        if (std.mem.startsWith(u8, stmt, "INSERT INTO \"po\"\"sts__new\"")) saw_insert = true;
        if (std.mem.eql(u8, stmt, "DROP TABLE \"po\"\"sts\";")) saw_drop = true;
        if (std.mem.eql(u8, stmt, "ALTER TABLE \"po\"\"sts__new\" RENAME TO \"po\"\"sts\";")) saw_rename = true;
    }
    try std.testing.expect(saw_insert);
    try std.testing.expect(saw_drop);
    try std.testing.expect(saw_rename);
}

test "createIndexSql builds unique and non-unique" {
    const a = std.testing.allocator;
    const u = try createIndexSql(a, "posts", .{ .name = "idx_title", .fields = &.{"title"}, .unique = true }, .sqlite);
    defer a.free(u);
    try std.testing.expectEqualStrings("CREATE UNIQUE INDEX \"idx_title\" ON \"posts\" (\"title\");", u);
    const n = try createIndexSql(a, "posts", .{ .name = "idx_ab", .fields = &.{ "a", "b" }, .unique = false }, .sqlite);
    defer a.free(n);
    try std.testing.expectEqualStrings("CREATE INDEX \"idx_ab\" ON \"posts\" (\"a\",\"b\");", n);
}

test "createIndexSql emits COLLATE NOCASE and a partial WHERE predicate" {
    const a = std.testing.allocator;
    const ci = try createIndexSql(a, "customers", .{ .name = "idx_email", .fields = &.{"email"}, .unique = true, .collation = .nocase }, .sqlite);
    defer a.free(ci);
    try std.testing.expectEqualStrings("CREATE UNIQUE INDEX \"idx_email\" ON \"customers\" (\"email\" COLLATE NOCASE);", ci);
    const partial = try createIndexSql(a, "posts", .{ .name = "idx_active", .fields = &.{"slug"}, .unique = true, .where = "deleted_at IS NULL" }, .sqlite);
    defer a.free(partial);
    try std.testing.expectEqualStrings("CREATE UNIQUE INDEX \"idx_active\" ON \"posts\" (\"slug\") WHERE deleted_at IS NULL;", partial);
    // collation applies per-column, predicate follows the column list
    const both = try createIndexSql(a, "t", .{ .name = "idx_both", .fields = &.{ "a", "b" }, .collation = .nocase, .where = "a IS NOT NULL" }, .sqlite);
    defer a.free(both);
    try std.testing.expectEqualStrings("CREATE INDEX \"idx_both\" ON \"t\" (\"a\" COLLATE NOCASE,\"b\" COLLATE NOCASE) WHERE a IS NOT NULL;", both);
    // an empty or whitespace-only predicate emits no WHERE clause (not "WHERE ;")
    const empty = try createIndexSql(a, "t", .{ .name = "idx_e", .fields = &.{"a"}, .where = "" }, .sqlite);
    defer a.free(empty);
    try std.testing.expectEqualStrings("CREATE INDEX \"idx_e\" ON \"t\" (\"a\");", empty);
    const ws = try createIndexSql(a, "t", .{ .name = "idx_w", .fields = &.{"a"}, .where = "  \t\n" }, .sqlite);
    defer a.free(ws);
    try std.testing.expectEqualStrings("CREATE INDEX \"idx_w\" ON \"t\" (\"a\");", ws);
    // Postgres: no built-in NOCASE collation, so `.nocase` becomes a `lower()` FUNCTIONAL index
    // (#159) — a UNIQUE one over `lower("email")` rejects case-variant duplicates, giving PG the
    // same case-insensitive uniqueness SQLite gets from COLLATE NOCASE.
    const pg_ci = try createIndexSql(a, "customers", .{ .name = "idx_email", .fields = &.{"email"}, .unique = true, .collation = .nocase }, .postgres);
    defer a.free(pg_ci);
    try std.testing.expectEqualStrings("CREATE UNIQUE INDEX \"idx_email\" ON \"customers\" (lower(\"email\"));", pg_ci);
    // Multi-column `.nocase` lowers each column independently on Postgres.
    const pg_both = try createIndexSql(a, "t", .{ .name = "idx_both", .fields = &.{ "a", "b" }, .collation = .nocase, .where = "a IS NOT NULL" }, .postgres);
    defer a.free(pg_both);
    try std.testing.expectEqualStrings("CREATE INDEX \"idx_both\" ON \"t\" (lower(\"a\"),lower(\"b\")) WHERE a IS NOT NULL;", pg_both);
}

test "rebuildPlan copies retained columns by field id, adds new, drops removed" {
    const a = std.testing.allocator;
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
    defer {
        for (plan) |s| a.free(s);
        a.free(plan);
    }
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
    const a = std.testing.allocator;
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
    defer {
        for (plan) |s| a.free(s);
        a.free(plan);
    }
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
    const a = std.testing.allocator;
    const sql = try authIdentityIndexSql(a, "users", "email");
    defer a.free(sql);
    try std.testing.expectEqualStrings(
        "CREATE UNIQUE INDEX IF NOT EXISTS \"idx_auth_users_email\" ON \"users\" (\"email\") WHERE \"email\" != '';",
        sql,
    );
}
