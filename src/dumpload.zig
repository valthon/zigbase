//! SQLite → PostgreSQL data migration (issue #159, PR-9).
//!
//! Moves an existing SQLite-backed ZigBase instance to PostgreSQL: it provisions the equivalent
//! schema on the target (the system migrations + every `_collections`-declared record table) and
//! bulk-loads every row from the source `data.db` into the target, **carrying encrypted-field
//! envelopes verbatim** (they are backend-neutral TEXT — never decrypted/re-encrypted here) and
//! preserving record ids, timestamps, and collection metadata.
//!
//! ## Backend-neutral by construction
//! `run` operates on two already-open `db.Db` handles (a SQLite `source` + a target `writer`) and
//! only ever calls the generic `db.Db`/`db.Stmt` surface plus the existing provisioning code
//! (`migrations.run`, `collections.list`, `ddl.*`). The few backend-specific bits — listing
//! tables/columns (`sqlite_master`/`PRAGMA` vs `information_schema`) and toggling FK enforcement —
//! branch on `db.dbBackend`, so this file compiles unchanged in the default (`-Dpostgres=false`)
//! build; the Postgres arms are simply never reached there. The CLI wrapper (`framework.zig`) is
//! the only place that opens an actual PG connection, and it is comptime-gated on the build flag.
//!
//! ## What it does NOT do
//! It does not migrate SQLite-only physical artifacts (the FTS5 shadow tables): the copy is driven
//! by the *target's* tables, so SQLite-only tables are skipped. The collection's `.searchable`
//! metadata is preserved in `_collections`, so a subsequent `zigbase serve` against the Postgres
//! target reprovisions the Postgres full-text index idempotently at startup.

const std = @import("std");
const builtin = @import("builtin");
const db = @import("db.zig");
const migrations = @import("migrations.zig");
const collections = @import("collections.zig");
const ddl = @import("ddl.zig");
const schema = @import("schema.zig");
const analytics = @import("analytics/analytics.zig"); // tests only (rollup-watermark reset)

pub const Options = struct {
    /// Overwrite a target that already contains a ZigBase schema. Without it, a non-empty
    /// target is refused (idempotency / clobber guard).
    force: bool = false,
};

pub const Error = error{
    /// The target already has a ZigBase schema (a `_collections` table with rows) and `--force`
    /// was not given.
    TargetNotEmpty,
    /// A copied table's row count on the target did not match the source after load.
    RowCountMismatch,
} || collections.EngineError || db.DbError || std.mem.Allocator.Error;

pub const TableReport = struct {
    name: []const u8,
    rows: usize,
};

pub const Report = struct {
    /// Per-table loaded row counts (target side), in load order.
    tables: []const TableReport,
    /// Number of record tables provisioned on the target from `_collections` metadata
    /// (excludes system tables created by the migrations).
    collections_provisioned: usize,
    total_rows: usize,

    /// Free the `tables` slice + each table name (allocated with the `gpa` passed to `run`).
    pub fn deinit(self: Report, gpa: std.mem.Allocator) void {
        for (self.tables) |t| gpa.free(t.name);
        gpa.free(self.tables);
    }
};

/// Migrate every table from `source` (a SQLite `data.db`) into `target` (typically Postgres).
///
/// Steps: (1) refuse a non-empty target unless `opts.force`; (2) run the system migrations on the
/// target; (3) provision each `_collections` record table that the migrations did not already
/// create; (4) bulk-copy every target table's rows from the matching source table — wrapped in ONE
/// transaction so a mid-load failure leaves the target clean — carrying every value (including
/// encrypted TEXT envelopes) verbatim and verifying the TARGET row count per table; (5) reset the
/// analytics rollup watermarks so they recompute against the target's regenerated `_seq`.
pub fn run(gpa: std.mem.Allocator, source: *db.Db, target: *db.Db, opts: Options) Error!Report {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // (1) Clobber guard: a fresh target has no `_collections` table at all. The error is returned
    // (not logged) so callers — and tests — drive the messaging.
    if (!opts.force and try targetHasSchema(a, target)) return Error.TargetNotEmpty;

    // (2) System schema on the target (idempotent; dialect-aware). Runs its own transactions.
    try migrations.run(target);

    // (3) Provision the record tables declared in the SOURCE `_collections` that the migrations
    // did not already create (i.e. the user collections — system collections come from migrations).
    const src_cols = try collections.list(a, source);
    const collections_provisioned = try provisionRecordTables(a, target, src_cols);

    // (4) Bulk-load, ATOMICALLY. Drive the copy by the TARGET's tables so SQLite-only artifacts
    // (FTS shadow tables) are never touched and identity columns are skipped. The whole load runs
    // in ONE transaction: a failure on any table rolls the target back to its post-provision state
    // (schema present, zero migrated rows) rather than leaving it half-populated.
    const target_tables = try listTables(a, target);

    try target.begin();
    errdefer target.rollback() catch {};

    // FK enforcement is suspended INSIDE the txn so row order / self-references never trip a
    // constraint (a bare Postgres `SET` is itself transactional, so a rollback reverts it; we also
    // restore it explicitly before commit). Best-effort: needs a superuser target, otherwise we
    // fall back to topological table order.
    const fk_suspended = suspendForeignKeys(target);
    if (!fk_suspended) try deferForeignKeys(target);

    // The returned report outlives this function's arena, so allocate it with the caller's `gpa`.
    // On the error path (e.g. a rejected row → rollback) free the table names duped so far too.
    var reports: std.ArrayList(TableReport) = .empty;
    errdefer {
        for (reports.items) |t| gpa.free(t.name);
        reports.deinit(gpa);
    }
    var total: usize = 0;
    const order = try tableLoadOrder(a, target_tables, src_cols, fk_suspended);

    // Clear every target table we will (re)load BEFORE inserting any rows. Doing all clears up
    // front keeps a --force re-run idempotent while avoiding a subtle interaction on the
    // deferred-FK (non-superuser) path: once a row with a deferred FK check has been inserted,
    // Postgres refuses to TRUNCATE any table with pending trigger events — so an interleaved
    // clear-then-insert-per-table fails when a later table's `TRUNCATE … CASCADE` reaches a table
    // already loaded this transaction. (The superuser path disables FK triggers, so it never has
    // pending events, but clearing up front is correct — and cheaper — for both.)
    for (order) |tname| {
        if (std.mem.eql(u8, tname, "_migrations")) continue;
        try clearTarget(a, source, target, tname);
    }

    for (order) |tname| {
        // Never copy the `_migrations` ledger: the target already applied its OWN migrations during
        // provisioning. Overwriting it with the source's ledger would desync the recorded version
        // from the physical schema if the source binary is older. Leave the target ledger intact.
        if (std.mem.eql(u8, tname, "_migrations")) continue;
        const n = try copyTable(a, source, target, tname);
        try reports.append(gpa, .{ .name = try gpa.dupe(u8, tname), .rows = n });
        total += n;
    }

    // H1: the analytics rollup watermarks in `_kv` (`analytics:rollup:<name>:watermark`) hold an
    // ABSOLUTE `_seq`/rowid value from the source. The target's `_events._seq` is an IDENTITY column
    // regenerated 1..N, so a verbatim-copied watermark would exceed `max(_seq)` and every future
    // rollup pass would silently no-op (`_seq > watermark` matches nothing). Reset the watermarks so
    // each rollup recomputes cleanly from the dense target `_seq`; the `_rollup_<name>` summaries
    // (not migrated — absent on a fresh target) are rebuilt from the migrated `_events` on the next
    // scheduled pass.
    try resetRollupWatermarks(target);

    if (fk_suspended) restoreForeignKeys(target);
    target.commit() catch |e| {
        if (!fk_suspended) logDeferredFkCommitFailure(a, src_cols);
        return e;
    };

    return .{
        .tables = try reports.toOwnedSlice(gpa),
        .collections_provisioned = collections_provisioned,
        .total_rows = total,
    };
}

