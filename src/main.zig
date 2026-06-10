const std = @import("std");
const zigbase = @import("zigbase");

/// The shipped binary is the framework with no extensions registered.
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{}).runCli(init);
}
