//! Typed single-table SELECT builder (issue #281, option 2).
//!
//! The companion to the raw-SQL *checker* (`schema_check.zig`): where the checker validates SQL a
//! consumer *hand-wrote*, this *constructs* the SQL from a config struct, validating every table
//! and column against the comptime `.collections` schema as it goes. It **emits** a validated
//! `[:0]const u8` string plus positional `?N` binds — it does NOT execute or decode — so the
//! output feeds the existing `queryAs`/`prepare` path unchanged:
//! ```zig
//! const Q = zigbase.Query.select(Backend.collections, "orders", .{
//!     .columns = &.{ "id", "total" },
//!     .where   = &.{ .{ .col = "total", .op = .gt }, .{ .col = "status", .op = .eq } },
//!     .order   = &.{ .{ .col = "created", .dir = .desc } },
//!     .limit   = 50,
//! });
//! // Q.sql == `SELECT "id", "total" FROM "orders" WHERE "total" > ?1 AND "status" = ?2 ORDER BY "created" DESC LIMIT 50`
//! // Q.bind_count == 2  → pass exactly that many values, in WHERE order:
//! const rows = try ctx.records().queryAs(OrderRow, Q.sql, .{ min_total, "open" });
//! ```
//!
//! ## Scope (v1) — deliberately small
//! Single-table SELECT reads only: no joins, no writes (INSERT/UPDATE/DELETE), no GROUP BY /
//! HAVING / aggregates. Every `Op` is single-bind (`eq/ne/lt/le/gt/ge/like`); an `IN` predicate is
//! variadic-bind and is **future work** (it would need the bind count to depend on a runtime-length
//! value list). Joins and writes are future work too — for anything past this, drop to hand-written
//! SQL guarded by `zigbase.checkedSql`.
//!
//! ## Guarantees
//! - **Unknown table / column → `@compileError`** naming the offending identifier and listing the
//!   valid options — same quality bar and same underlying valid-column set as `checkSql` (both go
//!   through `schema_ident.zig`).
//! - **Binds are positional by construction**: WHERE conditions become `?1..?N` left-to-right, and
//!   `bind_count` (== `where.len`) is exposed so callers/tests can assert arity.
//! - **Identifiers are double-quoted** in the emitted SQL (field names are identifier-safe).

const std = @import("std");
const schema = @import("../schema.zig");
const ident = @import("schema_ident.zig");

/// Comparison operators. All are SINGLE-bind (the right-hand side is one `?N` placeholder),
/// including `like` (`"col" LIKE ?N`). A variadic `in` is intentionally omitted in v1 (see the
/// module scope note).
pub const Op = enum { eq, ne, lt, le, gt, ge, like };

pub const Dir = enum { asc, desc };

/// One `WHERE` condition: `<col> <op> ?N`. `N` is assigned by position in the `where` slice.
pub const Cond = struct { col: []const u8, op: Op = .eq };

pub const OrderBy = struct { col: []const u8, dir: Dir = .asc };

pub const SelectSpec = struct {
    /// Projected columns. **Empty ⇒ `SELECT *`** (the raw star — SQLite expands it to the physical
    /// columns; use an explicit list when you decode into a struct so the projection is stable).
    columns: []const []const u8 = &.{},
    /// `WHERE` conditions, ANDed together. Each binds one placeholder `?1..?N` in slice order.
    where: []const Cond = &.{},
    /// `ORDER BY` terms, emitted in slice order with an explicit `ASC`/`DESC`.
    order: []const OrderBy = &.{},
    limit: ?usize = null,
    /// `OFFSET` — only valid together with `limit` (SQLite has no bare `OFFSET`); setting it
    /// without `limit` is a `@compileError`.
    offset: ?usize = null,
    distinct: bool = false,
};

fn opSql(op: Op) []const u8 {
    return switch (op) {
        .eq => "=",
        .ne => "!=",
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
        .like => "LIKE",
    };
}

fn tableErr(comptime cols: []const schema.Collection, comptime table: []const u8) []const u8 {
    return "Query.select: unknown table \"" ++ table ++ "\" (known: " ++ ident.tableNamesList(cols) ++ ")";
}

fn colErr(comptime c: schema.Collection, comptime col: []const u8) []const u8 {
    return "Query.select: column \"" ++ col ++ "\" does not exist on collection \"" ++ c.name ++
        "\" (columns: " ++ ident.columnsList(c) ++ ")";
}

