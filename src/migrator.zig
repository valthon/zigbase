//! `Migrator` — the dialect-aware handle threaded into every migration's `up` function (issue
//! #159, PR-2). It carries the live `*db.Db`, the active SQL `Dialect`, a short-lived arena, and
//! (for consumer migrations) the request `std.Io`, plus the helpers a migration uses to emit
//! backend-correct SQL.
//!
//! ## The cross-backend migration contract
//!
//! ZigBase runs on SQLite (default) or, when built with `-Dpostgres`, PostgreSQL — chosen at
//! startup from the connection string. The framework's OWN system migrations are written ONCE
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
const ddl = @import("ddl.zig");
const schema = @import("schema.zig");
const records_mod = @import("records.zig");
const collections_mod = @import("collections.zig");

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
    /// Apply direction: `.forward` runs each DSL op's forward SQL; `.reverse` (Piece B rollback)
    /// runs its inverse — or fails via `notReversible` for ops with no known inverse.
    direction: Direction = .forward,

    /// The direction a `change`/DSL op is being applied in. Forward is the default; reverse is
    /// the rollback pass (Piece B) that inverts each op.
    pub const Direction = enum { forward, reverse };

    /// A logical column type for the schema DSL (`createTable`/`addColumn`). Mapped to the
    /// backend-native TYPE keyword by `colTypeSql`: `text`/`integer`/`real` route through the
    /// dialect's storage-class mapping (`TEXT`, `INTEGER`/`BIGINT`, `REAL`/`DOUBLE PRECISION`);
    /// `boolean`/`blob`/`timestamp` have no storage-class analog and take a dialect-native keyword
    /// (`INTEGER`/`BOOLEAN`, `BLOB`/`BYTEA`, `TEXT`/`TIMESTAMPTZ`) — these tables are migration-owned.
    pub const ColType = enum { text, integer, real, boolean, blob, timestamp };

    /// A column declaration for the schema DSL. `default` is a raw, dialect-correct SQL expression
    /// (e.g. `"0"`, `"'draft'"`, `"now()"`) spliced verbatim; `pk` implies NOT NULL.
    pub const Col = struct {
        name: []const u8,
        type: ColType,
        null: bool = true,
        pk: bool = false,
        default: ?[]const u8 = null,
    };

    pub const Error = error{WrongBackend} || db.DbError;

    /// The error set a DSL op (including `raw`) can return: DB errors plus the reverse-mode
    /// "no known inverse" guard from `notReversible`.
    pub const OpError = db.DbError || error{MigrationNotReversible};

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

    /// A statement that genuinely diverges per backend; runs the arm for the active dialect.
    /// `raw` is irreversible: it carries no known inverse, so a `change` that uses it and is
    /// then rolled back (Piece B) fails loudly in reverse mode — pair such a change with `up`/`down`.
    pub fn raw(self: *Migrator, per: struct { sqlite: [:0]const u8, postgres: [:0]const u8 }) OpError!void {
        if (self.direction == .reverse) return self.notReversible("raw");
        return switch (self.dialect.kind) {
            .sqlite => self.exec(per.sqlite),
            .postgres => self.exec(per.postgres),
        };
    }

    /// Reverse-mode guard: an op that cannot auto-invert calls this to fail loudly (logging which
    /// op) rather than silently skipping. Consumed by every DSL op in reverse mode.
    ///
    /// Logs at `.warn`, not `.err`: this is an expected-failure path that unit tests exercise
    /// directly via `expectError`, and an `.err`-level log would trip the Zig test runner's
    /// "logged N errors" failure (same precedent as `provision.injectOAuthSecrets` and
    /// `static_files.validateRouteTargetsDir`). The real rollback caller (Piece B) still surfaces
    /// the returned error loudly.
    fn notReversible(self: *Migrator, comptime op: []const u8) error{MigrationNotReversible} {
        _ = self;
        std.log.warn("migration: `" ++ op ++ "` is not auto-reversible in a `change` migration; provide up/down", .{});
        return error.MigrationNotReversible;
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

    // -----------------------------------------------------------------------
    // Schema DSL (auto-reversible ops)
    //
    // Every op follows the same shape: `if (self.direction == .reverse) { <inverse, or
    // notReversible> } else { <forward SQL> }`. Forward SQL reuses the `ddl.zig` generators and
    // the shared `colTypeSql`/`columnDefSql` helpers below so type-mapping + ident-quoting live in
    // ONE place. Arena/format failures map to `error.ExecFailed` (a `db.DbError`), matching the
    // existing `execLowered`/`execf` convention.
    // -----------------------------------------------------------------------

    /// The backend-native column TYPE keyword for a DSL `ColType`. The DRY chokepoint shared by
    /// `createTable`/`addColumn`; `text`/`integer`/`real` go through `dialect.sqlType`.
    fn colTypeSql(self: *const Migrator, t: ColType) []const u8 {
        return switch (t) {
            .text => self.dialect.sqlType(.text),
            .integer => self.dialect.sqlType(.integer),
            .real => self.dialect.sqlType(.real),
            .boolean => switch (self.dialect.kind) {
                .sqlite => "INTEGER",
                .postgres => "BOOLEAN",
            },
            .blob => switch (self.dialect.kind) {
                .sqlite => "BLOB",
                .postgres => "BYTEA",
            },
            .timestamp => switch (self.dialect.kind) {
                .sqlite => "TEXT",
                .postgres => "TIMESTAMPTZ",
            },
        };
    }

    /// `"name" TYPE [PRIMARY KEY | NOT NULL] [DEFAULT <expr>]` — the single column-definition
    /// builder used by both `createTable` and `addColumn` (DRY). `pk` implies NOT NULL.
    fn columnDefSql(self: *Migrator, col: Col) std.mem.Allocator.Error![]u8 {
        const a = self.arena;
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, try ddl.quoteIdent(a, col.name));
        try out.append(a, ' ');
        try out.appendSlice(a, self.colTypeSql(col.type));
        if (col.pk) {
            try out.appendSlice(a, " PRIMARY KEY");
        } else if (!col.null) {
            try out.appendSlice(a, " NOT NULL");
        }
        if (col.default) |dfl| {
            try out.appendSlice(a, " DEFAULT ");
            try out.appendSlice(a, dfl);
        }
        return out.toOwnedSlice(a);
    }

    /// Dupe an arena-built statement to a sentinel-terminated slice and run it.
    fn execArena(self: *Migrator, sql: []const u8) OpError!void {
        const z = self.arena.dupeZ(u8, sql) catch return error.ExecFailed;
        return self.exec(z);
    }

    fn createTableForward(self: *Migrator, name: []const u8, cols: []const Col) OpError!void {
        const a = self.arena;
        var out: std.ArrayList(u8) = .empty;
        out.appendSlice(a, "CREATE TABLE ") catch return error.ExecFailed;
        out.appendSlice(a, ddl.quoteIdent(a, name) catch return error.ExecFailed) catch return error.ExecFailed;
        out.appendSlice(a, " (") catch return error.ExecFailed;
        for (cols, 0..) |col, i| {
            if (i > 0) out.appendSlice(a, ", ") catch return error.ExecFailed;
            out.appendSlice(a, self.columnDefSql(col) catch return error.ExecFailed) catch return error.ExecFailed;
        }
        out.appendSlice(a, ");") catch return error.ExecFailed;
        return self.execArena(out.items);
    }

    fn dropTableForward(self: *Migrator, name: []const u8) OpError!void {
        const q = ddl.quoteIdent(self.arena, name) catch return error.ExecFailed;
        const sql = std.fmt.allocPrintSentinel(self.arena, "DROP TABLE IF EXISTS {s};", .{q}, 0) catch return error.ExecFailed;
        return self.exec(sql);
    }

    /// Create a table from an ordered column list. Reverse mode drops it (auto-reversible).
    pub fn createTable(self: *Migrator, name: []const u8, cols: []const Col) OpError!void {
        if (self.direction == .reverse) return self.dropTableForward(name);
        return self.createTableForward(name, cols);
    }

    /// Drop a table. Auto-reversible ONLY when `.was` (the original column list) is supplied — the
    /// inverse re-creates it; without `.was` a rollback has nothing to rebuild from → not reversible.
    pub fn dropTable(self: *Migrator, name: []const u8, opts: struct { was: ?[]const Col = null }) OpError!void {
        if (self.direction == .reverse) {
            const was = opts.was orelse return self.notReversible("dropTable");
            return self.createTableForward(name, was);
        }
        return self.dropTableForward(name);
    }

    fn addColumnForward(self: *Migrator, table: []const u8, col: Col) OpError!void {
        const q = ddl.quoteIdent(self.arena, table) catch return error.ExecFailed;
        const def = self.columnDefSql(col) catch return error.ExecFailed;
        const sql = std.fmt.allocPrintSentinel(self.arena, "ALTER TABLE {s} ADD COLUMN {s};", .{ q, def }, 0) catch return error.ExecFailed;
        return self.exec(sql);
    }

    fn dropColumnForward(self: *Migrator, table: []const u8, name: []const u8) OpError!void {
        const qt = ddl.quoteIdent(self.arena, table) catch return error.ExecFailed;
        const qc = ddl.quoteIdent(self.arena, name) catch return error.ExecFailed;
        const sql = std.fmt.allocPrintSentinel(self.arena, "ALTER TABLE {s} DROP COLUMN {s};", .{ qt, qc }, 0) catch return error.ExecFailed;
        return self.exec(sql);
    }

    /// Add a column to an existing table. Reverse mode drops it (auto-reversible). SQLite `DROP
    /// COLUMN` needs SQLite ≥ 3.35 (the vendored amalgamation is far newer, so this is safe).
    pub fn addColumn(self: *Migrator, table: []const u8, col: Col) OpError!void {
        if (self.direction == .reverse) return self.dropColumnForward(table, col.name);
        return self.addColumnForward(table, col);
    }

    /// Drop a column. Auto-reversible ONLY with `.was` (the original column decl) so the inverse
    /// can re-add it with the correct type/constraints; without it a rollback can't rebuild it.
    pub fn dropColumn(self: *Migrator, table: []const u8, name: []const u8, opts: struct { was: ?Col = null }) OpError!void {
        if (self.direction == .reverse) {
            const was = opts.was orelse return self.notReversible("dropColumn");
            return self.addColumnForward(table, was);
        }
        return self.dropColumnForward(table, name);
    }

    /// The deterministic default index name (`idx_<table>_<col1>_<col2>…`) so a reverse `addIndex`
    /// can drop the same index it created without the caller repeating the name.
    fn defaultIndexName(self: *Migrator, table: []const u8, columns: []const []const u8) std.mem.Allocator.Error![]u8 {
        const a = self.arena;
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, "idx_");
        try out.appendSlice(a, table);
        for (columns) |c| {
            try out.append(a, '_');
            try out.appendSlice(a, c);
        }
        return out.toOwnedSlice(a);
    }

    fn addIndexForward(self: *Migrator, table: []const u8, columns: []const []const u8, name: []const u8, unique: bool) OpError!void {
        // Reuse the schema DDL generator (dialect-correct quoting + UNIQUE handling).
        const idx = schema.Index{ .name = name, .fields = columns, .unique = unique };
        const sql = ddl.createIndexSql(self.arena, table, idx, self.dialect) catch return error.ExecFailed;
        return self.execArena(sql);
    }

    fn dropIndexForward(self: *Migrator, name: []const u8) OpError!void {
        const q = ddl.quoteIdent(self.arena, name) catch return error.ExecFailed;
        const sql = std.fmt.allocPrintSentinel(self.arena, "DROP INDEX IF EXISTS {s};", .{q}, 0) catch return error.ExecFailed;
        return self.exec(sql);
    }

    /// Create an index over `columns`. Name defaults to `idx_<table>_<cols…>` (deterministic so the
    /// inverse can name the index it drops). Reverse mode drops the index (auto-reversible).
    pub fn addIndex(self: *Migrator, table: []const u8, columns: []const []const u8, opts: struct { name: ?[]const u8 = null, unique: bool = false }) OpError!void {
        const name = opts.name orelse (self.defaultIndexName(table, columns) catch return error.ExecFailed);
        if (self.direction == .reverse) return self.dropIndexForward(name);
        return self.addIndexForward(table, columns, name, opts.unique);
    }

    /// Drop an index by name. Auto-reversible ONLY with `.was` (its table/columns/unique) so the
    /// inverse can re-create it.
    pub fn dropIndex(self: *Migrator, name: []const u8, opts: struct {
        was: ?struct { table: []const u8, columns: []const []const u8, unique: bool = false } = null,
    }) OpError!void {
        if (self.direction == .reverse) {
            const was = opts.was orelse return self.notReversible("dropIndex");
            return self.addIndexForward(was.table, was.columns, name, was.unique);
        }
        return self.dropIndexForward(name);
    }

    /// Rename a table. Self-inverse: reverse mode renames `to` back to `from` (no extra args) —
    /// forward and inverse are the same statement with the operands swapped.
    pub fn renameTable(self: *Migrator, from: []const u8, to: []const u8) OpError!void {
        const src = if (self.direction == .reverse) to else from;
        const dst = if (self.direction == .reverse) from else to;
        const qs = ddl.quoteIdent(self.arena, src) catch return error.ExecFailed;
        const qd = ddl.quoteIdent(self.arena, dst) catch return error.ExecFailed;
        const sql = std.fmt.allocPrintSentinel(self.arena, "ALTER TABLE {s} RENAME TO {s};", .{ qs, qd }, 0) catch return error.ExecFailed;
        return self.exec(sql);
    }

    /// Rename a column. Self-inverse: reverse mode renames `to` back to `from` (no extra args).
    pub fn renameColumn(self: *Migrator, table: []const u8, from: []const u8, to: []const u8) OpError!void {
        const src = if (self.direction == .reverse) to else from;
        const dst = if (self.direction == .reverse) from else to;
        const qt = ddl.quoteIdent(self.arena, table) catch return error.ExecFailed;
        const qs = ddl.quoteIdent(self.arena, src) catch return error.ExecFailed;
        const qd = ddl.quoteIdent(self.arena, dst) catch return error.ExecFailed;
        const sql = std.fmt.allocPrintSentinel(self.arena, "ALTER TABLE {s} RENAME COLUMN {s} TO {s};", .{ qt, qs, qd }, 0) catch return error.ExecFailed;
        return self.exec(sql);
    }

    /// Pure `ALTER TABLE … ADD CONSTRAINT … FOREIGN KEY …` (Postgres). Factored out so the exact
    /// SQL is unit-testable without a live Postgres connection (mirrors `ddl.zig`'s string tests).
    /// A plain (non-deferrable) constraint — `ddl.addDeferrableFkSql` hardcodes the name/ref-column/
    /// DEFERRABLE for the cycle-load path and doesn't fit the DSL's custom name + ref_column opts.
    fn addForeignKeySqlPg(a: std.mem.Allocator, table: []const u8, name: []const u8, column: []const u8, ref_table: []const u8, ref_column: []const u8, cascade: bool) ![]u8 {
        const on_delete = if (cascade) " ON DELETE CASCADE" else "";
        return std.fmt.allocPrint(
            a,
            "ALTER TABLE \"{s}\" ADD CONSTRAINT \"{s}\" FOREIGN KEY (\"{s}\") REFERENCES \"{s}\" (\"{s}\"){s};",
            .{ table, name, column, ref_table, ref_column, on_delete },
        );
    }

    fn dropConstraintSqlPg(a: std.mem.Allocator, table: []const u8, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(a, "ALTER TABLE \"{s}\" DROP CONSTRAINT IF EXISTS \"{s}\";", .{ table, name });
    }

    /// SQLite guard for `addForeignKey`: SQLite has no `ALTER TABLE ADD/DROP CONSTRAINT` (adding an
    /// FK to an existing table needs a full table rebuild), so v1 supports this op on Postgres only.
    /// Logs at `.warn` (not `.err`, which would trip the test runner) and returns
    /// `error.WrongBackend`; the SQLite escape hatch is `m.raw(.{ .sqlite, .postgres })` or declaring
    /// the FK inline via `createTable`.
    fn foreignKeyUnsupportedOnSqlite(self: *Migrator) error{WrongBackend} {
        _ = self;
        std.log.warn("migration: `addForeignKey` on an existing table is not supported on SQLite (needs a table rebuild); use m.raw(.{{ .sqlite = …, .postgres = … }}) or declare the FK inline in createTable", .{});
        return error.WrongBackend;
    }

    /// Add a foreign key to an existing table. Constraint name defaults to `fk_<table>_<column>`
    /// (deterministic so the inverse can drop it). Reverse mode drops the constraint.
    ///
    /// **Backend support:** Postgres only. SQLite cannot `ALTER TABLE ADD CONSTRAINT` (FK-add
    /// requires a table rebuild), so both directions return `error.WrongBackend` on SQLite — use
    /// `m.raw` or declare the FK inline via `createTable`. (v1 decision: keep the op lean; the
    /// common cross-backend case is a fresh table with an inline FK, which `createTable` covers.)
    pub fn addForeignKey(self: *Migrator, table: []const u8, column: []const u8, ref_table: []const u8, opts: struct {
        ref_column: []const u8 = "id",
        on_delete_cascade: bool = false,
        name: ?[]const u8 = null,
    }) (OpError || error{WrongBackend})!void {
        if (self.dialect.kind == .sqlite) return self.foreignKeyUnsupportedOnSqlite();
        const name = opts.name orelse (std.fmt.allocPrint(self.arena, "fk_{s}_{s}", .{ table, column }) catch return error.ExecFailed);
        if (self.direction == .reverse) {
            const sql = dropConstraintSqlPg(self.arena, table, name) catch return error.ExecFailed;
            return self.execArena(sql);
        }
        const sql = addForeignKeySqlPg(self.arena, table, name, column, ref_table, opts.ref_column, opts.on_delete_cascade) catch return error.ExecFailed;
        return self.execArena(sql);
    }

    // -----------------------------------------------------------------------
    // Data transforms (#241) — `m.records()`
    //
    // A schema DSL reshapes columns; a data migration reshapes the ROWS. `records()` hands back a
    // small facade that reads and writes records through the SAME engine primitives the HTTP API
    // uses (`collections.get` to resolve the collection, `records.get`/`list`/`update` for the
    // row I/O) — so encrypted fields decrypt on read and re-encrypt on write, and typed fields
    // coerce exactly as a normal API write would. The migration does NOT re-implement any of that.
    //
    // Data transforms are IRREVERSIBLE: there is no general inverse for "recompute this field", so
    // `records()` returns `error.MigrationNotReversible` in reverse mode. A `change` that touches
    // data must therefore be paired with an explicit `down` (or written as `up`/`down`).
    // -----------------------------------------------------------------------

    /// A records-aware facade for data migrations, obtained from `Migrator.records()`. Every op
    /// routes through the engine's real record primitives (no re-implemented encryption/coercion).
    /// All ops run in FORWARD semantics only — reverse-mode is rejected at `records()` before a
    /// facade is ever handed out.
    pub const RecordsMig = struct {
        m: *Migrator,

        /// Resolve a collection by name (arena-scoped), or `error.UnknownCollection`.
        fn collection(self: RecordsMig, col_name: []const u8) !schema.Collection {
            return (try collections_mod.get(self.m.arena, self.m.db, col_name)) orelse error.UnknownCollection;
        }

        /// Fetch one record by id, read through the engine (encrypted fields decrypted, values
        /// coerced), or `null` when the collection or record is absent.
        pub fn get(self: RecordsMig, col_name: []const u8, id: []const u8) !?std.json.Value {
            const col = try self.collection(col_name);
            return records_mod.get(self.m.arena, self.m.db, col, id);
        }

        /// Every record of a collection, read through the engine (all pages, arena-allocated). The
        /// entry point for a bulk data transform: iterate, compute, then `update` each row. Rows
        /// come back unscoped (no access rule) — a migration sees the whole table.
        pub fn all(self: RecordsMig, col_name: []const u8) ![]std.json.Value {
            const col = try self.collection(col_name);
            var out: std.ArrayList(std.json.Value) = .empty;
            var page: u32 = 1;
            const per_page: u32 = 500;
            while (true) {
                const res = try records_mod.list(self.m.arena, self.m.db, col, .{ .page = page, .perPage = per_page });
                try out.appendSlice(self.m.arena, res.items);
                if (res.items.len < per_page) break;
                page += 1;
            }
            return out.toOwnedSlice(self.m.arena);
        }

        /// Partial-update a record's fields through the engine write path (only the keys present in
        /// `value` change; encrypted fields re-encrypt, typed fields coerce). Returns the updated
        /// record, or `null` when the id is absent.
        pub fn update(self: RecordsMig, col_name: []const u8, id: []const u8, value: std.json.Value) !?std.json.Value {
            const col = try self.collection(col_name);
            return records_mod.update(self.m.arena, self.m.db, col, id, value);
        }
    };

    /// A records-aware facade for data transforms (#241): iterate a collection and rewrite fields
    /// through the real engine read/update primitives. IRREVERSIBLE — in reverse mode this returns
    /// `error.MigrationNotReversible` (pair a data-transform `change` with an explicit `down`).
    pub fn records(self: *Migrator) OpError!RecordsMig {
        if (self.direction == .reverse) return self.notReversible("records");
        return .{ .m = self };
    }
};