/// Reset the analytics rollup watermarks on `target` so each rollup recomputes from the target's
/// regenerated `_seq` (see H1 in `run`). `_kv` always exists post-migration; the `LIKE` predicate
/// and `key` column are portable across both backends.
fn resetRollupWatermarks(target: *db.Db) Error!void {
    try target.exec("DELETE FROM \"_kv\" WHERE \"key\" LIKE 'analytics:rollup:%:watermark';");
}

// ===========================================================================
// Target provisioning
// ===========================================================================

/// Create, on `target`, the physical record table for every source collection whose table
/// does not yet exist (system collections' tables come from the migrations), in
/// dependency order. On a POSTGRES target, relation-cycle FK edges are OMITTED from
/// CREATE TABLE (cyclic inline REFERENCES cannot be created in any order there) and added
/// back afterwards as `DEFERRABLE INITIALLY IMMEDIATE` constraints — identical to a plain
/// FK outside explicit SET CONSTRAINTS, deferrable by the load transaction. SQLite permits
/// forward/cyclic inline FK DDL natively, so its DDL is unchanged. Returns the count created.
fn provisionRecordTables(a: std.mem.Allocator, target: *db.Db, src_cols: []const schema.Collection) Error!usize {
    const d = db.dbDialect(target);
    // id -> table name, so a relation field's stored targetCollectionId (an id) resolves to the
    // referenced table NAME that `ddl.createTableSql` interpolates into the FOREIGN KEY clause.
    var id_to_name = std.StringHashMap([]const u8).init(a);
    for (src_cols) |c| try id_to_name.put(c.id, c.name);

    const plan = try planCreateOrder(a, src_cols);
    const defer_cycle_fks = db.dbBackend(target) == .postgres;
    const created_flags = try a.alloc(bool, src_cols.len);
    @memset(created_flags, false);

    var created: usize = 0;
    for (plan.order) |idx| {
        const col = src_cols[idx];
        if (try tableExists(a, target, col.name)) continue; // system tables already exist
        // For auth collections, materialize the injected system columns (passwordHash/tokenKey/…)
        // exactly as `collections.create` does, so the physical table matches.
        const full = try schema.injectAuthFields(a, col);
        const ddl_col = try resolveRelationTargets(a, full, id_to_name);
        const skip: []const []const u8 = if (defer_cycle_fks) try cycleFieldNames(a, plan.cycle_edges, src_cols, idx) else &.{};
        try target.exec(try a.dupeZ(u8, try ddl.createTableSql(a, ddl_col, null, d, skip)));
        for (col.indexes) |ix| target.exec(try a.dupeZ(u8, try ddl.createIndexSql(a, col.name, ix, d))) catch |e| {
            std.log.warn("migrate-db: index '{s}' on '{s}' skipped ({s})", .{ ix.name, col.name, @errorName(e) });
        };
        if (col.type == .auth) {
            for (col.options.auth.identityFields) |idf|
                try target.exec(try a.dupeZ(u8, try ddl.authIdentityIndexSql(a, col.name, idf)));
        }
        created_flags[idx] = true;
        created += 1;
    }

    // Add the omitted cycle-edge FKs back, deferrable, now that every table exists.
    // Only for tables created THIS run — a pre-existing table keeps its constraints.
    if (defer_cycle_fks) {
        for (plan.cycle_edges) |e| {
            if (!created_flags[e.col_idx]) continue;
            const col = src_cols[e.col_idx];
            const f = col.fields[e.field_idx];
            const r = f.options.relation;
            const tgt = id_to_name.get(r.targetCollectionId) orelse r.targetCollectionId;
            const sql = try ddl.addDeferrableFkSql(a, col.name, f.name, tgt, r.cascadeDelete);
            target.exec(try a.dupeZ(u8, sql)) catch |err| {
                std.log.err(
                    "migrate-db: could not add deferrable FK \"fk_{s}_{s}\" on \"{s}\"(\"{s}\") -> \"{s}\"(\"id\"): {s}. Fix the target schema (or use a superuser target role) and re-run.",
                    .{ col.name, f.name, col.name, f.name, tgt, @errorName(err) },
                );
                return err;
            };
        }
    }
    return created;
}

