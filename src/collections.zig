const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const migrations = @import("migrations.zig");
const ddl = @import("ddl.zig");
const id = @import("id.zig");
const schema_gen = @import("schema_gen.zig");
const fts = @import("search/fts.zig");

/// The JSON parse helpers in schema.zig return the inferred error set of
/// std.json.parseFromSlice, which is wider than schema.ParseError. Capture it so
/// EngineError covers everything rowToCollection can produce.
const SchemaJsonError = @typeInfo(@typeInfo(@TypeOf(schema.fieldsFromJson)).@"fn".return_type.?).error_union.error_set ||
    @typeInfo(@typeInfo(@TypeOf(schema.indexesFromJson)).@"fn".return_type.?).error_union.error_set;

pub const EngineError = error{ Validation, NotFound, Conflict, UnsafeSqliteRebuild, MigrationObjectConflict, StorageNamespaceMissing } || @import("files/namespace.zig").Error || db.DbError || std.mem.Allocator.Error || schema.ParseError || SchemaJsonError || fts.EnsureIndexError;

/// Validation details for the most recent failed create/update (2b surfaces these).
pub threadlocal var last_errors: ?[]const schema.ValidationError = null;

// Bounded diagnostics, independent of updateImpl's scratch lifetime. Long migration names
// are shown by prefix; no heap allocation or ownership transfer is needed on an error path.
threadlocal var rebuild_error_buf: [2048]u8 = undefined;
pub threadlocal var last_rebuild_error: []const u8 = "";

/// A write scope for one collection's DDL that JOINS an already-open transaction instead of
/// failing inside it.
///
/// `create`/`update`/`delete` are each all-or-nothing on their own, which is all a single REST
/// request needs. `schema apply` needs a whole DOCUMENT to be all-or-nothing (#383): a run that
/// fails on the fourth collection must not leave the first three behind. It gets that by opening
/// ONE transaction around the loop — but SQLite and PostgreSQL both reject a nested `BEGIN`, so a
/// scope that finds a transaction already open brackets itself with a SAVEPOINT instead and lets
/// the outer transaction decide the final outcome. Standalone callers are unaffected: with no
/// outer transaction the scope is the plain `BEGIN`/`COMMIT` it always was.
///
/// The savepoint name is fixed. Both engines stack same-named savepoints and scope RELEASE
/// and ROLLBACK TO to the most recent one. Startup convergence can therefore hold this lock
/// while joining an outer transaction and invoke update in another nested scope without
/// releasing the caller's savepoint.
const Tx = struct {
    const savepoint = "zb_collection";

    w: *db.Db,
    /// True when this scope is a savepoint inside a caller's transaction rather than the
    /// transaction itself. Also the answer to "does this call own connection-level state?" —
    /// see `update`'s `PRAGMA foreign_keys`, which is a silent no-op inside a transaction.
    nested: bool,

    fn begin(w: *db.Db) db.DbError!Tx {
        const nested = w.inTransaction();
        if (nested) try w.exec("SAVEPOINT " ++ savepoint ++ ";") else try w.begin();
        const tx = Tx{ .w = w, .nested = nested };
        errdefer tx.rollback();
        try schema_gen.lock(w);
        return tx;
    }

    fn commit(self: Tx) db.DbError!void {
        if (self.nested) return self.w.exec("RELEASE SAVEPOINT " ++ savepoint ++ ";");
        return self.w.commit();
    }

    /// Best-effort undo for an `errdefer`, hence infallible: there is already an error in
    /// flight and it is the one worth reporting. A failed `ROLLBACK TO` leaves the OUTER
    /// transaction open and still doomed — the caller's own errdefer rolls it back whole.
    fn rollback(self: Tx) void {
        if (self.nested) {
            self.w.exec("ROLLBACK TO SAVEPOINT " ++ savepoint ++ ";") catch return;
            self.w.exec("RELEASE SAVEPOINT " ++ savepoint ++ ";") catch {};
            return;
        }
        self.w.rollback() catch {};
    }
};

pub fn create(alloc: std.mem.Allocator, io: std.Io, w: *db.Db, def: schema.Collection) EngineError!schema.Collection {
    last_errors = null;

    // Build the working collection entirely on a scratch child arena: only the validation
    // errors (via `last_errors`) and the final fully-owned reload escape on `alloc`. Because
    // nothing else escapes, the field array, the generated field/collection ids, the auth
    // injection and all DDL/probe/insert scratch live on `sa` and are reclaimed on return —
    // so none of them needs an errdefer.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    // assign field ids where empty (on the scratch arena)
    const fields = try sa.alloc(schema.Field, def.fields.len);
    for (def.fields, 0..) |f, i| {
        fields[i] = f;
        if (f.id.len == 0) {
            var fid = id.fieldId(io);
            fields[i].id = try sa.dupe(u8, &fid);
        }
    }
    var col = def;
    col.fields = fields;
    var cid = id.collectionId(io);
    col.id = try sa.dupe(u8, &cid);

    // validate. `errs` escapes via `last_errors` (read by the API layer after return) as an OWNED
    // slice on `alloc`, so the caller can free it on a non-arena allocator; `toOwnedSlice` shrinks
    // the ArrayList buffer to exactly its length. `errdefer` covers the OOM edge and any later
    // error (where `errs` is empty, so deinit is a no-op).
    var errs: std.ArrayList(schema.ValidationError) = .empty;
    errdefer errs.deinit(alloc);
    try schema.validate(alloc, col, &errs);
    if (errs.items.len > 0) {
        last_errors = try errs.toOwnedSlice(alloc);
        return error.Validation;
    }

    // reject duplicate collection name up front (→ 409 instead of a raw DbError → 500)
    if ((try get(sa, w, def.name)) != null) return error.Conflict;

    // For auth collections, prepend the system columns so the physical table carries them; only
    // the user fields (`col`) are persisted in _collections. On `sa`, so the array injectAuthFields
    // allocates (and the inner array it orphans for auth) are both reclaimed with the scratch arena.
    const full = try schema.injectAuthFields(sa, col);
    // build a DDL view where each single-relation's target collection id is resolved to its table name
    const ddl_col = try resolveRelations(sa, w, full);

    const d = db.dbDialect(w);
    const tx = try Tx.begin(w);
    errdefer tx.rollback();
    try @import("files/namespace.zig").reserve(sa, w, col.id, col.name);
    try w.exec(try sa.dupeZ(u8, try ddl.createTableSql(sa, ddl_col, null, d, &.{})));
    for (col.indexes) |idx| try w.exec(try sa.dupeZ(u8, try ddl.createIndexSql(sa, col.name, idx, d)));
    if (col.type == .auth) {
        for (col.options.auth.identityFields) |idf| {
            try w.exec(try sa.dupeZ(u8, try ddl.authIdentityIndexSql(sa, col.name, idf)));
        }
    }
    // The search index (FTS5 shadow table + triggers, or the Postgres tsvector) is part of the
    // collection's physical shape, so it commits or rolls back with the table (#507). A no-op for
    // a collection with no searchable field.
    try fts.ensureIndex(sa, w, col);
    try insertRow(sa, w, col);
    try schema_gen.bump(w); // inside the tx: a rolled-back create must not advertise a change
    try tx.commit();

    // Return a fully-owned reload on `alloc`. The just-persisted row round-trips through
    // toJson/fromJson to the same shape the former hand-assembled `full` had (now including
    // real created/updated timestamps), but every string/slice is owned — a non-arena caller
    // can `deinit` it. The reload keys on the generated collection id.
    return (try get(alloc, w, col.id)).?;
}

/// Returns a copy of `col` where each relation field's targetCollectionId is replaced by the
/// referenced collection's table NAME (so the FK clause references a real table). Returns
/// error.Validation if a referenced collection does not exist.
///
/// A self-relation (a field targeting `col` itself, e.g. a tree's `parent`) is resolved WITHOUT a
/// DB lookup: `col.id`/`col.name` are already assigned by `create()` before this runs, but the row
/// does not exist yet, so `get()` would spuriously miss it and reject an otherwise-legal schema.
fn resolveRelations(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection) EngineError!schema.Collection {
    const fields = try alloc.alloc(schema.Field, col.fields.len);
    for (col.fields, 0..) |f, i| {
        fields[i] = f;
        switch (f.options) {
            .relation => |r| {
                var nr = r;
                if (std.mem.eql(u8, r.targetCollectionId, col.id) or std.mem.eql(u8, r.targetCollectionId, col.name)) {
                    nr.targetCollectionId = col.name;
                } else {
                    const target = (try get(alloc, w, r.targetCollectionId)) orelse return error.Validation;
                    nr.targetCollectionId = target.name;
                }
                fields[i].options = .{ .relation = nr };
            },
            else => {},
        }
    }
    var out = col;
    out.fields = fields;
    return out;
}

fn bindOptText(st: *db.Stmt, idx: c_int, v: ?[]const u8) db.DbError!void {
    if (v) |s| try st.bindText(idx, s) else try st.bindNull(idx);
}

fn insertRow(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection) EngineError!void {
    const schema_json = try schema.fieldsToJson(alloc, col.fields);
    const indexes_json = try schema.indexesToJson(alloc, col.indexes);
    const options_json = try schema.optionsToJson(alloc, col, false);
    const d = db.dbDialect(w);
    const now = d.nowTextExpr();
    // Identifiers are double-quoted: the mixed-case columns (listRule/viewRule/…) were created
    // quoted by migration 0001, so Postgres (which folds UNQUOTED identifiers to lowercase) needs
    // them quoted to match; SQLite is unaffected.
    const raw = try std.fmt.allocPrint(alloc,
        \\INSERT INTO "_collections"
        \\ ("id","name","type","system","schema","indexes","listRule","viewRule","createRule","updateRule","deleteRule","options","created","updated")
        \\ VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12, {s}, {s});
    , .{ now, now });
    var st = try w.prepare(try d.renumberPlaceholders(alloc, raw));
    defer st.finalize();
    try st.bindText(1, col.id);
    try st.bindText(2, col.name);
    try st.bindText(3, @tagName(col.type));
    try st.bindInt(4, if (col.system) 1 else 0);
    try st.bindText(5, schema_json);
    try st.bindText(6, indexes_json);
    try bindOptText(&st, 7, col.listRule);
    try bindOptText(&st, 8, col.viewRule);
    try bindOptText(&st, 9, col.createRule);
    try bindOptText(&st, 10, col.updateRule);
    try bindOptText(&st, 11, col.deleteRule);
    try st.bindText(12, options_json);
    _ = try st.step();
}

const select_cols =
    \\SELECT "id","name","type","system","schema","indexes","listRule","viewRule","createRule","updateRule","deleteRule","created","updated","options","rename_epoch",(SELECT "namespace" FROM "_storage_namespaces" WHERE "collection_id"="_collections"."id") FROM "_collections"
;

/// Validate the current metadata projection without loading any collections.
/// Read-only maintenance commands must reject an unmigrated schema before
/// reporting per-object unknown references or invoking storage callbacks.
pub fn checkReadSchema(w: *db.Db) db.DbError!void {
    var st = try w.prepare(select_cols ++ " LIMIT 0;");
    defer st.finalize();
    _ = try st.step();
}

fn dupOptText(alloc: std.mem.Allocator, st: *db.Stmt, idx: c_int) !?[]const u8 {
    if (st.isNull(idx)) return null;
    return try alloc.dupe(u8, st.columnText(idx));
}

/// Convert the current row of `st` (columns in `select_cols` order) into a Collection.
/// Must be called before the next step()/finalize() (columnText pointers are transient).
fn rowToCollection(alloc: std.mem.Allocator, st: *db.Stmt) EngineError!schema.Collection {
    if (st.isNull(15)) return error.StorageNamespaceMissing;
    // Start with an empty owned graph; the auth identity default normally points
    // at static "email", so override it until optionsFromJson installs ownership.
    var result: schema.Collection = .{
        .id = "",
        .name = "",
        .fields = &.{},
        .options = .{ .auth = .{ .identityFields = &.{} } },
    };
    errdefer result.deinit(alloc);
    result.id = try alloc.dupe(u8, st.columnText(0));
    result.name = try alloc.dupe(u8, st.columnText(1));
    result.type = std.meta.stringToEnum(schema.CollectionType, st.columnText(2)) orelse .base;
    result.system = st.columnInt(3) != 0;
    result.fields = try schema.fieldsFromJson(alloc, st.columnText(4));
    result.indexes = try schema.indexesFromJson(alloc, st.columnText(5));
    result.listRule = try dupOptText(alloc, st, 6);
    result.viewRule = try dupOptText(alloc, st, 7);
    result.createRule = try dupOptText(alloc, st, 8);
    result.updateRule = try dupOptText(alloc, st, 9);
    result.deleteRule = try dupOptText(alloc, st, 10);
    result.created = try alloc.dupe(u8, st.columnText(11));
    result.updated = try alloc.dupe(u8, st.columnText(12));
    result.options = try schema.optionsFromJson(alloc, st.columnText(13));
    result.rename_epoch = st.columnInt(14);
    result.storage_namespace = try alloc.dupe(u8, st.columnText(15));
    return result;
}

/// Load one FULLY-OWNED collection from the current row of `st`: `rowToCollection` plus auth
/// system-field injection. For auth collections injectAuthFields allocates a fresh fields array
/// (the six static system fields prepended, the user fields shallow-copied in) and thereby ORPHANS
/// the inner `fieldsFromJson` array — its ARRAY BACKING only, since every element string is still
/// referenced by the injected array. Free that backing so the result is a single owned graph the
/// caller can `Collection.deinit`. Base collections are returned unchanged (no injection, no orphan).
fn loadOwned(alloc: std.mem.Allocator, st: *db.Stmt) EngineError!schema.Collection {
    const loaded = try rowToCollection(alloc, st);
    if (loaded.type != .auth) return loaded;
    // If injectAuthFields OOMs, `loaded` is a fully-owned but NOT-yet-injected collection whose
    // ownership shape is a BASE collection (fields = the raw fieldsFromJson user array, no static
    // prefix). Free it as such — as `.auth`, deinit would skip the first six fields (and slice out
    // of bounds when there are fewer than six user fields).
    errdefer {
        var b = loaded;
        b.type = .base;
        b.deinit(alloc);
    }
    const full = try schema.injectAuthFields(alloc, loaded);
    alloc.free(loaded.fields);
    return full;
}

pub fn get(alloc: std.mem.Allocator, w: *db.Db, id_or_name: []const u8) EngineError!?schema.Collection {
    const sql = try db.dbDialect(w).renumberPlaceholders(alloc, select_cols ++ " WHERE id = ?1 OR name = ?1 LIMIT 1;");
    defer alloc.free(sql); // renumberPlaceholders always returns an owned copy (dupeZ on SQLite too)
    var st = try w.prepare(sql);
    defer st.finalize();
    try st.bindText(1, id_or_name);
    if (!try st.step()) return null;
    return try loadOwned(alloc, &st);
}

/// Exact logical-name lookup, excluding the ID alias accepted by get.
pub fn getByName(alloc: std.mem.Allocator, w: *db.Db, name: []const u8) EngineError!?schema.Collection {
    const sql = try db.dbDialect(w).renumberPlaceholders(alloc, select_cols ++ " WHERE name = ?1 LIMIT 1;");
    defer alloc.free(sql);
    var st = try w.prepare(sql);
    defer st.finalize();
    try st.bindText(1, name);
    if (!try st.step()) return null;
    return try loadOwned(alloc, &st);
}

pub fn list(alloc: std.mem.Allocator, w: *db.Db) EngineError![]schema.Collection {
    var out: std.ArrayList(schema.Collection) = .empty;
    // Each element is a fully-owned collection; on any error free every one loaded so far plus the
    // backing buffer, so list() is leak-correct under a raw (non-arena) allocator too.
    errdefer {
        for (out.items) |c| c.deinit(alloc);
        out.deinit(alloc);
    }
    var st = try w.prepare(select_cols ++ " ORDER BY created;");
    defer st.finalize();
    while (try st.step()) {
        try out.append(alloc, try loadOwned(alloc, &st));
    }
    return out.toOwnedSlice(alloc);
}