test "raw picks the dialect statement; direction defaults forward" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = Migrator{ .db = &d, .dialect = db.dbDialect(&d), .arena = arena.allocator(), .io = undefined };
    try std.testing.expectEqual(Migrator.Direction.forward, m.direction);
    try m.raw(.{ .sqlite = "CREATE TABLE t(a INTEGER);", .postgres = "CREATE TABLE t(a BIGINT);" });
    // table exists
    var st = try m.prepare("SELECT count(*) FROM t;");
    defer st.finalize();
    try std.testing.expect(try st.step());

    // In reverse mode `raw` has no known inverse and fails loudly (the `.warn` log it emits does
    // not trip the test runner, unlike an `.err`).
    m.direction = .reverse;
    try std.testing.expectError(error.MigrationNotReversible, m.raw(.{ .sqlite = "SELECT 1;", .postgres = "SELECT 1;" }));
}

// ---------------------------------------------------------------------------
// DSL op test helpers
// ---------------------------------------------------------------------------

/// A dialect-portable existence probe: prepare a trivial SELECT against the table; a prepare
/// failure means the relation is absent. (openMemory is SQLite, so these run on SQLite; the PG
/// path is covered by the live PG harness.)
fn tableExists(m: *Migrator, name: []const u8) !bool {
    const sql = try std.fmt.allocPrintSentinel(m.arena, "SELECT 1 FROM \"{s}\" LIMIT 0;", .{name}, 0);
    var st = m.prepare(sql) catch return false;
    st.finalize();
    return true;
}