/// Field names of `col_idx`'s cycle edges — the FK clauses `createTableSql` must omit.
fn cycleFieldNames(a: std.mem.Allocator, edges: []const CycleEdge, cols: []const schema.Collection, col_idx: usize) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (edges) |e| {
        if (e.col_idx == col_idx) try out.append(a, cols[col_idx].fields[e.field_idx].name);
    }
    return out.toOwnedSlice(a);
}

/// A copy of `col` with each single-relation field's `targetCollectionId` rewritten from the
/// stored id to the referenced collection's table NAME (what the FK clause needs).
fn resolveRelationTargets(a: std.mem.Allocator, col: schema.Collection, id_to_name: std.StringHashMap([]const u8)) Error!schema.Collection {
    const fields = try a.alloc(schema.Field, col.fields.len);
    for (col.fields, 0..) |f, i| {
        fields[i] = f;
        switch (f.options) {
            .relation => |r| {
                var nr = r;
                // Already a name (or a system collection targeted by name) → leave as-is.
                nr.targetCollectionId = id_to_name.get(r.targetCollectionId) orelse r.targetCollectionId;
                fields[i].options = .{ .relation = nr };
            },
            else => {},
        }
    }
    var out = col;
    out.fields = fields;
    return out;
}

pub const CycleEdge = struct { col_idx: usize, field_idx: usize };

pub const CreatePlan = struct {
    /// Collection indices in creation order. Every collection appears exactly once;
    /// cycle members are appended in declaration order after the acyclic prefix.
    order: []usize,
    /// Single-relation fields that participate in a dependency cycle — every relation
    /// edge between two Kahn leftovers (conservative) plus EVERY self-relation (its DDL
    /// is legal inline, but its rows still need COMMIT-time deferral):
    /// `cols[e.col_idx].fields[e.field_idx]`. Empty for an acyclic graph.
    cycle_edges: []CycleEdge,
};

/// Kahn-style creation plan over the collection relation graph. Pure (arena-allocating,
/// no I/O) so cycle handling is unit-testable. The nodes Kahn cannot place form the
/// cyclic core; on Postgres their in-cycle FK edges are provisioned as deferrable
/// `ALTER TABLE ADD CONSTRAINT`s instead of inline REFERENCES (see provisionRecordTables).
fn planCreateOrder(a: std.mem.Allocator, cols: []const schema.Collection) Error!CreatePlan {
    const n = cols.len;
    const placed = try a.alloc(bool, n);
    @memset(placed, false);
    var order: std.ArrayList(usize) = .empty;
    var progress = true;
    while (order.items.len < n and progress) {
        progress = false;
        for (cols, 0..) |c, i| {
            if (placed[i]) continue;
            if (depsPlaced(cols, c, placed)) {
                try order.append(a, i);
                placed[i] = true;
                progress = true;
            }
        }
    }

    // Cycle edges: FK-bearing (single) relations where BOTH endpoints are Kahn leftovers,
    // plus every self-relation regardless of placement.
    var cycle_edges: std.ArrayList(CycleEdge) = .empty;
    for (cols, 0..) |c, i| {
        for (c.fields, 0..) |f, fi| switch (f.options) {
            .relation => |r| {
                if (r.maxSelect != 1) continue; // multi-relations carry no FK
                const j = findCollection(cols, r.targetCollectionId) orelse continue;
                if (i == j) {
                    try cycle_edges.append(a, .{ .col_idx = i, .field_idx = fi });
                } else if (!placed[i] and !placed[j]) {
                    try cycle_edges.append(a, .{ .col_idx = i, .field_idx = fi });
                }
            },
            else => {},
        };
    }

    // Append the cyclic core in declaration order (its tables are still created — only
    // the in-cycle FK clauses are handled specially) and log the members once.
    var had_cycle = false;
    for (0..n) |i| {
        if (!placed[i]) {
            if (!had_cycle) {
                had_cycle = true;
                std.log.info("migrate-db: relation cycle detected; deferring its FK edges to COMMIT. Members:", .{});
            }
            std.log.info("migrate-db:   cycle member '{s}'", .{cols[i].name});
            try order.append(a, i);
        }
    }
    return .{
        .order = try order.toOwnedSlice(a),
        .cycle_edges = try cycle_edges.toOwnedSlice(a),
    };
}

/// Index of the collection whose id OR name equals `target` (relation targets are stored
/// either way), or null for out-of-set targets (e.g. system `_superusers`).
fn findCollection(cols: []const schema.Collection, target: []const u8) ?usize {
    for (cols, 0..) |c, j| {
        if (std.mem.eql(u8, c.id, target) or std.mem.eql(u8, c.name, target)) return j;
    }
    return null;
}

/// True if every user-collection relation target of `c` is already placed. Targets that are not
/// other collections in the set (e.g. the system `_superusers` table) are treated as satisfied.
fn depsPlaced(cols: []const schema.Collection, c: schema.Collection, placed: []const bool) bool {
    for (c.fields) |f| switch (f.options) {
        .relation => |r| {
            for (cols, 0..) |o, j| {
                if (std.mem.eql(u8, o.id, r.targetCollectionId) or std.mem.eql(u8, o.name, r.targetCollectionId)) {
                    if (o.id.len == c.id.len and std.mem.eql(u8, o.id, c.id)) break; // self-relation
                    if (!placed[j]) return false;
                    break;
                }
            }
        },
        else => {},
    };
    return true;
}

// ===========================================================================
// Bulk copy
// ===========================================================================

