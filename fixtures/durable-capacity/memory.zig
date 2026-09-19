const std = @import("std");
const zb = @import("zigbase");
pub fn main(init: std.process.Init) !void {
    return zb.App(.{ .queues = .{ .q = .{ .backend = .memory, .capacity = .{ .max_jobs = 1 } } } }).runCli(init);
}