test "createTable forward creates; reverse drops" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = Migrator{ .db = &d, .dialect = db.dbDialect(&d), .arena = arena.allocator(), .io = undefined };
    const cols = [_]Migrator.Col{
        .{ .name = "id", .type = .integer, .pk = true, .null = false },
        .{ .name = "title", .type = .text },
    };
    try m.createTable("posts", &cols);
    try std.testing.expect(try tableExists(&m, "posts"));

    m.direction = .reverse;
    try m.createTable("posts", &cols); // reverse-mode createTable == DROP TABLE
    try std.testing.expect(!try tableExists(&m, "posts"));
}

test "dropTable forward drops; reverse re-creates from .was; bare reverse errors" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = Migrator{ .db = &d, .dialect = db.dbDialect(&d), .arena = arena.allocator(), .io = undefined };
    const cols = [_]Migrator.Col{
        .{ .name = "id", .type = .integer, .pk = true, .null = false },
        .{ .name = "body", .type = .text },
    };
    try m.createTable("notes", &cols);
    try m.dropTable("notes", .{});
    try std.testing.expect(!try tableExists(&m, "notes"));

    // reverse with .was re-creates the table.
    m.direction = .reverse;
    try m.dropTable("notes", .{ .was = &cols });
    try std.testing.expect(try tableExists(&m, "notes"));
}

