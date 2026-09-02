const std = @import("std");
const zigbase = @import("zigbase");

fn headSuccess(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    _ = ctx;
    return .{ .status = 200, .body = "custom-head-representation", .content_type = "text/plain" };
}

fn headError(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    _ = ctx;
    return error.DeliberateHeadFailure;
}

fn reclaimedState(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    _ = ctx;
    return .{ .status = 200, .body = "consumer-state", .content_type = "text/plain" };
}

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .features = .{ .public_route = "/public/features" },
        .routes = .{
            .{ .method = .GET, .path = "/api/state", .name = "consumerState", .handler = reclaimedState, .auth = .public },
            .{ .method = .HEAD, .path = "/api/state", .name = "consumerStateHead", .handler = reclaimedState, .auth = .public },
            .{ .method = .HEAD, .path = "/custom/head-success", .handler = headSuccess, .auth = .public },
            .{ .method = .HEAD, .path = "/custom/head-error", .handler = headError, .auth = .public },
            .{ .method = .GET, .path = "/api/profile/me", .name = "profileMe", .handler = headSuccess, .auth = .{ .authed = "profiles", .allow_superuser = true } },
        },
        .collections = .{
            .profiles = .{
                .type = .auth,
                .fields = .{.{ .name = "name", .type = .text }},
            },
        },
    }).runCli(init);
}
