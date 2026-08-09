const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const migrations = @import("migrations.zig");
const ddl = @import("ddl.zig");
const id = @import("id.zig");
const schema_gen = @import("schema_gen.zig");

/// The JSON parse helpers in schema.zig return the inferred error set of
/// std.json.parseFromSlice, which is wider than schema.ParseError. Capture it so
/// EngineError covers everything rowToCollection can produce.
const SchemaJsonError = @typeInfo(@typeInfo(@TypeOf(schema.fieldsFromJson)).@"fn".return_type.?).error_union.error_set ||
    @typeInfo(@typeInfo(@TypeOf(schema.indexesFromJson)).@"fn".return_type.?).error_union.error_set;

pub const EngineError = error{ Validation, NotFound, Conflict } || db.DbError || std.mem.Allocator.Error || schema.ParseError || SchemaJsonError;

/// Validation details for the most recent failed create/update (2b surfaces these).
pub threadlocal var last_errors: ?[]const schema.ValidationError = null;

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
    try w.begin();
    errdefer w.rollback() catch {};
    try w.exec(try sa.dupeZ(u8, try ddl.createTableSql(sa, ddl_col, null, d, &.{})));
    for (col.indexes) |idx| try w.exec(try sa.dupeZ(u8, try ddl.createIndexSql(sa, col.name, idx, d)));
    if (col.type == .auth) {
        for (col.options.auth.identityFields) |idf| {
            try w.exec(try sa.dupeZ(u8, try ddl.authIdentityIndexSql(sa, col.name, idf)));
        }
    }
    try insertRow(sa, w, col);
    try schema_gen.bump(w); // inside the tx: a rolled-back create must not advertise a change
    try w.commit();

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
    \\SELECT "id","name","type","system","schema","indexes","listRule","viewRule","createRule","updateRule","deleteRule","created","updated","options" FROM "_collections"
;

fn dupOptText(alloc: std.mem.Allocator, st: *db.Stmt, idx: c_int) !?[]const u8 {
    if (st.isNull(idx)) return null;
    return try alloc.dupe(u8, st.columnText(idx));
}

/// Convert the current row of `st` (columns in `select_cols` order) into a Collection.
/// Must be called before the next step()/finalize() (columnText pointers are transient).
fn rowToCollection(alloc: std.mem.Allocator, st: *db.Stmt) EngineError!schema.Collection {
    const col_id = try alloc.dupe(u8, st.columnText(0));
    const name = try alloc.dupe(u8, st.columnText(1));
    const ctype = std.meta.stringToEnum(schema.CollectionType, st.columnText(2)) orelse .base;
    const system = st.columnInt(3) != 0;
    const fields = try schema.fieldsFromJson(alloc, st.columnText(4));
    const indexes = try schema.indexesFromJson(alloc, st.columnText(5));
    return .{
        .id = col_id,
        .name = name,
        .type = ctype,
        .system = system,
        .fields = fields,
        .indexes = indexes,
        .listRule = try dupOptText(alloc, st, 6),
        .viewRule = try dupOptText(alloc, st, 7),
        .createRule = try dupOptText(alloc, st, 8),
        .updateRule = try dupOptText(alloc, st, 9),
        .deleteRule = try dupOptText(alloc, st, 10),
        .created = try alloc.dupe(u8, st.columnText(11)),
        .updated = try alloc.dupe(u8, st.columnText(12)),
        .options = try schema.optionsFromJson(alloc, st.columnText(13)),
    };
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
    last_errors = null;

    // Like create(): everything except the validation errors (via `last_errors`) and the final
    // fully-owned reload is scratch on `sa` and reclaimed on return — the existing-collection load,
    // the field array, generated field ids, the duped id/name, the auth injection, and every DDL/
    // rebuild statement. None of them needs an errdefer.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const old = (try get(sa, w, id_or_name)) orelse return error.NotFound;

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
    // Rename is not supported in SP2, so the id/name are preserved from `old`.
    newc.id = try sa.dupe(u8, old.id);
    newc.name = try sa.dupe(u8, old.name);

    // validate (see create(): last_errors is handed back as an OWNED, freeable slice on `alloc`)
    var errs: std.ArrayList(schema.ValidationError) = .empty;
    errdefer errs.deinit(alloc);
    try schema.validate(alloc, newc, &errs);
    if (errs.items.len > 0) {
        last_errors = try errs.toOwnedSlice(alloc);
        return error.Validation;
    }

    // Inject auth system fields (after validation, which only sees user fields) so the rebuild
    // preserves the auth columns: `old` is auth-injected (from get), so both sides carry the
    // auth field ids and rebuildPlan keeps them. Without this an auth-collection update would
    // drop email/passwordHash/tokenKey/etc and destroy all credentials. On `sa`.
    const newc_full = try schema.injectAuthFields(sa, newc);
    // relation-resolved view for the rebuild's FK generation
    const ddl_new = try resolveRelations(sa, w, newc_full);

    const d = db.dbDialect(w);
    // SQLite rebuilds via __new+copy+drop+rename, so FK enforcement must be paused around it;
    // Postgres uses in-place ALTERs (rebuildPlanPg) and has no such PRAGMA (it would error).
    const sqlite_rebuild = d.kind == .sqlite;
    if (sqlite_rebuild) {
        try w.exec("PRAGMA foreign_keys=OFF;");
    }
    errdefer if (sqlite_rebuild) {
        w.exec("PRAGMA foreign_keys=ON;") catch {};
    };
    try w.begin();
    errdefer w.rollback() catch {};
    const plan = try ddl.rebuildPlan(sa, old, ddl_new, d);
    for (plan) |stmt| try w.exec(try sa.dupeZ(u8, stmt));
    if (newc.type == .auth) {
        for (newc.options.auth.identityFields) |idf| {
            try w.exec(try sa.dupeZ(u8, try ddl.authIdentityIndexSql(sa, newc.name, idf)));
        }
    }
    try updateRow(sa, w, newc.id, newc); // persist user fields only
    try schema_gen.bump(w); // inside the tx: a rolled-back rebuild must not advertise a change
    try w.commit();
    if (sqlite_rebuild) {
        try w.exec("PRAGMA foreign_keys=ON;");
    }

    // Return a fully-owned reload on `alloc` (keyed on old.id — rename is unsupported), matching
    // the former hand-assembled `newc_full` but with every string/slice owned.
    return (try get(alloc, w, old.id)).?;
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
    try w.begin();
    errdefer w.rollback() catch {};
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
    try w.commit();
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
    try w.begin();
    errdefer w.rollback() catch {};
    try w.exec(try std.fmt.allocPrintSentinel(sa, "DROP TABLE {s};", .{try ddl.quoteIdent(sa, target.name)}, 0));
    var st = try w.prepare(try db.dbDialect(w).renumberPlaceholders(sa, "DELETE FROM \"_collections\" WHERE \"id\" = ?1;"));
    defer st.finalize();
    try st.bindText(1, target.id);
    _ = try st.step();
    try schema_gen.bump(w); // inside the tx: a rolled-back delete must not advertise a change
    try w.commit();
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
