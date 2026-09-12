const std = @import("std");
const zigbase = @import("zigbase");

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{ .files = .{ .resumable = .{
        .durable = true,
        .max_upload_bytes = 1 << 30,
        .max_total_bytes = 1 << 30,
    } } }).runCli(init);
}
