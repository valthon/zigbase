const std = @import("std");
const zb = @import("zigbase");
pub fn main(init: std.process.Init) !void {
    return zb.App(.{ .pools = .{ .memory_jobs = 0 } }).runCli(init);
}
