const std = @import("std");
const http = @import("../http.zig");
const db = @import("../db.zig");

/// The active database backend, as a short, non-secret label. Derived from the live pool's
/// backend tag (`db.poolBackend`). Never exposes the connection string, host, credentials, or
/// any other config — only the backend KIND ("sqlite" | "postgres"), so the admin SPA can show
/// a read-only badge. Pure-handler unit tests (no `app`) report the default "sqlite".
fn backendLabel(ctx: *http.RequestCtx) []const u8 {
    const app = ctx.app orelse return "sqlite";
    return switch (db.poolBackend(app.pool)) {
        .sqlite => "sqlite",
        .postgres => "postgres",
    };
}

/// GET /api/health -> 200 {"status":"ok","backend":"sqlite"|"postgres"}
///
/// The `backend` field is a read-only badge for the admin UI. It is deliberately the backend
/// KIND only — no connection string / host / credentials are ever surfaced here.
pub fn handle(ctx: *http.RequestCtx) !http.Response {
    const body = try std.json.Stringify.valueAlloc(
        ctx.allocator,
        .{ .status = "ok", .backend = backendLabel(ctx) },
        .{},
    );
    return .{ .status = 200, .body = body };
}

test "health returns 200 and ok status with backend badge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = http.RequestCtx{
        .method = .GET,
        .path = "/api/health",
        .allocator = arena.allocator(),
    };
    const resp = try handle(&ctx);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    // No live app in this pure-handler test → reports the default backend, never any secret.
    try std.testing.expectEqualStrings("{\"status\":\"ok\",\"backend\":\"sqlite\"}", resp.body);
}