fn num(comptime n: usize) []const u8 {
    return std.fmt.comptimePrint("{d}", .{n});
}

/// Comptime-build a validated single-table SELECT string. Pure (returns the SQL text) so it is
/// unit-testable at comptime with `expectEqualStrings`; `select` wraps it into a type. `table` must
/// be a known collection and every column referenced (in `columns`/`where`/`order`) must be a valid
/// column of it, else a `@compileError`.
pub fn buildSelect(comptime cols: []const schema.Collection, comptime table: []const u8, comptime spec: SelectSpec) []const u8 {
    comptime {
        const c = ident.collectionByName(cols, table) orelse @compileError(tableErr(cols, table));
        if (spec.offset != null and spec.limit == null)
            @compileError("Query.select: .offset requires .limit (SQLite has no bare OFFSET); set .limit");

        var sql: []const u8 = "SELECT ";
        if (spec.distinct) sql = sql ++ "DISTINCT ";

        if (spec.columns.len == 0) {
            sql = sql ++ "*";
        } else {
            for (spec.columns, 0..) |col, i| {
                if (!ident.isValidColumn(c, col)) @compileError(colErr(c, col));
                if (i != 0) sql = sql ++ ", ";
                sql = sql ++ ident.quoteIdent(col);
            }
        }

        sql = sql ++ " FROM " ++ ident.quoteIdent(table);

        if (spec.where.len != 0) {
            sql = sql ++ " WHERE ";
            for (spec.where, 0..) |cond, i| {
                if (!ident.isValidColumn(c, cond.col)) @compileError(colErr(c, cond.col));
                if (i != 0) sql = sql ++ " AND ";
                sql = sql ++ ident.quoteIdent(cond.col) ++ " " ++ opSql(cond.op) ++ " ?" ++ num(i + 1);
            }
        }

        if (spec.order.len != 0) {
            sql = sql ++ " ORDER BY ";
            for (spec.order, 0..) |ob, i| {
                if (!ident.isValidColumn(c, ob.col)) @compileError(colErr(c, ob.col));
                if (i != 0) sql = sql ++ ", ";
                sql = sql ++ ident.quoteIdent(ob.col) ++ (if (ob.dir == .desc) " DESC" else " ASC");
            }
        }

        if (spec.limit) |lim| {
            sql = sql ++ " LIMIT " ++ num(lim);
            if (spec.offset) |off| sql = sql ++ " OFFSET " ++ num(off);
        }

        return sql;
    }
}

/// Comptime-build a validated single-table SELECT. Returns a type exposing:
///   - `pub const sql: [:0]const u8` — the validated, `?N`-parameterized SQL string.
///   - `pub const bind_count: usize` — number of positional binds (== `spec.where.len`).
/// See the module comment for usage and the `buildSelect` doc for validation semantics.
pub fn select(comptime cols: []const schema.Collection, comptime table: []const u8, comptime spec: SelectSpec) type {
    return struct {
        /// `comptimePrint("{s}", …)` re-materializes the built text as a sentinel-terminated
        /// `[:0]const u8` so it drops straight into `queryAs`/`prepare`.
        pub const sql: [:0]const u8 = std.fmt.comptimePrint("{s}", .{buildSelect(cols, table, spec)});
        pub const bind_count: usize = spec.where.len;
    };
}

// ===========================================================================
// Tests — comptime `buildSelect` output + `select` type surface. Column/table validation is a
// `@compileError` (it fails the build by design, so it cannot be an executable test); the shared
// validation logic in schema_ident.zig has its own runtime tests. The expected build-error message
// for e.g. `select(cols, "orders", .{ .columns = &.{"totl"} })` is:
//   Query.select: column "totl" does not exist on collection "orders" (columns: id, created, updated, total, status, note)
// ===========================================================================

const testing = std.testing;

fn testCols() []const schema.Collection {
    const S = struct {
        const users_fields = [_]schema.Field{
            .{ .id = "u_name", .name = "name", .options = .{ .text = .{} } },
        };
        const orders_fields = [_]schema.Field{
            .{ .id = "o_total", .name = "total", .options = .{ .number = .{} } },
            .{ .id = "o_status", .name = "status", .options = .{ .text = .{} } },
            .{ .id = "o_note", .name = "note", .options = .{ .text = .{} } },
        };
        const cols = [_]schema.Collection{
            .{ .id = "users", .name = "users", .type = .auth, .fields = &users_fields },
            .{ .id = "orders", .name = "orders", .type = .base, .fields = &orders_fields },
        };
    };
    return &S.cols;
}

