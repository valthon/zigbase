//! Output-side helpers for `zigbase openapi`, kept separate so atomic replacement is
//! unit-testable without constructing a process Init or a live database.
const std = @import("std");

/// Write a complete artifact to a sibling temporary file and rename it over `path`.
/// A failed write or rename removes the temporary file and leaves any old artifact intact.
pub fn writeAtomic(alloc: std.mem.Allocator, io: std.Io, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    var random: [8]u8 = undefined;
    io.random(&random);
    const temp = try std.fmt.allocPrint(alloc, "{s}.tmp-{x}", .{ path, random });
    defer alloc.free(temp);
    errdefer std.Io.Dir.cwd().deleteFile(io, temp) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temp, .data = data });
    try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), path, io);
}

test "atomic writer creates parents and replaces a complete artifact" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "nested", "openapi.json" });
    defer a.free(path);
    try writeAtomic(a, io, path, "old");
    try writeAtomic(a, io, path, "new document\n");
    const got = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024));
    defer a.free(got);
    try std.testing.expectEqualStrings("new document\n", got);
}