pub fn update(alloc: std.mem.Allocator, io: std.Io, w: *db.Db, id_or_name: []const u8, newdef: schema.Collection) EngineError!schema.Collection {
    return updateImpl(alloc, io, w, id_or_name, newdef, null);
}

/// Provisioning may plan an additive rebuild before another process changes the
/// schema. Recheck preflight's full stored definition under the same metadata lock as
/// the rebuild, before issuing DDL. Keep update()'s FK and savepoint ownership:
/// wrapping it in a new outer transaction would defeat SQLite's FK pause.
pub fn updateWithExpectedDefinition(alloc: std.mem.Allocator, io: std.Io, w: *db.Db, id_or_name: []const u8, newdef: schema.Collection, expected: schema.Collection) EngineError!schema.Collection {
    return updateImpl(alloc, io, w, id_or_name, newdef, expected);
}

fn updateImpl(alloc: std.mem.Allocator, io: std.Io, w: *db.Db, id_or_name: []const u8, newdef: schema.Collection, expected: ?schema.Collection) EngineError!schema.Collection {
    last_errors = null;

    // Like create(): everything except the validation errors (via `last_errors`) and the final
    // fully-owned reload is scratch on `sa` and reclaimed on return — the existing-collection load,
    // the field array, generated field ids, the duped id/name, the auth injection, and every DDL/
    // rebuild statement. None of them needs an errdefer.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    // assign ids to new fields lacking one; preserve existing ids (all on the scratch arena)
    const fields = try sa.alloc(schema.Field, newdef.fields.len);
    for (newdef.fields, 0..) |f, i| {
        fields[i] = f;
        if (f.id.len == 0) {
            var fid = id.fieldId(io);
            fields[i].id = try sa.dupe(u8, &fid);
        }
    }
    var newc = newdef;
    newc.fields = fields;
    // An update ignores an incoming rename. Validate its fields/options now;
    // the canonical stored name is checked after loading metadata under lock.

    // validate (see create(): last_errors is handed back as an OWNED, freeable slice on `alloc`)
    var errs: std.ArrayList(schema.ValidationError) = .empty;
    errdefer errs.deinit(alloc);
    try schema.validateFieldsAndOptions(alloc, newc, &errs);
    if (errs.items.len > 0) {
        last_errors = try errs.toOwnedSlice(alloc);
        return error.Validation;
    }

    const d = db.dbDialect(w);
    // SQLite rebuilds via __new+copy+drop+rename, so FK enforcement must be paused around it;
    // Postgres uses in-place ALTERs (rebuildPlanPg) and has no such PRAGMA (it would error).
    //
    // `PRAGMA foreign_keys` is a NO-OP inside a transaction, so this is also gated on there
    // NOT being one already open: a caller that brought its own transaction (`schema apply`,
    // which wraps a whole document in one) owns the PRAGMA and must have set it OUTSIDE that
    // transaction. Issuing it here anyway would silently do nothing — the failure mode the
    // gate exists to make impossible.
    const sqlite_rebuild = d.kind == .sqlite and !w.inTransaction();
    if (sqlite_rebuild) {
        try w.exec("PRAGMA foreign_keys=OFF;");
    }
    defer if (sqlite_rebuild) {
        w.exec("PRAGMA foreign_keys=ON;") catch |err| {
            std.log.warn("collection update: could not restore foreign keys ({s}); connection quarantined", .{@errorName(err)});
            const inner = if (comptime @import("build_options").postgres) &w.sqlite else w;
            inner.quarantined = true;
        };
    };
    const tx = try Tx.begin(w);
    errdefer tx.rollback();
    // Every input to the rebuild plan, including relation target names, must
    // come from this locked snapshot. A pre-lock read could observe an interim
    // definition even when another writer restores the expected one (ABA).
    const old = (try get(sa, w, id_or_name)) orelse return error.NotFound;
    try validateStoredName(alloc, old.name);
    newc.id = try sa.dupe(u8, old.id);
    newc.name = try sa.dupe(u8, old.name);
    const same_definition = expected != null and try definitionEql(sa, old, newc);
    // A provisioning caller (`expected` set) also rebuilds an unchanged SQLite definition whose
    // physical unique constraints do not match it: a table created before #498 enforces a
    // tenant-owned collection's unique fields table-wide, and SQLite can drop an inline column
    // constraint only by rebuilding the table. Postgres converges in place
    // (`reconcileUniqueConstraintsPg`), so it never needs this.
    const scope_drift = same_definition and d.kind == .sqlite and try uniqueScopeDriftSqlite(sa, w, old);
    const unchanged = same_definition and !scope_drift;
    if (!unchanged) {
        if (expected) |snapshot| try checkDefinitionSnapshot(sa, snapshot, old);
        // A metadata rebuild must never silently discard migration-owned schema. Check under
        // the metadata lock before any destructive DDL, including tenant-field changes.
        if (d.kind == .sqlite) try checkSqliteRebuild(sa, w, old);
        const foreign = if (d.kind == .sqlite) try tableObjectsSqlite(&scratch, w, old.name) else &[_]TableObject{};

        // Inject auth system fields (after validation, which only sees user fields) so the rebuild
        // preserves the auth columns: `old` is auth-injected (from get), so both sides carry the
        // auth field ids and rebuildPlan keeps them. Without this an auth-collection update would
        // drop email/passwordHash/tokenKey/etc and destroy all credentials. On `sa`.
        const newc_full = try schema.injectAuthFields(sa, newc);
        // relation-resolved view for the rebuild's FK generation
        const ddl_new = try resolveRelations(sa, w, newc_full);

        const migration_objects = if (d.kind == .sqlite)
            try preflightTableObjects(&scratch, w, old, ddl_new, foreign)
        else
            &[_]TableObject{};
        // Validate/drop old search state while all old columns still exist. Sync triggers
        // are regenerated from the new definition after the base table has been rebuilt.
        if (d.kind == .sqlite) {
            // These objects already passed dependency/conflict preflight. Remove them only
            // within this transaction, then restore their exact SQL after regeneration. This
            // keeps search's separate catalog validation from adopting migration objects.
            for (migration_objects) |obj| {
                const kind = if (obj.kind == .index) "INDEX" else "TRIGGER";
                try w.exec(try std.fmt.allocPrintSentinel(sa, "DROP {s} \"main\".{s};", .{ kind, try ddl.quoteIdent(sa, obj.name) }, 0));
            }
            try fts.dropIndexFor(sa, w, old);
        }
        // PostgreSQL alters in place; remove dependent search state only when its operands change.
        if (d.kind == .postgres and !fts.sameSearchColumns(old, newc)) try fts.dropIndexFor(sa, w, old);
        const plan = try ddl.rebuildPlan(sa, old, ddl_new, d);
        for (plan) |stmt| try w.exec(try sa.dupeZ(u8, stmt));
        // Postgres alters in place, so its field-level unique constraints converge from the
        // catalog: scope changes, unique toggles, and a collection made (un)tenant-owned (#498).
        if (d.kind == .postgres and newc.type != .auth) {
            try reconcileUniqueConstraintsPg(sa, w, old, newc_full);
        }
        if (newc.type == .auth) {
            for (newc.options.auth.identityFields) |idf| {
                try w.exec(try sa.dupeZ(u8, try ddl.authIdentityIndexSql(sa, newc.name, idf)));
            }
        }
        if (d.kind == .sqlite or expected != null) try ensureTenantIndex(sa, w, newc);
        // Runtime and startup changes provision search inside the schema transaction.
        try fts.ensureIndex(sa, w, newc);
        for (migration_objects) |obj| {
            std.log.info("provision: collection '{s}' restoring '{s}' after the unique-scope rebuild", .{ old.name, obj.name });
            try w.exec(try sa.dupeZ(u8, obj.sql));
        }
        try updateRow(sa, w, newc.id, newc); // persist user fields only
        try schema_gen.bump(w); // inside the tx: a rolled-back rebuild must not advertise a change
    }
    // Materialize the owned result before committing. An allocator failure in
    // get() must roll back the rebuild rather than report failure after a write.
    const result = (try get(alloc, w, old.id)).?;
    errdefer result.deinit(alloc);
    try tx.commit();
    return result;
}

fn updateRow(alloc: std.mem.Allocator, w: *db.Db, col_id: []const u8, col: schema.Collection) EngineError!void {
    const schema_json = try schema.fieldsToJson(alloc, col.fields);
    const indexes_json = try schema.indexesToJson(alloc, col.indexes);
    const options_json = try schema.optionsToJson(alloc, col, false);
    const d = db.dbDialect(w);
    const raw = try std.fmt.allocPrint(alloc,
        \\UPDATE "_collections" SET "schema"=?2, "indexes"=?3, "listRule"=?4, "viewRule"=?5,
        \\ "createRule"=?6, "updateRule"=?7, "deleteRule"=?8, "options"=?9, "updated"={s} WHERE "id"=?1;
    , .{d.nowTextExpr()});
    var st = try w.prepare(try d.renumberPlaceholders(alloc, raw));
    defer st.finalize();
    try st.bindText(1, col_id);
    try st.bindText(2, schema_json);
    try st.bindText(3, indexes_json);
    try bindOptText(&st, 4, col.listRule);
    try bindOptText(&st, 5, col.viewRule);
    try bindOptText(&st, 6, col.createRule);
    try bindOptText(&st, 7, col.updateRule);
    try bindOptText(&st, 8, col.deleteRule);
    try st.bindText(9, options_json);
    _ = try st.step();
}

/// The five per-collection access rules as a standalone value, so a rule-only change can be
/// compared and persisted without dragging a whole `schema.Collection` (and its physical
/// schema) along.
pub const Rules = struct {
    list: ?[]const u8 = null,
    view: ?[]const u8 = null,
    create: ?[]const u8 = null,
    update: ?[]const u8 = null,
    delete: ?[]const u8 = null,

    pub fn from(col: schema.Collection) Rules {
        return .{
            .list = col.listRule,
            .view = col.viewRule,
            .create = col.createRule,
            .update = col.updateRule,
            .delete = col.deleteRule,
        };
    }

    /// Overlay these rules onto `col`'s rule fields, leaving everything else untouched.
    pub fn applyTo(self: Rules, col: *schema.Collection) void {
        col.listRule = self.list;
        col.viewRule = self.view;
        col.createRule = self.create;
        col.updateRule = self.update;
        col.deleteRule = self.delete;
    }

    /// True if both sides express the SAME five rules.
    ///
    /// `null` and `""` are the same rule — both mean Locked, superusers only (see rules.zig) —
    /// but they PERSIST distinctly: `bindOptText` writes SQL NULL for one and an empty string
    /// for the other. Comparing them literally would make a schema that spells a rule `""`
    /// against a live NULL (or vice versa) look changed forever, rewriting the row on every boot.
    pub fn eql(self: Rules, other: Rules) bool {
        return ruleEql(self.list, other.list) and
            ruleEql(self.view, other.view) and
            ruleEql(self.create, other.create) and
            ruleEql(self.update, other.update) and
            ruleEql(self.delete, other.delete);
    }
};

fn ruleEql(a: ?[]const u8, b: ?[]const u8) bool {
    return std.mem.eql(u8, a orelse "", b orelse "");
}

/// Persist ONLY the five access-rule columns (plus `updated`) of an existing collection.
///
/// The metadata-only counterpart to `update()`. An access rule has no physical-schema
/// consequence whatsoever, but `update()` unconditionally runs `ddl.rebuildPlan`, which has no
/// no-op path: it always emits CREATE "<t>__new" + INSERT…SELECT (a full copy of every row) +
/// DROP TABLE + RENAME, re-creating only the indexes it knows about. Routing a rule change
/// through it would copy the entire table during boot provisioning and destroy any index the
/// plan does not re-create. This writes the rules and nothing else.
///
/// `col_id` must be a collection id (not a name). Callers that only have a name should resolve
/// it via `get` first.
pub fn updateRules(alloc: std.mem.Allocator, w: *db.Db, col_id: []const u8, rules: Rules) EngineError!void {
    // Nothing escapes this call — only the SQL text and its renumbered copy are allocated — so a
    // child arena makes it leak-correct under a raw (non-arena) allocator with no errdefer needed.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const d = db.dbDialect(w);
    // Mixed-case identifiers are quoted for the same reason as insertRow/updateRow: migration
    // 0001 created them quoted, and Postgres folds unquoted identifiers to lowercase.
    const raw = try std.fmt.allocPrint(sa,
        \\UPDATE "_collections" SET "listRule"=?2, "viewRule"=?3, "createRule"=?4,
        \\ "updateRule"=?5, "deleteRule"=?6, "updated"={s} WHERE "id"=?1;
    , .{d.nowTextExpr()});
    // The rule write and its generation bump must land together: a committed rule change that
    // did not bump would leave every serving process enforcing the OLD rule out of its cache,
    // which is precisely the staleness this marker exists to prevent. One transaction, so the
    // two either both happen or neither does.
    const tx = try Tx.begin(w);
    errdefer tx.rollback();
    {
        var st = try w.prepare(try d.renumberPlaceholders(sa, raw));
        defer st.finalize();
        try st.bindText(1, col_id);
        try bindOptText(&st, 2, rules.list);
        try bindOptText(&st, 3, rules.view);
        try bindOptText(&st, 4, rules.create);
        try bindOptText(&st, 5, rules.update);
        try bindOptText(&st, 6, rules.delete);
        _ = try st.step();
    } // finalize the statement BEFORE commit — SQLite will not commit with a live statement
    try schema_gen.bump(w);
    try tx.commit();
}

/// Apply a provisioning plan without rebuilding records. All physical index/search
/// changes and metadata share one lock, transaction, and generation bump.
pub fn provisionMetadata(alloc: std.mem.Allocator, w: *db.Db, expected: schema.Collection, desired: schema.Collection) EngineError!void {
    last_errors = null;
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const a = scratch.allocator();
    const tx = try Tx.begin(w);
    errdefer tx.rollback();
    const current = (try get(a, w, expected.id)) orelse return error.NotFound;
    const unchanged = try definitionEql(a, current, desired);
    if (!unchanged) {
        try validateStoredName(alloc, current.name);
        try checkDefinitionSnapshot(a, expected, current);
    }
    try reconcileIndexes(alloc, w, current, desired);
    try ensureTenantIndex(a, w, desired);
    try fts.ensureIndex(a, w, desired);
    if (!unchanged) {
        try updateRow(a, w, desired.id, desired);
        try schema_gen.bump(w);
    }
    try tx.commit();
}

/// Only a caller that will write checks this: a legacy reserved name that needs no
/// change must keep starting. On failure, `last_errors` is an owned slice on `alloc`.
fn validateStoredName(alloc: std.mem.Allocator, name: []const u8) EngineError!void {
    var errs: std.ArrayList(schema.ValidationError) = .empty;
    errdefer errs.deinit(alloc);
    try schema.validateCollectionName(alloc, name, &errs);
    if (errs.items.len == 0) return;
    last_errors = try errs.toOwnedSlice(alloc);
    return error.Validation;
}

fn definitionEql(alloc: std.mem.Allocator, a: schema.Collection, b: schema.Collection) EngineError!bool {
    if (!std.mem.eql(u8, a.id, b.id) or !std.mem.eql(u8, a.name, b.name) or
        a.system != b.system or a.rename_epoch != b.rename_epoch or
        !std.mem.eql(u8, a.storage_namespace, b.storage_namespace)) return false;
    if (!Rules.from(a).eql(Rules.from(b))) return false;
    checkFieldSnapshot(alloc, a, b) catch |err| switch (err) {
        error.Conflict => return false,
        else => return err,
    };
    const ai = try schema.indexesToJson(alloc, a.indexes);
    defer alloc.free(ai);
    const bi = try schema.indexesToJson(alloc, b.indexes);
    defer alloc.free(bi);
    const ao = try schema.optionsToJson(alloc, a, false);
    defer alloc.free(ao);
    const bo = try schema.optionsToJson(alloc, b, false);
    defer alloc.free(bo);
    return a.type == b.type and std.mem.eql(u8, ai, bi) and std.mem.eql(u8, ao, bo);
}

