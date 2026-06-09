const std = @import("std");
const joiner = @import("joiner.zig");

pub const SortError = error{ BadSort } || joiner.JoinError;

/// Compile a comma-separated sort spec ("-created,author.name") into an ORDER BY fragment
/// (without the "ORDER BY" keywords), resolving relation paths via `j`. Empty -> "".
pub fn compile(alloc: std.mem.Allocator, j: *joiner.Joiner, spec: []const u8) SortError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, spec, ',');
    var first = true;
    while (it.next()) |raw| {
        const term = std.mem.trim(u8, raw, " ");
        if (term.len == 0) continue;
        const desc = term[0] == '-';
        const path = if (desc or term[0] == '+') term[1..] else term;
        if (path.len == 0) return error.BadSort;
        const col = try j.resolve(path);
        if (!first) try out.appendSlice(alloc, ", ");
        first = false;
        try out.appendSlice(alloc, col.sql);
        try out.appendSlice(alloc, if (desc) " DESC" else " ASC");
    }
    return out.toOwnedSlice(alloc);
}

test "sort compiles direction and relation paths" {
    const db = @import("../db.zig");
    const schema = @import("../schema.zig");
    const migrations = @import("../migrations.zig");
    const collections = @import("../collections.zig");
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const users = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "users", .fields = &[_]schema.Field{.{ .id = "u1", .name = "name", .options = .{ .text = .{} } }} });
    const pf = [_]schema.Field{.{ .id = "f3", .name = "author", .options = .{ .relation = .{ .targetCollectionId = users.id, .maxSelect = 1 } } }};
    const posts = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &pf });
    var j = joiner.Joiner.init(a, &d, posts);
    const ob = try compile(a, &j, "-created,author.name");
    try std.testing.expectEqualStrings("\"posts\".\"created\" DESC, j1.\"name\" ASC", ob);
}