test "dropTable without .was is not reversible" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = Migrator{ .db = &d, .dialect = db.dbDialect(&d), .arena = arena.allocator(), .io = undefined };
    m.direction = .reverse;
    try std.testing.expectError(error.MigrationNotReversible, m.dropTable("posts", .{}));
}

/// True when `col` exists on `table` (probe a SELECT of just that column).
fn columnExists(m: *Migrator, table: []const u8, col: []const u8) !bool {
    const sql = try std.fmt.allocPrintSentinel(m.arena, "SELECT \"{s}\" FROM \"{s}\" LIMIT 0;", .{ col, table }, 0);
    var st = m.prepare(sql) catch return false;
    st.finalize();
    return true;
}

test "addColumn forward adds; reverse drops" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = Migrator{ .db = &d, .dialect = db.dbDialect(&d), .arena = arena.allocator(), .io = undefined };
    try m.createTable("posts", &[_]Migrator.Col{.{ .name = "id", .type = .integer, .pk = true, .null = false }});
    try std.testing.expect(!try columnExists(&m, "posts", "views"));

    try m.addColumn("posts", .{ .name = "views", .type = .integer, .null = false, .default = "0" });
    try std.testing.expect(try columnExists(&m, "posts", "views"));

    m.direction = .reverse;
    try m.addColumn("posts", .{ .name = "views", .type = .integer }); // reverse == DROP COLUMN
    try std.testing.expect(!try columnExists(&m, "posts", "views"));
}

