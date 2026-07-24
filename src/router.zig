const std = @import("std");
const RequestArena = @import("request_arena.zig").RequestArena;
const http = @import("http.zig");

pub const Route = struct { method: http.Method, pattern: []const u8, handler: http.Handler };

/// Match `pattern` (with `:name` capture segments) against `path`, splitting on '/'.
/// Returns captured params (possibly empty) on match, or null on mismatch.
pub fn matchPath(alloc: std.mem.Allocator, pattern: []const u8, path: []const u8) !?[]http.Param {
    var params: std.ArrayList(http.Param) = .empty;
    errdefer params.deinit(alloc);
    var pit = std.mem.splitScalar(u8, pattern, '/');
    var sit = std.mem.splitScalar(u8, path, '/');
    while (true) {
        const pseg = pit.next();
        const sseg = sit.next();
        if (pseg == null and sseg == null) break;
        if (pseg == null or sseg == null) return null;
        if (pseg.?.len > 0 and pseg.?[0] == ':') {
            try params.append(alloc, .{ .key = pseg.?[1..], .value = sseg.? });
        } else if (!std.mem.eql(u8, pseg.?, sseg.?)) {
            return null;
        }
    }
    return try params.toOwnedSlice(alloc);
}

/// Like `dispatch`, but returns null instead of a 404 envelope when nothing matches.
/// Lets the caller try multiple route tables (built-in, then custom) before 404ing.
pub fn tryDispatch(routes: []const Route, ctx: *http.RequestCtx) anyerror!?http.Response {
    for (routes) |rt| {
        if (rt.method != ctx.method) continue;
        if (try matchPath(ctx.allocator.a, rt.pattern, ctx.path)) |params| {
            ctx.params = params;
            return try rt.handler(ctx);
        }
    }
    return null;
}

/// Find the first matching route (method + path), fill ctx.params, invoke handler.
/// Returns a 404 envelope when nothing matches.
pub fn dispatch(routes: []const Route, ctx: *http.RequestCtx) anyerror!http.Response {
    const ApiError = @import("api/error.zig").ApiError;
    return (try tryDispatch(routes, ctx)) orelse ApiError.notFound().toResponse(ctx.allocator.a);
}

fn dummyHandler(ctx: *http.RequestCtx) anyerror!http.Response {
    return .{ .status = 200, .body = ctx.param("idOrName") orelse "none" };
}

test "matchPath: literal match yields empty params" {
    const p = (try matchPath(std.testing.allocator, "/api/collections", "/api/collections")).?;
    defer std.testing.allocator.free(p);
    try std.testing.expectEqual(@as(usize, 0), p.len);
}
test "matchPath: captures a param" {
    const p = (try matchPath(std.testing.allocator, "/api/collections/:idOrName", "/api/collections/posts")).?;
    defer std.testing.allocator.free(p);
    try std.testing.expectEqual(@as(usize, 1), p.len);
    try std.testing.expectEqualStrings("idOrName", p[0].key);
    try std.testing.expectEqualStrings("posts", p[0].value);
}
test "matchPath: literal mismatch and length mismatch return null" {
    try std.testing.expect((try matchPath(std.testing.allocator, "/api/collections", "/api/users")) == null);
    try std.testing.expect((try matchPath(std.testing.allocator, "/api/collections/:id", "/api/collections")) == null);
}
test "dispatch routes to handler with params, else 404" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const routes = [_]Route{.{ .method = .GET, .pattern = "/api/collections/:idOrName", .handler = dummyHandler }};
    var ctx = http.RequestCtx{ .method = .GET, .path = "/api/collections/posts", .allocator = RequestArena.from(&arena) };
    const r = try dispatch(&routes, &ctx);
    try std.testing.expectEqualStrings("posts", r.body);
    var ctx2 = http.RequestCtx{ .method = .GET, .path = "/nope", .allocator = RequestArena.from(&arena) };
    const r2 = try dispatch(&routes, &ctx2);
    try std.testing.expectEqual(@as(u16, 404), r2.status);
}
test "tryDispatch returns null when nothing matches, Response when it does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const routes = [_]Route{.{ .method = .GET, .pattern = "/api/collections/:idOrName", .handler = dummyHandler }};
    var ctx = http.RequestCtx{ .method = .GET, .path = "/api/collections/posts", .allocator = RequestArena.from(&arena) };
    const hit = try tryDispatch(&routes, &ctx);
    try std.testing.expect(hit != null);
    try std.testing.expectEqualStrings("posts", hit.?.body);
    var ctx2 = http.RequestCtx{ .method = .GET, .path = "/nope", .allocator = RequestArena.from(&arena) };
    try std.testing.expect((try tryDispatch(&routes, &ctx2)) == null);
}
