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

    /// A SQL expression evaluating to "now" as a TEXT value suitable for INSERT/UPDATE into a
    /// TEXT timestamp column (the `_collections`/`_migrations` metadata timestamps). The SQLite arm
    /// is byte-identical to the historical `datetime('now')` so existing seed rows keep their exact
    /// format. The Postgres arm uses the ISO-8601 `Z` shape (NOT `now()::text`, which would carry
    /// microseconds + a `+00` tz offset) so the stored metadata timestamp has a clean, predictable
    /// shape across backends. (`now()` is a `timestamptz` with no implicit assignment cast to
    /// `text`, so an explicit text-producing expression is required on Postgres regardless.)
    pub fn nowTextExpr(self: Dialect) []const u8 {
        return switch (self.kind) {
            .sqlite => "datetime('now')",
            .postgres => self.nowIso8601Expr(),
        };
    }

    /// A trailing `COLLATE` clause that pins a TEXT column to byte (binary) ordering, or "" when
    /// the backend already orders text that way. SQLite's default text collation is BINARY (raw
    /// byte order); Postgres orders by the database LOCALE, so the same TEXT `ORDER BY` / keyset
    /// comparison (notably the `id` tiebreaker) yields a DIFFERENT order — breaking cross-backend
    /// pagination determinism. Postgres pins it back with `COLLATE "C"` (the byte-order collation,
    /// always present). NOT applied to case-insensitive (`.nocase`) columns, which intentionally
    /// need a different collation (handled separately).
    pub fn textCollate(self: Dialect) []const u8 {
        return switch (self.kind) {
            .sqlite => "",
            .postgres => " COLLATE \"C\"",
        };
    }

    /// The column definition for an auto-incrementing integer PRIMARY KEY (used by the
    /// `_migrations` ledger). SQLite spells it `INTEGER PRIMARY KEY AUTOINCREMENT`; Postgres uses
    /// an identity column. The app never supplies this id (it is auto-filled), so both forms are
    /// write-compatible with the existing `INSERT (name, applied_at)` statements.
    pub fn autoIncPk(self: Dialect) []const u8 {
        return switch (self.kind) {
            .sqlite => "INTEGER PRIMARY KEY AUTOINCREMENT",
            .postgres => "BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY",
        };
    }

    /// Rewrite a curated SQL statement that uses SQLite's numbered placeholders (`?1..?N`) into
    /// the active backend's positional form. SQLite keeps `?N` (byte-identical dupe); Postgres
    /// rewrites each `?<digits>` run to `$<digits>` (the driver binds `$n` positionally and a
    /// repeated `?1`/`$1` reuses the same param). The result is NUL-terminated for `Db.prepare`.
    ///
    /// This is the focused PR-2 lowering for the schema/migration prepared statements
    /// (`_collections` CRUD, `_migrations` ledger); the comprehensive `$n` ParamSink rework over
    /// the whole read/query stack is PR-3. Only `?` immediately followed by a digit is rewritten,
    /// so a bare `?` (none appear in the curated statements) is left untouched.
    pub fn renumberPlaceholders(self: Dialect, alloc: std.mem.Allocator, sql: []const u8) ![:0]u8 {
        if (self.kind == .sqlite) return alloc.dupeZ(u8, sql);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        var i: usize = 0;
        while (i < sql.len) {
            if (sql[i] == '?' and i + 1 < sql.len and std.ascii.isDigit(sql[i + 1])) {
                try out.append(alloc, '$');
                i += 1;
                while (i < sql.len and std.ascii.isDigit(sql[i])) : (i += 1) try out.append(alloc, sql[i]);
            } else {
                try out.append(alloc, sql[i]);
                i += 1;
            }
        }
        return out.toOwnedSliceSentinel(alloc, 0);
    }

    /// Lower a curated *migration* statement written in the SQLite flavor to the active backend.
    /// On SQLite it returns a byte-identical NUL-terminated dupe (so SQLite DDL/seeds are
    /// unchanged); on Postgres it applies the three migration-level SQLite-isms via the dialect:
    ///   * the `INTEGER` column-type keyword → `sqlType(.integer)` (`BIGINT`),
    ///   * `datetime('now')` → `nowTextExpr()` (`now()::text`),
    ///   * `INSERT OR IGNORE … ;` → `INSERT …  ON CONFLICT DO NOTHING ;`.
    /// It deliberately does NOT touch placeholders (migrations seed with literal/bound values, not
    /// `?N`) and is brace-safe (no `std.fmt`), so seed JSON blobs pass through verbatim. The
    /// `INTEGER` substitution is safe for these statements because `INTEGER` never appears inside a
    /// string literal or identifier in the system migrations (only as a column type).
    pub fn lowerMigrationSql(self: Dialect, alloc: std.mem.Allocator, sql: []const u8) ![:0]u8 {
        if (self.kind == .sqlite) return alloc.dupeZ(u8, sql);
        // Intermediates are freed explicitly so the function is leak-correct for any allocator
        // (production callers pass an arena, but the unit tests use the checked testing allocator).
        const s1 = try std.mem.replaceOwned(u8, alloc, sql, "INTEGER", self.sqlType(.integer));
        defer alloc.free(s1);
        const s2 = try std.mem.replaceOwned(u8, alloc, s1, "datetime('now')", self.nowTextExpr());
        defer alloc.free(s2);
        if (std.mem.indexOf(u8, s2, "INSERT OR IGNORE") == null) return alloc.dupeZ(u8, s2);
        const s3 = try std.mem.replaceOwned(u8, alloc, s2, "INSERT OR IGNORE", "INSERT");
        defer alloc.free(s3);
        // The `ON CONFLICT DO NOTHING` suffix must land before the statement TERMINATOR — but a
        // `lastIndexOfScalar(';')` would mis-split a statement whose JSON/string literal contains a
        // `;`. So trim trailing whitespace + a single trailing `;` (the real terminator), append the
        // clause, then re-add the `;` if one was present. (gemini #1.)
        var end = s3.len;
        while (end > 0 and std.ascii.isWhitespace(s3[end - 1])) end -= 1;
        const had_semi = end > 0 and s3[end - 1] == ';';
        if (had_semi) end -= 1;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.appendSlice(alloc, s3[0..end]);
        try out.appendSlice(alloc, " ON CONFLICT DO NOTHING");
        if (had_semi) try out.append(alloc, ';');
        return out.toOwnedSliceSentinel(alloc, 0);
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

test "dialect: nowTextExpr + autoIncPk keep SQLite byte-identical, diverge on PG" {
    try std.testing.expectEqualStrings("datetime('now')", Dialect.sqlite.nowTextExpr());
    // PG uses the ISO-8601 Z shape (not now()::text with microseconds/tz), matching nowIso8601Expr.
    try std.testing.expectEqualStrings(Dialect.postgres.nowIso8601Expr(), Dialect.postgres.nowTextExpr());
    try std.testing.expect(std.mem.indexOf(u8, Dialect.postgres.nowTextExpr(), "to_char(now()") != null);
    try std.testing.expectEqualStrings("INTEGER PRIMARY KEY AUTOINCREMENT", Dialect.sqlite.autoIncPk());
    try std.testing.expect(std.mem.indexOf(u8, Dialect.postgres.autoIncPk(), "IDENTITY") != null);
}

test "dialect: textCollate pins PG text to byte order, no-op on SQLite" {
    try std.testing.expectEqualStrings("", Dialect.sqlite.textCollate());
    try std.testing.expectEqualStrings(" COLLATE \"C\"", Dialect.postgres.textCollate());
}

test "dialect: renumberPlaceholders ?N -> $N only on Postgres" {
    const a = std.testing.allocator;
    const tmpl = "SELECT 1 FROM t WHERE id = ?1 OR name = ?1 AND x = ?10;";
    const s = try Dialect.sqlite.renumberPlaceholders(a, tmpl);
    defer a.free(s);
    try std.testing.expectEqualStrings(tmpl, s); // SQLite: byte-identical
    const p = try Dialect.postgres.renumberPlaceholders(a, tmpl);
    defer a.free(p);
    try std.testing.expectEqualStrings("SELECT 1 FROM t WHERE id = $1 OR name = $1 AND x = $10;", p);
}

test "dialect: lowerMigrationSql is identity on SQLite, lowers the three isms on PG" {
    const a = std.testing.allocator;
    // SQLite: byte-identical (DDL + seed unchanged).
    const ddl = "CREATE TABLE \"t\" (\"x\" INTEGER NOT NULL DEFAULT 0, \"c\" TEXT);";
    const s = try Dialect.sqlite.lowerMigrationSql(a, ddl);
    defer a.free(s);
    try std.testing.expectEqualStrings(ddl, s);
    // Postgres: INTEGER -> BIGINT.
    const p = try Dialect.postgres.lowerMigrationSql(a, ddl);
    defer a.free(p);
    try std.testing.expectEqualStrings("CREATE TABLE \"t\" (\"x\" BIGINT NOT NULL DEFAULT 0, \"c\" TEXT);", p);
    // Postgres seed: INSERT OR IGNORE + datetime('now') + brace-laden JSON pass through (the now
    // expr lowers to the ISO to_char form).
    const seed = "INSERT OR IGNORE INTO \"c\" (\"id\",\"opt\") VALUES ('a','{\"k\":{}}');";
    const ps = try Dialect.postgres.lowerMigrationSql(a, seed);
    defer a.free(ps);
    try std.testing.expectEqualStrings(
        "INSERT INTO \"c\" (\"id\",\"opt\") VALUES ('a','{\"k\":{}}') ON CONFLICT DO NOTHING;",
        ps,
    );

    // gemini #1: a `;` INSIDE a string literal must NOT be treated as the terminator — the
    // ON CONFLICT clause still lands before the single real trailing `;`.
    const tricky = "INSERT OR IGNORE INTO \"c\" (\"id\",\"note\") VALUES ('a','hello; world');";
    const pt = try Dialect.postgres.lowerMigrationSql(a, tricky);
    defer a.free(pt);
    try std.testing.expectEqualStrings(
        "INSERT INTO \"c\" (\"id\",\"note\") VALUES ('a','hello; world') ON CONFLICT DO NOTHING;",
        pt,
    );
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
