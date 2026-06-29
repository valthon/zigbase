//! SQL dialect abstraction (issue #159, PR-1b). ZigBase has historically emitted a single
//! SQLite flavor of SQL via `std.fmt.allocPrint` scattered across the query/DDL/records layers.
//! Adding PostgreSQL as a runtime-selectable backend means those flavor-specific fragments must
//! flow through ONE place that knows the active backend. This file is that place.
//!
//! A `Dialect` is a tiny tagged value (`kind: Kind`) whose methods return the backend-correct
//! SQL fragment. It is selected alongside the database backend (`db.Pool`/`db.Db`) at startup
//! and threaded to the SQL producers. PR-1b establishes the abstraction + the foundational type
//! mapping (`sqlType`, used by schema/DDL/provision); rewriting every `?`-placeholder / `now()`
//! / `LIKE` call site to flow through it is the job of the parity PRs (PR-2 DDL, PR-3 CRUD/$n),
//! so several helpers here ship ahead of their call-site adoption — by design.
//!
//! The default `-Dpostgres=false` build only ever constructs `Dialect.sqlite`; every Postgres
//! branch is reachable but never taken, so the shipped binary's behavior is unchanged.

const std = @import("std");

/// The SQL flavor a `Dialect` emits. Mirrors `db.Backend`, kept independent here so the
/// dialect layer has no dependency on the database seam (and vice-versa: `schema.zig` can
/// import the type mapping without pulling in libc/SQLite).
pub const Kind = enum { sqlite, postgres };

/// The physical storage class a logical field maps to. Backend-independent: the same field
/// is `integer`/`real`/`text` on every backend; only the concrete column TYPE string differs
/// (e.g. `integer` → `INTEGER` on SQLite, `BIGINT` on Postgres). `schema.Field.storageClass`
/// produces this; `Dialect.sqlType` lowers it to the backend type keyword.
pub const StorageClass = enum { integer, real, text };

/// Sort direction, for `nullsOrder` (Postgres needs an explicit `NULLS FIRST/LAST` to match
/// SQLite's implicit NULL ordering).
pub const SortDir = enum { asc, desc };

