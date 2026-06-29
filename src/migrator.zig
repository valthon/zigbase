//! `Migrator` — the dialect-aware handle threaded into every migration's `up` function (issue
//! #159, PR-2). It carries the live `*db.Db`, the active SQL `Dialect`, a short-lived arena, and
//! (for consumer migrations) the request `std.Io`, plus the helpers a migration uses to emit
//! backend-correct SQL.
//!
//! ## The cross-backend migration contract
//!
//! ZigBase runs on SQLite (default) or, when built with `-Dpostgres`, PostgreSQL — chosen at
//! startup from the connection string. The framework's OWN 16 system migrations are written ONCE
//! and lowered to the active backend by the dialect (`execLowered`), so they provision cleanly on
//! both. A **consumer** `.migrations` entry's `up(m: *Migrator)` likewise receives the dialect:
//!
//!   * `m.execLowered(sql)` — run a curated statement written in the SQLite flavor; the dialect
//!     lowers the migration-level SQLite-isms (`INTEGER`→`BIGINT`, `datetime('now')`→a text now,
//!     `INSERT OR IGNORE`→`ON CONFLICT DO NOTHING`) on Postgres and leaves SQLite byte-identical.
//!     Good enough for most additive DDL + seeds.
//!   * `m.exec(sql)` — run **raw, backend-specific** SQL verbatim. It is the consumer's job to
//!     ensure dialect-correctness; SQLite-only SQL run on Postgres FAILS LOUD (the DB rejects it
//!     and the migration aborts startup — migrations are fail-fast). Branch with `m.dialect.kind`
//!     or `m.rawFor(.sqlite, …)` / `m.rawFor(.postgres, …)`.
//!   * `m.requireBackend(.sqlite)` — assert the active backend up front and fail loudly (with a
//!     clear log) if a migration is backend-specific and is being run on the wrong one.
//!
//! There is deliberately **no SQL transpiler** (a SQLite→PG string rewriter): it is fragile and
//! silently mis-handles the exact edges that matter. Pass-the-dialect + an honest raw escape hatch
//! is the contract (the user-locked F-REBUILD decision).

const std = @import("std");
const db = @import("db.zig");
const dialect_mod = @import("sql/dialect.zig");

pub const Migrator = struct {
    /// The live writer connection the migration runs against.
    db: *db.Db,
    /// The active backend's SQL dialect. Branch on `dialect.kind` (`.sqlite`/`.postgres`).
    dialect: dialect_mod.Dialect,
    /// A short-lived arena scoped to the migration run. Anything allocated here is freed when the
    /// run completes — do not store pointers derived from it beyond the migration.
    arena: std.mem.Allocator,
    /// The request `std.Io`. Provided for consumer migrations (id generation, etc.); the system
    /// migrations never read it (it is left `undefined` for `migrations.run`).
    io: std.Io,

    pub const Error = error{WrongBackend} || db.DbError;

    /// The active backend tag.
    pub fn backend(self: *const Migrator) db.Backend {
        return switch (self.dialect.kind) {
            .sqlite => .sqlite,
            .postgres => .postgres,
        };
    }

    /// Run raw SQL verbatim on the active backend. Backend-specific: the caller owns dialect
    /// correctness (see the module doc). Prefer `execLowered` for portable DDL/seeds.
    pub fn exec(self: *Migrator, sql: [:0]const u8) db.DbError!void {
        return self.db.exec(sql);
    }

    /// Run a curated statement written in the SQLite flavor, lowered to the active backend by the
    /// dialect (`INTEGER`→backend int type, `datetime('now')`→text now, `INSERT OR IGNORE`→
    /// `ON CONFLICT DO NOTHING`). SQLite is byte-identical to the original statement.
    ///
    /// **Contract:** ONE statement per call, intended for the narrow set of portable
    /// migration-level SQLite-isms above — type-keyword DDL (`CREATE TABLE` / `ALTER … ADD COLUMN`)
    /// and `INSERT OR IGNORE` seeds. It is a small, brace-safe string lowering, NOT a general SQL
    /// transpiler: it textually rewrites the `INTEGER` keyword and the `datetime('now')` token, so
    /// SQL whose string literals contain those substrings, or anything needing other dialect
    /// divergence, must use `exec`/`rawFor` and own its dialect correctness.
    pub fn execLowered(self: *Migrator, sql: [:0]const u8) db.DbError!void {
        const lowered = self.dialect.lowerMigrationSql(self.arena, sql) catch return error.ExecFailed;
        return self.db.exec(lowered);
    }

    /// `std.fmt`-format a statement into the arena and run it raw (backend-specific). The format
    /// string is comptime; remember `std.fmt` treats `{`/`}` specially (double them in SQL).
    pub fn execf(self: *Migrator, comptime fmt: []const u8, args: anytype) db.DbError!void {
        const sql = std.fmt.allocPrintSentinel(self.arena, fmt, args, 0) catch return error.ExecFailed;
        return self.db.exec(sql);
    }

    /// Run `sql` only when the active backend is `kind`; otherwise a no-op. The escape hatch for a
    /// migration that needs genuinely different SQL per backend.
    pub fn rawFor(self: *Migrator, kind: dialect_mod.Kind, sql: [:0]const u8) db.DbError!void {
        if (self.dialect.kind == kind) return self.db.exec(sql);
    }

    /// Fail loudly (`error.WrongBackend`, with a logged message) unless the active backend is
    /// `kind`. For a migration that is intentionally written for one backend only.
    pub fn requireBackend(self: *Migrator, kind: dialect_mod.Kind) error{WrongBackend}!void {
        if (self.dialect.kind != kind) {
            std.log.err(
                "migration requires the {s} backend but the active backend is {s} — aborting (write a dialect-aware migration or branch on m.dialect.kind)",
                .{ @tagName(kind), @tagName(self.dialect.kind) },
            );
            return error.WrongBackend;
        }
    }

    /// Prepare a curated statement written with SQLite numbered placeholders (`?1..?N`), rewriting
    /// to `$N` on Postgres. For the framework's own metadata DML; record CRUD is PR-3.
    pub fn prepare(self: *Migrator, sql: []const u8) db.DbError!db.Stmt {
        const lowered = self.dialect.renumberPlaceholders(self.arena, sql) catch return error.PrepareFailed;
        return self.db.prepare(lowered);
    }
};

test "migrator: rawFor runs only on the matching backend (sqlite)" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = Migrator{ .db = &d, .dialect = db.dbDialect(&d), .arena = arena.allocator(), .io = undefined };
    try std.testing.expectEqual(db.Backend.sqlite, m.backend());

    // A .postgres-only raw statement is skipped on SQLite (never executed → no error).
    try m.rawFor(.postgres, "THIS IS NOT VALID SQL;");
    // A .sqlite raw statement runs.
    try m.rawFor(.sqlite, "CREATE TABLE rf (x INTEGER);");
    try m.exec("INSERT INTO rf (x) VALUES (1);");

    // requireBackend passes for the active backend (the mismatch path logs + errors loudly, which
    // the test runner would flag as a logged error, so only the happy path is asserted here).
    try m.requireBackend(.sqlite);

    // execLowered is byte-identical on SQLite (the table already exists → IF NOT EXISTS no-op).
    try m.execLowered("CREATE TABLE IF NOT EXISTS rf (x INTEGER);");
    var st = try m.prepare("SELECT x FROM rf WHERE x = ?1;");
    defer st.finalize();
    try st.bindInt(1, 1);
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 1), st.columnInt(0));
}
