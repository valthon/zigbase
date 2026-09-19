//! Explicit record invalidation backfill. Bearer credentials are optional:
//! anonymous public access is allowed, and cookie credentials are ignored.
const std = @import("std");
const http = @import("../http.zig");
const db = @import("../db.zig");
const collections = @import("../collections.zig");
const hub = @import("../realtime/hub.zig");
const Conn = @import("../realtime/connection.zig").Conn;
const ApiError = @import("error.zig").ApiError;
const unsupported_backend = ApiError.withCode(501, .not_implemented, "Backfill supports single-process SQLite only.");
const DeliveryError = @typeInfo(@typeInfo(@TypeOf(hub.frameForCollectionDelivery)).@"fn".return_type.?).error_union.error_set;

pub fn get(ctx: *http.RequestCtx) !http.Response {
    if (comptime !@import("build_options").realtime_backfill) return ApiError.notFound().toResponse(ctx.allocator.a);
    const a = ctx.allocator.a;
    const app = ctx.app orelse return ApiError.notFound().toResponse(a);
    // LISTEN/NOTIFY is best-effort, not a durable ordered log. Do not imply a
    // complete backfill on PostgreSQL even when requests stick to one instance.
    if (!@import("build_options").durable_realtime and db.poolBackend(app.pool) != .sqlite) return unsupported_backend.toResponse(a);
    if (!@import("build_options").durable_realtime and app.backfill == null) return ApiError.notFound().toResponse(a);
    if (ctx.query.len > 4096) return ApiError.badRequest("Backfill query too large.").toResponse(a);
    const params = try @import("../query/params.zig").parse(a, ctx.query);
    defer params.deinit(a);
    const input = .{
        .topic = params.get("topic") orelse return ApiError.badRequest("topic is required.").toResponse(a),
        .cursor = params.get("cursor"),
        .limit = std.fmt.parseInt(usize, params.get("limit") orelse "128", 10) catch return ApiError.badRequest("Invalid limit.").toResponse(a),
    };
    if (input.limit == 0 or input.limit > 128) return ApiError.badRequest("limit must be 1-128.").toResponse(a);
    var conn = Conn{ .tenancy_enabled = app.tenancy.enabled };
    var identity = std.heap.ArenaAllocator.init(a);
    defer identity.deinit();
    if (ctx.authorization.len > 0) {
        const token = ctx.bearerToken() orelse return ApiError.withCode(401, .unauthorized, "Invalid bearer token.").toResponse(a);
        if (!hub.authVerb(app, &conn, &identity, token, ctx.header("x-account-id") orelse "")) return ApiError.withCode(401, .unauthorized, "Invalid bearer token.").toResponse(a);
    }
    // Only real collection topics: dropping a collection must not reinterpret its
    // retained frames as a public custom channel in frameForDelivery.
    var reader = try app.pool.acquireReader();
    const col = collections.get(a, &reader, input.topic) catch |err| {
        app.pool.releaseReader(&reader);
        return err;
    };
    app.pool.releaseReader(&reader);
    if (col == null) return ApiError.notFound().toResponse(a);
    if (hub.subscribeCheck(app, &conn, ctx.allocator, input.topic) != .ok) return ApiError.withCode(403, .forbidden, "Subscription denied.").toResponse(a);
    const collection = col.?;
    const cursor_scope = if (comptime @import("build_options").durable_realtime)
        try std.fmt.allocPrint(a, "{s}:{d}", .{ collection.id, collection.rename_epoch })
    else
        collection.id;
    const checkpoint: ?[]const u8 = if (input.cursor) |cursor| blk: {
        if (cursor.len <= cursor_scope.len or !std.mem.startsWith(u8, cursor, cursor_scope) or cursor[cursor_scope.len] != ':') return resetRequired(a);
        break :blk cursor[cursor_scope.len + 1 ..];
    } else null;
    const result = blk: {
        if (comptime @import("build_options").durable_realtime) {
            var journal_reader = try app.pool.acquireReader();
            defer app.pool.releaseReader(&journal_reader);
            const page = @import("../realtime/durable.zig").readPage(ctx.allocator, app.io, &journal_reader, collection.id, cursor_scope, checkpoint, input.limit, @import("../clock.zig").nowUnix(app.io)) catch |err| switch (err) {
                error.ResetRequired, error.ReplayFrameTooLarge => return resetRequired(a),
                else => return err,
            };
            break :blk page;
        } else {
            const store = app.backfill.?;
            const page = store.page(ctx.allocator, collection.id, checkpoint, input.limit) catch |err| switch (err) {
                error.ResetRequired => return resetRequired(a),
                else => return err,
            };
            const entries = try a.alloc(@import("../realtime/durable.zig").Entry, page.items.len);
            for (page.items, entries) |source, *dest| dest.* = .{ .frame = source.frame };
            break :blk @import("../realtime/durable.zig").Page{ .items = entries, .position = try store.cursor(a, page), .has_next = page.has_next };
        }
    };
    var items: std.ArrayList(std.json.Value) = .empty;
    for (result.items) |e| {
        // Deliberately revalidate identity and reacquire current collection metadata
        // per item: a revocation committed mid-page discards the entire response.
        // A request-wide identity/schema snapshot would weaken that guarantee.
        const delivered = hub.frameForCollectionDelivery(a, app, &conn, null, input.topic, e.frame, col.?.id) catch |err| return deliveryError(a, err);
        if (delivered) |frame| {
            const value = try std.json.parseFromSliceLeaky(std.json.Value, a, frame, .{});
            try items.append(a, value);
        }
    }
    const position = result.position;
    const next_cursor = try std.fmt.allocPrint(a, "{s}:{s}", .{ cursor_scope, position });
    if (comptime @import("build_options").durable_realtime) {
        const durable = @import("../realtime/durable.zig");
        return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(a, .{ .items = items.items, .nextCursor = next_cursor, .hasNext = result.has_next, .resetRequired = false, .retention = .{ .maxEntries = durable.max_entries, .maxBytes = durable.max_bytes, .maxFrameBytes = durable.max_frame_bytes, .seconds = durable.retention_seconds } }, .{}) };
    }
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(a, .{ .items = items.items, .nextCursor = next_cursor, .hasNext = result.has_next, .resetRequired = false }, .{}) };
}

