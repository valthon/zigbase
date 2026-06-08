const std = @import("std");

pub fn main() void {
    std.debug.print("zigbase: usage: zigbase serve [--http-port N] [--data-dir PATH]\n", .{});
}

test "smoke" {
    try std.testing.expect(true);
}
