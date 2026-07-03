const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const migrations = @import("migrations.zig");
const ddl = @import("ddl.zig");
const id = @import("id.zig");

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
    // assign field ids where empty
    const fields = try alloc.alloc(schema.Field, def.fields.len);
    for (def.fields, 0..) |f, i| {
        fields[i] = f;
        if (f.id.len == 0) {
            var fid = id.fieldId(io);
            fields[i].id = try alloc.dupe(u8, &fid);
        }
    }
    var col = def;
    col.fields = fields;
    var cid = id.collectionId(io);
    col.id = try alloc.dupe(u8, &cid);

    // validate
    var errs: std.ArrayList(schema.ValidationError) = .empty;
    try schema.validate(alloc, col, &errs);
    if (errs.items.len > 0) {
        last_errors = errs.items;
        return error.Validation;
    }

    // reject duplicate collection name up front (→ 409 instead of a raw DbError → 500)
    if ((try get(alloc, w, def.name)) != null) return error.Conflict;

    // For auth collections, prepend the system columns so the physical table and the
    // loaded collection carry them; only the user fields (`col`) are persisted in _collections.
    const full = try schema.injectAuthFields(alloc, col);
    // build a DDL view where each single-relation's target collection id is resolved to its table name
    const ddl_col = try resolveRelations(alloc, w, full);

    const d = db.dbDialect(w);
    try w.begin();
    errdefer w.rollback() catch {};
    try w.exec(try alloc.dupeZ(u8, try ddl.createTableSql(alloc, ddl_col, null, d, &.{})));
    for (col.indexes) |idx| try w.exec(try alloc.dupeZ(u8, try ddl.createIndexSql(alloc, col.name, idx, d)));
    if (col.type == .auth) {
        for (col.options.auth.identityFields) |idf| {
            try w.exec(try alloc.dupeZ(u8, try ddl.authIdentityIndexSql(alloc, col.name, idf)));
        }
    }
    try insertRow(alloc, w, col);
    try w.commit();
    return full;
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

pub fn get(alloc: std.mem.Allocator, w: *db.Db, id_or_name: []const u8) EngineError!?schema.Collection {
    const sql = try db.dbDialect(w).renumberPlaceholders(alloc, select_cols ++ " WHERE id = ?1 OR name = ?1 LIMIT 1;");
    var st = try w.prepare(sql);
    defer st.finalize();
    try st.bindText(1, id_or_name);
    if (!try st.step()) return null;
    return try schema.injectAuthFields(alloc, try rowToCollection(alloc, &st));
}

pub fn list(alloc: std.mem.Allocator, w: *db.Db) EngineError![]schema.Collection {
    var out: std.ArrayList(schema.Collection) = .empty;
    var st = try w.prepare(select_cols ++ " ORDER BY created;");
    defer st.finalize();
    while (try st.step()) {
        try out.append(alloc, try schema.injectAuthFields(alloc, try rowToCollection(alloc, &st)));
    }
    return out.toOwnedSlice(alloc);
}

