const std = @import("std");
const zigbase = @import("zigbase");
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{ .realtime = .{ .max_connections = 0 } }).runCli(init);
}
