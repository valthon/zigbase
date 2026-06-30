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
const db = @import("db.zig");
const migrations = @import("migrations.zig");
const collections = @import("collections.zig");
const ddl = @import("ddl.zig");
const schema = @import("schema.zig");

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
/// create; (4) bulk-copy every target table's rows from the matching source table, carrying every
/// value (including encrypted TEXT envelopes) verbatim; (5) verify per-table row counts.
pub fn run(gpa: std.mem.Allocator, source: *db.Db, target: *db.Db, opts: Options) Error!Report {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // (1) Clobber guard: a fresh target has no `_collections` table at all. The error is returned
    // (not logged) so callers — and tests — drive the messaging.
    if (!opts.force and try targetHasSchema(a, target)) return Error.TargetNotEmpty;

    // (2) System schema on the target (idempotent; dialect-aware).
    try migrations.run(target);

    // (3) Provision the record tables declared in the SOURCE `_collections` that the migrations
    // did not already create (i.e. the user collections — system collections come from migrations).
    const src_cols = try collections.list(a, source);
    const collections_provisioned = try provisionRecordTables(a, target, src_cols);

    // (4) Bulk-load. Drive the copy by the TARGET's tables so SQLite-only artifacts (FTS shadow
    // tables) are never touched and identity columns are skipped. FK enforcement is suspended for
    // the load so row order / self-references never trip a constraint (best-effort: requires a
    // superuser target; otherwise we fall back to topological table order).
    const target_tables = try listTables(a, target);
    const fk_suspended = suspendForeignKeys(target);
    defer if (fk_suspended) restoreForeignKeys(target);

    // The returned report outlives this function's arena, so allocate it with the caller's `gpa`.
    var reports: std.ArrayList(TableReport) = .empty;
    errdefer reports.deinit(gpa);
    var total: usize = 0;
    // Copy parents before children when FK enforcement could not be suspended.
    const order = try tableLoadOrder(a, target_tables, src_cols, fk_suspended);
    for (order) |tname| {
        const n = try copyTable(a, source, target, tname);
        try reports.append(gpa, .{ .name = try gpa.dupe(u8, tname), .rows = n });
        total += n;
    }

    return .{
        .tables = try reports.toOwnedSlice(gpa),
        .collections_provisioned = collections_provisioned,
        .total_rows = total,
    };
}

// ===========================================================================
// Target provisioning
// ===========================================================================

