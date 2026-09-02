const std = @import("std");
const zigbase = @import("zigbase");

fn handler(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    _ = ctx;
    return .{ .status = 200, .body = "ok" };
}

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .routes = .{.{ .method = .UNKNOWN, .path = "/api/unknown", .handler = handler }},
    }).runCli(init);
}