fn checkDefinitionSnapshot(alloc: std.mem.Allocator, expected: schema.Collection, current: schema.Collection) EngineError!void {
    if (!try definitionEql(alloc, expected, current)) return error.Conflict;
}

fn checkFieldSnapshot(alloc: std.mem.Allocator, expected: schema.Collection, current: schema.Collection) EngineError!void {
    const expected_json = try userFieldsJson(alloc, expected);
    defer alloc.free(expected_json);
    const current_json = try userFieldsJson(alloc, current);
    defer alloc.free(current_json);
    if (!std.mem.eql(u8, expected_json, current_json)) return error.Conflict;
}

/// get() injects auth system fields, which have reserved names. User field ids are
/// opaque: an underscore prefix does not identify a system-owned field.
fn userFieldsJson(alloc: std.mem.Allocator, col: schema.Collection) ![]u8 {
    var user_fields: std.ArrayList(schema.Field) = .empty;
    defer user_fields.deinit(alloc);
    for (col.fields) |field| {
        if (schema.isInjectedField(col.type, field.name)) continue;
        try user_fields.append(alloc, field);
    }
    return schema.fieldsToJson(alloc, user_fields.items);
}

/// Caller owns the metadata transaction and generation bump. Reconcile declared
/// indexes without rebuilding records or touching migration-owned objects.
fn reconcileIndexes(alloc: std.mem.Allocator, w: *db.Db, old: schema.Collection, desired: schema.Collection) EngineError!void {
    const indexes = desired.indexes;
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const old_json = try schema.indexesToJson(sa, old.indexes);
    const new_json = try schema.indexesToJson(sa, indexes);
    if (std.mem.eql(u8, old_json, new_json)) return;
    var newc = desired;
    var user_fields: std.ArrayList(schema.Field) = .empty;
    for (desired.fields) |field| {
        if (schema.isSystemFieldName(field.name)) continue;
        try user_fields.append(sa, field);
    }
    newc.fields = user_fields.items;
    // Reserved names are hidden from field validation, which would refuse a stored
    // legacy field. Index rules still apply to it, so those see every desired field.
    newc.indexes = &.{};
    var errs: std.ArrayList(schema.ValidationError) = .empty;
    errdefer errs.deinit(alloc);
    try schema.validate(alloc, newc, &errs);
    try schema.validateIndexes(alloc, desired, &errs);
    if (errs.items.len > 0) {
        last_errors = try errs.toOwnedSlice(alloc);
        return error.Validation;
    }
    const d = db.dbDialect(w);
    // Only names recorded as belonging to this collection may be dropped. In particular,
    // never DROP a newly declared name: an unrelated migration/collection may own it.
    for (old.indexes) |idx| {
        const unchanged = for (indexes) |next| {
            if (indexEql(idx, next)) break true;
        } else false;
        if (!unchanged) {
            std.log.info("provision: collection '{s}' DROP index '{s}'", .{ old.name, idx.name });
            w.exec(try std.fmt.allocPrintSentinel(sa, "DROP INDEX IF EXISTS {s};", .{try ddl.quoteIdent(sa, idx.name)}, 0)) catch |err| {
                std.log.warn("provision: collection '{s}' index '{s}' DROP failed: {s}; {s}", .{ old.name, idx.name, @errorName(err), w.errMsg() });
                return err;
            };
        }
    }
    for (indexes) |idx| {
        const unchanged = for (old.indexes) |prev| {
            if (indexEql(prev, idx)) break true;
        } else false;
        if (!unchanged) {
            switch (try existingIndex(sa, w, old.name, idx)) {
                .matching => {
                    std.log.info("provision: collection '{s}' ADOPT existing index '{s}'", .{ old.name, idx.name });
                    continue;
                },
                .conflicting => {
                    std.log.warn("provision: collection '{s}' index '{s}' already exists with a different or unsupported definition; startup refused, index preserved", .{ old.name, idx.name });
                    return error.ExecFailed;
                },
                .absent => {},
            }
            std.log.info("provision: collection '{s}' CREATE index '{s}'", .{ old.name, idx.name });
            w.exec(try sa.dupeZ(u8, try ddl.createIndexSql(sa, old.name, idx, d))) catch |err| {
                std.log.warn("provision: collection '{s}' index '{s}' CREATE failed: {s}; {s}; startup refused", .{ old.name, idx.name, @errorName(err), w.errMsg() });
                return err;
            };
        }
    }
    {
        const raw = try std.fmt.allocPrint(sa, "UPDATE \"_collections\" SET \"indexes\"=?2, \"updated\"={s} WHERE \"id\"=?1;", .{d.nowTextExpr()});
        var st = try w.prepare(try d.renumberPlaceholders(sa, raw));
        defer st.finalize();
        try st.bindText(1, old.id);
        try st.bindText(2, new_json);
        _ = try st.step();
    }
}

/// Conservative adoption of ordinary migration-created indexes. Compare catalog properties,
/// not SQL whitespace/quoting. Partial/expression/constraint indexes require an explicit
/// migration: guessing equivalence could silently weaken a declared constraint.
fn existingIndex(alloc: std.mem.Allocator, w: *db.Db, table: []const u8, idx: schema.Index) EngineError!enum { absent, matching, conflicting } {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const a = scratch.allocator();
    const pg = db.dbDialect(w).kind == .postgres;
    // indnullsnotdistinct was introduced in PostgreSQL 15. Catalog-row JSON keeps
    // older servers compatible: absence means their only supported NULLS DISTINCT.
    var st = try w.prepare(if (pg)
        "SELECT t.relname, i.indisunique::int, i.indisvalid::int, i.indnatts, i.indnkeyatts, (i.indpred IS NULL)::int, am.amname, (NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid=i.indexrelid))::int, COALESCE((to_jsonb(i)->>'indnullsnotdistinct')::boolean, false)::int FROM pg_class n JOIN pg_namespace ns ON ns.oid=n.relnamespace LEFT JOIN pg_index i ON i.indexrelid=n.oid LEFT JOIN pg_class t ON t.oid=i.indrelid LEFT JOIN pg_am am ON am.oid=n.relam WHERE ns.nspname=current_schema() AND n.relname=$1;"
    else
        "SELECT tbl_name FROM sqlite_master WHERE name=?1 COLLATE NOCASE;");
    defer st.finalize();
    try st.bindText(1, idx.name);
    if (!try st.step()) return .absent;
    if (!std.mem.eql(u8, st.columnText(0), table) or idx.where != null) return .conflicting;
    if (pg) {
        if (st.columnInt(1) != @intFromBool(idx.unique) or st.columnInt(2) != 1 or
            st.columnInt(3) != idx.fields.len or st.columnInt(4) != idx.fields.len or
            st.columnInt(5) != 1 or !std.mem.eql(u8, st.columnText(6), "btree") or st.columnInt(7) != 1 or
            st.columnInt(8) != 0) return .conflicting;
        // Column-only pg_get_indexdef omits ordering/opclass/collation decorations;
        // check those catalog properties separately before comparing the expression.
        var cols = try w.prepare("SELECT pg_get_indexdef(n.oid, k, true), i.indoption[k-1], op.opcdefault::int, (i.indcollation[k-1] = (SELECT a.attcollation FROM pg_attribute a WHERE a.attrelid=i.indrelid AND a.attname=(string_to_array($3, ','))[k]))::int FROM pg_class n JOIN pg_namespace ns ON ns.oid=n.relnamespace JOIN pg_index i ON i.indexrelid=n.oid CROSS JOIN generate_series(1, $2::int) k JOIN pg_opclass op ON op.oid=i.indclass[k-1] WHERE ns.nspname=current_schema() AND n.relname=$1 ORDER BY k;");
        defer cols.finalize();
        try cols.bindText(1, idx.name);
        try cols.bindInt(2, @intCast(idx.fields.len));
        try cols.bindText(3, try std.mem.join(a, ",", idx.fields));
        for (idx.fields) |field| {
            if (!try cols.step()) return .conflicting;
            if (cols.columnInt(1) != 0 or cols.columnInt(2) != 1 or cols.columnInt(3) != 1) return .conflicting;
            const quoted = try ddl.quoteIdent(a, field);
            const bare_expr = if (idx.collation == .nocase) try std.fmt.allocPrint(a, "lower({s})", .{field}) else field;
            const quoted_expr = if (idx.collation == .nocase) try std.fmt.allocPrint(a, "lower({s})", .{quoted}) else quoted;
            if (!std.mem.eql(u8, cols.columnText(0), bare_expr) and !std.mem.eql(u8, cols.columnText(0), quoted_expr)) return .conflicting;
        }
    } else {
        var props = try w.prepare("SELECT \"unique\", origin, partial FROM pragma_index_list(?1, 'main') WHERE name=?2 COLLATE NOCASE;");
        defer props.finalize();
        try props.bindText(1, table);
        try props.bindText(2, idx.name);
        if (!try props.step() or props.columnInt(0) != @intFromBool(idx.unique) or
            !std.mem.eql(u8, props.columnText(1), "c") or props.columnInt(2) != 0) return .conflicting;
        var cols = try w.prepare("SELECT name, \"desc\", coll FROM pragma_index_xinfo(?1) WHERE key=1 ORDER BY seqno;");
        defer cols.finalize();
        try cols.bindText(1, idx.name);
        for (idx.fields) |field| {
            if (!try cols.step() or !std.mem.eql(u8, cols.columnText(0), field) or cols.columnInt(1) != 0 or
                !std.ascii.eqlIgnoreCase(cols.columnText(2), if (idx.collation == .nocase) "nocase" else "binary")) return .conflicting;
        }
        if (try cols.step()) return .conflicting;
    }
    return .matching;
}

fn indexEql(a: schema.Index, b: schema.Index) bool {
    if (!std.mem.eql(u8, a.name, b.name) or a.unique != b.unique or a.collation != b.collation or
        (a.where == null) != (b.where == null) or !ruleEql(a.where, b.where) or a.fields.len != b.fields.len) return false;
    for (a.fields, b.fields) |af, bf| if (!std.mem.eql(u8, af, bf)) return false;
    return true;
}

pub fn delete(alloc: std.mem.Allocator, w: *db.Db, id_or_name: []const u8) EngineError!void {
    // delete() returns nothing, so every allocation here is scratch — the target/collection loads
    // and the DROP/DELETE SQL. Reclaim them via a child arena so the call is leak-correct under
    // any allocator.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const target = (try get(sa, w, id_or_name)) orelse return error.NotFound;
    // refuse if another collection has a relation targeting this one
    const all = try list(sa, w);
    for (all) |c| {
        if (std.mem.eql(u8, c.id, target.id)) continue;
        for (c.fields) |f| switch (f.options) {
            .relation => |r| if (std.mem.eql(u8, r.targetCollectionId, target.id)) return error.Conflict,
            else => {},
        };
    }
    const tx = try Tx.begin(w);
    errdefer tx.rollback();
    // SQLite's FTS5 shadow table is a separate table that `DROP TABLE` on the base would orphan;
    // drop it (and its triggers) first, in the same transaction (#507). The Postgres tsvector
    // column and its GIN index go with the table.
    if (db.dbDialect(w).kind == .sqlite) try fts.dropIndexFor(sa, w, target);
    try w.exec(try std.fmt.allocPrintSentinel(sa, "DROP TABLE {s};", .{try ddl.quoteIdent(sa, target.name)}, 0));
    var st = try w.prepare(try db.dbDialect(w).renumberPlaceholders(sa, "DELETE FROM \"_collections\" WHERE \"id\" = ?1;"));
    defer st.finalize();
    try st.bindText(1, target.id);
    _ = try st.step();
    try schema_gen.bump(w); // inside the tx: a rolled-back delete must not advertise a change
    try tx.commit();
}

test "create/update return a fully-owned reload and leak nothing on any error path" {
    // Runs create/update SUCCESS and ERROR paths under the RAW leak-detecting allocator — no arena
    // to mask a missed free OR a double-free. create()/update() now build their working collection
    // on a scratch child arena and return a fully-owned reload (via get()), so the ONLY things that
    // escape on `alloc` are that reload and the validation `last_errors`. On every error path the
    // scratch arena reclaims all working state, so nothing must leak; the reload is freed via
    // `Collection.deinit`. The arena-wrapped collections tests cannot catch a double-free/UAF in the
    // owned graph (the arena reclaims regardless), so this is the guard.
    const a = std.testing.allocator;
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);

    // base create SUCCESS — a fully-owned reload.
    const bfields = [_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }};
    const bdef = schema.Collection{ .id = "", .name = "posts", .fields = &bfields, .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "" };
    const base = try create(a, std.testing.io, &d, bdef);
    base.deinit(a);

    // create CONFLICT (duplicate name) — the probe runs before any escaping alloc; the scratch
    // arena must reclaim the field array + generated id with no leak.
    const cfields = [_]schema.Field{.{ .id = "", .name = "note", .options = .{ .text = .{} } }};
    const cdef = schema.Collection{ .id = "", .name = "posts", .fields = &cfields, .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "" };
    try std.testing.expectError(error.Conflict, create(a, std.testing.io, &d, cdef));

    // create VALIDATION error (bad collection name) with an empty-id field — the id is generated on
    // the scratch arena before validation fails; only `last_errors` escapes on `alloc`.
    const vfields = [_]schema.Field{.{ .id = "", .name = "x", .options = .{ .text = .{} } }};
    const vdef = schema.Collection{ .id = "", .name = "1bad", .fields = &vfields, .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "" };
    try std.testing.expectError(error.Validation, create(a, std.testing.io, &d, vdef));
    // last_errors is handed back as an owned slice (elements are static/borrowed strings) — free it.
    if (last_errors) |le| {
        a.free(le);
        last_errors = null;
    }

    // auth create SUCCESS — the reload exercises loadOwned's static-field skip + orphan-free and is
    // fully owned; deinit must skip the six static system fields and free only the injected backing
    // plus the user fields.
    const afields = [_]schema.Field{.{ .id = "af1", .name = "bio", .options = .{ .text = .{} } }};
    const adef = schema.Collection{ .id = "", .name = "members", .type = .auth, .fields = &afields, .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "" };
    const auth = try create(a, std.testing.io, &d, adef);
    auth.deinit(a);

    // auth create ERROR after injectAuthFields — a relation to a missing target makes
    // resolveRelations fail once the auth-injected array + orphan already exist on the scratch
    // arena; the arena must reclaim them with no leak.
    const rfields = [_]schema.Field{.{ .id = "r1", .name = "ref", .options = .{ .relation = .{ .targetCollectionId = "ghost", .maxSelect = 1 } } }};
    const rdef = schema.Collection{ .id = "", .name = "linkers", .type = .auth, .fields = &rfields, .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "" };
    try std.testing.expectError(error.Validation, create(a, std.testing.io, &d, rdef));

    // update SUCCESS (base) — a fully-owned reload.
    const ufields = [_]schema.Field{ .{ .id = "f1", .name = "title", .options = .{ .text = .{} } }, .{ .id = "f2", .name = "body", .options = .{ .text = .{} } } };
    const udef = schema.Collection{ .id = "", .name = "posts", .fields = &ufields, .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "" };
    const upd = try update(a, std.testing.io, &d, "posts", udef);
    upd.deinit(a);

    // update VALIDATION error — the id/name dupes and the generated field id live on the scratch
    // arena when validation fails on the bad field name; only `last_errors` escapes.
    const ubadfields = [_]schema.Field{.{ .id = "", .name = "1bad", .options = .{ .text = .{} } }};
    const ubaddef = schema.Collection{ .id = "", .name = "posts", .fields = &ubadfields, .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "" };
    try std.testing.expectError(error.Validation, update(a, std.testing.io, &d, "posts", ubaddef));
    if (last_errors) |le| {
        a.free(le);
        last_errors = null;
    }

    // update NOT-FOUND — errors before any escaping alloc; must simply not leak.
    try std.testing.expectError(error.NotFound, update(a, std.testing.io, &d, "no-such", udef));
}

