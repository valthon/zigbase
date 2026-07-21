//! GET /api/realtime/stats — superuser-only, read-only realtime health: the live
//! connection count plus the static caps and configured outbound high-water-mark.
const std = @import("std");
const http = @import("../http.zig");
const auth = @import("../auth.zig");
const conn = @import("../realtime/connection.zig");
const ApiError = @import("error.zig").ApiError;

pub fn get(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    var r = try app.pool.acquireReader();
    defer app.pool.releaseReader(&r);
    const a = (auth.authenticate(app.io, ctx.allocator.a, app, ctx, &r) catch null) orelse
        return (ApiError{ .status = 401, .message = "Authentication required." }).toResponse(ctx.allocator.a);
    if (!a.is_superuser)
        return (ApiError{ .status = 403, .message = "Superuser only." }).toResponse(ctx.allocator.a);

    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator.a, "connections", .{ .integer = @intCast(conn.connectionCount()) });
    try root.put(ctx.allocator.a, "max_connections", .{ .integer = @intCast(conn.MAX_CONNECTIONS) });
    try root.put(ctx.allocator.a, "max_subs", .{ .integer = @intCast(conn.MAX_SUBS) });
    try root.put(ctx.allocator.a, "outbound_hwm", .{ .integer = @intCast(app.realtime_outbound_hwm) });
    return .{
        .status = 200,
        .content_type = "application/json",
        .body = try std.json.Stringify.valueAlloc(ctx.allocator.a, std.json.Value{ .object = root }, .{}),
    };
}

test "realtime stats exposes count + caps + hwm" {
    // Pin the connection.zig symbol names this handler depends on.
    try std.testing.expect(conn.MAX_CONNECTIONS == 10_000);
    try std.testing.expect(conn.MAX_SUBS == 256);
    _ = conn.connectionCount();
}
