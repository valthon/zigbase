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