test "create persists a collection and builds its physical table" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .required = true, .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } },
    };
    const def = schema.Collection{ .id = "", .name = "posts", .fields = &fields };
    const created = try create(a, std.testing.io, &d, def);
    defer created.deinit(a);
    try std.testing.expect(created.id.len == 15);
    var st = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('posts') WHERE name IN ('id','created','updated','title','price');");
    defer st.finalize();
    try std.testing.expect((try st.step()));
    try std.testing.expectEqual(@as(i64, 5), st.columnInt(0));
    const got = (try get(a, &d, "posts")).?;
    defer got.deinit(a);
    try std.testing.expectEqualStrings("posts", got.name);
    try std.testing.expectEqual(@as(usize, 2), got.fields.len);
    const all = try list(a, &d);
    defer {
        for (all) |c| c.deinit(a);
        a.free(all);
    }
    var user_count: usize = 0;
    for (all) |c| if (!c.system) {
        user_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), user_count);
}

test "create rejects an invalid collection" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;
    const def = schema.Collection{ .id = "", .name = "1bad", .fields = &.{} };
    try std.testing.expectError(error.Validation, create(a, std.testing.io, &d, def));
    if (last_errors) |le| {
        a.free(le);
        last_errors = null;
    }
}

test "update rebuilds table and preserves data across a field rename" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    const f0 = [_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }};
    const created = try create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &f0 });
    defer created.deinit(a);
    try d.exec("INSERT INTO posts (id, created, updated, title) VALUES ('r1','t','t','hello');");

    const f1 = [_]schema.Field{
        .{ .id = "f1", .name = "headline", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "views", .options = .{ .number = .{ .mode = .int } } },
    };
    var newdef = created;
    newdef.fields = &f1;
    const updated = try update(a, std.testing.io, &d, created.id, newdef);
    defer updated.deinit(a);

    var st = try d.prepare("SELECT headline, views FROM posts WHERE id='r1';");
    defer st.finalize();
    try std.testing.expect((try st.step()));
    try std.testing.expectEqualStrings("hello", st.columnText(0));
    try std.testing.expect(st.isNull(1));
}

test "create rejects an index name containing SQL (injection guard)" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;
    const evil = [_]schema.Index{.{ .name = "x\" ON \"posts\" (\"id\"); DROP TABLE \"_collections\"; --", .fields = &.{"id"}, .unique = false }};
    const def = schema.Collection{ .id = "", .name = "posts", .fields = &.{}, .indexes = &evil };
    try std.testing.expectError(error.Validation, create(a, std.testing.io, &d, def));
    if (last_errors) |le| {
        a.free(le);
        last_errors = null;
    }
    // _collections still exists
    var st = try d.prepare("SELECT COUNT(*) FROM \"_collections\";");
    defer st.finalize();
    try std.testing.expect((try st.step()));
}

test "create rejects a duplicate collection name with Conflict" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;
    const created = try create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &.{} });
    defer created.deinit(a);
    try std.testing.expectError(error.Conflict, create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &.{} }));
}

test "unique field enforces uniqueness at the db level" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;
    const fields = [_]schema.Field{.{ .id = "f1", .name = "slug", .unique = true, .options = .{ .text = .{} } }};
    const created = try create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &fields });
    defer created.deinit(a);
    try d.exec("INSERT INTO posts (id, created, updated, slug) VALUES ('r1','t','t','x');");
    try std.testing.expectError(db.DbError.ExecFailed, d.exec("INSERT INTO posts (id, created, updated, slug) VALUES ('r2','t','t','x');"));
}

test "auth collection gets system columns; passwordHash hidden in metadata" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    try migrations.run(&d);
    const fields = [_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }};
    const created = try create(a, std.testing.io, &d, .{ .id = "", .name = "users", .type = .auth, .fields = &fields });
    created.deinit(a);

    var st = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('users') WHERE name IN ('email','username','passwordHash','tokenKey','verified');");
    defer st.finalize();
    _ = try st.step();
    try std.testing.expectEqual(@as(i64, 5), st.columnInt(0));

    const got = (try get(a, &d, "users")).?;
    defer got.deinit(a);
    try std.testing.expect(schema.fieldByName(got, "email") != null);
    try std.testing.expect(schema.fieldByName(got, "bio") != null);
    // collectionToJson self-frees its scratch (contract 1): returns only the serialized
    // string on `a`, so the raw testing allocator catches any leak.
    const json = try schema.collectionToJson(a, got);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"email\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "passwordHash") == null);
}

test "updating an auth collection preserves its auth columns (credentials not dropped)" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    try migrations.run(&d);
    const f0 = [_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }};
    const created = try create(a, std.testing.io, &d, .{ .id = "", .name = "users", .type = .auth, .fields = &f0 });
    defer created.deinit(a);
    // seed a credential row directly
    try d.exec("INSERT INTO users (id,created,updated,email,passwordHash,tokenKey,verified) VALUES ('u1','t','t','a@b.c','$argon2id$hash','tk',1);");

    // update the user-field schema (add a field) — must NOT drop the auth columns
    const f1 = [_]schema.Field{
        .{ .id = "f1", .name = "bio", .options = .{ .text = .{} } },
        .{ .id = "", .name = "nickname", .options = .{ .text = .{} } },
    };
    var newdef = created;
    newdef.fields = &f1;
    const updated = try update(a, std.testing.io, &d, created.id, newdef);
    defer updated.deinit(a);

    // the credential survives the rebuild
    var st = try d.prepare("SELECT email, passwordHash, tokenKey, verified, nickname FROM users WHERE id='u1';");
    defer st.finalize();
    try std.testing.expect((try st.step()));
    try std.testing.expectEqualStrings("a@b.c", st.columnText(0));
    try std.testing.expectEqualStrings("$argon2id$hash", st.columnText(1));
    try std.testing.expectEqualStrings("tk", st.columnText(2));
}

test "delete drops the table; delete refuses when referenced by a relation" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = std.testing.allocator;

    const users = try create(a, std.testing.io, &d, .{ .id = "", .name = "users", .fields = &.{} });
    defer users.deinit(a);
    const pf = [_]schema.Field{.{ .id = "f1", .name = "author", .options = .{ .relation = .{ .targetCollectionId = users.id, .maxSelect = 1 } } }};
    const posts = try create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &pf });
    defer posts.deinit(a);

    try std.testing.expectError(error.Conflict, delete(a, &d, "users"));
    try delete(a, &d, "posts");
    try delete(a, &d, "users");
    try std.testing.expect((try get(a, &d, "posts")) == null);
}

test "auth collection enforces identity uniqueness via partial unique index, allows multiple empty" {
    var d = try db.Db.openMemory();
    defer d.close();
    try @import("migrations.zig").run(&d);
    const a = std.testing.allocator;
    const created = try create(a, std.testing.io, &d, .{
        .id = "",
        .name = "members",
        .type = .auth,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
    });
    defer created.deinit(a);
    // two distinct emails ok
    try d.exec("INSERT INTO \"members\" (\"id\",\"created\",\"updated\",\"email\") VALUES ('a','','','x@y.z');");
    try d.exec("INSERT INTO \"members\" (\"id\",\"created\",\"updated\",\"email\") VALUES ('b','','','q@y.z');");
    // duplicate non-empty email rejected (exec maps the SQLite constraint error to ExecFailed)
    try std.testing.expectError(error.ExecFailed, d.exec("INSERT INTO \"members\" (\"id\",\"created\",\"updated\",\"email\") VALUES ('c','','','x@y.z');"));
    // two empty emails allowed (partial index excludes them)
    try d.exec("INSERT INTO \"members\" (\"id\",\"created\",\"updated\",\"email\") VALUES ('d','','','');");
    try d.exec("INSERT INTO \"members\" (\"id\",\"created\",\"updated\",\"email\") VALUES ('e','','','');");
}

test "deinit frees a fully-owned base collection: every field type + indexes + rules + ttl/tenant" {
    // The exhaustive mirror check: a base collection populated with EVERY field type carrying owned
    // options (text pattern, date min/max, select values, relation target, file mimeTypes, …), plus
    // multiple indexes (unique / partial-where / multi-column), all five rules, and ttl/tenant
    // fields. Read back with get() → a fully-owned graph → Collection.deinit under the RAW
    // leak-detecting allocator. A missed free leaks; a stray free of a static/borrowed string, or
    // freeing an already-freed pointer, panics the DebugAllocator. Zero leaks == the deinit mirrors
    // fromJson exactly.
    const a = std.testing.allocator;
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);

    // relation target created first (its id is the relation field's targetCollectionId)
    const tfields = [_]schema.Field{.{ .id = "t1", .name = "label", .options = .{ .text = .{} } }};
    const target = try create(a, std.testing.io, &d, .{ .id = "", .name = "targets", .fields = &tfields });
    defer target.deinit(a);

    const values = [_][]const u8{ "red", "green", "blue" };
    const mimes = [_][]const u8{ "image/png", "image/jpeg" };
    const fields = [_]schema.Field{
        .{ .id = "f_title", .name = "title", .options = .{ .text = .{ .min = 1, .max = 100, .pattern = "^[a-z]+$" } } },
        .{ .id = "f_email", .name = "contact", .options = .{ .email = .{} } },
        .{ .id = "f_url", .name = "homepage", .options = .{ .url = .{} } },
        .{ .id = "f_editor", .name = "body", .options = .{ .editor = .{} } },
        .{ .id = "f_date", .name = "start_at", .options = .{ .date = .{ .min = "2020-01-01T00:00:00Z", .max = "2030-01-01T00:00:00Z" } } },
        .{ .id = "f_auto", .name = "made_at", .options = .{ .autodate = .{ .onCreate = true } } },
        .{ .id = "f_bool", .name = "active", .options = .{ .bool = .{} } },
        .{ .id = "f_num", .name = "qty", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } },
        .{ .id = "f_json", .name = "meta", .options = .{ .json = .{} } },
        .{ .id = "f_select", .name = "color", .options = .{ .select = .{ .values = &values, .maxSelect = 1 } } },
        .{ .id = "f_rel", .name = "owner", .options = .{ .relation = .{ .targetCollectionId = target.id, .maxSelect = 1 } } },
        .{ .id = "f_file", .name = "avatar", .options = .{ .file = .{ .maxSelect = 1, .mimeTypes = &mimes } } },
        .{ .id = "f_acct", .name = "account", .options = .{ .text = .{} } },
    };
    const cols = [_][]const u8{ "title", "qty" };
    const indexes = [_]schema.Index{
        .{ .name = "idx_title", .fields = &[_][]const u8{"title"}, .unique = true },
        .{ .name = "idx_active", .fields = &[_][]const u8{"active"}, .where = "active = 1" },
        .{ .name = "idx_multi", .fields = &cols },
    };
    const def = schema.Collection{
        .id = "",
        .name = "widgets",
        .fields = &fields,
        .indexes = &indexes,
        .listRule = "@public",
        .viewRule = "@public",
        .createRule = "@public",
        .updateRule = "@public",
        .deleteRule = "@public",
        .options = .{ .ttl_field = "made_at", .tenant_field = "account" },
    };
    const created = try create(a, std.testing.io, &d, def);
    defer created.deinit(a);

    const got = (try get(a, &d, "widgets")).?;
    try std.testing.expectEqualStrings("widgets", got.name);
    try std.testing.expectEqual(@as(usize, fields.len), got.fields.len);
    try std.testing.expect(schema.fieldByName(got, "title") != null);
    try std.testing.expect(schema.fieldByName(got, "owner") != null);
    try std.testing.expectEqual(@as(usize, 3), got.indexes.len);
    try std.testing.expectEqualStrings("made_at", got.options.ttl_field.?);
    try std.testing.expectEqualStrings("account", got.options.tenant_field.?);
    got.deinit(a);

    // list() returns fully-owned collections too — free every one via deinit (no orphan leak).
    const all = try list(a, &d);
    defer {
        for (all) |c| c.deinit(a);
        a.free(all);
    }
    try std.testing.expect(all.len >= 2);
}

test "deinit frees a fully-owned auth collection: static-field skip + orphan-free + oauth2/identity" {
    // Auth path: identityFields, a populated oauth2 provider (name/clientId/clientSecret/
    // redirectUrls/scopes/authURL/tokenURL), and a user field. get() prepends the six STATIC
    // system fields (authSystemFields) and frees the orphaned inner fields array (loadOwned). deinit
    // must SKIP those six static fields (freeing their static id/name would panic) and free only the
    // injected slice backing + the user field + the whole options graph. RAW allocator → zero leaks.
    const a = std.testing.allocator;
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);

    const ids = [_][]const u8{ "email", "username" };
    const redirects = [_][]const u8{ "https://app.example/cb", "https://app.example/cb2" };
    const scopes = [_][]const u8{ "openid", "email" };
    const providers = [_]schema.OAuth2Provider{.{
        .name = "google",
        .clientId = "client-123",
        .clientSecret = "secret-xyz",
        .redirectUrls = &redirects,
        .authURL = "https://accounts.example/auth",
        .tokenURL = "https://accounts.example/token",
        .scopes = &scopes,
    }};
    const ufields = [_]schema.Field{.{ .id = "u_bio", .name = "bio", .options = .{ .text = .{} } }};
    const def = schema.Collection{
        .id = "",
        .name = "accounts",
        .type = .auth,
        .fields = &ufields,
        .options = .{ .auth = .{
            .identityFields = &ids,
            .oauth2 = .{ .enabled = true, .providers = &providers },
        } },
    };
    const created = try create(a, std.testing.io, &d, def);
    defer created.deinit(a);

    const got = (try get(a, &d, "accounts")).?;
    // 6 static system fields + 1 user field
    try std.testing.expectEqual(@as(usize, 7), got.fields.len);
    try std.testing.expectEqualStrings("email", got.fields[0].name); // static system field
    try std.testing.expect(schema.fieldByName(got, "bio") != null);
    try std.testing.expectEqual(@as(usize, 2), got.options.auth.identityFields.len);
    try std.testing.expectEqual(@as(usize, 1), got.options.auth.oauth2.providers.len);
    try std.testing.expectEqualStrings("google", got.options.auth.oauth2.providers[0].name);
    try std.testing.expectEqual(@as(usize, 2), got.options.auth.oauth2.providers[0].redirectUrls.len);
    got.deinit(a);
}

test "create and update return deinit-safe fully-owned reloads (base and auth)" {
    // Proves the reload returned by create()/update() is a single fully-owned graph: deinit it
    // directly under the RAW allocator (no get() round-trip needed). Covers base and auth for both.
    const a = std.testing.allocator;
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);

    // base create → deinit the reload
    const bf = [_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }};
    const bc = try create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &bf });
    bc.deinit(a);

    // base update (add a field) → deinit the reload
    const bf2 = [_]schema.Field{ .{ .id = "f1", .name = "title", .options = .{ .text = .{} } }, .{ .id = "", .name = "body", .options = .{ .text = .{} } } };
    const bu = try update(a, std.testing.io, &d, "posts", .{ .id = "", .name = "posts", .fields = &bf2 });
    bu.deinit(a);

    // auth create → deinit the reload (static-field skip on the reload path)
    const af = [_]schema.Field{.{ .id = "a1", .name = "bio", .options = .{ .text = .{} } }};
    const ac = try create(a, std.testing.io, &d, .{ .id = "", .name = "users", .type = .auth, .fields = &af });
    ac.deinit(a);

    // auth update → deinit the reload
    const af2 = [_]schema.Field{ .{ .id = "a1", .name = "bio", .options = .{ .text = .{} } }, .{ .id = "", .name = "nick", .options = .{ .text = .{} } } };
    const au = try update(a, std.testing.io, &d, "users", .{ .id = "", .name = "users", .type = .auth, .fields = &af2 });
    au.deinit(a);
}