pub const Dialect = struct {
    kind: Kind,

    pub const sqlite: Dialect = .{ .kind = .sqlite };
    pub const postgres: Dialect = .{ .kind = .postgres };

    /// Pick the dialect for a backend kind.
    pub fn forKind(kind: Kind) Dialect {
        return .{ .kind = kind };
    }

    /// Width needed by `placeholder` to format the largest `$n`. Postgres caps params at the
    /// Bind message's i16 count (`$32767`), so 6 bytes ("$32767") always suffices; round up.
    pub const placeholder_buf_len = 8;

    /// The positional parameter placeholder for the `n`-th (1-based) bound parameter, written
    /// into `buf` and returned. SQLite uses the anonymous `?` (auto-numbered by position, so
    /// `n` is ignored); Postgres requires the explicit `$n`. Callers that emit SQLite's `?`
    /// today will, in PR-3, thread a running counter and call this so the same producer emits
    /// `$n` under Postgres.
    pub fn placeholder(self: Dialect, buf: []u8, n: usize) []const u8 {
        return switch (self.kind) {
            .sqlite => "?",
            .postgres => std.fmt.bufPrint(buf, "${d}", .{n}) catch unreachable,
        };
    }

    /// A SQL expression evaluating to "now" in the backend's native timestamp form. Used where
    /// the value is compared/stored as the backend's own clock (not a portable ISO string).
    pub fn nowExpr(self: Dialect) []const u8 {
        return switch (self.kind) {
            .sqlite => "datetime('now')",
            .postgres => "now()",
        };
    }

    /// A SQL expression evaluating to the current time as an ISO-8601 `Z` string, so a TEXT
    /// column keeps the identical `YYYY-MM-DDTHH:MM:SSZ` shape on both backends (ZigBase stores
    /// timestamps as TEXT for cross-backend rule consistency).
    pub fn nowIso8601Expr(self: Dialect) []const u8 {
        return switch (self.kind) {
            .sqlite => "strftime('%Y-%m-%dT%H:%M:%SZ','now')",
            // to_char on the UTC-normalized now(); the literal T/Z are quoted so they pass through.
            .postgres => "to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')",
        };
    }

    /// The concrete column TYPE keyword for a storage class. This is the foundational mapping
    /// `schema.Field.sqlType` and the DDL/provision layers go through. SQLite's `INTEGER`/`REAL`
    /// are dynamically typed; Postgres needs the wider `BIGINT` (binds are i64; PG `INTEGER` is
    /// 32-bit) and `DOUBLE PRECISION`. TEXT is portable.
    pub fn sqlType(self: Dialect, sc: StorageClass) []const u8 {
        return switch (self.kind) {
            .sqlite => switch (sc) {
                .integer => "INTEGER",
                .real => "REAL",
                .text => "TEXT",
            },
            .postgres => switch (sc) {
                .integer => "BIGINT",
                .real => "DOUBLE PRECISION",
                .text => "TEXT",
            },
        };
    }

    /// The `LIKE` operator keyword. SQLite's `LIKE` is ASCII-case-insensitive by default;
    /// Postgres's `LIKE` is case-sensitive, so to match SQLite's behavior a case-insensitive
    /// match emits `ILIKE`.
    pub fn likeOp(self: Dialect, case_insensitive: bool) []const u8 {
        return switch (self.kind) {
            .sqlite => "LIKE",
            .postgres => if (case_insensitive) "ILIKE" else "LIKE",
        };
    }

    /// A trailing `COLLATE` clause giving case-insensitive ordering/comparison for a text
    /// column, or "" when the backend has no direct analog. SQLite ships `NOCASE`; Postgres has
    /// no built-in case-insensitive collation (citext / a `lower()` expression index is the
    /// portable route — handled by the index DDL in PR-2), so this returns "" there.
    pub fn collateNocase(self: Dialect) []const u8 {
        return switch (self.kind) {
            .sqlite => " COLLATE NOCASE",
            .postgres => "",
        };
    }

    /// The explicit NULL-ordering suffix for an ORDER BY term. SQLite sorts NULLs FIRST for
    /// ascending and LAST for descending (and has no `NULLS` syntax, so this is ""); Postgres
    /// defaults to the OPPOSITE (NULLs LAST for ascending), so it must spell out the SQLite
    /// ordering to match keyset-pagination behavior.
    pub fn nullsOrder(self: Dialect, dir: SortDir) []const u8 {
        return switch (self.kind) {
            .sqlite => "",
            .postgres => switch (dir) {
                .asc => " NULLS FIRST",
                .desc => " NULLS LAST",
            },
        };
    }

    /// The INSERT verb that silently ignores a unique/PK conflict on the inserted row.
    /// SQLite spells this `INSERT OR IGNORE` (a verb prefix); Postgres expresses it as a plain
    /// `INSERT` with an `ON CONFLICT DO NOTHING` SUFFIX (see `onConflictDoNothing`). Callers
    /// emit `<insertVerb()> INTO … <onConflictDoNothing()>`; on SQLite the suffix is "".
    pub fn insertVerb(self: Dialect, or_ignore: bool) []const u8 {
        return switch (self.kind) {
            .sqlite => if (or_ignore) "INSERT OR IGNORE" else "INSERT",
            .postgres => "INSERT",
        };
    }

    /// The conflict-ignoring suffix paired with `insertVerb(true)`. "" on SQLite (the verb
    /// carries it); ` ON CONFLICT DO NOTHING` on Postgres.
    pub fn onConflictDoNothing(self: Dialect) []const u8 {
        return switch (self.kind) {
            .sqlite => "",
            .postgres => " ON CONFLICT DO NOTHING",
        };
    }

    /// A `CAST(expr AS <type>)` expression. Portable across both backends; centralized here so
    /// the `<type>` keyword can diverge later (e.g. a future `jsonb` cast) without touching call
    /// sites. `type_sql` is a trusted, dialect-correct type keyword (often `sqlType(...)`).
    pub fn castExpr(self: Dialect, alloc: std.mem.Allocator, expr: []const u8, type_sql: []const u8) ![]u8 {
        _ = self;
        return std.fmt.allocPrint(alloc, "CAST({s} AS {s})", .{ expr, type_sql });
    }

    /// A boolean predicate that is TRUE when the ISO-8601 TEXT timestamp in `col` is in the past
    /// (i.e. a TTL row has expired), comparing against the backend's current time. `col` is a
    /// trusted, already-quoted identifier.
    ///
    /// **Fail-safe (M-3):** this feeds record DELETION (TTL GC), so a MALFORMED `col` value must
    /// be treated as NOT expired (never silently deleted). SQLite's `strftime` returns NULL on a
    /// malformed value, so its `>` comparison is NULL → the row doesn't match → not deleted. The
    /// Postgres arm reproduces that: a plain text `>` never yields NULL (a garbage string could
    /// compare as "expired"), so it is GUARDED by a regex validity check on `col` — only a
    /// well-formed `YYYY-MM-DDTHH:MM:SSZ` value is eligible; a malformed one fails the AND and is
    /// treated as not expired. (ISO-8601 `Z` strings sort chronologically as text, so the `>` is
    /// correct once the shape is validated.)
    pub fn ttlExpiredPredicate(self: Dialect, alloc: std.mem.Allocator, col: []const u8) ![]u8 {
        return switch (self.kind) {
            .sqlite => std.fmt.allocPrint(alloc, "strftime('%Y-%m-%dT%H:%M:%SZ','now') > {s}", .{col}),
            .postgres => std.fmt.allocPrint(
                alloc,
                "({s} ~ '^[0-9]{{4}}-[0-9]{{2}}-[0-9]{{2}}T[0-9]{{2}}:[0-9]{{2}}:[0-9]{{2}}Z$' AND {s} > {s})",
                .{ col, self.nowIso8601Expr(), col },
            ),
        };
    }
};

