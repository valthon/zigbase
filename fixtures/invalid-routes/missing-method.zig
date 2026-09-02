const std = @import("std");
const zigbase = @import("zigbase");

fn handler(req: *zigbase.Req(void)) zigbase.RouteError!void {
    _ = req;
}

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .routes = .{
            .{ .path = "/api/missing-method", .handler = handler },
        },
    }).runCli(init);
}
