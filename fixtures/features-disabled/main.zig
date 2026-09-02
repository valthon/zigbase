const std = @import("std");
const zigbase = @import("zigbase");

fn reclaimedState(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    _ = ctx;
    return .{ .status = 200, .body = "consumer-state", .content_type = "text/plain" };
}

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .features = .{ .public_route = .disabled },
        .routes = .{
            .{ .method = .GET, .path = "/api/state", .name = "consumerState", .handler = reclaimedState, .auth = .public },
            .{ .method = .HEAD, .path = "/api/state", .name = "consumerStateHead", .handler = reclaimedState, .auth = .public },
        },
    }).runCli(init);
}
