const std = @import("std");
const zigbase = @import("zigbase");
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{ .query_workbench = true }).runCli(init);
}
