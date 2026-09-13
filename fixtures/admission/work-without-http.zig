const zigbase = @import("zigbase");
pub fn main(init: @import("std").process.Init) !void {
    return zigbase.App(.{ .admission = .{ .max_work = 4, .max_job_bytes = 8 } }).runCli(init);
}
