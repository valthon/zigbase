const std = @import("std");
const http = @import("../http.zig");

/// GET /api/health -> 200 {"status":"ok"}
pub fn handle(ctx: *http.RequestCtx) !http.Response {
    const body = try std.json.Stringify.valueAlloc(
        ctx.allocator,
        .{ .status = "ok" },
        .{},
    );
    return .{ .status = 200, .body = body };
}

test "health returns 200 and ok status" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = http.RequestCtx{
        .method = .GET,
        .path = "/api/health",
        .allocator = arena.allocator(),
    };
    const resp = try handle(&ctx);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("{\"status\":\"ok\"}", resp.body);
}