/// Clear `table` on the target iff `copyTable` would (re)load it — the source has the table and it
/// shares at least one column. Called for every table BEFORE any inserts (see the copy loop in
/// `run`) so a --force re-run is idempotent without an interleaved TRUNCATE tripping the deferred-FK
/// path's pending-trigger-events restriction. Postgres uses `TRUNCATE … RESTART IDENTITY CASCADE`:
/// RESTART IDENTITY resets owned sequences so a re-migration regenerates `_events._seq` (and any
/// IDENTITY) densely from 1 — deterministic repeats, preserving the dense-`_seq`-from-1 invariant
/// the rollup-watermark reset relies on; CASCADE clears a parent with seeded/old child rows (every
/// table is reloaded anyway). SQLite has no TRUNCATE, so `DELETE FROM` (rowids restart when empty).
fn clearTarget(a: std.mem.Allocator, source: *db.Db, target: *db.Db, table: []const u8) Error!void {
    var ta = std.heap.ArenaAllocator.init(a);
    defer ta.deinit();
    const al = ta.allocator();

    if (!try tableExists(al, source, table)) return;
    const tgt_cols = try listColumns(al, target, table, false);
    const src_cols = try listColumns(al, source, table, false);
    var src_set = std.StringHashMap(void).init(al);
    for (src_cols) |c| try src_set.put(c, {});
    var any = false;
    for (tgt_cols) |c| if (src_set.contains(c)) {
        any = true;
        break;
    };
    if (!any) return; // no shared columns → copyTable skips it, so leave it untouched

    const clear_sql = switch (db.dbBackend(target)) {
        .postgres => try std.fmt.allocPrintSentinel(al, "TRUNCATE TABLE {s} RESTART IDENTITY CASCADE;", .{try ddl.quoteIdent(al, table)}, 0),
        .sqlite => try std.fmt.allocPrintSentinel(al, "DELETE FROM {s};", .{try ddl.quoteIdent(al, table)}, 0),
    };
    try target.exec(clear_sql);
}

/// Copy every row of `table` from `source` into `target`. The column set is the target's
/// (non-identity) columns intersected with the source's columns, preserving target order. The
/// target table is cleared beforehand by `clearTarget` so re-runs (under `--force`) are idempotent.
/// Each value is bound by its source storage type, so encrypted TEXT envelopes are carried verbatim.
/// Returns the number of rows loaded.
fn copyTable(a: std.mem.Allocator, source: *db.Db, target: *db.Db, table: []const u8) Error!usize {
    var ta = std.heap.ArenaAllocator.init(a);
    defer ta.deinit();
    const al = ta.allocator();

    // Skip tables the source does not have (target-only: e.g. nothing today, but future-proof).
    if (!try tableExists(al, source, table)) return 0;

    const tgt_cols = try listColumns(al, target, table, false); // non-identity, ordinal order
    const tgt_all = try listColumns(al, target, table, true); // incl. identity, for drop detection
    const src_cols = try listColumns(al, source, table, false);
    var src_set = std.StringHashMap(void).init(al);
    for (src_cols) |c| try src_set.put(c, {});
    var tgt_all_set = std.StringHashMap(void).init(al);
    for (tgt_all) |c| try tgt_all_set.put(c, {});

    // Warn (not silently drop) on source-only PHYSICAL columns — raw-SQL escape-hatch additions
    // not present on the target — so the operator knows their data is not carried over.
    for (src_cols) |c| if (!tgt_all_set.contains(c))
        std.log.warn("migrate-db: table '{s}' source column '{s}' has no target column — its data is NOT migrated", .{ table, c });

    var cols: std.ArrayList([]const u8) = .empty;
    for (tgt_cols) |c| if (src_set.contains(c)) try cols.append(al, c);
    if (cols.items.len == 0) return 0;

    // The target was cleared up front (see `clearTarget`, called before the copy loop) so a
    // --force re-run is idempotent — we do NOT clear here, because on the deferred-FK path an
    // interleaved TRUNCATE would hit a table with pending trigger events once rows are loaded.

    // Build the column list + a parameter list for the INSERT and the SELECT.
    var collist: std.ArrayList(u8) = .empty;
    var params: std.ArrayList(u8) = .empty;
    for (cols.items, 0..) |c, i| {
        if (i > 0) {
            try collist.appendSlice(al, ",");
            try params.appendSlice(al, ",");
        }
        try collist.appendSlice(al, try ddl.quoteIdent(al, c));
        try params.appendSlice(al, try std.fmt.allocPrint(al, "?{d}", .{i + 1}));
    }

    // Deterministic source iteration order so the target's regenerated `_events._seq` IDENTITY is
    // assigned in source insertion order (SQLite `rowid` is exactly that). Other tables don't need
    // it (no server-generated ordering column).
    const order_by = orderClause(table, db.dbBackend(source));
    const sel_sql = try std.fmt.allocPrintSentinel(al, "SELECT {s} FROM {s}{s};", .{ collist.items, try ddl.quoteIdent(al, table), order_by }, 0);
    const ins_raw = try std.fmt.allocPrint(al, "INSERT INTO {s} ({s}) VALUES ({s});", .{ try ddl.quoteIdent(al, table), collist.items, params.items });

    var sel = try source.prepare(sel_sql);
    defer sel.finalize();

    while (try sel.step()) {
        // Fresh INSERT statement per row keeps the (Postgres) per-statement param arena bounded
        // for large tables; execution cost is dominated by the round-trip regardless.
        const ins_sql = try db.dbDialect(target).renumberPlaceholders(al, ins_raw);
        var ins = try target.prepare(ins_sql);
        defer ins.finalize();
        for (cols.items, 0..) |_, i| {
            const idx: c_int = @intCast(i + 1);
            try bindFromColumn(&ins, idx, &sel, @intCast(i));
        }
        _ = try ins.step();
    }

    // Real integrity check: count the TARGET (not the source iterator) and assert it equals the
    // source row count. This catches a silent target-side drop (a rejected row, a missing column,
    // a unique-collision) that comparing source-to-source never could.
    const want = try countRows(al, source, table);
    const got = try countRows(al, target, table);
    if (want != got) {
        std.log.err("migrate-db: table '{s}' row-count mismatch (source {d}, target {d})", .{ table, want, got });
        return Error.RowCountMismatch;
    }
    return got;
}

