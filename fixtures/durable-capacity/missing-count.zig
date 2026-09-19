const std = @import("std");
const zb = @import("zigbase");
pub fn main(init: std.process.Init) !void {
    return zb.App(.{ .queues = .{ .q = .{ .backend = .durable, .capacity = .{ .max_payload_bytes = 1 } } } }).runCli(init);
}