test "dropColumn forward drops; reverse re-adds from .was; bare reverse errors" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = Migrator{ .db = &d, .dialect = db.dbDialect(&d), .arena = arena.allocator(), .io = undefined };
    try m.createTable("posts", &[_]Migrator.Col{
        .{ .name = "id", .type = .integer, .pk = true, .null = false },
        .{ .name = "slug", .type = .text },
    });
    try m.dropColumn("posts", "slug", .{});
    try std.testing.expect(!try columnExists(&m, "posts", "slug"));

    // reverse with .was re-adds the column.
    m.direction = .reverse;
    try m.dropColumn("posts", "slug", .{ .was = .{ .name = "slug", .type = .text } });
    try std.testing.expect(try columnExists(&m, "posts", "slug"));

    // without .was, reverse has nothing to rebuild from.
    try std.testing.expectError(error.MigrationNotReversible, m.dropColumn("posts", "slug", .{}));
}

/// True when an index named `name` exists (SQLite `sqlite_master` probe; these run on SQLite).
fn indexExists(m: *Migrator, name: []const u8) !bool {
    var st = try m.prepare("SELECT 1 FROM sqlite_master WHERE type='index' AND name=?1;");
    defer st.finalize();
    try st.bindText(1, name);
    return try st.step();
}

test "addIndex forward creates (default name); reverse drops the same name" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = Migrator{ .db = &d, .dialect = db.dbDialect(&d), .arena = arena.allocator(), .io = undefined };
    try m.createTable("posts", &[_]Migrator.Col{
        .{ .name = "id", .type = .integer, .pk = true, .null = false },
        .{ .name = "status", .type = .text },
    });
    // default name = idx_<table>_<cols…>
    try m.addIndex("posts", &.{"status"}, .{});
    try std.testing.expect(try indexExists(&m, "idx_posts_status"));

    m.direction = .reverse;
    try m.addIndex("posts", &.{"status"}, .{}); // reverse == DROP INDEX by the derived name
    try std.testing.expect(!try indexExists(&m, "idx_posts_status"));
}