// ---------------------------------------------------------------------------
// Tests — pure string assertions; run in EVERY build (no backend needed).
// ---------------------------------------------------------------------------

test "dialect: placeholder differs (? vs \\$n)" {
    var buf: [Dialect.placeholder_buf_len]u8 = undefined;
    try std.testing.expectEqualStrings("?", Dialect.sqlite.placeholder(&buf, 1));
    try std.testing.expectEqualStrings("?", Dialect.sqlite.placeholder(&buf, 7));
    try std.testing.expectEqualStrings("$1", Dialect.postgres.placeholder(&buf, 1));
    try std.testing.expectEqualStrings("$42", Dialect.postgres.placeholder(&buf, 42));
}

test "dialect: now expressions differ" {
    try std.testing.expectEqualStrings("datetime('now')", Dialect.sqlite.nowExpr());
    try std.testing.expectEqualStrings("now()", Dialect.postgres.nowExpr());
    try std.testing.expectEqualStrings("strftime('%Y-%m-%dT%H:%M:%SZ','now')", Dialect.sqlite.nowIso8601Expr());
    try std.testing.expect(std.mem.indexOf(u8, Dialect.postgres.nowIso8601Expr(), "to_char(now()") != null);
}

test "dialect: sqlType maps storage classes per backend" {
    // SQLite: INTEGER/REAL/TEXT (unchanged from the historical schema.Field.sqlType).
    try std.testing.expectEqualStrings("INTEGER", Dialect.sqlite.sqlType(.integer));
    try std.testing.expectEqualStrings("REAL", Dialect.sqlite.sqlType(.real));
    try std.testing.expectEqualStrings("TEXT", Dialect.sqlite.sqlType(.text));
    // Postgres: wider integer/float, portable text.
    try std.testing.expectEqualStrings("BIGINT", Dialect.postgres.sqlType(.integer));
    try std.testing.expectEqualStrings("DOUBLE PRECISION", Dialect.postgres.sqlType(.real));
    try std.testing.expectEqualStrings("TEXT", Dialect.postgres.sqlType(.text));
}

test "dialect: likeOp emits ILIKE only for case-insensitive Postgres" {
    try std.testing.expectEqualStrings("LIKE", Dialect.sqlite.likeOp(true));
    try std.testing.expectEqualStrings("LIKE", Dialect.sqlite.likeOp(false));
    try std.testing.expectEqualStrings("ILIKE", Dialect.postgres.likeOp(true));
    try std.testing.expectEqualStrings("LIKE", Dialect.postgres.likeOp(false));
}

test "dialect: nullsOrder is explicit only on Postgres" {
    try std.testing.expectEqualStrings("", Dialect.sqlite.nullsOrder(.asc));
    try std.testing.expectEqualStrings("", Dialect.sqlite.nullsOrder(.desc));
    try std.testing.expectEqualStrings(" NULLS FIRST", Dialect.postgres.nullsOrder(.asc));
    try std.testing.expectEqualStrings(" NULLS LAST", Dialect.postgres.nullsOrder(.desc));
}

test "dialect: collate + insert-ignore + on-conflict differ" {
    try std.testing.expectEqualStrings(" COLLATE NOCASE", Dialect.sqlite.collateNocase());
    try std.testing.expectEqualStrings("", Dialect.postgres.collateNocase());
    try std.testing.expectEqualStrings("INSERT OR IGNORE", Dialect.sqlite.insertVerb(true));
    try std.testing.expectEqualStrings("INSERT", Dialect.postgres.insertVerb(true));
    try std.testing.expectEqualStrings("", Dialect.sqlite.onConflictDoNothing());
    try std.testing.expectEqualStrings(" ON CONFLICT DO NOTHING", Dialect.postgres.onConflictDoNothing());
}

test "dialect: cast + ttl predicate" {
    const a = std.testing.allocator;
    const c1 = try Dialect.sqlite.castExpr(a, "\"n\"", "REAL");
    defer a.free(c1);
    try std.testing.expectEqualStrings("CAST(\"n\" AS REAL)", c1);

    const t1 = try Dialect.sqlite.ttlExpiredPredicate(a, "\"expires\"");
    defer a.free(t1);
    try std.testing.expect(std.mem.startsWith(u8, t1, "strftime("));
    const t2 = try Dialect.postgres.ttlExpiredPredicate(a, "\"expires\"");
    defer a.free(t2);
    try std.testing.expect(std.mem.indexOf(u8, t2, "> \"expires\"") != null);
    // M-3 fail-safe: the PG arm guards the compare with a regex validity check on col, so a
    // malformed timestamp is treated as NOT expired (never deleted) — matching SQLite's NULL.
    try std.testing.expect(std.mem.indexOf(u8, t2, "\"expires\" ~ '^") != null);
    try std.testing.expect(std.mem.indexOf(u8, t2, " AND ") != null);
}