/// Create, on `target`, the physical record table for every source collection whose table does
/// not yet exist (system collections' tables are created by the migrations). Tables are created
/// in relation-dependency order so a FK's referenced table exists first. Returns the count created.
fn provisionRecordTables(a: std.mem.Allocator, target: *db.Db, src_cols: []const schema.Collection) Error!usize {
    const d = db.dbDialect(target);
    // id -> table name, so a relation field's stored targetCollectionId (an id) resolves to the
    // referenced table NAME that `ddl.createTableSql` interpolates into the FOREIGN KEY clause.
    var id_to_name = std.StringHashMap([]const u8).init(a);
    for (src_cols) |c| try id_to_name.put(c.id, c.name);

    const order = try collectionCreateOrder(a, src_cols);
    var created: usize = 0;
    for (order) |idx| {
        const col = src_cols[idx];
        if (try tableExists(a, target, col.name)) continue; // system tables already exist
        // For auth collections, materialize the injected system columns (passwordHash/tokenKey/…)
        // exactly as `collections.create` does, so the physical table matches.
        const full = try schema.injectAuthFields(a, col);
        const ddl_col = try resolveRelationTargets(a, full, id_to_name);
        try target.exec(try a.dupeZ(u8, try ddl.createTableSql(a, ddl_col, null, d)));
        for (col.indexes) |ix| target.exec(try a.dupeZ(u8, try ddl.createIndexSql(a, col.name, ix, d))) catch |e| {
            std.log.warn("migrate-db: index '{s}' on '{s}' skipped ({s})", .{ ix.name, col.name, @errorName(e) });
        };
        if (col.type == .auth) {
            for (col.options.auth.identityFields) |idf|
                try target.exec(try a.dupeZ(u8, try ddl.authIdentityIndexSql(a, col.name, idf)));
        }
        created += 1;
    }
    return created;
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

/// Order collection indices so a relation target is created before the collection referencing it.
/// Falls back to declaration order on a cycle (the FK create then fails loudly — acceptable, a
/// circular hard-FK schema is not representable as inline FKs on either backend).
fn collectionCreateOrder(a: std.mem.Allocator, cols: []const schema.Collection) Error![]usize {
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
    // Append any cycle remainder in declaration order.
    for (0..n) |i| if (!placed[i]) try order.append(a, i);
    return order.toOwnedSlice(a);
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

/// Copy every row of `table` from `source` into `target`. The column set is the target's
/// (non-identity) columns intersected with the source's columns, preserving target order. The
/// target table is truncated first so re-runs (under `--force`) are idempotent. Each value is
/// bound by its source storage type, so encrypted TEXT envelopes are carried verbatim. Returns the
/// number of rows loaded.
fn copyTable(a: std.mem.Allocator, source: *db.Db, target: *db.Db, table: []const u8) Error!usize {
    var ta = std.heap.ArenaAllocator.init(a);
    defer ta.deinit();
    const al = ta.allocator();

    // Skip tables the source does not have (target-only: e.g. nothing today, but future-proof).
    if (!try tableExists(al, source, table)) return 0;

    const tgt_cols = try listColumns(al, target, table); // non-identity, ordinal order
    const src_cols = try listColumns(al, source, table);
    var src_set = std.StringHashMap(void).init(al);
    for (src_cols) |c| try src_set.put(c, {});

    var cols: std.ArrayList([]const u8) = .empty;
    for (tgt_cols) |c| if (src_set.contains(c)) try cols.append(al, c);
    if (cols.items.len == 0) return 0;

    // Clear the target table first so a re-run (under --force) is idempotent. Postgres uses
    // TRUNCATE … CASCADE (so a parent with seeded/old child rows clears cleanly — every table is
    // reloaded anyway); SQLite has no TRUNCATE, so DELETE FROM.
    const clear_sql = switch (db.dbBackend(target)) {
        .postgres => try std.fmt.allocPrintSentinel(al, "TRUNCATE TABLE {s} CASCADE;", .{try ddl.quoteIdent(al, table)}, 0),
        .sqlite => try std.fmt.allocPrintSentinel(al, "DELETE FROM {s};", .{try ddl.quoteIdent(al, table)}, 0),
    };
    try target.exec(clear_sql);

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

    const sel_sql = try std.fmt.allocPrintSentinel(al, "SELECT {s} FROM {s};", .{ collist.items, try ddl.quoteIdent(al, table) }, 0);
    const ins_raw = try std.fmt.allocPrint(al, "INSERT INTO {s} ({s}) VALUES ({s});", .{ try ddl.quoteIdent(al, table), collist.items, params.items });

    var sel = try source.prepare(sel_sql);
    defer sel.finalize();

    var loaded: usize = 0;
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
        loaded += 1;
    }

    // Verify the load matches the source row count for this table.
    const want = try countRows(al, source, table);
    if (want != loaded) {
        std.log.err("migrate-db: table '{s}' row-count mismatch (source {d}, loaded {d})", .{ table, want, loaded });
        return Error.RowCountMismatch;
    }
    return loaded;
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

/// List the insertable column names of `table` in ordinal order. On Postgres, IDENTITY columns
/// (`_migrations.id`, `_events._seq`) are excluded — they are server-generated and rejected by a
/// plain INSERT.
fn listColumns(a: std.mem.Allocator, d: *db.Db, table: []const u8) Error![]const []const u8 {
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
            const raw = "SELECT column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = ?1 AND is_identity = 'NO' ORDER BY ordinal_position;";
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
/// caller then falls back to topological table ordering.
fn suspendForeignKeys(d: *db.Db) bool {
    if (db.dbBackend(d) != .postgres) return false;
    d.exec("SET session_replication_role = replica;") catch {
        std.log.warn("migrate-db: could not suspend FK enforcement (target role is not superuser); loading in dependency order", .{});
        return false;
    };
    return true;
}

fn restoreForeignKeys(d: *db.Db) void {
    d.exec("SET session_replication_role = origin;") catch {};
}

/// The order to load tables in. When FK enforcement is suspended, the target's natural (name)
/// order is fine. Otherwise, sort so a relation's referenced record table loads before the
/// referencing one (best-effort, by `_collections` relation graph); non-collection/system tables
/// keep their place.
fn tableLoadOrder(a: std.mem.Allocator, tables: []const []const u8, src_cols: []const schema.Collection, fk_suspended: bool) Error![]const []const u8 {
    if (fk_suspended) return tables;
    // Build a name->dependency(name) set from collections, then stable-topo the table list.
    const order = try collectionCreateOrder(a, src_cols);
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