test "addIndex honors explicit name + unique; dropIndex reverse re-creates from .was; bare reverse errors" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = Migrator{ .db = &d, .dialect = db.dbDialect(&d), .arena = arena.allocator(), .io = undefined };
    try m.createTable("users", &[_]Migrator.Col{
        .{ .name = "id", .type = .integer, .pk = true, .null = false },
        .{ .name = "email", .type = .text },
    });
    try m.addIndex("users", &.{"email"}, .{ .name = "ux_email", .unique = true });
    try std.testing.expect(try indexExists(&m, "ux_email"));

    try m.dropIndex("ux_email", .{});
    try std.testing.expect(!try indexExists(&m, "ux_email"));

    // reverse with .was re-creates it.
    m.direction = .reverse;
    try m.dropIndex("ux_email", .{ .was = .{ .table = "users", .columns = &.{"email"}, .unique = true } });
    try std.testing.expect(try indexExists(&m, "ux_email"));

    // without .was, reverse can't re-create it.
    try std.testing.expectError(error.MigrationNotReversible, m.dropIndex("ux_email", .{}));
}

test "renameTable forward renames; reverse restores (self-inverse)" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = Migrator{ .db = &d, .dialect = db.dbDialect(&d), .arena = arena.allocator(), .io = undefined };
    try m.createTable("posts", &[_]Migrator.Col{.{ .name = "id", .type = .integer, .pk = true, .null = false }});

    try m.renameTable("posts", "articles");
    try std.testing.expect(try tableExists(&m, "articles"));
    try std.testing.expect(!try tableExists(&m, "posts"));

    m.direction = .reverse;
    try m.renameTable("posts", "articles"); // reverse swaps: articles -> posts
    try std.testing.expect(try tableExists(&m, "posts"));
    try std.testing.expect(!try tableExists(&m, "articles"));
}