pub fn update(alloc: std.mem.Allocator, io: std.Io, w: *db.Db, id_or_name: []const u8, newdef: schema.Collection) EngineError!schema.Collection {
    last_errors = null;
    const old = (try get(alloc, w, id_or_name)) orelse return error.NotFound;

    // assign ids to new fields lacking one; preserve existing ids
    const fields = try alloc.alloc(schema.Field, newdef.fields.len);
    for (newdef.fields, 0..) |f, i| {
        fields[i] = f;
        if (f.id.len == 0) {
            var fid = id.fieldId(io);
            fields[i].id = try alloc.dupe(u8, &fid);
        }
    }
    var newc = newdef;
    newc.fields = fields;
    newc.id = old.id;
    newc.name = old.name; // rename not supported in SP2

    // validate
    var errs: std.ArrayList(schema.ValidationError) = .empty;
    try schema.validate(alloc, newc, &errs);
    if (errs.items.len > 0) {
        last_errors = errs.items;
        return error.Validation;
    }

    // Inject auth system fields (after validation, which only sees user fields) so the rebuild
    // preserves the auth columns: `old` is auth-injected (from get), so both sides carry the
    // auth field ids and rebuildPlan keeps them. Without this an auth-collection update would
    // drop email/passwordHash/tokenKey/etc and destroy all credentials.
    const newc_full = try schema.injectAuthFields(alloc, newc);

    // relation-resolved view for the rebuild's FK generation
    const ddl_new = try resolveRelations(alloc, w, newc_full);

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
    const plan = try ddl.rebuildPlan(alloc, old, ddl_new, d);
    for (plan) |stmt| try w.exec(try alloc.dupeZ(u8, stmt));
    if (newc.type == .auth) {
        for (newc.options.auth.identityFields) |idf| {
            try w.exec(try alloc.dupeZ(u8, try ddl.authIdentityIndexSql(alloc, newc.name, idf)));
        }
    }
    try updateRow(alloc, w, old.id, newc); // persist user fields only
    try w.commit();
    if (sqlite_rebuild) {
        try w.exec("PRAGMA foreign_keys=ON;");
    }

    return newc_full;
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

pub fn delete(alloc: std.mem.Allocator, w: *db.Db, id_or_name: []const u8) EngineError!void {
    const target = (try get(alloc, w, id_or_name)) orelse return error.NotFound;
    // refuse if another collection has a relation targeting this one
    const all = try list(alloc, w);
    for (all) |c| {
        if (std.mem.eql(u8, c.id, target.id)) continue;
        for (c.fields) |f| switch (f.options) {
            .relation => |r| if (std.mem.eql(u8, r.targetCollectionId, target.id)) return error.Conflict,
            else => {},
        };
    }
    try w.begin();
    errdefer w.rollback() catch {};
    try w.exec(try std.fmt.allocPrintSentinel(alloc, "DROP TABLE \"{s}\";", .{target.name}, 0));
    var st = try w.prepare(try db.dbDialect(w).renumberPlaceholders(alloc, "DELETE FROM \"_collections\" WHERE \"id\" = ?1;"));
    defer st.finalize();
    try st.bindText(1, target.id);
    _ = try st.step();
    try w.commit();
}

test "create persists a collection and builds its physical table" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .required = true, .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } },
    };
    const def = schema.Collection{ .id = "", .name = "posts", .fields = &fields };
    const created = try create(arena.allocator(), std.testing.io, &d, def);
    try std.testing.expect(created.id.len == 15);
    var st = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('posts') WHERE name IN ('id','created','updated','title','price');");
    defer st.finalize();
    try std.testing.expect((try st.step()));
    try std.testing.expectEqual(@as(i64, 5), st.columnInt(0));
    const got = (try get(arena.allocator(), &d, "posts")).?;
    try std.testing.expectEqualStrings("posts", got.name);
    try std.testing.expectEqual(@as(usize, 2), got.fields.len);
    const all = try list(arena.allocator(), &d);
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const def = schema.Collection{ .id = "", .name = "1bad", .fields = &.{} };
    try std.testing.expectError(error.Validation, create(arena.allocator(), std.testing.io, &d, def));
}

test "update rebuilds table and preserves data across a field rename" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const f0 = [_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }};
    const created = try create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &f0 });
    try d.exec("INSERT INTO posts (id, created, updated, title) VALUES ('r1','t','t','hello');");

    const f1 = [_]schema.Field{
        .{ .id = "f1", .name = "headline", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "views", .options = .{ .number = .{ .mode = .int } } },
    };
    var newdef = created;
    newdef.fields = &f1;
    _ = try update(a, std.testing.io, &d, created.id, newdef);

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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const evil = [_]schema.Index{.{ .name = "x\" ON \"posts\" (\"id\"); DROP TABLE \"_collections\"; --", .fields = &.{"id"}, .unique = false }};
    const def = schema.Collection{ .id = "", .name = "posts", .fields = &.{}, .indexes = &evil };
    try std.testing.expectError(error.Validation, create(a, std.testing.io, &d, def));
    // _collections still exists
    var st = try d.prepare("SELECT COUNT(*) FROM \"_collections\";");
    defer st.finalize();
    try std.testing.expect((try st.step()));
}