test "create/update/delete join a caller's open transaction and roll back with it" {
    // The seam `schema apply` is built on (#383). Each of these opens its own transaction
    // when called standalone — which is why a nested `BEGIN` used to be a hard SQLite error
    // ("cannot start a transaction within a transaction") and why a document could only ever
    // be applied one committed collection at a time. Inside a caller's transaction they must
    // instead bracket themselves with a SAVEPOINT, so the CALLER's rollback undoes all of it.
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try migrations.run(&conn);

    // A collection that exists BEFORE the outer transaction, so the rollback has something to
    // restore rather than merely something to discard.
    const notes = try create(a, std.testing.io, &conn, .{
        .id = "",
        .name = "notes",
        .fields = &.{.{ .id = "", .name = "body", .options = .{ .text = .{} } }},
    });
    defer notes.deinit(a);

    try conn.begin();
    {
        const made = try create(a, std.testing.io, &conn, .{
            .id = "",
            .name = "scratch",
            .fields = &.{.{ .id = "", .name = "x", .options = .{ .text = .{} } }},
        });
        made.deinit(a);
        // Visible to this connection mid-transaction — the savepoint was released, not committed.
        const seen = (try get(a, &conn, "scratch")).?;
        seen.deinit(a);

        const grown = try update(a, std.testing.io, &conn, "notes", .{
            .id = "",
            .name = "notes",
            .fields = &.{
                .{ .id = notes.fields[0].id, .name = "body", .options = .{ .text = .{} } },
                .{ .id = "", .name = "extra", .options = .{ .text = .{} } },
            },
        });
        defer grown.deinit(a);
        try std.testing.expectEqual(@as(usize, 2), grown.fields.len);
    }
    try conn.rollback();

    // The outer rollback undid every one of them.
    try std.testing.expect((try get(a, &conn, "scratch")) == null);
    const after = (try get(a, &conn, "notes")).?;
    defer after.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), after.fields.len);
    try std.testing.expectEqualStrings("body", after.fields[0].name);

    // And the connection is left usable: `delete` still works standalone afterwards.
    try delete(a, &conn, "notes");
    try std.testing.expect((try get(a, &conn, "notes")) == null);
}

test "a failed create inside a caller's transaction leaves the caller's transaction usable" {
    // The savepoint half of the contract: an inner failure must roll back to its OWN
    // savepoint and no further, so the caller can decide whether to continue or abandon.
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try migrations.run(&conn);

    try conn.begin();
    const first = try create(a, std.testing.io, &conn, .{
        .id = "",
        .name = "keep",
        .fields = &.{.{ .id = "", .name = "x", .options = .{ .text = .{} } }},
    });
    first.deinit(a);

    // Fail INSIDE the savepoint, not before it: a raw table with no `_collections` row passes
    // the up-front duplicate-name check (which reads `_collections`) and then collides on the
    // `CREATE TABLE` — the first statement after `Tx.begin`. `insertRow`/`schema_gen.bump`
    // never run, so there IS partial work for the savepoint to undo.
    try conn.exec("CREATE TABLE \"squatter\" (\"x\" TEXT);");
    try std.testing.expectError(error.ExecFailed, create(a, std.testing.io, &conn, .{
        .id = "",
        .name = "squatter",
        .fields = &.{.{ .id = "", .name = "y", .options = .{ .text = .{} } }},
    }));
    try std.testing.expect((try get(a, &conn, "squatter")) == null);

    // The caller's transaction survived the inner failure — it is still open and still holds
    // the work done before it — so the caller, not the callee, decides the outcome.
    try std.testing.expect(conn.inTransaction());
    const kept = (try get(a, &conn, "keep")).?;
    kept.deinit(a);
    try conn.commit();
    const still = (try get(a, &conn, "keep")).?;
    still.deinit(a);
}

/// One unique constraint of a physical table, as the column names it covers in key order
/// (SQLite: an `origin='u'` autoindex; Postgres: a `contype='u'` constraint).
const UniqueConstraint = struct { name: []const u8, cols: []const []const u8 };

/// The unique table/column constraints of `table`, allocated on `alloc` (a scratch arena:
/// callers never free the result piecemeal). Unique INDEXES (`.indexes`, migrations) are not
/// constraints and are not listed, so nothing here can touch a declared or migration-owned index.
fn uniqueConstraints(alloc: std.mem.Allocator, w: *db.Db, table: []const u8) EngineError![]UniqueConstraint {
    var out: std.ArrayList(UniqueConstraint) = .empty;
    if (db.dbDialect(w).kind == .postgres) {
        var st = try w.prepare("SELECT c.conname, a.attname FROM pg_constraint c CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY k(n, o) JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.n WHERE c.conrelid = to_regclass($1) AND c.contype = 'u' ORDER BY c.conname, k.o;");
        defer st.finalize();
        try st.bindText(1, try ddl.quoteIdent(alloc, table));
        var cols: std.ArrayList([]const u8) = .empty;
        while (try st.step()) {
            const name = st.columnText(0);
            if (out.items.len == 0 or !std.mem.eql(u8, out.items[out.items.len - 1].name, name)) {
                cols = .empty;
                try out.append(alloc, .{ .name = try alloc.dupe(u8, name), .cols = &.{} });
            }
            try cols.append(alloc, try alloc.dupe(u8, st.columnText(1)));
            out.items[out.items.len - 1].cols = cols.items;
        }
        return out.items;
    }
    var names: std.ArrayList([]const u8) = .empty;
    {
        var st = try w.prepare("SELECT name FROM pragma_index_list(?1, 'main') WHERE origin = 'u' ORDER BY name;");
        defer st.finalize();
        try st.bindText(1, table);
        while (try st.step()) try names.append(alloc, try alloc.dupe(u8, st.columnText(0)));
    }
    for (names.items) |name| {
        var cols: std.ArrayList([]const u8) = .empty;
        var st = try w.prepare("SELECT name FROM pragma_index_info(?1, 'main') ORDER BY seqno;");
        defer st.finalize();
        try st.bindText(1, name);
        while (try st.step()) try cols.append(alloc, try alloc.dupe(u8, st.columnText(0)));
        try out.append(alloc, .{ .name = name, .cols = cols.items });
    }
    return out.items;
}