test "renameColumn forward renames; reverse restores (self-inverse)" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = Migrator{ .db = &d, .dialect = db.dbDialect(&d), .arena = arena.allocator(), .io = undefined };
    try m.createTable("posts", &[_]Migrator.Col{
        .{ .name = "id", .type = .integer, .pk = true, .null = false },
        .{ .name = "title", .type = .text },
    });

    try m.renameColumn("posts", "title", "headline");
    try std.testing.expect(try columnExists(&m, "posts", "headline"));
    try std.testing.expect(!try columnExists(&m, "posts", "title"));

    m.direction = .reverse;
    try m.renameColumn("posts", "title", "headline"); // reverse swaps: headline -> title
    try std.testing.expect(try columnExists(&m, "posts", "title"));
    try std.testing.expect(!try columnExists(&m, "posts", "headline"));
}

test "addForeignKey is Postgres-only: SQLite errors in both directions" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = Migrator{ .db = &d, .dialect = db.dbDialect(&d), .arena = arena.allocator(), .io = undefined };
    // SQLite cannot ALTER TABLE ADD/DROP CONSTRAINT — the op guards to WrongBackend (logged .warn).
    try std.testing.expectError(error.WrongBackend, m.addForeignKey("posts", "author_id", "users", .{}));
    m.direction = .reverse;
    try std.testing.expectError(error.WrongBackend, m.addForeignKey("posts", "author_id", "users", .{}));
}

