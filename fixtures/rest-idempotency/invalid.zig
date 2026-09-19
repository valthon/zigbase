const std = @import("std");
const zb = @import("zigbase");
pub fn main(init: std.process.Init) !void {
    return zb.App(.{ .rest_idempotency = .{ .collections = .{"posts"}, .limits = .{ .namespace = "bad", .max_entries = 0 } } }).runCli(init);
}