fn colsEql(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// PostgreSQL stores at most 63 bytes of these ASCII schema identifiers. Compare
/// catalog columns to their physical names, including both keys of tenant composites.
fn constraintColsEql(a: []const []const u8, b: []const []const u8, postgres: bool) bool {
    if (!postgres) return colsEql(a, b);
    if (a.len != b.len) return false;
    for (a, b) |physical, metadata| {
        if (!std.mem.eql(u8, physical, metadata[0..@min(metadata.len, 63)])) return false;
    }
    return true;
}

fn hasConstraint(cons: []const UniqueConstraint, cols: []const []const u8, postgres: bool) bool {
    for (cons) |con| if (constraintColsEql(con.cols, cols, postgres)) return true;
    return false;
}

fn hasTenantScopedUnique(col: schema.Collection) bool {
    for (col.fields) |f| if (schema.uniqueScope(col, f) == .tenant) return true;
    return false;
}

/// True when SQLite `col`'s table does not enforce its tenant-scoped unique fields (#498) as
/// declared: a table-wide constraint on one of them (a pre-#498 table), or a missing
/// `UNIQUE (<tenant_field>, <field>)`.
fn uniqueScopeDriftSqlite(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection) EngineError!bool {
    if (col.type == .auth) return false;
    const tf = col.options.tenant_field orelse return false;
    if (!hasTenantScopedUnique(col)) return false;
    const cons = try uniqueConstraints(alloc, w, col.name);
    for (col.fields) |f| {
        if (schema.uniqueScope(col, f) != .tenant) continue;
        if (hasConstraint(cons, &.{f.name}, false) or !hasConstraint(cons, &.{ tf, f.name }, false)) return true;
    }
    return false;
}

/// Converge Postgres table `new.name`'s field-level unique constraints on `new`'s flags (#498),
/// after its columns have been altered to match `new`.
///   - A tenant-scoped field loses any table-wide constraint on its column and gains
///     `UNIQUE (<tenant_field>, <field>)`. Dropping a unique constraint only loosens it, and the
///     composite cannot fail where the table-wide one held, so this is safe on live data.
///   - With `old` (a definition change), a field that stops being tenant-scoped loses the
///     composite it had, and a field that becomes table-wide unique gains its column constraint
///     (which fails, rolling the update back, if existing rows already repeat a value).
///     Without `old` (startup convergence) only the first rule applies: nothing is added that
///     live data could refuse.
fn reconcileUniqueConstraintsPg(alloc: std.mem.Allocator, w: *db.Db, old: ?schema.Collection, new: schema.Collection) EngineError!void {
    const cons = try uniqueConstraints(alloc, w, new.name);
    const run = struct {
        fn exec(a: std.mem.Allocator, conn: *db.Db, sql: []const u8) EngineError!void {
            const sql_z = try a.dupeZ(u8, sql);
            defer a.free(sql_z);
            // step preserves uniqueness violations as Constraint for the API's 409 mapping.
            var st = try conn.prepare(sql_z);
            defer st.finalize();
            _ = try st.step();
        }
    }.exec;
    const dropMatching = struct {
        fn drop(a: std.mem.Allocator, conn: *db.Db, all: []const UniqueConstraint, table: []const u8, cols: []const []const u8) EngineError!void {
            for (all) |con| if (constraintColsEql(con.cols, cols, true)) {
                std.log.info("provision: collection '{s}' DROP unique constraint '{s}'", .{ table, con.name });
                try run(a, conn, try ddl.dropConstraintSql(a, table, con.name));
            };
        }
    }.drop;
    for (new.fields) |nf| {
        const scope = schema.uniqueScope(new, nf);
        const prev: ?schema.Field = if (old) |o| for (o.fields) |of| {
            if (std.mem.eql(u8, of.id, nf.id)) break of;
        } else null else null;
        const prev_scope: ?schema.UniqueScope = if (prev) |of| schema.uniqueScope(old.?, of) else null;

        if (scope == .tenant or (scope != .global and prev_scope == .global))
            try dropMatching(alloc, w, cons, new.name, &.{nf.name});
        if (scope == .global and prev_scope != null and prev_scope.? != .global and !hasConstraint(cons, &.{nf.name}, true))
            try run(alloc, w, try ddl.addUniqueConstraintSql(alloc, new.name, &.{nf.name}));

        // The composite the old definition implied, under its tenant column's CURRENT name.
        if (prev_scope == .tenant) old_tf: {
            const old_tf_name = old.?.options.tenant_field.?;
            const old_tf = schema.fieldByName(old.?, old_tf_name) orelse break :old_tf;
            const tf_now = for (new.fields) |f| {
                if (std.mem.eql(u8, f.id, old_tf.id)) break f.name;
            } else break :old_tf; // the tenant column was dropped, and its constraints with it
            if (scope == .tenant and std.mem.eql(u8, tf_now, new.options.tenant_field.?)) break :old_tf;
            try dropMatching(alloc, w, cons, new.name, &.{ tf_now, nf.name });
        }
        if (scope == .tenant) {
            const cols = [_][]const u8{ new.options.tenant_field.?, nf.name };
            if (!hasConstraint(cons, &cols, true)) {
                std.log.info("provision: collection '{s}' scoping unique field '{s}' to '{s}'", .{ new.name, nf.name, cols[0] });
                try run(alloc, w, try ddl.addUniqueConstraintSql(alloc, new.name, &cols));
            }
        }
    }
}

/// Converge one collection's physical unique constraints on its tenant-scoped unique fields
/// (#498) at startup. A deployment whose tenant-owned table predates #498 enforces those fields
/// table-wide: Postgres swaps the constraints in place, SQLite rebuilds the table (the only way
/// it can drop an inline column constraint). A no-op for a collection that already matches, so
/// it is safe on every boot and under concurrent boots (the rebuild re-checks under the lock).
/// Auth collections are excluded; their physical uniqueness remains as on main.
pub fn ensureUniqueScopes(alloc: std.mem.Allocator, io: std.Io, w: *db.Db, name: []const u8) EngineError!void {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();
    // SQLite must pause FK enforcement outside the transaction, including the nested rebuild.
    const pause_fk = db.dbDialect(w).kind == .sqlite and !w.inTransaction();
    if (pause_fk) try w.exec("PRAGMA foreign_keys=OFF;");
    defer if (pause_fk) {
        w.exec("PRAGMA foreign_keys=ON;") catch |err| {
            std.log.warn("unique scope convergence: FK restoration failed ({s}); connection quarantined", .{@errorName(err)});
            const inner = if (comptime @import("build_options").postgres) &w.sqlite else w;
            inner.quarantined = true;
        };
    };
    const tx = try Tx.begin(w);
    errdefer tx.rollback();
    // All decisions and reconciliation use the definition read AFTER acquiring the lock.
    const live = (try get(sa, w, name)) orelse {
        try tx.commit();
        return;
    };
    // Auth keeps main's physical uniqueness, including legacy non-identity usernames.
    if (live.type == .auth) {
        try tx.commit();
        return;
    }
    if (hasTenantScopedUnique(live)) {
        if (db.dbDialect(w).kind == .postgres) {
            try reconcileUniqueConstraintsPg(sa, w, null, live);
        } else if (try uniqueScopeDriftSqlite(sa, w, live)) {
            std.log.info("provision: collection '{s}' rebuilding its table to scope unique fields to '{s}'", .{ live.name, live.options.tenant_field.? });
            var desired = live;
            var user_fields: std.ArrayList(schema.Field) = .empty;
            for (live.fields) |f| if (!schema.isInjectedField(live.type, f.name)) try user_fields.append(sa, f);
            desired.fields = user_fields.items;
            _ = try updateWithExpectedDefinition(sa, io, w, live.id, desired, live);
        }
    }
    try tx.commit();
}

/// `ensureUniqueScopes` for every collection, including ones created at runtime through the
/// collections API (startup provisioning of `.collections` sees only the comptime ones).
pub fn ensureAllUniqueScopes(alloc: std.mem.Allocator, io: std.Io, w: *db.Db) EngineError!void {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();
    for (try list(sa, w)) |col| {
        if (col.type == .auth) continue;
        try ensureUniqueScopes(alloc, io, w, col.id);
    }
}

/// Refuse physical schema that the metadata-only rebuild cannot reproduce. Scratch is
/// arena-owned by updateImpl. Indexes/triggers with SQL are restored separately.
fn checkSqliteRebuild(alloc: std.mem.Allocator, w: *db.Db, old: schema.Collection) EngineError!void {
    // TEMP objects win unqualified name resolution, including catalog PRAGMAs.
    var shadow = try w.prepare("SELECT name FROM sqlite_temp_schema WHERE type IN ('table','view','index') AND (name=?1 COLLATE NOCASE OR name=?2 COLLATE NOCASE) LIMIT 1;");
    defer shadow.finalize();
    try shadow.bindText(1, old.name);
    try shadow.bindText(2, try std.fmt.allocPrint(alloc, "{s}__new", .{old.name}));
    if (try shadow.step()) return unsafeSqliteRebuild(old.name, shadow.columnText(0), "shadowing TEMP object");
    var cols = try w.prepare("SELECT name, type, \"notnull\", pk, hidden FROM pragma_table_xinfo(?1);");
    defer cols.finalize();
    try cols.bindText(1, old.name);
    while (try cols.step()) {
        const name = cols.columnText(0);
        const system = std.mem.eql(u8, name, "id") or std.mem.eql(u8, name, "created") or std.mem.eql(u8, name, "updated");
        const field = schema.fieldByName(old, name);
        if (!system and field == null) {
            return unsafeSqliteRebuild(old.name, name, "physical column absent from metadata");
        }
        const expected_type = if (field) |f| db.dbDialect(w).sqlType(f.storageClass()) else "TEXT";
        if (!std.ascii.eqlIgnoreCase(cols.columnText(1), expected_type) or cols.columnInt(2) != 0 or cols.columnInt(4) != 0 or cols.columnInt(3) != @as(i64, if (std.mem.eql(u8, name, "id")) 1 else 0)) {
            return unsafeSqliteRebuild(old.name, name, "unowned column type, NOT NULL or primary key");
        }
    }
    // Engine DDL never emits these clauses. A conservative refusal also covers defaults,
    // custom collations, named constraints, generated columns and table storage options.
    var table = try w.prepare("SELECT sql FROM sqlite_master WHERE type='table' AND name=?1;");
    defer table.finalize();
    try table.bindText(1, old.name);
    if (!try table.step()) return error.NotFound;
    if (@import("sql/schema_check.zig").firstKeyword(table.columnText(0), &.{ "CHECK", "DEFAULT", "COLLATE", "CONSTRAINT", "GENERATED", "STRICT", "WITHOUT", "CONFLICT", "DEFERRABLE", "INITIALLY", "AUTOINCREMENT", "MATCH", "ASC", "DESC" })) |clause| {
        return unsafeSqliteRebuild(old.name, clause, "unsupported physical clause");
    }
    for (try uniqueConstraints(alloc, w, old.name)) |con| {
        var owned = false;
        for (old.fields) |f| {
            if (!f.unique) continue;
            if (colsEql(con.cols, &.{f.name})) owned = true;
            if (schema.uniqueScope(old, f) == .tenant and colsEql(con.cols, &.{ old.options.tenant_field.?, f.name })) {
                owned = true;
            }
        }
        if (!owned) {
            return unsafeSqliteRebuild(old.name, con.name, "unowned unique constraint");
        }
    }
    // Compare physical foreign keys to the resolved metadata. Composite or customized
    // referential actions cannot be reproduced by the engine's single-relation DDL.
    const resolved = try resolveRelations(alloc, w, old);
    var fk = try w.prepare("SELECT \"from\", \"table\", \"to\", on_update, on_delete, match, seq FROM pragma_foreign_key_list(?1);");
    defer fk.finalize();
    try fk.bindText(1, old.name);
    while (try fk.step()) {
        const f = schema.fieldByName(resolved, fk.columnText(0));
        const owned = if (f) |field| switch (field.options) {
            .relation => |rel| rel.maxSelect == 1 and fk.columnInt(6) == 0 and std.mem.eql(u8, rel.targetCollectionId, fk.columnText(1)) and std.mem.eql(u8, fk.columnText(2), "id") and std.mem.eql(u8, fk.columnText(3), "NO ACTION") and std.mem.eql(u8, fk.columnText(4), if (rel.cascadeDelete) "CASCADE" else "SET NULL") and std.mem.eql(u8, fk.columnText(5), "NONE"),
            else => false,
        } else false;
        if (!owned) {
            return unsafeSqliteRebuild(old.name, fk.columnText(0), "unowned foreign key");
        }
    }
}

/// Generate the engine's actual catalog SQL in a private empty database. Includes declared
/// indexes, identity indexes, tenant indexes and FTS triggers; autoindexes have no stored SQL.
/// Result graph is scratch-owned by updateImpl's arena.
fn engineTableObjectsSqlite(scratch: *std.heap.ArenaAllocator, col: schema.Collection) EngineError![]TableObject {
    const alloc = scratch.allocator();
    var model = try db.Db.openMemory();
    defer model.close();
    try model.exec("PRAGMA foreign_keys=OFF;");
    const d = db.dbDialect(&model);
    try model.exec(try alloc.dupeZ(u8, try ddl.createTableSql(alloc, col, null, d, &.{})));
    for (col.indexes) |idx| try model.exec(try alloc.dupeZ(u8, try ddl.createIndexSql(alloc, col.name, idx, d)));
    if (col.type == .auth) for (col.options.auth.identityFields) |field| {
        try model.exec(try alloc.dupeZ(u8, try ddl.authIdentityIndexSql(alloc, col.name, field)));
    };
    try ensureTenantIndex(alloc, &model, col);
    try fts.ensureIndex(alloc, &model, col);
    return tableObjectsSqlite(scratch, &model, null);
}

fn sameTableObject(a: TableObject, b: TableObject) bool {
    return a.kind == b.kind and std.ascii.eqlIgnoreCase(a.name, b.name) and
        @import("sql/schema_check.zig").whitespaceEql(a.sql, b.sql);
}

fn unsafeSqliteRebuild(table: []const u8, object: []const u8, reason: []const u8) error{UnsafeSqliteRebuild} {
    last_rebuild_error = std.fmt.bufPrint(&rebuild_error_buf, "Collection '{s}': {s} '{s}'; use an explicit migration before changing the collection.", .{ table[0..@min(table.len, 256)], reason, object[0..@min(object.len, 768)] }) catch unreachable;
    std.log.warn("{s}", .{last_rebuild_error});
    return error.UnsafeSqliteRebuild;
}

fn migrationObjectConflict(object: []const u8, column: []const u8) error{MigrationObjectConflict} {
    // Prefix lengths prove the message fits even for arbitrarily long raw-SQL object names.
    last_rebuild_error = std.fmt.bufPrint(&rebuild_error_buf, "Migration-owned object '{s}' conflicts with column or engine object '{s}'; explicitly migrate this object before changing the collection.", .{ object[0..@min(object.len, 768)], column[0..@min(column.len, 768)] }) catch unreachable;
    std.log.warn("{s}", .{last_rebuild_error});
    return error.MigrationObjectConflict;
}

/// Decide every captured object's ownership by OLD generated SQL, never by name alone.
/// Refuse migration dependencies and NEW engine-name conflicts before destructive DDL.
/// Returned objects and all model catalogs are on updateImpl's scratch arena.
fn preflightTableObjects(scratch: *std.heap.ArenaAllocator, w: *db.Db, old: schema.Collection, new: schema.Collection, actual: []const TableObject) EngineError![]TableObject {
    const alloc = scratch.allocator();
    // TEMP triggers live on this connection and are deleted by DROP TABLE too.
    // They are absent from the main catalog capture, so refuse before any DDL.
    var temp_triggers = try w.prepare("SELECT name FROM sqlite_temp_schema WHERE type='trigger' AND tbl_name=?1 COLLATE NOCASE LIMIT 1;");
    defer temp_triggers.finalize();
    try temp_triggers.bindText(1, old.name);
    if (try temp_triggers.step()) return unsafeSqliteRebuild(old.name, temp_triggers.columnText(0), "attached TEMP trigger");
    const layout_changed = !columnLayoutEql(old, new) or !try sqliteColumnLayoutEql(w, new);
    const old_engine = try engineTableObjectsSqlite(scratch, old);
    const new_engine = try engineTableObjectsSqlite(scratch, new);
    // Search's virtual and shadow tables may be removed only when they match the OLD
    // generated catalog too. This also refuses stale search state absent from metadata.
    const ft = try fts.tableName(alloc, old.name);
    var search_tables = try w.prepare("SELECT name, sql FROM sqlite_master WHERE type='table' AND (name=?1 COLLATE NOCASE OR substr(name,1,length(?1)+1)=?1||'_' COLLATE NOCASE);");
    defer search_tables.finalize();
    try search_tables.bindText(1, ft);
    search: while (try search_tables.step()) {
        for (old_engine) |generated| {
            if (generated.kind == .table and std.ascii.eqlIgnoreCase(generated.name, search_tables.columnText(0)) and @import("sql/schema_check.zig").whitespaceEql(generated.sql, search_tables.columnText(1))) continue :search;
        }
        return migrationObjectConflict(search_tables.columnText(0), ft);
    }
    // SQLite index names are database-global, not scoped to their attached table. Check
    // every desired engine name before IF NOT EXISTS could silently suppress enforcement.
    var occupied = try w.prepare("SELECT name,type,sql FROM sqlite_master WHERE name=?1 COLLATE NOCASE AND ((?2='trigger' AND type='trigger') OR (?2<>'trigger' AND type IN ('table','index','view')));");
    defer occupied.finalize();
    for (new_engine) |generated| {
        // The base table itself is checked by checkSqliteRebuild, which intentionally
        // accepts the supported legacy unique-constraint shape during startup convergence.
        if (generated.kind == .table and std.ascii.eqlIgnoreCase(generated.name, old.name)) continue;
        occupied.reset();
        try occupied.bindText(1, generated.name);
        try occupied.bindText(2, if (generated.kind == .trigger) "trigger" else "relation");
        occupants: while (try occupied.step()) {
            const kind = occupied.columnText(1);
            const obj = TableObject{
                .name = occupied.columnText(0),
                .sql = occupied.columnText(2),
                .kind = if (std.mem.eql(u8, kind, "trigger")) .trigger else if (std.mem.eql(u8, kind, "index")) .index else .table,
            };
            for (old_engine) |owned| if (sameTableObject(obj, owned)) continue :occupants;
            return migrationObjectConflict(obj.name, generated.name);
        }
    }
    // Engine relation FKs target id, which a metadata rebuild preserves. Other incoming
    // keys are migration-owned and may rely on uniqueness that tenant scoping removes.
    var incoming = try w.prepare("SELECT m.name, fk.\"to\" FROM sqlite_master m JOIN pragma_foreign_key_list(m.name) fk WHERE m.type='table' AND m.name<>?1 COLLATE NOCASE AND fk.\"table\"=?1 COLLATE NOCASE AND fk.\"to\" IS NOT NULL AND fk.\"to\"<>'id' COLLATE NOCASE LIMIT 1;");
    defer incoming.finalize();
    try incoming.bindText(1, old.name);
    if (try incoming.step()) return migrationObjectConflict(incoming.columnText(0), incoming.columnText(1));
    // External views/triggers cannot be safely rebuilt by this collection's DDL. Refuse
    // them before any DROP rather than rely on ALTER TABLE validation after the copy.
    var external = try w.prepare("SELECT name, sql FROM sqlite_master WHERE type IN ('view','trigger') AND tbl_name<>?1 COLLATE NOCASE AND sql IS NOT NULL;");
    defer external.finalize();
    try external.bindText(1, old.name);
    while (try external.step()) {
        const sql = external.columnText(1);
        for (old_engine) |generated| {
            if (generated.kind != .table or !@import("sql/schema_check.zig").mentionsIdentifier(sql, generated.name)) continue;
            for (old.fields) |field| {
                if (!fieldRetained(new, field) and @import("sql/schema_check.zig").mentionsIdentifier(sql, field.name))
                    return migrationObjectConflict(external.columnText(0), field.name);
            }
            return migrationObjectConflict(external.columnText(0), generated.name);
        }
    }
    var migrations_owned: std.ArrayList(TableObject) = .empty;
    objects: for (actual) |obj| {
        for (old_engine) |generated| if (sameTableObject(obj, generated)) continue :objects;
        if (layout_changed and obj.kind == .trigger and @import("sql/schema_check.zig").hasLayoutDependency(obj.sql, old.name))
            return migrationObjectConflict(obj.name, "column layout (wildcard or positional dependency)");
        // Constraint autoindexes have no stored SQL (absent from old_engine) and a rebuild does
        // not preserve their numbering, so any INDEXED BY on one of this table's autoindexes
        // would break after the rebuild: refuse it before DDL.
        if (obj.kind == .trigger and @import("sql/schema_check.zig").referencesIndexPrefix(obj.sql, try std.fmt.allocPrint(alloc, "sqlite_autoindex_{s}_", .{old.name})))
            return migrationObjectConflict(obj.name, "a SQLite constraint autoindex (INDEXED BY)");
        indexes: for (old_engine) |removed| {
            if (obj.kind != .trigger or removed.kind != .index) continue;
            // Only an index regenerated with the SAME definition stays valid for INDEXED BY;
            // a changed one (e.g. made partial) can break the trigger like a removed one.
            for (new_engine) |retained| if (sameTableObject(removed, retained)) continue :indexes;
            if (@import("sql/schema_check.zig").referencesIndex(obj.sql, removed.name))
                return migrationObjectConflict(obj.name, removed.name);
        }
        tables: for (old_engine) |removed| {
            if (removed.kind != .table) continue;
            for (new_engine) |retained| if (retained.kind == .table and std.ascii.eqlIgnoreCase(removed.name, retained.name)) {
                // A retained engine table other than the base table whose definition changes
                // (the FTS shadow table gaining or losing a column) breaks a trigger that reads
                // it by wildcard/position, or by naming a column it no longer has. A trigger
                // that only counts its rows keeps working. The base table is covered by
                // `layout_changed` and the field checks.
                if (obj.kind == .trigger and !std.ascii.eqlIgnoreCase(removed.name, old.name) and !sameTableObject(removed, retained)) {
                    const sc = @import("sql/schema_check.zig");
                    if (sc.hasLayoutDependency(obj.sql, removed.name))
                        return migrationObjectConflict(obj.name, removed.name);
                    if (sc.mentionsIdentifier(obj.sql, removed.name)) {
                        for (old.fields) |of| {
                            if (!fts.isIndexedField(of)) continue;
                            const still = for (new.fields) |nf| {
                                if (fts.isIndexedField(nf) and std.mem.eql(u8, nf.name, of.name)) break true;
                            } else false;
                            if (!still and sc.mentionsIdentifier(obj.sql, of.name))
                                return migrationObjectConflict(obj.name, of.name);
                        }
                    }
                }
                continue :tables;
            };
            if (@import("sql/schema_check.zig").mentionsIdentifier(obj.sql, removed.name))
                return migrationObjectConflict(obj.name, removed.name);
        }
        for (old.fields) |field| {
            if (!fieldRetained(new, field) and @import("sql/schema_check.zig").mentionsIdentifier(obj.sql, field.name))
                return migrationObjectConflict(obj.name, field.name);
        }
        // A newly added field can change what a restored trigger's names resolve to: one named
        // like a rowid alias shadows the hidden rowid (`NEW.rowid`/`NEW.oid`), and any other
        // can make an unqualified column in a join ambiguous. Refuse a trigger that mentions
        // a field name this update adds.
        if (obj.kind == .trigger) for (new.fields) |nf| {
            const existed = for (old.fields) |of| {
                if (std.ascii.eqlIgnoreCase(of.name, nf.name)) break true;
            } else false;
            if (!existed and @import("sql/schema_check.zig").mentionsIdentifier(obj.sql, nf.name))
                return migrationObjectConflict(obj.name, nf.name);
        };
        try migrations_owned.append(alloc, obj);
    }
    return migrations_owned.items;
}

/// A migration can reorder columns without changing metadata. The rebuild emits the
/// system columns followed by new.fields, so compare that layout to the live catalog.
fn sqliteColumnLayoutEql(w: *db.Db, new: schema.Collection) EngineError!bool {
    var cols = try w.prepare("SELECT name FROM pragma_table_info(?1) ORDER BY cid;");
    defer cols.finalize();
    try cols.bindText(1, new.name);
    for ([_][]const u8{ "id", "created", "updated" }) |name| {
        if (!try cols.step() or !std.mem.eql(u8, cols.columnText(0), name)) return false;
    }
    for (new.fields) |field| {
        if (!try cols.step() or !std.mem.eql(u8, cols.columnText(0), field.name)) return false;
    }
    return !try cols.step();
}

fn columnLayoutEql(old: schema.Collection, new: schema.Collection) bool {
    if (old.fields.len != new.fields.len) return false;
    for (old.fields, new.fields) |of, nf| {
        if (!std.mem.eql(u8, of.id, nf.id) or !std.mem.eql(u8, of.name, nf.name)) return false;
    }
    return true;
}

fn fieldRetained(new: schema.Collection, field: schema.Field) bool {
    for (new.fields) |nf| if (std.mem.eql(u8, field.id, nf.id) and std.mem.eql(u8, field.name, nf.name)) return true;
    return false;
}

const TableObject = struct { name: []const u8, sql: []const u8, kind: enum { index, trigger, table } };

/// The indexes and triggers SQLite holds on `table` that carry their own SQL (autoindexes,
/// which back table constraints, have none and are rebuilt with the table).
fn tableObjectsSqlite(scratch: *std.heap.ArenaAllocator, w: *db.Db, table: ?[]const u8) EngineError![]TableObject {
    const alloc = scratch.allocator();
    var out: std.ArrayList(TableObject) = .empty;
    var st = try w.prepare("SELECT name, sql, type FROM sqlite_master WHERE (?1 IS NULL OR (tbl_name=?1 COLLATE NOCASE AND type IN ('index','trigger'))) AND type IN ('index','trigger','table') AND sql IS NOT NULL ORDER BY type, name;");
    defer st.finalize();
    if (table) |name| try st.bindText(1, name) else try st.bindNull(1);
    while (try st.step()) try out.append(alloc, .{ .name = try alloc.dupe(u8, st.columnText(0)), .sql = try alloc.dupe(u8, st.columnText(1)), .kind = if (std.mem.eql(u8, st.columnText(2), "index")) .index else if (std.mem.eql(u8, st.columnText(2), "trigger")) .trigger else .table });
    return out.items;
}

/// Auto-create the index backing the `tenant_field` column so the per-request tenant scope
/// predicate (`"<col>"."<tenant_field>" = ?`) is served from an index, not a scan. Idempotent
/// (`IF NOT EXISTS`); identifiers are gated through `schema.isValidIdentifier` before interpolation.
pub fn ensureTenantIndex(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection) EngineError!void {
    const tf = col.options.tenant_field orelse return;
    if (!schema.isValidIdentifier(col.name) or !schema.isValidIdentifier(tf)) return;
    // Bound + freed rather than nested inside the allocPrint: `alloc` here is the caller's
    // allocator, not an arena (the `sql` free below says so), so a nested temporary would leak.
    const qidx = try ddl.quoteComposite(alloc, "idx_{s}_{s}_tenant", .{ col.name, tf });
    defer alloc.free(qidx);
    const qtbl = try ddl.quoteIdent(alloc, col.name);
    defer alloc.free(qtbl);
    const qtf = try ddl.quoteIdent(alloc, tf);
    defer alloc.free(qtf);
    const sql = try std.fmt.allocPrintSentinel(
        alloc,
        "CREATE INDEX IF NOT EXISTS {s} ON {s} ({s});",
        .{ qidx, qtbl, qtf },
        0,
    );
    defer alloc.free(sql);
    try w.exec(sql);
    std.log.info("provision: ensured tenant index on '{s}'.'{s}'", .{ col.name, tf });
}

test "rebuild preserves unrelated TEMP indexes and triggers with migration object names" {
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try migrations.run(&conn);
    const original = try create(a, std.testing.io, &conn, .{
        .id = "",
        .name = "items",
        .fields = &.{.{ .id = "title_id", .name = "title", .options = .{ .text = .{} } }},
    });
    defer original.deinit(a);
    try conn.exec("CREATE INDEX migration_idx ON items(title);");
    try conn.exec("CREATE TRIGGER migration_trigger AFTER INSERT ON items BEGIN SELECT NEW.title; END;");
    try conn.exec("CREATE TEMP TABLE unrelated(value TEXT);");
    try conn.exec("CREATE INDEX temp.migration_idx ON unrelated(value);");
    try conn.exec("CREATE TEMP TRIGGER migration_trigger AFTER INSERT ON unrelated BEGIN SELECT NEW.value; END;");
    var desired = original;
    desired.fields = &.{ original.fields[0], .{ .id = "extra_id", .name = "extra", .options = .{ .text = .{} } } };
    const updated = try update(a, std.testing.io, &conn, original.id, desired);
    defer updated.deinit(a);
    var st = try conn.prepare("SELECT (SELECT count(*) FROM main.sqlite_schema WHERE tbl_name='items' AND name IN ('migration_idx','migration_trigger')), (SELECT count(*) FROM temp.sqlite_schema WHERE tbl_name='unrelated' AND name IN ('migration_idx','migration_trigger'));");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 2), st.columnInt(0));
    try std.testing.expectEqual(@as(i64, 2), st.columnInt(1));
    try std.testing.expect(schema.fieldByName(updated, "extra") != null);
}

