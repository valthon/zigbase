const std = @import("std");
const zigbase = @import("zigbase");

fn handler(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    _ = ctx;
    return .{ .status = 200, .body = "ok" };
}

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .routes = .{.{
            .method = .GET,
            .path = "/api/hooks/:token",
            .handler = handler,
            .auth = .{ .path_secret = .{
                .param = "missing",
                .source = .{ .config = "hook_secret" },
            } },
        }},
    }).runCli(init);
}