/// The deterministic source ORDER BY for `table` (so a regenerated target IDENTITY/`_seq` is
/// assigned in source insertion order), or "" when none is needed. `_events` orders by the SQLite
/// `rowid` (true insertion order); a non-SQLite source falls back to `occurred_at`,`id`.
fn orderClause(table: []const u8, source_backend: db.Backend) []const u8 {
    if (!std.mem.eql(u8, table, "_events")) return "";
    return switch (source_backend) {
        .sqlite => " ORDER BY rowid",
        .postgres => " ORDER BY \"occurred_at\",\"id\"",
    };
}

/// Bind column `src_idx` of `src`'s current row into `dst` parameter `dst_idx`, preserving the
/// source storage type. TEXT (the type of every encrypted envelope, JSON blob, id, timestamp) is
/// copied byte-for-byte.
fn bindFromColumn(dst: *db.Stmt, dst_idx: c_int, src: *db.Stmt, src_idx: c_int) db.DbError!void {
    if (src.isNull(src_idx)) return dst.bindNull(dst_idx);
    return switch (src.columnType(src_idx)) {
        .Null => dst.bindNull(dst_idx),
        .Integer => dst.bindInt(dst_idx, src.columnInt(src_idx)),
        .Float => dst.bindDouble(dst_idx, src.columnDouble(src_idx)),
        // Blob is not used by any ZigBase column; fall back to the text accessor.
        .Text, .Blob => dst.bindText(dst_idx, src.columnText(src_idx)),
    };
}

// ===========================================================================
// Backend-specific introspection (branches on the active backend)
// ===========================================================================

/// True if the target already carries a ZigBase schema: a `_collections` table that has rows.
fn targetHasSchema(a: std.mem.Allocator, target: *db.Db) Error!bool {
    if (!try tableExists(a, target, "_collections")) return false;
    return (try countRows(a, target, "_collections")) > 0;
}

/// List the base tables in the database's active schema, excluding SQLite's internal tables.
fn listTables(a: std.mem.Allocator, d: *db.Db) Error![]const []const u8 {
    const sql: [:0]const u8 = switch (db.dbBackend(d)) {
        .sqlite => "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;",
        .postgres => "SELECT table_name FROM information_schema.tables WHERE table_schema = current_schema() AND table_type = 'BASE TABLE' ORDER BY table_name;",
    };
    var st = try d.prepare(sql);
    defer st.finalize();
    var out: std.ArrayList([]const u8) = .empty;
    while (try st.step()) try out.append(a, try a.dupe(u8, st.columnText(0)));
    return out.toOwnedSlice(a);
}

/// List the column names of `table` in ordinal order. With `include_identity = false` (the
/// insertable set), Postgres IDENTITY columns (`_migrations.id`, `_events._seq`) are excluded —
/// they are server-generated and rejected by a plain INSERT. With `true` (used only to detect
/// source-only dropped columns), every column is returned. SQLite has no identity concept, so the
/// flag is a no-op there.
fn listColumns(a: std.mem.Allocator, d: *db.Db, table: []const u8, include_identity: bool) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    switch (db.dbBackend(d)) {
        .sqlite => {
            // PRAGMA cannot be parameterized; quote the (validated) identifier inline.
            const sql = try std.fmt.allocPrintSentinel(a, "PRAGMA table_info({s});", .{try ddl.quoteIdent(a, table)}, 0);
            var st = try d.prepare(sql);
            defer st.finalize();
            while (try st.step()) try out.append(a, try a.dupe(u8, st.columnText(1))); // col 1 = name
        },
        .postgres => {
            const raw = if (include_identity)
                "SELECT column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = ?1 ORDER BY ordinal_position;"
            else
                "SELECT column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = ?1 AND is_identity = 'NO' ORDER BY ordinal_position;";
            const sql = try db.dbDialect(d).renumberPlaceholders(a, raw);
            var st = try d.prepare(sql);
            defer st.finalize();
            try st.bindText(1, table);
            while (try st.step()) try out.append(a, try a.dupe(u8, st.columnText(0)));
        },
    }
    return out.toOwnedSlice(a);
}

fn tableExists(a: std.mem.Allocator, d: *db.Db, table: []const u8) Error!bool {
    const raw = switch (db.dbBackend(d)) {
        .sqlite => "SELECT 1 FROM sqlite_master WHERE type='table' AND name = ?1;",
        .postgres => "SELECT 1 FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = ?1;",
    };
    const sql = try db.dbDialect(d).renumberPlaceholders(a, raw);
    var st = try d.prepare(sql);
    defer st.finalize();
    try st.bindText(1, table);
    return try st.step();
}

fn countRows(a: std.mem.Allocator, d: *db.Db, table: []const u8) Error!usize {
    const sql = try std.fmt.allocPrintSentinel(a, "SELECT COUNT(*) FROM {s};", .{try ddl.quoteIdent(a, table)}, 0);
    var st = try d.prepare(sql);
    defer st.finalize();
    if (!try st.step()) return 0;
    const c = st.columnInt(0);
    return if (c < 0) 0 else @intCast(c);
}

/// Suspend FK enforcement on the target for the duration of the load (Postgres only, best effort).
/// `SET session_replication_role = replica` disables FK triggers so rows load in any order and
/// self-references never trip. Returns false if it could not be set (non-superuser target) — the
/// caller then falls back to `deferForeignKeys`.
///
/// The attempt is wrapped in a SAVEPOINT: on Postgres, ANY failed statement poisons the rest of
/// the enclosing transaction (every later statement errors "current transaction is aborted" until
/// a ROLLBACK), so a plain failed `SET` here would silently break the load transaction for the
/// non-superuser fallback path that follows it in `run`. Rolling back to the savepoint undoes just
/// this one failed statement, leaving the load transaction otherwise usable.
fn suspendForeignKeys(d: *db.Db) bool {
    if (db.dbBackend(d) != .postgres) return false;
    d.exec("SAVEPOINT zb_fk_suspend;") catch return false;
    d.exec("SET session_replication_role = replica;") catch {
        d.exec("ROLLBACK TO SAVEPOINT zb_fk_suspend;") catch {};
        std.log.warn("migrate-db: could not suspend FK enforcement (target role is not superuser); deferring constraints to COMMIT instead", .{});
        return false;
    };
    d.exec("RELEASE SAVEPOINT zb_fk_suspend;") catch {};
    return true;
}

