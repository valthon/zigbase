const std = @import("std");
const zigbase = @import("zigbase");

const App = zigbase.App(.{
    .routes = .{
        .{ .method = .GET, .path = "/api/ping", .handler = ping, .auth = .public },
    },
});

fn ping(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    _ = ctx;
    return .{ .status = 200, .body = "pong" };
}

test "ping" {
    var harness = try zigbase.testing.start(App, .{});
    defer harness.deinit();
    const response = try harness.request(.GET, "/api/ping", .{});
    try std.testing.expectEqual(@as(u16, 200), response.status);
}
