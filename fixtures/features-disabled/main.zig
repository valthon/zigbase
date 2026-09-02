const std = @import("std");
const zigbase = @import("zigbase");

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .features = .{ .public_route = .disabled },
    }).runCli(init);
}
