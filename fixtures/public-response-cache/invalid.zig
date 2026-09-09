const std = @import("std");
const zigbase = @import("zigbase");
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{ .public_response_cache = .{ .max_entries = 0 } }).runCli(init);
}