test "basic multi-column select" {
    const sql = comptime buildSelect(testCols(), "orders", .{ .columns = &.{ "id", "total" } });
    try testing.expectEqualStrings("SELECT \"id\", \"total\" FROM \"orders\"", sql);
}

test "empty columns => SELECT *" {
    const sql = comptime buildSelect(testCols(), "orders", .{});
    try testing.expectEqualStrings("SELECT * FROM \"orders\"", sql);
}

test "each operator emits a single positional bind" {
    const cases = .{
        .{ Op.eq, "=" },
        .{ Op.ne, "!=" },
        .{ Op.lt, "<" },
        .{ Op.le, "<=" },
        .{ Op.gt, ">" },
        .{ Op.ge, ">=" },
        .{ Op.like, "LIKE" },
    };
    inline for (cases) |case| {
        const sql = comptime buildSelect(testCols(), "orders", .{ .where = &.{.{ .col = "total", .op = case[0] }} });
        try testing.expectEqualStrings("SELECT * FROM \"orders\" WHERE \"total\" " ++ case[1] ++ " ?1", sql);
    }
}

test "multiple WHERE conds AND with positional ?1/?2 in order" {
    const Q = select(testCols(), "orders", .{
        .where = &.{ .{ .col = "total", .op = .gt }, .{ .col = "status", .op = .eq } },
    });
    try testing.expectEqualStrings("SELECT * FROM \"orders\" WHERE \"total\" > ?1 AND \"status\" = ?2", Q.sql);
    try testing.expectEqual(@as(usize, 2), Q.bind_count);
}

test "ORDER BY asc/desc, single and multi" {
    const asc = comptime buildSelect(testCols(), "orders", .{ .order = &.{.{ .col = "created" }} });
    try testing.expectEqualStrings("SELECT * FROM \"orders\" ORDER BY \"created\" ASC", asc);
    const multi = comptime buildSelect(testCols(), "orders", .{
        .order = &.{ .{ .col = "total", .dir = .asc }, .{ .col = "created", .dir = .desc } },
    });
    try testing.expectEqualStrings("SELECT * FROM \"orders\" ORDER BY \"total\" ASC, \"created\" DESC", multi);
}

test "LIMIT and LIMIT+OFFSET" {
    const lim = comptime buildSelect(testCols(), "orders", .{ .limit = 50 });
    try testing.expectEqualStrings("SELECT * FROM \"orders\" LIMIT 50", lim);
    const both = comptime buildSelect(testCols(), "orders", .{ .limit = 10, .offset = 5 });
    try testing.expectEqualStrings("SELECT * FROM \"orders\" LIMIT 10 OFFSET 5", both);
}

test "DISTINCT" {
    const sql = comptime buildSelect(testCols(), "orders", .{ .distinct = true, .columns = &.{"status"} });
    try testing.expectEqualStrings("SELECT DISTINCT \"status\" FROM \"orders\"", sql);
}

test "auth system column is valid in WHERE" {
    const sql = comptime buildSelect(testCols(), "users", .{ .where = &.{.{ .col = "email", .op = .eq }} });
    try testing.expectEqualStrings("SELECT * FROM \"users\" WHERE \"email\" = ?1", sql);
}

test "representative fully-featured example (matches the docs)" {
    const Q = select(testCols(), "orders", .{
        .columns = &.{ "id", "total" },
        .where = &.{ .{ .col = "total", .op = .gt }, .{ .col = "status", .op = .eq } },
        .order = &.{.{ .col = "created", .dir = .desc }},
        .limit = 50,
    });
    try testing.expectEqualStrings(
        "SELECT \"id\", \"total\" FROM \"orders\" WHERE \"total\" > ?1 AND \"status\" = ?2 ORDER BY \"created\" DESC LIMIT 50",
        Q.sql,
    );
    try testing.expectEqual(@as(usize, 2), Q.bind_count);
}

test "select type exposes a null-terminated sql and zero bind_count when no WHERE" {
    const Q = select(testCols(), "orders", .{ .columns = &.{"id"} });
    try testing.expectEqual(@as(usize, 0), Q.bind_count);
    try testing.expectEqual(@as(u8, 0), Q.sql[Q.sql.len]); // sentinel present
}