test "owned update result allocation failure rolls back rebuild and generation" {
    const a = std.testing.allocator;
    var allocations: usize = 0;
    for ([_]bool{ false, true }) |fail_last| {
        var conn = try db.Db.openMemory();
        defer conn.close();
        try migrations.run(&conn);
        const original = try create(a, std.testing.io, &conn, .{
            .id = "",
            .name = "items",
            .fields = &.{.{ .id = "title_id", .name = "title", .options = .{ .text = .{} } }},
        });
        defer original.deinit(a);
        try conn.exec("INSERT INTO items(id,title) VALUES ('old','preserve me');");
        try conn.exec("CREATE INDEX migration_index ON items(title);");
        const generation = try schema_gen.read(&conn);
        var desired = original;
        desired.fields = &.{ original.fields[0], .{ .id = "extra_id", .name = "extra", .options = .{ .text = .{} } } };
        // Measure the successful path, then fail its last allocation: the owned
        // reload after the DDL and metadata writes, rather than an early preflight.
        var failing = std.testing.FailingAllocator.init(a, .{
            .fail_index = if (fail_last) allocations - 1 else std.math.maxInt(usize),
        });
        const fa = failing.allocator();
        if (fail_last) {
            try std.testing.expectError(error.OutOfMemory, updateWithExpectedDefinition(fa, std.testing.io, &conn, original.id, desired, original));
            try std.testing.expectEqual(generation, try schema_gen.read(&conn));
            const preserved = (try get(a, &conn, original.id)).?;
            defer preserved.deinit(a);
            try std.testing.expect(schema.fieldByName(preserved, "extra") == null);
            var st = try conn.prepare("SELECT (SELECT title FROM items WHERE id='old'), (SELECT count(*) FROM pragma_table_info('items') WHERE name='extra'), (SELECT count(*) FROM sqlite_master WHERE name='migration_index');");
            defer st.finalize();
            try std.testing.expect(try st.step());
            try std.testing.expectEqualStrings("preserve me", st.columnText(0));
            try std.testing.expectEqual(@as(i64, 0), st.columnInt(1));
            try std.testing.expectEqual(@as(i64, 1), st.columnInt(2));
        } else {
            const updated = try updateWithExpectedDefinition(fa, std.testing.io, &conn, original.id, desired, original);
            updated.deinit(fa);
            allocations = failing.alloc_index;
            try std.testing.expect(allocations > 0);
            try std.testing.expectEqual(generation + 1, try schema_gen.read(&conn));
        }
        try std.testing.expect(!conn.inTransaction());
        var fk = try conn.prepare("PRAGMA foreign_keys;");
        defer fk.finalize();
        try std.testing.expect(try fk.step());
        try std.testing.expectEqual(@as(i64, 1), fk.columnInt(0));
    }
}

test "rebuild reads collection and relation metadata only after locking" {
    const c = @import("c.zig").c;
    const Reads = struct {
        handle: ?*c.sqlite3,
        locked: bool = false,
        reads: usize = 0,
        denied: bool = false,

        fn authorize(context: ?*anyopaque, action: c_int, first: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (first == null) return c.SQLITE_OK;
            const table = std.mem.span(first);
            if (action == c.SQLITE_UPDATE and std.mem.eql(u8, table, "_schema_state")) self.locked = true;
            if (action == c.SQLITE_READ and std.mem.eql(u8, table, "_collections")) {
                self.reads += 1;
                // The SQLite authorizer rejects pre-lock reads rather than
                // coordinating threads with timing-sensitive sleeps.
                if (!self.locked or c.sqlite3_get_autocommit(self.handle) != 0) {
                    self.denied = true;
                    return c.SQLITE_DENY;
                }
            }
            return c.SQLITE_OK;
        }
    };
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try migrations.run(&conn);
    const target = try create(a, std.testing.io, &conn, .{ .id = "", .name = "targets", .fields = &.{} });
    defer target.deinit(a);
    const original = try create(a, std.testing.io, &conn, .{
        .id = "",
        .name = "items",
        .fields = &.{.{ .id = "title_id", .name = "title", .options = .{ .text = .{} } }},
    });
    defer original.deinit(a);
    var desired = original;
    desired.fields = &.{ original.fields[0], .{ .id = "target_id", .name = "target", .options = .{ .relation = .{ .targetCollectionId = target.id } } } };
    const inner = if (comptime @import("build_options").postgres) &conn.sqlite else &conn;
    var reads: Reads = .{ .handle = inner.handle };
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_set_authorizer(inner.handle, Reads.authorize, &reads));
    defer _ = c.sqlite3_set_authorizer(inner.handle, null, null);
    const updated = try updateWithExpectedDefinition(a, std.testing.io, &conn, original.id, desired, original);
    defer updated.deinit(a);
    try std.testing.expect(reads.locked);
    try std.testing.expect(reads.reads > 1);
    try std.testing.expect(!reads.denied);
    try std.testing.expect(schema.fieldByName(updated, "target") != null);
}

test "committed rebuild survives FK restoration failure and quarantines its connection" {
    const c = @import("c.zig").c;
    const DenyRestore = struct {
        fn authorize(_: ?*anyopaque, action: c_int, first: [*c]const u8, second: [*c]const u8, _: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
            if (action == c.SQLITE_PRAGMA and first != null and second != null and
                std.mem.eql(u8, std.mem.span(first), "foreign_keys") and
                std.ascii.eqlIgnoreCase(std.mem.span(second), "ON")) return c.SQLITE_DENY;
            return c.SQLITE_OK;
        }
    };
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(dir);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/data.db", .{dir}, 0);
    defer a.free(path);
    var conn = try db.Db.open(path);
    defer conn.close();
    try migrations.run(&conn);
    const original = try create(a, std.testing.io, &conn, .{
        .id = "",
        .name = "items",
        .fields = &.{.{ .id = "title_id", .name = "title", .options = .{ .text = .{} } }},
    });
    defer original.deinit(a);
    const generation = try schema_gen.read(&conn);
    var desired = original;
    desired.fields = &.{ original.fields[0], .{ .id = "extra_id", .name = "extra", .options = .{ .text = .{} } } };
    const inner = if (comptime @import("build_options").postgres) &conn.sqlite else &conn;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_set_authorizer(inner.handle, DenyRestore.authorize, null));
    const result = try updateWithExpectedDefinition(a, std.testing.io, &conn, original.id, desired, original);
    defer result.deinit(a);
    try std.testing.expect(schema.fieldByName(result, "extra") != null);
    try std.testing.expect(!conn.isHealthy());
    try std.testing.expectError(error.WriterUnavailable, conn.exec("SELECT 1;"));
    var observer = try db.Db.open(path);
    defer observer.close();
    try std.testing.expectEqual(generation + 1, try schema_gen.read(&observer));
    const saved = (try get(a, &observer, original.id)).?;
    defer saved.deinit(a);
    try std.testing.expect(schema.fieldByName(saved, "extra") != null);
}

test "invalid update inputs are rejected before foreign key changes or metadata locks" {
    const c = @import("c.zig").c;
    const RejectMutation = struct {
        attempts: usize = 0,
        fn authorize(context: ?*anyopaque, action: c_int, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (action == c.SQLITE_UPDATE or action == c.SQLITE_TRANSACTION or action == c.SQLITE_PRAGMA) {
                self.attempts += 1;
                return c.SQLITE_DENY;
            }
            return c.SQLITE_OK;
        }
    };
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try migrations.run(&conn);
    const original = try create(a, std.testing.io, &conn, .{ .id = "", .name = "items", .fields = &.{} });
    defer original.deinit(a);
    var invalid = original;
    invalid.fields = &.{.{ .id = "bad_id", .name = "bad-name", .options = .{ .text = .{} } }};
    var rejected: RejectMutation = .{};
    const inner = if (comptime @import("build_options").postgres) &conn.sqlite else &conn;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_set_authorizer(inner.handle, RejectMutation.authorize, &rejected));
    defer _ = c.sqlite3_set_authorizer(inner.handle, null, null);
    try std.testing.expectError(error.Validation, update(a, std.testing.io, &conn, original.id, invalid));
    const errors = last_errors.?;
    defer a.free(errors);
    defer last_errors = null;
    try std.testing.expectEqual(@as(usize, 0), rejected.attempts);
    try std.testing.expect(!conn.inTransaction());
}

fn expectStoredNameRejected(a: std.mem.Allocator, reserved_name: []const u8, by_id: bool) !void {
    const c = @import("c.zig").c;
    const DdlAttempts = struct {
        count: usize = 0,
        fn authorize(context: ?*anyopaque, action: c_int, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (action == c.SQLITE_CREATE_TABLE or action == c.SQLITE_DROP_TABLE or
                action == c.SQLITE_ALTER_TABLE or action == c.SQLITE_CREATE_INDEX or
                action == c.SQLITE_DROP_INDEX) self.count += 1;
            return c.SQLITE_OK;
        }
    };
    var conn = try db.Db.openMemory();
    defer conn.close();
    try migrations.run(&conn);
    if (!std.mem.eql(u8, reserved_name, "_superusers")) {
        const created = try create(a, std.testing.io, &conn, .{
            .id = "",
            .name = "legacy",
            .fields = &.{.{ .id = "title_id", .name = "title", .options = .{ .text = .{} } }},
        });
        created.deinit(a);
        // Simulate a legacy table created before the FTS suffix reservation.
        try conn.exec("ALTER TABLE legacy RENAME TO legacy_fts;");
        try conn.exec("UPDATE _collections SET name='legacy_fts' WHERE name='legacy';");
    }
    const original = (try get(a, &conn, reserved_name)).?;
    defer original.deinit(a);
    const quoted = try ddl.quoteIdent(a, original.name);
    defer a.free(quoted);
    const index_sql = try std.fmt.allocPrintSentinel(a, "CREATE INDEX name_guard_marker ON {s}(created);", .{quoted}, 0);
    defer a.free(index_sql);
    try conn.exec(index_sql);
    const generation = try schema_gen.read(&conn);
    var desired = original;
    var fields: std.ArrayList(schema.Field) = .empty;
    defer fields.deinit(a);
    for (original.fields) |field| {
        if (!schema.isSystemFieldName(field.name)) try fields.append(a, field);
    }
    try fields.append(a, .{ .id = "extra_id", .name = "extra", .options = .{ .text = .{} } });
    desired.fields = fields.items;
    var attempts: DdlAttempts = .{};
    const inner = if (comptime @import("build_options").postgres) &conn.sqlite else &conn;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_set_authorizer(inner.handle, DdlAttempts.authorize, &attempts));
    defer _ = c.sqlite3_set_authorizer(inner.handle, null, null);
    const key = if (by_id) original.id else original.name;
    if (update(a, std.testing.io, &conn, key, desired)) |saved| {
        saved.deinit(a);
        return error.TestExpectedStoredNameValidation;
    } else |err| try std.testing.expectEqual(error.Validation, err);
    const errors = last_errors.?;
    defer a.free(errors);
    defer last_errors = null;
    try std.testing.expectEqualStrings("name", errors[0].field);
    try std.testing.expectEqual(@as(usize, 0), attempts.count);
    try std.testing.expectEqual(generation, try schema_gen.read(&conn));
    try std.testing.expect(!conn.inTransaction());
    const preserved = (try get(a, &conn, original.id)).?;
    defer preserved.deinit(a);
    try std.testing.expect(schema.fieldByName(preserved, "extra") == null);
    var state = try conn.prepare("SELECT (SELECT count(*) FROM sqlite_master WHERE name='name_guard_marker'), (SELECT foreign_keys FROM pragma_foreign_keys);");
    defer state.finalize();
    try std.testing.expect(try state.step());
    try std.testing.expectEqual(@as(i64, 1), state.columnInt(0));
    try std.testing.expectEqual(@as(i64, 1), state.columnInt(1));
}

