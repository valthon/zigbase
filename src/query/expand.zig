const std = @import("std");
const collections = @import("../collections.zig");
const records = @import("../records.zig");
const schema = @import("../schema.zig");
const db = @import("../db.zig");
const migrations = @import("../migrations.zig");

const max_depth = 6;

/// Explicit error set so the mutual recursion between `expand` and `expandField`
/// does not produce an inferred-error-set dependency loop.
pub const ExpandError = records.RecordError || collections.EngineError;

/// Expand the given comma-separated, dot-nested expand-spec ("author,tags.owner") into
/// `rec.object`'s "expand" key. `rec` must be a `.object`. Single relations nest an object;
/// multi nest an array. Depth-guarded.
///
/// LIMITATION: when multiple expand paths share a head (e.g. "author.org,author.name"),
/// `head` is expanded once per comma-segment and the later segment overwrites the earlier.
pub fn expand(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, rec: *std.json.Value, spec: []const u8, depth: usize) ExpandError!void {
    if (depth >= max_depth or rec.* != .object) return;
    var it = std.mem.splitScalar(u8, spec, ',');
    var expand_obj: std.json.ObjectMap = .empty;
    var any = false;
    while (it.next()) |raw| {
        const path = std.mem.trim(u8, raw, " ");
        if (path.len == 0) continue;
        const dot = std.mem.indexOfScalar(u8, path, '.');
        const head = if (dot) |i| path[0..i] else path;
        const rest = if (dot) |i| path[i + 1 ..] else "";
        const field = schema.fieldByName(col, head) orelse continue;
        if (field.fieldType() != .relation) continue;
        const target = (try collections.get(alloc, conn, field.options.relation.targetCollectionId)) orelse continue;
        const id_val = rec.object.get(head) orelse continue;
        const nested = try expandField(alloc, conn, target, id_val, rest, depth);
        try expand_obj.put(alloc, head, nested);
        any = true;
    }
    if (any) try rec.object.put(alloc, "expand", .{ .object = expand_obj });
}

fn expandField(alloc: std.mem.Allocator, conn: *db.Db, target: schema.Collection, id_val: std.json.Value, rest: []const u8, depth: usize) ExpandError!std.json.Value {
    switch (id_val) {
        .string => |id| {
            var sub = (try records.get(alloc, conn, target, id)) orelse return .null;
            if (rest.len > 0) try expand(alloc, conn, target, &sub, rest, depth + 1);
            return sub;
        },
        .array => |arr| {
            var out = std.json.Array.init(alloc);
            for (arr.items) |item| if (item == .string) {
                var sub = (try records.get(alloc, conn, target, item.string)) orelse continue;
                if (rest.len > 0) try expand(alloc, conn, target, &sub, rest, depth + 1);
                try out.append(sub);
            };
            return .{ .array = out };
        },
        else => return .null,
    }
}

test "expand nests a single relation under record.expand" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const users = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "users", .fields = &[_]schema.Field{.{ .id = "u1", .name = "name", .options = .{ .text = .{} } }} });
    const pf = [_]schema.Field{.{ .id = "f3", .name = "author", .options = .{ .relation = .{ .targetCollectionId = users.id, .maxSelect = 1 } } }};
    const posts = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &pf });
    try d.exec("INSERT INTO users (id,created,updated,name) VALUES ('u_1','t','t','Ada');");
    try d.exec("INSERT INTO posts (id,created,updated,author) VALUES ('p_1','t','t','u_1');");

    var rec = (try records.get(a, &d, posts, "p_1")).?;
    try expand(a, &d, posts, &rec, "author", 0);
    const exp = rec.object.get("expand").?.object;
    try std.testing.expectEqualStrings("Ada", exp.get("author").?.object.get("name").?.string);
}

test "expand nests two hops (author.org)" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const orgs = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "orgs", .fields = &[_]schema.Field{.{ .id = "o1", .name = "label", .options = .{ .text = .{} } }} });
    const uf = [_]schema.Field{
        .{ .id = "u1", .name = "name", .options = .{ .text = .{} } },
        .{ .id = "u2", .name = "org", .options = .{ .relation = .{ .targetCollectionId = orgs.id, .maxSelect = 1 } } },
    };
    const users = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "users", .fields = &uf });
    const pf = [_]schema.Field{.{ .id = "f3", .name = "author", .options = .{ .relation = .{ .targetCollectionId = users.id, .maxSelect = 1 } } }};
    const posts = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &pf });
    try d.exec("INSERT INTO orgs (id,created,updated,label) VALUES ('o_1','t','t','Acme');");
    try d.exec("INSERT INTO users (id,created,updated,name,org) VALUES ('u_1','t','t','Ada','o_1');");
    try d.exec("INSERT INTO posts (id,created,updated,author) VALUES ('p_1','t','t','u_1');");

    var rec = (try records.get(a, &d, posts, "p_1")).?;
    try expand(a, &d, posts, &rec, "author.org", 0);
    const author = rec.object.get("expand").?.object.get("author").?.object;
    const org = author.get("expand").?.object.get("org").?.object;
    try std.testing.expectEqualStrings("Acme", org.get("label").?.string);
}