fn restoreForeignKeys(d: *db.Db) void {
    d.exec("SET session_replication_role = origin;") catch {};
}

/// The non-superuser path: instead of suspending FK enforcement, defer constraint
/// checking to COMMIT inside the (already-open) load transaction. Postgres:
/// `SET CONSTRAINTS ALL DEFERRED` — no privilege required, affects only DEFERRABLE
/// constraints, i.e. exactly the cycle-edge FKs provisioned by provisionRecordTables.
/// SQLite: `PRAGMA defer_foreign_keys=ON` — transaction-scoped, auto-resets at COMMIT
/// (SQLite's inline FK DDL is already cycle-capable; only row order needs this).
fn deferForeignKeys(d: *db.Db) Error!void {
    switch (db.dbBackend(d)) {
        .postgres => try d.exec("SET CONSTRAINTS ALL DEFERRED;"),
        .sqlite => try d.exec("PRAGMA defer_foreign_keys=ON;"),
    }
}

/// A COMMIT failure on the deferred-constraint path means a dangling reference in the
/// source data — the ONLY hard error left in the non-superuser design. Name the cycle
/// members so the operator can find it. (Errors are logged here, then the DbError
/// propagates; the CLI wrapper prints its usual abort message.)
fn logDeferredFkCommitFailure(a: std.mem.Allocator, src_cols: []const schema.Collection) void {
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(a);
    if (planCreateOrder(a, src_cols)) |plan| {
        for (plan.cycle_edges) |e| {
            const n = src_cols[e.col_idx].name;
            if (std.mem.indexOf(u8, names.items, n) != null) continue;
            if (names.items.len > 0) names.appendSlice(a, ", ") catch break;
            names.appendSlice(a, n) catch break;
        }
    } else |_| {}
    // A dangling cyclic reference is a hard `.err` in production, but Zig's test runner counts
    // every `std.log.err` as a test failure — and the deferred-FK rollback test deliberately
    // exercises this path. Under the test runner emit the identical message at `.warn`; the
    // returned `DbError` (the test's real assertion) is unchanged.
    if (builtin.is_test) std.log.warn(
        "migrate-db: foreign-key cycle across collections [{s}] could not be satisfied at commit — a row references a missing target. The target was rolled back; fix the dangling reference in the source (or use a superuser target role) and re-run.",
        .{names.items},
    ) else std.log.err(
        "migrate-db: foreign-key cycle across collections [{s}] could not be satisfied at commit — a row references a missing target. The target was rolled back; fix the dangling reference in the source (or use a superuser target role) and re-run.",
        .{names.items},
    );
}

/// The order to load tables in. When FK enforcement is suspended, the target's natural (name)
/// order is fine. Otherwise, sort so a relation's referenced record table loads before the
/// referencing one (best-effort, by `_collections` relation graph); non-collection/system tables
/// keep their place.
fn tableLoadOrder(a: std.mem.Allocator, tables: []const []const u8, src_cols: []const schema.Collection, fk_suspended: bool) Error![]const []const u8 {
    if (fk_suspended) return tables;
    // Build a name->dependency(name) set from collections, then stable-topo the table list.
    const order = (try planCreateOrder(a, src_cols)).order;
    var rank = std.StringHashMap(usize).init(a);
    for (order, 0..) |idx, r| try rank.put(src_cols[idx].name, r);
    const out = try a.dupe([]const u8, tables);
    std.mem.sort([]const u8, out, &rank, struct {
        fn lt(rk: *std.StringHashMap(usize), x: []const u8, y: []const u8) bool {
            const rx = rk.get(x) orelse std.math.maxInt(usize) / 2;
            const ry = rk.get(y) orelse std.math.maxInt(usize) / 2;
            if (rx == ry) return std.mem.lessThan(u8, x, y);
            return rx < ry;
        }
    }.lt);
    return out;
}

// ===========================================================================
// Tests (backend-neutral: SQLite -> in-memory SQLite round-trip)
// ===========================================================================

test "dumpload: copies system + a user collection's records SQLite->SQLite" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    // Source: a provisioned SQLite instance with a user collection + two records.
    var source = try db.Db.openMemory();
    defer source.close();
    try migrations.run(&source);
    const col = schema.Collection{ .id = "c1", .name = "notes", .fields = &[_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "secret", .options = .{ .text = .{} } },
    } };
    // create() assigns the real (random) collection id; capture it to assert it is preserved.
    const created_col = try collections.create(al, io, &source, col);
    const src_col_id = try al.dupe(u8, created_col.id);
    try source.exec("INSERT INTO \"notes\" (\"id\",\"created\",\"updated\",\"title\",\"secret\") VALUES ('r1','t0','t0','hello','v1:envelopeAAA');");
    try source.exec("INSERT INTO \"notes\" (\"id\",\"created\",\"updated\",\"title\",\"secret\") VALUES ('r2','t1','t1','world','v1:envelopeBBB');");

    // Target: a fresh empty SQLite (stands in for a fresh PG in this backend-neutral test).
    var target = try db.Db.openMemory();
    defer target.close();

    const report = try run(a, &source, &target, .{});
    defer report.deinit(a);

    try std.testing.expectEqual(@as(usize, 1), report.collections_provisioned);

    // The user table round-trips with ids, timestamps, and the encrypted envelope VERBATIM.
    var st = try target.prepare("SELECT \"id\",\"title\",\"secret\" FROM \"notes\" ORDER BY \"id\";");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("r1", st.columnText(0));
    try std.testing.expectEqualStrings("hello", st.columnText(1));
    try std.testing.expectEqualStrings("v1:envelopeAAA", st.columnText(2));
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("r2", st.columnText(0));
    try std.testing.expectEqualStrings("v1:envelopeBBB", st.columnText(2));
    try std.testing.expect(!try st.step());

    // _collections metadata copied VERBATIM: the user collection's original id survives.
    var cs = try target.prepare("SELECT \"id\" FROM \"_collections\" WHERE \"name\"='notes';");
    defer cs.finalize();
    try std.testing.expect(try cs.step());
    try std.testing.expectEqualStrings(src_col_id, cs.columnText(0));
}

