const std = @import("std");
const zigbase = @import("zigbase");

fn work(ctx: *zigbase.Ctx) !zigbase.http.Response {
    var reader = try ctx.app.pool.acquireReader();
    defer ctx.app.pool.releaseReader(&reader);
    for (0..3) |_| {
        const postgres = if (comptime @typeInfo(zigbase.Db) == .@"union") std.meta.activeTag(reader) == .postgres else false;
        var stmt = try reader.prepare(if (postgres) "SELECT $1::text, 'private-literal';" else "SELECT ?1, 'private-literal';");
        defer stmt.finalize();
        try stmt.bindText(1, ctx.request.?.param("id") orelse "missing");
        _ = try stmt.step();
    }
    return .{ .status = 204, .body = "" };
}

fn held(ctx: *zigbase.Ctx) !zigbase.http.Response {
    var reader = try ctx.app.pool.acquireReader();
    defer ctx.app.pool.releaseReader(&reader);
    var stmt = try reader.prepare("SELECT 1;");
    defer stmt.finalize();
    _ = try stmt.step();
    // Deliberately retain the statement outside the backend. This is not a slow query.
    try ctx.app.io.sleep(std.Io.Duration.fromMilliseconds(50), .awake);
    stmt.reset();
    _ = try stmt.step();
    return .{ .status = 204, .body = "" };
}
fn noQuery(ctx: *zigbase.Ctx) !zigbase.http.Response {
    try ctx.app.io.sleep(std.Io.Duration.fromMilliseconds(50), .awake);
    return .{ .status = 204, .body = "" };
}
fn failed(_: *zigbase.Ctx) !zigbase.http.Response {
    return error.TestRouteFailure;
}
pub fn main(init: std.process.Init) !void {
    const routes = .{
        .{ .method = .GET, .path = "/no-query/:id", .auth = .public, .handler = noQuery },
        .{ .name = "postNoQuery", .method = .POST, .path = "/no-query/:id", .auth = .public, .handler = noQuery },
        .{ .name = "denied", .method = .GET, .path = "/denied", .auth = .authed, .handler = noQuery },
        .{ .method = .GET, .path = "/failed", .auth = .public, .handler = failed },
        .{ .method = .GET, .path = "/work/:id", .auth = .public, .handler = work },
        .{ .method = .GET, .path = "/held", .auth = .public, .handler = held },
    };
    const App = if (@import("fixture_options").enabled) zigbase.App(.{
        .query_workbench = .{ .max_entries = 8, .slow_ms = 1 },
        .routes = routes,
    }) else zigbase.App(.{ .routes = routes });
    return App.runCli(init);
}
