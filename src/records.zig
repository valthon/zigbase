const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const collections = @import("collections.zig");
const migrations = @import("migrations.zig");
const values = @import("values.zig");
const ddl = @import("ddl.zig");

/// readValue / rowToObject can surface std.json parse errors (for json and multi-value
/// fields), and collections.get widens its own inferred error set. Capture those so
/// RecordError covers everything get/create can produce, the way collections.zig does.
const ReadError = @typeInfo(@typeInfo(@TypeOf(values.readValue)).@"fn".return_type.?).error_union.error_set;
const CollectionsGetError = @typeInfo(@typeInfo(@TypeOf(collections.get)).@"fn".return_type.?).error_union.error_set;

pub const RecordError = error{ Validation, NotFound, NotObject } ||
    db.DbError || values.ValueError || ReadError || CollectionsGetError;

fn columnList(alloc: std.mem.Allocator, col: schema.Collection) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "\"id\",\"created\",\"updated\"");
    for (col.fields) |f| {
        try out.append(alloc, ',');
        try out.appendSlice(alloc, try ddl.quoteIdent(alloc, f.name));
    }
    return out.toOwnedSlice(alloc);
}

fn rowToObject(alloc: std.mem.Allocator, stmt: *db.Stmt, col: schema.Collection) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "id", .{ .string = try alloc.dupe(u8, stmt.columnText(0)) });
    try obj.put(alloc, "created", .{ .string = try alloc.dupe(u8, stmt.columnText(1)) });
    try obj.put(alloc, "updated", .{ .string = try alloc.dupe(u8, stmt.columnText(2)) });
    for (col.fields, 0..) |f, i| {
        const v = try values.readValue(alloc, stmt, @intCast(3 + i), f);
        try obj.put(alloc, f.name, v);
    }
    return .{ .object = obj };
}

pub fn get(alloc: std.mem.Allocator, r: *db.Db, col: schema.Collection, id: []const u8) RecordError!?std.json.Value {
    const cols = try columnList(alloc, col);
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT {s} FROM \"{s}\" WHERE \"id\" = ?1;", .{ cols, col.name }, 0);
    var st = try r.prepare(sql);
    defer st.finalize();
    try st.bindText(1, id);
    if (!try st.step()) return null;
    return try rowToObject(alloc, &st, col);
}

fn seedPosts(d: *db.Db, a: std.mem.Allocator) !schema.Collection {
    try migrations.run(d);
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } },
    };
    return collections.create(a, std.testing.io, d, .{ .id = "", .name = "posts", .fields = &fields });
}

test "get returns a record as a JSON object with typed values" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    try d.exec("INSERT INTO posts (id,created,updated,title,price) VALUES ('r1','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','hello',1050);");
    const rec = (try get(a, &d, col, "r1")).?;
    try std.testing.expectEqualStrings("r1", rec.object.get("id").?.string);
    try std.testing.expectEqualStrings("hello", rec.object.get("title").?.string);
    try std.testing.expectEqualStrings("10.50", rec.object.get("price").?.string);
    try std.testing.expect((try get(a, &d, col, "nope")) == null);
}