test "dumpload: refuses a non-empty target without force" {
    const a = std.testing.allocator;

    var source = try db.Db.openMemory();
    defer source.close();
    try migrations.run(&source);

    var target = try db.Db.openMemory();
    defer target.close();
    try migrations.run(&target); // target already has a _collections schema with rows

    try std.testing.expectError(Error.TargetNotEmpty, run(a, &source, &target, .{}));

    // …but --force proceeds.
    const report = try run(a, &source, &target, .{ .force = true });
    defer report.deinit(a);
    try std.testing.expect(report.total_rows > 0);
}

test "dumpload: rollup watermark reset counts migrated events correctly (H1)" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    // Source: three `user.signup` events + a STALE rollup watermark in `_kv`. The watermark holds a
    // large source-rowid value; on the target the `_events` rowid/`_seq` is regenerated dense, so a
    // verbatim-copied watermark would make every rollup pass a silent no-op (H1).
    var source = try db.Db.openMemory();
    defer source.close();
    try migrations.run(&source);
    try source.exec(
        \\INSERT INTO "_events" ("id","created","updated","name","payload","account","occurred_at") VALUES
        \\ ('e1','t','t','user.signup','{}','acc1','2026-01-01T08:00:00Z'),
        \\ ('e2','t','t','user.signup','{}','acc1','2026-01-01T09:00:00Z'),
        \\ ('e3','t','t','user.signup','{}','acc1','2026-01-01T10:00:00Z');
    );
    try source.exec("INSERT INTO \"_kv\" (\"key\",\"value\",\"created\",\"updated\") VALUES ('analytics:rollup:signups_daily:watermark','999999','t','t');");

    var target = try db.Db.openMemory();
    defer target.close();

    const report = try run(a, &source, &target, .{});
    defer report.deinit(a);

    // The watermark key was RESET (deleted) on the target so the rollup starts from 0.
    var wm = try target.prepare("SELECT COUNT(*) FROM \"_kv\" WHERE \"key\"='analytics:rollup:signups_daily:watermark';");
    defer wm.finalize();
    try std.testing.expect(try wm.step());
    try std.testing.expectEqual(@as(i64, 0), wm.columnInt(0));

    // A rollup pass on the target now COUNTS the three migrated events (it would no-op if the stale
    // watermark had survived).
    const spec = analytics.RollupSpec{
        .name = "signups_daily",
        .event = "user.signup",
        .every = .{ .interval = .hourly },
        .group_account = true,
        .group_actor = false,
        .time_bucket = .day,
        .metric = .count,
    };
    try analytics.runRollup(&target, al, spec);

    var rv = try target.prepare("SELECT \"value\" FROM \"_rollup_signups_daily\" WHERE \"account\"='acc1';");
    defer rv.finalize();
    try std.testing.expect(try rv.step());
    try std.testing.expectEqual(@as(i64, 3), rv.columnInt(0));
}

test "dumpload: per-table report counts equal the real target row counts (M1)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var source = try db.Db.openMemory();
    defer source.close();
    try migrations.run(&source);
    const col = schema.Collection{ .id = "_", .name = "notes", .fields = &[_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
    } };
    _ = try collections.create(al, io, &source, col);
    try source.exec("INSERT INTO \"notes\" (\"id\",\"created\",\"updated\",\"title\") VALUES ('r1','t','t','a');");
    try source.exec("INSERT INTO \"notes\" (\"id\",\"created\",\"updated\",\"title\") VALUES ('r2','t','t','b');");

    var target = try db.Db.openMemory();
    defer target.close();

    const report = try run(a, &source, &target, .{});
    defer report.deinit(a);

    // Each reported count is the TARGET's actual COUNT(*), not a source-side tautology. Query the
    // target independently and assert equality for every reported table (and that `_migrations` —
    // the freshly-applied target ledger — was NOT copied/clobbered, so it isn't in the report).
    var saw_migrations = false;
    for (report.tables) |t| {
        if (std.mem.eql(u8, t.name, "_migrations")) saw_migrations = true;
        const got = try countRows(al, &target, t.name);
        try std.testing.expectEqual(t.rows, got);
    }
    try std.testing.expect(!saw_migrations);

    // And the notes table really has the two migrated rows.
    var n = try target.prepare("SELECT COUNT(*) FROM \"notes\";");
    defer n.finalize();
    try std.testing.expect(try n.step());
    try std.testing.expectEqual(@as(i64, 2), n.columnInt(0));
}

