const std = @import("std");
const zigbase = @import("zigbase");

fn work(ctx: *zigbase.Ctx) !zigbase.http.Response {
    var reader = try ctx.app.pool.acquireReader();
    defer ctx.app.pool.releaseReader(&reader);
    for (0..3) |_| {
        var stmt = try reader.prepare("SELECT ?1, 'private-literal';");
        defer stmt.finalize();
        try stmt.bindText(1, ctx.request.?.param("id") orelse "missing");
        _ = try stmt.step();
    }
    return .{ .status = 204, .body = "" };
}
pub fn main(init: std.process.Init) !void {
    const routes = .{.{ .method = .GET, .path = "/work/:id", .auth = .public, .handler = work }};
    const App = if (@import("fixture_options").enabled) zigbase.App(.{
        .query_workbench = .{ .max_entries = 8, .slow_ms = 1 },
        .routes = routes,
    }) else zigbase.App(.{ .routes = routes });
    return App.runCli(init);
}