/// The shared delivery path can fail after earlier items were authorized. Return
/// only an error envelope, never a partial page/checkpoint. Operational failures
/// still propagate to the server's 500 handler; identity changes require reauth.
fn deliveryError(allocator: std.mem.Allocator, err: DeliveryError) DeliveryError!http.Response {
    if (err == error.AuthenticationChanged) return ApiError.unauthorized().toResponse(allocator);
    return err;
}

test "backfill unsupported backend uses the standard error envelope" {
    const response = try unsupported_backend.toResponse(std.testing.allocator);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(@as(u16, 501), response.status);
    try std.testing.expectEqualStrings("{\"status\":501,\"code\":\"not_implemented\",\"message\":\"Backfill supports single-process SQLite only.\",\"data\":{}}", response.body);
}

test "backfill mid-page identity change returns 401 without partial results or cursor" {
    const response = try deliveryError(std.testing.allocator, error.AuthenticationChanged);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(@as(u16, 401), response.status);
    try std.testing.expectEqualStrings("{\"status\":401,\"code\":\"unauthorized\",\"message\":\"Unauthorized.\",\"data\":{}}", response.body);
    try std.testing.expectError(error.OutOfMemory, deliveryError(std.testing.allocator, error.OutOfMemory));
    try std.testing.expectError(error.PrepareFailed, deliveryError(std.testing.allocator, error.PrepareFailed));
}

fn resetRequired(allocator: std.mem.Allocator) !http.Response {
    return .{ .status = 409, .body = try allocator.dupe(u8, "{\"resetRequired\":true,\"items\":[],\"nextCursor\":null,\"hasNext\":false}") };
}

test "backfill reset response owns its body on the supplied allocator" {
    const response = try resetRequired(std.testing.allocator);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(@as(u16, 409), response.status);
    try std.testing.expectEqualStrings("{\"resetRequired\":true,\"items\":[],\"nextCursor\":null,\"hasNext\":false}", response.body);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, resetRequired(failing.allocator()));
}