test "dumpload: self-referential relation rows load in any order (defer_foreign_keys)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var source = try db.Db.openMemory();
    defer source.close();
    try migrations.run(&source);
    const col = schema.Collection{ .id = "_", .name = "nodes", .fields = &[_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "parent", .options = .{ .relation = .{ .targetCollectionId = "nodes", .maxSelect = 1 } } },
    } };
    _ = try collections.create(al, io, &source, col);
    // r1 references the LATER row r2: with foreign_keys=ON and no deferral, copying in natural
    // order would fail at the first INSERT — dumpload's defer_foreign_keys validates at COMMIT
    // instead. The vendored SQLite is built with SQLITE_DEFAULT_FOREIGN_KEYS=1, so FK enforcement
    // is ON by default even on a bare test handle — seeding r1 before r2 exists would fail here
    // too without deferring, mirroring how such a row order can legitimately exist in a real
    // database (e.g. itself loaded via a deferred-FK bulk import).
    try source.exec("BEGIN;");
    try source.exec("PRAGMA defer_foreign_keys=ON;");
    try source.exec("INSERT INTO \"nodes\" (\"id\",\"created\",\"updated\",\"title\",\"parent\") VALUES ('r1','t','t','child','r2');");
    try source.exec("INSERT INTO \"nodes\" (\"id\",\"created\",\"updated\",\"title\",\"parent\") VALUES ('r2','t','t','root',NULL);");
    try source.exec("COMMIT;");

    var target = try db.Db.openMemory();
    defer target.close();
    // FK enforcement is already ON by default (SQLITE_DEFAULT_FOREIGN_KEYS=1), matching the
    // production pool writer (backend/sqlite/db.zig); set it explicitly anyway so the test does
    // not silently pass if that compile default is ever dropped.
    try target.exec("PRAGMA foreign_keys=ON;");

    const report = try run(a, &source, &target, .{});
    defer report.deinit(a);

    var st = try target.prepare("SELECT \"parent\" FROM \"nodes\" WHERE \"id\"='r1';");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("r2", st.columnText(0));
}

// --- planCreateOrder (pure cycle detection) ---------------------------------------

fn relField(comptime id: []const u8, comptime name: []const u8, comptime target: []const u8) schema.Field {
    return .{ .id = id, .name = name, .options = .{ .relation = .{ .targetCollectionId = target, .maxSelect = 1 } } };
}

test "dumpload: planCreateOrder — acyclic graph orders dependencies first, zero cycle edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const post_fields = [_]schema.Field{relField("f1", "author", "authors")};
    const cols = [_]schema.Collection{
        .{ .id = "c_posts", .name = "posts", .fields = &post_fields },
        .{ .id = "c_auth", .name = "authors", .fields = &.{} },
    };
    const plan = try planCreateOrder(al, &cols);
    try std.testing.expectEqual(@as(usize, 0), plan.cycle_edges.len);
    try std.testing.expectEqual(@as(usize, 2), plan.order.len);
    try std.testing.expectEqual(@as(usize, 1), plan.order[0]); // authors first
    try std.testing.expectEqual(@as(usize, 0), plan.order[1]); // then posts
}

test "dumpload: planCreateOrder — a self-relation is ALWAYS a cycle edge (but places normally)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const node_fields = [_]schema.Field{relField("f1", "parent", "nodes")};
    const cols = [_]schema.Collection{
        .{ .id = "c_nodes", .name = "nodes", .fields = &node_fields },
    };
    const plan = try planCreateOrder(al, &cols);
    try std.testing.expectEqual(@as(usize, 1), plan.order.len);
    try std.testing.expectEqual(@as(usize, 1), plan.cycle_edges.len);
    try std.testing.expectEqual(@as(usize, 0), plan.cycle_edges[0].col_idx);
    try std.testing.expectEqual(@as(usize, 0), plan.cycle_edges[0].field_idx);
}

test "dumpload: planCreateOrder — 2-cycle and 3-cycle mark every in-cycle edge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    {
        const af = [_]schema.Field{relField("f1", "buddy", "beta")};
        const bf = [_]schema.Field{relField("f2", "buddy", "alpha")};
        const cols = [_]schema.Collection{
            .{ .id = "c_a", .name = "alpha", .fields = &af },
            .{ .id = "c_b", .name = "beta", .fields = &bf },
        };
        const plan = try planCreateOrder(al, &cols);
        try std.testing.expectEqual(@as(usize, 2), plan.order.len); // both still created
        try std.testing.expectEqual(@as(usize, 2), plan.cycle_edges.len);
    }
    {
        const xf = [_]schema.Field{relField("f1", "next", "y")};
        const yf = [_]schema.Field{relField("f2", "next", "z")};
        const zf = [_]schema.Field{relField("f3", "next", "x")};
        const cols = [_]schema.Collection{
            .{ .id = "c_x", .name = "x", .fields = &xf },
            .{ .id = "c_y", .name = "y", .fields = &yf },
            .{ .id = "c_z", .name = "z", .fields = &zf },
        };
        const plan = try planCreateOrder(al, &cols);
        try std.testing.expectEqual(@as(usize, 3), plan.cycle_edges.len);
    }
}

test "dumpload: planCreateOrder — a diamond feeding a cycle only defers the in-cycle edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    // base <- x, base <- y (acyclic diamond); a -> {x, b}, b -> {y, a} (a/b cycle).
    const xf = [_]schema.Field{relField("f1", "root", "base")};
    const yf = [_]schema.Field{relField("f2", "root", "base")};
    const af = [_]schema.Field{ relField("f3", "via", "x"), relField("f4", "pair", "b") };
    const bf = [_]schema.Field{ relField("f5", "via", "y"), relField("f6", "pair", "a") };
    const cols = [_]schema.Collection{
        .{ .id = "c_base", .name = "base", .fields = &.{} },
        .{ .id = "c_x", .name = "x", .fields = &xf },
        .{ .id = "c_y", .name = "y", .fields = &yf },
        .{ .id = "c_a", .name = "a", .fields = &af },
        .{ .id = "c_b", .name = "b", .fields = &bf },
    };
    const plan = try planCreateOrder(al, &cols);
    try std.testing.expectEqual(@as(usize, 5), plan.order.len);
    // ONLY a.pair and b.pair are cycle edges — a.via/b.via point at placed (acyclic) nodes.
    try std.testing.expectEqual(@as(usize, 2), plan.cycle_edges.len);
    for (plan.cycle_edges) |e| {
        const f = cols[e.col_idx].fields[e.field_idx];
        try std.testing.expectEqualStrings("pair", f.name);
    }
}