test "create rejects a duplicate collection name with Conflict" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &.{} });
    try std.testing.expectError(error.Conflict, create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &.{} }));
}

test "unique field enforces uniqueness at the db level" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fields = [_]schema.Field{.{ .id = "f1", .name = "slug", .unique = true, .options = .{ .text = .{} } }};
    _ = try create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &fields });
    try d.exec("INSERT INTO posts (id, created, updated, slug) VALUES ('r1','t','t','x');");
    try std.testing.expectError(db.DbError.ExecFailed, d.exec("INSERT INTO posts (id, created, updated, slug) VALUES ('r2','t','t','x');"));
}

test "auth collection gets system columns; passwordHash hidden in metadata" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const fields = [_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }};
    _ = try create(a, std.testing.io, &d, .{ .id = "", .name = "users", .type = .auth, .fields = &fields });

    var st = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('users') WHERE name IN ('email','username','passwordHash','tokenKey','verified');");
    defer st.finalize();
    _ = try st.step();
    try std.testing.expectEqual(@as(i64, 5), st.columnInt(0));

    const got = (try get(a, &d, "users")).?;
    try std.testing.expect(schema.fieldByName(got, "email") != null);
    try std.testing.expect(schema.fieldByName(got, "bio") != null);
    const json = try schema.collectionToJson(a, got);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"email\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "passwordHash") == null);
}

test "updating an auth collection preserves its auth columns (credentials not dropped)" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const f0 = [_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }};
    const created = try create(a, std.testing.io, &d, .{ .id = "", .name = "users", .type = .auth, .fields = &f0 });
    // seed a credential row directly
    try d.exec("INSERT INTO users (id,created,updated,email,passwordHash,tokenKey,verified) VALUES ('u1','t','t','a@b.c','$argon2id$hash','tk',1);");

    // update the user-field schema (add a field) — must NOT drop the auth columns
    const f1 = [_]schema.Field{
        .{ .id = "f1", .name = "bio", .options = .{ .text = .{} } },
        .{ .id = "", .name = "nickname", .options = .{ .text = .{} } },
    };
    var newdef = created;
    newdef.fields = &f1;
    _ = try update(a, std.testing.io, &d, created.id, newdef);

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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const users = try create(a, std.testing.io, &d, .{ .id = "", .name = "users", .fields = &.{} });
    const pf = [_]schema.Field{.{ .id = "f1", .name = "author", .options = .{ .relation = .{ .targetCollectionId = users.id, .maxSelect = 1 } } }};
    _ = try create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &pf });

    try std.testing.expectError(error.Conflict, delete(a, &d, "users"));
    try delete(a, &d, "posts");
    try delete(a, &d, "users");
    try std.testing.expect((try get(a, &d, "posts")) == null);
}

test "auth collection enforces identity uniqueness via partial unique index, allows multiple empty" {
    var d = try db.Db.openMemory();
    defer d.close();
    try @import("migrations.zig").run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try create(a, std.testing.io, &d, .{
        .id = "",
        .name = "members",
        .type = .auth,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
    });
    // two distinct emails ok
    try d.exec("INSERT INTO \"members\" (\"id\",\"created\",\"updated\",\"email\") VALUES ('a','','','x@y.z');");
    try d.exec("INSERT INTO \"members\" (\"id\",\"created\",\"updated\",\"email\") VALUES ('b','','','q@y.z');");
    // duplicate non-empty email rejected (exec maps the SQLite constraint error to ExecFailed)
    try std.testing.expectError(error.ExecFailed, d.exec("INSERT INTO \"members\" (\"id\",\"created\",\"updated\",\"email\") VALUES ('c','','','x@y.z');"));
    // two empty emails allowed (partial index excludes them)
    try d.exec("INSERT INTO \"members\" (\"id\",\"created\",\"updated\",\"email\") VALUES ('d','','','');");
    try d.exec("INSERT INTO \"members\" (\"id\",\"created\",\"updated\",\"email\") VALUES ('e','','','');");
}
