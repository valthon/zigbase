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
    /// Raw request headers (filled by server.zig; "" when absent). Names are lowercase.
    authorization: []const u8 = "",
    cookie_header: []const u8 = "",
    csrf_token: []const u8 = "", // X-CSRF-Token header value

    pub fn param(self: *const RequestCtx, name: []const u8) ?[]const u8 {
        for (self.params) |p| {
            if (std.mem.eql(u8, p.key, name)) return p.value;
        }
        return null;
    }

    /// The bearer token from `Authorization: Bearer <token>`, or null.
    pub fn bearerToken(self: *const RequestCtx) ?[]const u8 {
        const prefix = "Bearer ";
        if (!std.mem.startsWith(u8, self.authorization, prefix)) return null;
        const t = self.authorization[prefix.len..];
        return if (t.len == 0) null else t;
    }

    /// The value of cookie `name` from the Cookie header, or null. Trims surrounding spaces.
    pub fn cookie(self: *const RequestCtx, name: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, self.cookie_header, ';');
        while (it.next()) |raw| {
            const pair = std.mem.trim(u8, raw, " ");
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
        }
        return null;
    }
};

pub const SameSite = enum { default, lax, strict, none };

/// A cookie the handler wants set on the response. `server.zig` translates this to zap.
pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    max_age_s: i32 = 0, // 0 = session cookie; negative clears
    http_only: bool = true,
    secure: bool = true,
    same_site: SameSite = .strict,
    path: []const u8 = "/",
};

pub const Response = struct {
    status: u16,
    content_type: []const u8 = "application/json",
    body: []const u8, // allocated in the request arena
    cookies: []const Cookie = &.{},
};

pub const Handler = *const fn (ctx: *RequestCtx) anyerror!Response;

test "param lookup" {
    const params = [_]Param{ .{ .key = "id", .value = "abc" }, .{ .key = "x", .value = "y" } };
    var ctx = RequestCtx{ .method = .GET, .path = "/", .allocator = std.testing.allocator, .params = &params };
    try std.testing.expectEqualStrings("abc", ctx.param("id").?);
    try std.testing.expect(ctx.param("missing") == null);
}

test "bearerToken extracts the token after 'Bearer '" {
    var ctx = RequestCtx{ .method = .GET, .path = "/", .allocator = std.testing.allocator, .authorization = "Bearer abc.def.ghi" };
    try std.testing.expectEqualStrings("abc.def.ghi", ctx.bearerToken().?);
    var none = RequestCtx{ .method = .GET, .path = "/", .allocator = std.testing.allocator, .authorization = "" };
    try std.testing.expect(none.bearerToken() == null);
    var basic = RequestCtx{ .method = .GET, .path = "/", .allocator = std.testing.allocator, .authorization = "Basic xyz" };
    try std.testing.expect(basic.bearerToken() == null);
}

test "cookie parses a named value out of the Cookie header" {
    var ctx = RequestCtx{ .method = .GET, .path = "/", .allocator = std.testing.allocator, .cookie_header = "a=1; zb_auth=tok123; b=2" };
    try std.testing.expectEqualStrings("tok123", ctx.cookie("zb_auth").?);
    try std.testing.expectEqualStrings("1", ctx.cookie("a").?);
    try std.testing.expect(ctx.cookie("missing") == null);
    var empty = RequestCtx{ .method = .GET, .path = "/", .allocator = std.testing.allocator, .cookie_header = "" };
    try std.testing.expect(empty.cookie("zb_auth") == null);
}