test "addForeignKey Postgres SQL: forward ADD CONSTRAINT (default name) + reverse DROP CONSTRAINT" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Default constraint name fk_<table>_<column>, default ref column "id", no cascade.
    try std.testing.expectEqualStrings(
        "ALTER TABLE \"posts\" ADD CONSTRAINT \"fk_posts_author_id\" FOREIGN KEY (\"author_id\") REFERENCES \"users\" (\"id\");",
        try Migrator.addForeignKeySqlPg(a, "posts", "fk_posts_author_id", "author_id", "users", "id", false),
    );
    // Custom ref column + ON DELETE CASCADE.
    try std.testing.expectEqualStrings(
        "ALTER TABLE \"posts\" ADD CONSTRAINT \"fk_posts_author_id\" FOREIGN KEY (\"author_id\") REFERENCES \"users\" (\"uuid\") ON DELETE CASCADE;",
        try Migrator.addForeignKeySqlPg(a, "posts", "fk_posts_author_id", "author_id", "users", "uuid", true),
    );
    // The inverse DROPs the same constraint name.
    try std.testing.expectEqualStrings(
        "ALTER TABLE \"posts\" DROP CONSTRAINT IF EXISTS \"fk_posts_author_id\";",
        try Migrator.dropConstraintSqlPg(a, "posts", "fk_posts_author_id"),
    );
}

test "records() transforms a field through the engine; reverse mode is not reversible" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("PRAGMA foreign_keys=ON;");
    try @import("migrations.zig").run(&conn);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    // Provision a collection through the engine so the records layer can resolve it.
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
    };
    const col = try collections_mod.create(a, io, &conn, .{ .id = "", .name = "posts", .fields = &fields });

    // Seed two rows through the engine (real create path).
    inline for (.{ "hello", "world" }) |t| {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(a, "title", .{ .string = t });
        _ = try records_mod.create(a, io, &conn, col, .{ .object = obj });
    }

    var m = Migrator{ .db = &conn, .dialect = db.dbDialect(&conn), .arena = a, .io = io };

    // Forward: iterate every record and upper-case its title through the real update path.
    {
        const r = try m.records();
        const all = try r.all("posts");
        try std.testing.expectEqual(@as(usize, 2), all.len);
        for (all) |rec| {
            const id = rec.object.get("id").?.string;
            const title = rec.object.get("title").?.string;
            const upper = try std.ascii.allocUpperString(a, title);
            var patch: std.json.ObjectMap = .empty;
            try patch.put(a, "title", .{ .string = upper });
            _ = try r.update("posts", id, .{ .object = patch });
        }
    }

    // Assert the transform persisted (read back through the engine).
    {
        const r = try m.records();
        const all = try r.all("posts");
        var seen_hello = false;
        var seen_world = false;
        for (all) |rec| {
            const title = rec.object.get("title").?.string;
            if (std.mem.eql(u8, title, "HELLO")) seen_hello = true;
            if (std.mem.eql(u8, title, "WORLD")) seen_world = true;
        }
        try std.testing.expect(seen_hello and seen_world);
    }

    // Reverse: data transforms are irreversible — `records()` fails loudly (`.warn` log, so the
    // test runner is not tripped). Pair a data-transform `change` with an explicit `down`.
    m.direction = .reverse;
    try std.testing.expectError(error.MigrationNotReversible, m.records());
}

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