test "updates reject stored superuser name for name and id lookups" {
    for ([_]bool{ false, true }) |by_id| try expectStoredNameRejected(std.testing.allocator, "_superusers", by_id);
}

test "updates reject stored legacy FTS suffix for name and id lookups" {
    for ([_]bool{ false, true }) |by_id| try expectStoredNameRejected(std.testing.allocator, "legacy_fts", by_id);
}

test "metadata-only provisioning rejects a stored reserved name only when it would write" {
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try migrations.run(&conn);
    const created = try create(a, std.testing.io, &conn, .{
        .id = "",
        .name = "legacy",
        .fields = &.{.{ .id = "title_id", .name = "title", .options = .{ .text = .{} } }},
    });
    created.deinit(a);
    // Simulate a legacy table created before the FTS suffix reservation.
    try conn.exec("ALTER TABLE legacy RENAME TO legacy_fts;");
    try conn.exec("UPDATE _collections SET name='legacy_fts' WHERE name='legacy';");
    const original = (try get(a, &conn, "legacy_fts")).?;
    defer original.deinit(a);
    const generation = try schema_gen.read(&conn);

    // An unchanged boot writes nothing, so an existing deployment keeps starting.
    try provisionMetadata(a, &conn, original, original);
    try std.testing.expectEqual(generation, try schema_gen.read(&conn));

    var desired = original;
    desired.listRule = "@public";
    try std.testing.expectError(error.Validation, provisionMetadata(a, &conn, original, desired));
    const errors = last_errors.?;
    defer a.free(errors);
    defer last_errors = null;
    try std.testing.expectEqualStrings("name", errors[0].field);
    try std.testing.expectEqual(generation, try schema_gen.read(&conn));
    try std.testing.expect(!conn.inTransaction());
    const preserved = (try get(a, &conn, original.id)).?;
    defer preserved.deinit(a);
    try std.testing.expectEqual(@as(?[]const u8, null), preserved.listRule);
}

test "updates validate stored name while ignoring incoming rename" {
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try migrations.run(&conn);
    const original = try create(a, std.testing.io, &conn, .{
        .id = "",
        .name = "items",
        .fields = &.{.{ .id = "title_id", .name = "title", .options = .{ .text = .{} } }},
    });
    defer original.deinit(a);
    for ([_][]const u8{ "_ignored", "ignored_fts" }) |incoming_name| {
        var desired = original;
        desired.name = incoming_name;
        const updated = try update(a, std.testing.io, &conn, original.id, desired);
        defer updated.deinit(a);
        try std.testing.expectEqualStrings("items", updated.name);
        try std.testing.expectEqualStrings(original.id, updated.id);
    }
}

// ---- Search index follows runtime schema changes (#507) ----------------------

/// Count the SQLite catalog objects (shadow tables, triggers) whose name starts with `prefix`.
fn ftsObjectCount(d: *db.Db, prefix: []const u8) !i64 {
    var st = try d.prepare("SELECT COUNT(*) FROM sqlite_master WHERE substr(name,1,length(?1))=?1;");
    defer st.finalize();
    try st.bindText(1, prefix);
    _ = try st.step();
    return st.columnInt(0);
}

/// The ids of `name` rows its FTS index matches for `term`, as one `id|id|…|` string (by id).
fn ftsMatches(a: std.mem.Allocator, d: *db.Db, name: []const u8, term: []const u8) ![]u8 {
    const sql = try std.fmt.allocPrintSentinel(a, "SELECT n.id FROM \"{s}\" n JOIN \"{s}_fts\" f ON f.rowid = n.rowid WHERE \"{s}_fts\" MATCH ?1 ORDER BY n.id;", .{ name, name, name }, 0);
    defer a.free(sql);
    var st = try d.prepare(sql);
    defer st.finalize();
    try st.bindText(1, term);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    while (try st.step()) {
        try out.appendSlice(a, st.columnText(0));
        try out.append(a, '|');
    }
    return out.toOwnedSlice(a);
}

fn expectMatches(d: *db.Db, term: []const u8, want: []const u8) !void {
    return expectMatchesIn(d, "notes", term, want);
}

fn expectMatchesIn(d: *db.Db, name: []const u8, term: []const u8, want: []const u8) !void {
    const a = std.testing.allocator;
    const got = try ftsMatches(a, d, name, term);
    defer a.free(got);
    try std.testing.expectEqualStrings(want, got);
}

/// Replace the stored definition of `col` with `fields` through `update`, returning the reload.
fn updateFields(a: std.mem.Allocator, d: *db.Db, col: schema.Collection, fields: []const schema.Field) !schema.Collection {
    var def = col;
    def.fields = fields;
    return update(a, std.testing.io, d, col.id, def);
}

test "create and update provision, backfill, re-sync and drop the FTS index (#507)" {
    if (comptime !fts.enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);

    // Created searchable: the index exists at once and its triggers index new rows.
    {
        const fields = [_]schema.Field{.{ .id = "t1", .name = "title", .searchable = true, .options = .{ .text = .{} } }};
        // (A deleted collection's storage namespace stays reserved, hence another name.)
        const memos = try create(a, std.testing.io, &d, .{ .id = "", .name = "memos", .fields = &fields });
        defer memos.deinit(a);
        try d.exec("INSERT INTO memos(id,title) VALUES ('r1','alpha one');");
        try expectMatchesIn(&d, "memos", "alpha", "r1|");
        try delete(a, &d, memos.id);
        try std.testing.expectEqual(@as(i64, 0), try ftsObjectCount(&d, "memos_fts"));
    }

    // Created NOT searchable, with rows: no index until a field becomes searchable.
    var fields = [_]schema.Field{
        .{ .id = "t1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "b1", .name = "body", .options = .{ .text = .{} } },
    };
    var col = try create(a, std.testing.io, &d, .{ .id = "", .name = "notes", .fields = &fields });
    defer col.deinit(a);
    try std.testing.expectEqual(@as(i64, 0), try ftsObjectCount(&d, "notes_fts"));
    try d.exec("INSERT INTO notes(id,title,body) VALUES ('r1','alpha one','bravo one');");

    // A field becomes searchable: the index is created and BACKFILLED with the existing row.
    fields[0].searchable = true;
    var next = try updateFields(a, &d, col, &fields);
    col.deinit(a);
    col = next;
    try expectMatches(&d, "alpha", "r1|");
    try d.exec("INSERT INTO notes(id,title,body) VALUES ('r2','alpha two','x');");
    try expectMatches(&d, "alpha", "r1|r2|");

    // A second searchable field joins the index.
    fields[1].searchable = true;
    next = try updateFields(a, &d, col, &fields);
    col.deinit(a);
    col = next;
    try expectMatches(&d, "bravo", "r1|");

    // A searchable field is renamed (same id): the index follows the new column name.
    fields[0].name = "headline";
    next = try updateFields(a, &d, col, &fields);
    col.deinit(a);
    col = next;
    try expectMatches(&d, "alpha", "r1|r2|");
    try d.exec("UPDATE notes SET headline='charlie' WHERE id='r2';");
    try expectMatches(&d, "alpha", "r1|");
    try expectMatches(&d, "charlie", "r2|");

    // A searchable field is removed: the index rebuilds over the remaining one.
    next = try updateFields(a, &d, col, fields[0..1]);
    col.deinit(a);
    col = next;
    try expectMatches(&d, "bravo", "");
    try expectMatches(&d, "charlie", "r2|");

    // Search turned off: the shadow table and its triggers are dropped.
    fields[0].searchable = false;
    next = try updateFields(a, &d, col, fields[0..1]);
    col.deinit(a);
    col = next;
    try std.testing.expectEqual(@as(i64, 0), try ftsObjectCount(&d, "notes_fts"));

    // Back on, then the collection is deleted: nothing named notes_fts* survives.
    fields[0].searchable = true;
    next = try updateFields(a, &d, col, fields[0..1]);
    col.deinit(a);
    col = next;
    try expectMatches(&d, "charlie", "r2|");
    try delete(a, &d, col.id);
    try std.testing.expectEqual(@as(i64, 0), try ftsObjectCount(&d, "notes_fts"));
}

test "a search-index failure rolls back the whole collection create or update (#507)" {
    if (comptime !fts.enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);

    // An application table already holds the shadow name: create fails and leaves nothing.
    try d.exec("CREATE TABLE notes_fts(x TEXT);");
    const fields = [_]schema.Field{.{ .id = "t1", .name = "title", .searchable = true, .options = .{ .text = .{} } }};
    try std.testing.expectError(error.Conflict, create(a, std.testing.io, &d, .{ .id = "", .name = "notes", .fields = &fields }));
    try std.testing.expect((try get(a, &d, "notes")) == null);
    {
        var st = try d.prepare("SELECT COUNT(*) FROM sqlite_master WHERE name='notes';");
        defer st.finalize();
        _ = try st.step();
        try std.testing.expectEqual(@as(i64, 0), st.columnInt(0));
    }
    try d.exec("DROP TABLE notes_fts;");

    // A view depends on the index: turning search off fails and changes nothing.
    const col = try create(a, std.testing.io, &d, .{ .id = "", .name = "notes", .fields = &fields });
    defer col.deinit(a);
    try d.exec("INSERT INTO notes(id,title) VALUES ('r1','alpha');");
    try d.exec("CREATE VIEW notes_view AS SELECT * FROM notes_fts;");
    var off = fields;
    off[0].searchable = false;
    try std.testing.expectError(error.MigrationObjectConflict, updateFields(a, &d, col, &off));
    const still = (try get(a, &d, col.id)).?;
    defer still.deinit(a);
    try std.testing.expect(still.fields[0].searchable);
    try expectMatches(&d, "alpha", "r1|");
}

test "without FTS5 a searchable create or update fails cleanly and changes nothing (#507)" {
    if (comptime fts.enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var fields = [_]schema.Field{.{ .id = "t1", .name = "title", .searchable = true, .options = .{ .text = .{} } }};
    try std.testing.expectError(error.SearchDisabled, create(a, std.testing.io, &d, .{ .id = "", .name = "notes", .fields = &fields }));
    try std.testing.expect((try get(a, &d, "notes")) == null);

    fields[0].searchable = false;
    const col = try create(a, std.testing.io, &d, .{ .id = "", .name = "notes", .fields = &fields });
    defer col.deinit(a);
    fields[0].searchable = true;
    try std.testing.expectError(error.SearchDisabled, updateFields(a, &d, col, &fields));
    const still = (try get(a, &d, col.id)).?;
    defer still.deinit(a);
    try std.testing.expect(!still.fields[0].searchable);
}

test "sameSearchColumns compares the indexed columns in order" {
    const t = schema.Field{ .id = "t", .name = "title", .searchable = true, .options = .{ .text = .{} } };
    const b = schema.Field{ .id = "b", .name = "body", .searchable = true, .options = .{ .text = .{} } };
    const n = schema.Field{ .id = "n", .name = "note", .options = .{ .text = .{} } };
    const base = schema.Collection{ .id = "c", .name = "notes", .fields = &.{ t, n, b } };
    var other = base;
    other.fields = &.{ t, b }; // a non-indexed field removed: same index
    try std.testing.expect(fts.sameSearchColumns(base, other));
    other.fields = &.{ b, t }; // reordered
    try std.testing.expect(!fts.sameSearchColumns(base, other));
    other.fields = &.{t}; // one dropped
    try std.testing.expect(!fts.sameSearchColumns(base, other));
    other = base;
    other.name = "posts"; // another table
    try std.testing.expect(!fts.sameSearchColumns(base, other));
}

test "startup convergence refuses layout triggers on migration-reordered columns" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "INSERT INTO audit SELECT * FROM items WHERE id=NEW.id",
        "INSERT INTO items VALUES('copy','','','acct-b','copy')",
    }) |body| {
        var conn = try db.Db.openMemory();
        defer conn.close();
        try migrations.run(&conn);
        const original = try create(a, std.testing.io, &conn, .{
            .id = "",
            .name = "items",
            .fields = &.{
                .{ .id = "slugid", .name = "slug", .unique = true, .options = .{ .text = .{} } },
                .{ .id = "tenantid", .name = "account", .options = .{ .text = .{} } },
            },
            .options = .{ .tenant_field = "account" },
        });
        defer original.deinit(a);
        // A migration kept the metadata but reordered the physical columns and left
        // legacy global uniqueness. Startup must rebuild to converge that constraint.
        try conn.exec("DROP TABLE items;");
        try conn.exec("CREATE TABLE items(id TEXT PRIMARY KEY,created TEXT,updated TEXT,account TEXT,slug TEXT UNIQUE);");
        try conn.exec("INSERT INTO items VALUES('kept','','','acct-a','one');");
        try conn.exec("CREATE TABLE audit AS SELECT * FROM items;");
        const trigger = try std.fmt.allocPrintSentinel(a, "CREATE TRIGGER migration_layout AFTER INSERT ON items BEGIN {s}; END;", .{body}, 0);
        defer a.free(trigger);
        try conn.exec(trigger);
        const generation = try schema_gen.read(&conn);
        try std.testing.expectError(error.MigrationObjectConflict, ensureUniqueScopes(a, std.testing.io, &conn, original.id));
        try std.testing.expectEqual(generation, try schema_gen.read(&conn));
        var order = try conn.prepare("SELECT name FROM pragma_table_info('items') ORDER BY cid;");
        defer order.finalize();
        for ([_][]const u8{ "id", "created", "updated", "account", "slug" }) |name| {
            try std.testing.expect(try order.step());
            try std.testing.expectEqualStrings(name, order.columnText(0));
        }
        try std.testing.expect(!try order.step());
        try conn.exec("INSERT INTO items(id,account,slug) VALUES('next','acct-b','two');");
        var kept = try conn.prepare("SELECT account,slug FROM items WHERE id='kept';");
        defer kept.finalize();
        try std.testing.expect(try kept.step());
        try std.testing.expectEqualStrings("acct-a", kept.columnText(0));
        try std.testing.expectEqualStrings("one", kept.columnText(1));
    }
}

test "startup convergence reads SQLite metadata only after locking" {
    const c = @import("c.zig").c;
    const Reads = struct {
        handle: ?*c.sqlite3,
        locked: bool = false,
        reads: usize = 0,
        denied: bool = false,

        fn authorize(context: ?*anyopaque, action: c_int, first: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (first == null) return c.SQLITE_OK;
            const table = std.mem.span(first);
            if (action == c.SQLITE_UPDATE and std.mem.eql(u8, table, "_schema_state")) self.locked = true;
            if (action == c.SQLITE_READ and std.mem.eql(u8, table, "_collections")) {
                self.reads += 1;
                // The SQLite authorizer rejects pre-lock reads rather than
                // coordinating threads with timing-sensitive sleeps.
                if (!self.locked or c.sqlite3_get_autocommit(self.handle) != 0) {
                    self.denied = true;
                    return c.SQLITE_DENY;
                }
            }
            return c.SQLITE_OK;
        }
    };
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try migrations.run(&conn);
    const original = try create(a, std.testing.io, &conn, .{
        .id = "",
        .name = "items",
        .fields = &.{.{ .id = "title_id", .name = "title", .options = .{ .text = .{} } }},
    });
    defer original.deinit(a);
    const inner = if (comptime @import("build_options").postgres) &conn.sqlite else &conn;
    var reads: Reads = .{ .handle = inner.handle };
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_set_authorizer(inner.handle, Reads.authorize, &reads));
    defer _ = c.sqlite3_set_authorizer(inner.handle, null, null);
    try ensureUniqueScopes(a, std.testing.io, &conn, original.id);
    try std.testing.expect(reads.locked);
    try std.testing.expect(reads.reads > 0);
    try std.testing.expect(!reads.denied);
}
