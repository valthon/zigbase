const std = @import("std");
const zigbase = @import("zigbase");

fn handler(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    _ = ctx;
    return .{ .status = 200, .body = "ok" };
}

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .routes = .{
            .{ .method = .GET, .path = "/api/report", .handler = handler, .name = "report.v1" },
        },
    }).runCli(init);
}
