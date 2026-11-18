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
        try a.print("{s}:{d}", .{ collection.id, collection.rename_epoch })
    else
        collection.id;
    const checkpoint: ?[]const u8 = if (input.cursor) |cursor| blk: {
        if (cursor.len <= cursor_scope.len or !std.mem.startsWith(u8, cursor, cursor_scope) or cursor[cursor_scope.len] != ':') return resetRequired(a);
        break :blk cursor[cursor_scope.len + 1 ..];
    } else null;
    const backfill = @import("../realtime/backfill.zig");
    const durable = @import("../realtime/durable.zig");
    const delivery = Delivery{ .a = a, .app = app, .conn = &conn, .topic = input.topic, .collection_id = collection.id };
    const page = if (comptime @import("build_options").durable_realtime) blk: {
        const now = @import("../clock.zig").nowUnix(app.io);
        var journal_reader = try app.pool.acquireReader();
        const resolved = durable.resolve(a, &journal_reader, cursor_scope, checkpoint, now);
        app.pool.releaseReader(&journal_reader);
        const start = resolved catch |err| return failure(a, err);
        const filled = if (checkpoint == null)
            backfill.Filled(std.json.Value){ .items = &.{}, .next = @intCast(start.head), .has_next = false }
        else
            backfill.fill(std.json.Value, ctx.allocator, JournalSource{ .app = app, .collection_id = collection.id, .upto = start.head, .now = now }, delivery, @intCast(start.after), input.limit, durable.scan_budget, durable.scan_chunk) catch |err| return failure(a, err);
        break :blk .{ filled, try durable.sealCursor(a, app.io, start.key, cursor_scope, @intCast(filled.next)) };
    } else blk: {
        const store = app.backfill.?;
        const start = store.start(collection.id, checkpoint) catch |err| return failure(a, err);
        // The ring holds at most `max_entries`: one chunk reaches the head.
        const filled = if (checkpoint == null)
            backfill.Filled(std.json.Value){ .items = &.{}, .next = start.sequence, .has_next = false }
        else
            backfill.fill(std.json.Value, ctx.allocator, LocalSource{ .store = store, .id = collection.id, .generation = start.generation }, delivery, start.sequence, input.limit, backfill.max_entries, backfill.max_entries) catch |err| return failure(a, err);
        break :blk .{ filled, try store.seal(a, collection.id, .{ .generation = start.generation, .sequence = filled.next }) };
    };
    const filled, const position = page;
    const next_cursor = try a.print("{s}:{s}", .{ cursor_scope, position });
    if (comptime @import("build_options").durable_realtime) {
        return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(a, .{ .items = filled.items, .nextCursor = next_cursor, .hasNext = filled.has_next, .resetRequired = false, .retention = .{ .maxEntries = durable.max_entries, .maxBytes = durable.max_bytes, .maxFrameBytes = durable.max_frame_bytes, .seconds = durable.retention_seconds } }, .{}) };
    }
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(a, .{ .items = filled.items, .nextCursor = next_cursor, .hasNext = filled.has_next, .resetRequired = false }, .{}) };
}

/// Per-item authorization for `backfill.fill`. Identity is deliberately revalidated and
/// collection metadata reacquired per item: a revocation committed mid-page discards the
/// entire response. A request-wide identity/schema snapshot would weaken that guarantee.
const Delivery = struct {
    a: std.mem.Allocator,
    app: *@import("../app.zig").App,
    conn: *const Conn,
    topic: []const u8,
    collection_id: []const u8,
    pub fn deliver(self: Delivery, scratch: std.mem.Allocator, entry: @import("../realtime/backfill.zig").Entry) !?std.json.Value {
        const frame = try hub.frameForCollectionDelivery(scratch, self.app, self.conn, null, self.topic, entry.frame, self.collection_id) orelse return null;
        // `frame` may alias the chunk's scratch copy: own every string on the request arena.
        return try std.json.parseFromSliceLeaky(std.json.Value, self.a, frame, .{ .allocate = .alloc_always });
    }
};

const LocalSource = struct {
    store: *@import("../realtime/backfill.zig").Store,
    id: []const u8,
    generation: u64,
    pub fn fetch(self: LocalSource, arena: @import("../request_arena.zig").RequestArena, after: u64, max: usize) !@import("../realtime/backfill.zig").Page {
        return self.store.read(arena, self.id, .{ .generation = self.generation, .sequence = after }, max);
    }
};

/// Chunks of the journal up to the head the request resolved, each in its own read
/// transaction (a reader is held only for the chunk, never across authorization).
const JournalSource = struct {
    app: *@import("../app.zig").App,
    collection_id: []const u8,
    upto: i64,
    now: i64,
    pub fn fetch(self: JournalSource, arena: @import("../request_arena.zig").RequestArena, after: u64, max: usize) !@import("../realtime/backfill.zig").Page {
        var reader = try self.app.pool.acquireReader();
        defer self.app.pool.releaseReader(&reader);
        return @import("../realtime/durable.zig").readPage(arena, &reader, self.collection_id, @intCast(after), self.upto, max, self.now);
    }
};

/// A page can fail after earlier items were authorized. Return only an error envelope,
/// never a partial page/checkpoint. A stale checkpoint, or a retained frame over the
/// current budget, needs a reset (409); an identity change mid-page needs reauth (401).
/// Operational failures (out of memory, the reader pool, the live database or the
/// delete-authorization sandbox failing) propagate to the server's 500 handler so a retry
/// of the same checkpoint can succeed. A failure tied to ONE retained item would instead
/// repeat on every retry, so it never reaches here: a deletion snapshot that no longer
/// fits its fields, or a rule that cannot be compiled against it, is a logged per-item
/// deny in `hub.matchesSnapshot` (#499).
fn failure(allocator: std.mem.Allocator, err: anytype) (@TypeOf(err) || error{OutOfMemory})!http.Response {
    if (try failureResponse(allocator, err)) |response| return response;
    return err;
}

fn failureResponse(allocator: std.mem.Allocator, err: anyerror) error{OutOfMemory}!?http.Response {
    return switch (err) {
        error.ResetRequired, error.ReplayFrameTooLarge => try resetRequired(allocator),
        error.AuthenticationChanged => try ApiError.unauthorized().toResponse(allocator),
        else => null,
    };
}

test "backfill unsupported backend uses the standard error envelope" {
    const response = try unsupported_backend.toResponse(std.testing.allocator);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(@as(u16, 501), response.status);
    try std.testing.expectEqualStrings("{\"status\":501,\"code\":\"not_implemented\",\"message\":\"Backfill supports single-process SQLite only.\",\"data\":{}}", response.body);
}

test "backfill mid-page identity change returns 401 and stale pages 409, without partial results or cursor" {
    const response = try failure(std.testing.allocator, @as(anyerror, error.AuthenticationChanged));
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(@as(u16, 401), response.status);
    try std.testing.expectEqualStrings("{\"status\":401,\"code\":\"unauthorized\",\"message\":\"Unauthorized.\",\"data\":{}}", response.body);
    for ([_]anyerror{ error.ResetRequired, error.ReplayFrameTooLarge }) |err| {
        const reset = try failure(std.testing.allocator, err);
        defer std.testing.allocator.free(reset.body);
        try std.testing.expectEqual(@as(u16, 409), reset.status);
    }
    try std.testing.expectError(error.OutOfMemory, failure(std.testing.allocator, @as(anyerror, error.OutOfMemory)));
    try std.testing.expectError(error.PrepareFailed, failure(std.testing.allocator, @as(anyerror, error.PrepareFailed)));
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
