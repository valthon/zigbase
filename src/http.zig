const std = @import("std");
const App = @import("app.zig").App;

pub const Method = enum { GET, POST, PUT, PATCH, DELETE, OPTIONS, HEAD, UNKNOWN };

pub const Param = struct { key: []const u8, value: []const u8 };

pub const RequestCtx = struct {
    method: Method,
    path: []const u8,
    query: []const u8 = "",
    body: []const u8 = "",
    allocator: std.mem.Allocator,
    /// Present for real requests; null in pure-handler unit tests that don't need the DB.
    app: ?*App = null,
    /// Path params captured by the router (e.g. ":id").
    params: []const Param = &.{},

    pub fn param(self: *const RequestCtx, name: []const u8) ?[]const u8 {
        for (self.params) |p| {
            if (std.mem.eql(u8, p.key, name)) return p.value;
        }
        return null;
    }
};

pub const Response = struct {
    status: u16,
    content_type: []const u8 = "application/json",
    body: []const u8, // allocated in the request arena
};

pub const Handler = *const fn (ctx: *RequestCtx) anyerror!Response;

test "param lookup" {
    const params = [_]Param{ .{ .key = "id", .value = "abc" }, .{ .key = "x", .value = "y" } };
    var ctx = RequestCtx{ .method = .GET, .path = "/", .allocator = std.testing.allocator, .params = &params };
    try std.testing.expectEqualStrings("abc", ctx.param("id").?);
    try std.testing.expect(ctx.param("missing") == null);
}
