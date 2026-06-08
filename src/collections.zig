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

    // build a DDL view where each single-relation's target collection id is resolved to its table name
    const ddl_col = try resolveRelations(alloc, w, col);

    try w.begin();
    errdefer w.rollback() catch {};
    try w.exec(try alloc.dupeZ(u8, try ddl.createTableSql(alloc, ddl_col, null)));
    for (col.indexes) |idx| try w.exec(try alloc.dupeZ(u8, try ddl.createIndexSql(alloc, col.name, idx)));
    try insertRow(alloc, w, col);
    try w.commit();
    return col;
}

/// Returns a copy of `col` where each relation field's targetCollectionId is replaced by the
/// referenced collection's table NAME (so the FK clause references a real table). Returns
/// error.Validation if a referenced collection does not exist.
fn resolveRelations(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection) EngineError!schema.Collection {
    const fields = try alloc.alloc(schema.Field, col.fields.len);
    for (col.fields, 0..) |f, i| {
        fields[i] = f;
        switch (f.options) {
            .relation => |r| {
                const target = (try get(alloc, w, r.targetCollectionId)) orelse return error.Validation;
                var nr = r;
                nr.targetCollectionId = target.name;
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
    var st = try w.prepare(
        \\INSERT INTO "_collections"
        \\ (id,name,type,system,schema,indexes,listRule,viewRule,createRule,updateRule,deleteRule,created,updated)
        \\ VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11, datetime('now'), datetime('now'));
    );
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
    _ = try st.step();
}

const select_cols =
    \\SELECT id,name,type,system,schema,indexes,listRule,viewRule,createRule,updateRule,deleteRule,created,updated FROM "_collections"
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
    };
}

pub fn get(alloc: std.mem.Allocator, w: *db.Db, id_or_name: []const u8) EngineError!?schema.Collection {
    var st = try w.prepare(select_cols ++ " WHERE id = ?1 OR name = ?1 LIMIT 1;");
    defer st.finalize();
    try st.bindText(1, id_or_name);
    if (!try st.step()) return null;
    return try rowToCollection(alloc, &st);
}

pub fn list(alloc: std.mem.Allocator, w: *db.Db) EngineError![]schema.Collection {
    var out: std.ArrayList(schema.Collection) = .empty;
    var st = try w.prepare(select_cols ++ " ORDER BY created;");
    defer st.finalize();
    while (try st.step()) {
        try out.append(alloc, try rowToCollection(alloc, &st));
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

    // relation-resolved view for the rebuild's FK generation
    const ddl_new = try resolveRelations(alloc, w, newc);

    try w.exec("PRAGMA foreign_keys=OFF;");
    errdefer w.exec("PRAGMA foreign_keys=ON;") catch {};
    try w.begin();
    errdefer w.rollback() catch {};
    const plan = try ddl.rebuildPlan(alloc, old, ddl_new);
    for (plan) |stmt| try w.exec(try alloc.dupeZ(u8, stmt));
    try updateRow(alloc, w, old.id, newc);
    try w.commit();
    try w.exec("PRAGMA foreign_keys=ON;");

    return newc;
}

fn updateRow(alloc: std.mem.Allocator, w: *db.Db, col_id: []const u8, col: schema.Collection) EngineError!void {
    const schema_json = try schema.fieldsToJson(alloc, col.fields);
    const indexes_json = try schema.indexesToJson(alloc, col.indexes);
    var st = try w.prepare(
        \\UPDATE "_collections" SET schema=?2, indexes=?3, listRule=?4, viewRule=?5,
        \\ createRule=?6, updateRule=?7, deleteRule=?8, updated=datetime('now') WHERE id=?1;
    );
    defer st.finalize();
    try st.bindText(1, col_id);
    try st.bindText(2, schema_json);
    try st.bindText(3, indexes_json);
    try bindOptText(&st, 4, col.listRule);
    try bindOptText(&st, 5, col.viewRule);
    try bindOptText(&st, 6, col.createRule);
    try bindOptText(&st, 7, col.updateRule);
    try bindOptText(&st, 8, col.deleteRule);
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
    var st = try w.prepare("DELETE FROM \"_collections\" WHERE \"id\" = ?1;");
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
    try std.testing.expectEqual(@as(usize, 1), all.len);
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
