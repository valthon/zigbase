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
    /// Best-effort client IP for rate limiting (filled by server.zig from
    /// X-Forwarded-For / X-Real-IP). "" when unknown (no proxy header); the
    /// limiter then falls back to keying on the submitted identity.
    remote_ip: []const u8 = "",
    /// User-Agent header (filled by server.zig; "" when absent). Recorded on a Variant B
    /// `_sessions` row (#99) so the per-device session UI can label each session.
    user_agent: []const u8 = "",
    /// Request content-type (filled by server.zig). Multipart bodies populate form_fields/files.
    content_type: []const u8 = "",
    /// If-None-Match request header value (filled by server.zig; "" when absent).
    if_none_match: []const u8 = "",
    form_fields: ?std.json.Value = null,
    files: []const UploadedFile = &.{},
    /// Generic request headers for the route-guard `.header` source (#139). Unit tests set
    /// this list directly; in production `server.zig` wires `raw_header_fn`/`raw_header_ctx`
    /// to the live request instead (the HTTP server exposes lookup-by-name, not iteration).
    /// `header(name)` consults the live lookup first, then this list.
    headers: []const Param = &.{},
    /// Opaque pointer to the live request, passed to `raw_header_fn`. Set by `server.zig`.
    raw_header_ctx: ?*anyopaque = null,
    /// Live header lookup-by-name (lowercase), wired by `server.zig` from the HTTP request.
    raw_header_fn: ?*const fn (*anyopaque, []const u8) ?[]const u8 = null,
    /// Live request-header SETTER (lowercase name), wired by server.zig onto facil.io's
    /// request-header hash (replace semantics — fiobj_hash_set frees the old value).
    /// Used by the static Range-normalization shim (§A.2) to rewrite the request's
    /// Range header into the one form the vendored facil.io parses correctly, BEFORE
    /// delegating to facil.io's sendFile. No-op when unwired (unit tests stub it).
    raw_header_set_fn: ?*const fn (*anyopaque, name: []const u8, value: []const u8) void = null,

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

    /// The value of an arbitrary request header `name` (case-insensitive), or null. Consults
    /// the live server lookup (`raw_header_fn`) first, then the `headers` list (unit tests).
    /// Used by the `path_secret` route guard's `.header` source.
    pub fn header(self: *const RequestCtx, name: []const u8) ?[]const u8 {
        if (self.raw_header_fn) |f| {
            if (self.raw_header_ctx) |ctx| {
                if (f(ctx, name)) |v| return v;
            }
        }
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.key, name)) return h.value;
        }
        return null;
    }

    /// Replace a request header on the live request (see raw_header_set_fn). No-op
    /// when no live request is wired.
    pub fn setRequestHeader(self: *const RequestCtx, name: []const u8, value: []const u8) void {
        const ctx = self.raw_header_ctx orelse return;
        if (self.raw_header_set_fn) |f| f(ctx, name, value);
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
    /// Cookie `Domain` attribute. null (the default) scopes the cookie to the exact
    /// host that set it (no `Domain=` emitted); set it to share a cookie across
    /// subdomains (e.g. ".example.com").
    domain: ?[]const u8 = null,
};

pub const Header = struct { name: []const u8, value: []const u8 };

/// A file part from a multipart/form-data upload. `bytes` lives in the request arena.
pub const UploadedFile = struct {
    field: []const u8,
    filename: []const u8, // client-supplied original (untrusted)
    mimetype: []const u8, // client-supplied (untrusted; advisory)
    bytes: []const u8,
};

/// A filesystem file reference for `Response.file`: a full file or a byte window of one.
pub const FileRef = struct {
    path: []const u8,
    offset: u64 = 0,
    len: ?u64 = null,
};

pub const Response = struct {
    status: u16,
    content_type: []const u8 = "application/json",
    body: []const u8, // allocated in the request arena
    cookies: []const Cookie = &.{},
    /// A filesystem file (or a byte window of one) to stream instead of `body`.
    /// `len == null` => server.zig DELEGATES wholesale to facil.io's sendFile
    /// (http_sendfile2: stat, mime, ETag, 304, `.gz` sidecar, Range — dir-mode
    /// static rides this). `len != null` => the ZigBase-OWNED path (§B): the
    /// handler has already planned status + headers; server.zig opens the path
    /// and transmits `[offset, offset+len)` through facil.io's public
    /// `http_sendfile(h, fd, len, offset)` fd primitive — the same call
    /// http_sendfile2 itself finishes through. 0.10.0, Breaking: replaces
    /// `Response.file_path` (migrate `.file_path = p` -> `.file = .{ .path = p }`).
    file: ?FileRef = null,
    extra_headers: []const Header = &.{},
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

test "Response file ref and UploadedFile default/usage" {
    const r = Response{ .status = 200, .body = "", .file = .{ .path = "/x/y.png" } };
    try std.testing.expectEqualStrings("/x/y.png", r.file.?.path);
    try std.testing.expect(r.file.?.len == null); // default: wholesale facil.io delegation
    const ranged = Response{ .status = 206, .body = "", .file = .{ .path = "/x/y.png", .offset = 10, .len = 5 } };
    try std.testing.expectEqual(@as(u64, 10), ranged.file.?.offset);
    const u = UploadedFile{ .field = "cover", .filename = "a.png", .mimetype = "image/png", .bytes = "x" };
    try std.testing.expectEqualStrings("cover", u.field);
    const ctx = RequestCtx{ .method = .POST, .path = "/", .allocator = std.testing.allocator };
    try std.testing.expect(ctx.files.len == 0 and ctx.form_fields == null);
}
