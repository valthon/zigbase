const zigbase = @import("zigbase");
pub fn main(init: @import("std").process.Init) !void {
    return zigbase.App(.{ .admission = .{ .max_requests = 1, .max_work = 0 } }).runCli(init);
}
