const std = @import("std");
const zigbase = @import("zigbase");
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .static_headers = &.{.{ .match = "/**", .set = &.{.{ "Content-Length", "42" }} }},
    }).runCli(init);
}
