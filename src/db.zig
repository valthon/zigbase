const std = @import("std");
const c = @import("c.zig").c;

/// Returns the linked SQLite library version string, e.g. "3.53.2".
pub fn libVersion() []const u8 {
    return std.mem.span(c.sqlite3_libversion());
}

test "sqlite library links and reports a 3.x version" {
    const v = libVersion();
    try std.testing.expect(std.mem.startsWith(u8, v, "3."));
}
