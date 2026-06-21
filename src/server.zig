const std = @import("std");
const zap = @import("zap");
const http = @import("http.zig");
const app_mod = @import("app.zig");
const router = @import("router.zig");
const health = @import("api/health.zig");
const collections_api = @import("api/collections.zig");
const records_api = @import("api/records.zig");
const auth_api = @import("api/auth.zig");
const auth_methods_api = @import("api/auth_methods.zig");
const webauthn_register_api = @import("api/webauthn_register.zig");
const oauth_api = @import("api/oauth.zig");
const files_api = @import("api/files.zig");
const realtime_ws = @import("realtime/ws.zig");
const files_multipart = @import("files/multipart.zig");
const admin = @import("admin.zig");
const static_files = @import("static_files.zig");
const ApiError = @import("api/error.zig").ApiError;
const auth = @import("auth.zig");
const events = @import("events.zig");
const request = @import("request.zig");

fn healthHandler(ctx: *http.RequestCtx) anyerror!http.Response {
    return health.handle(ctx);
}

const routes = [_]router.Route{
    .{ .method = .GET, .pattern = "/api/health", .handler = healthHandler },
    .{ .method = .GET, .pattern = "/api/collections", .handler = collections_api.list },
    .{ .method = .POST, .pattern = "/api/collections", .handler = collections_api.create },
    .{ .method = .GET, .pattern = "/api/collections/:idOrName", .handler = collections_api.get },
    .{ .method = .PATCH, .pattern = "/api/collections/:idOrName", .handler = collections_api.update },
    .{ .method = .DELETE, .pattern = "/api/collections/:idOrName", .handler = collections_api.delete },
    .{ .method = .GET, .pattern = "/api/collections/:col/records", .handler = records_api.list },
    .{ .method = .GET, .pattern = "/api/collections/:col/records/:id", .handler = records_api.view },
    .{ .method = .POST, .pattern = "/api/collections/:col/records", .handler = records_api.create },
    .{ .method = .PATCH, .pattern = "/api/collections/:col/records/:id", .handler = records_api.update },
    .{ .method = .DELETE, .pattern = "/api/collections/:col/records/:id", .handler = records_api.delete },
    .{ .method = .POST, .pattern = "/api/collections/:col/auth-with-password", .handler = auth_api.authWithPassword },
    .{ .method = .POST, .pattern = "/api/collections/:col/auth-refresh", .handler = auth_api.authRefresh },
    .{ .method = .POST, .pattern = "/api/collections/:col/auth-logout", .handler = auth_api.authLogout },
    .{ .method = .POST, .pattern = "/api/collections/:col/request-verification", .handler = auth_api.requestVerification },
    .{ .method = .POST, .pattern = "/api/collections/:col/confirm-verification", .handler = auth_api.confirmVerification },
    .{ .method = .POST, .pattern = "/api/collections/:col/request-password-reset", .handler = auth_api.requestPasswordReset },
    .{ .method = .POST, .pattern = "/api/collections/:col/confirm-password-reset", .handler = auth_api.confirmPasswordReset },
    .{ .method = .POST, .pattern = "/api/collections/:col/auth/:method/initiate", .handler = auth_methods_api.initiate },
    .{ .method = .POST, .pattern = "/api/collections/:col/auth/:method/complete", .handler = auth_methods_api.complete },
    .{ .method = .POST, .pattern = "/api/collections/:col/auth/webauthn/register/begin", .handler = webauthn_register_api.begin },
    .{ .method = .POST, .pattern = "/api/collections/:col/auth/webauthn/register/finish", .handler = webauthn_register_api.finish },
    .{ .method = .GET, .pattern = "/api/collections/:col/auth/oauth2/providers", .handler = oauth_api.oauth2Providers },
    .{ .method = .DELETE, .pattern = "/api/collections/:col/records/:id/external-auths/:provider", .handler = oauth_api.unlinkProvider },
    .{ .method = .GET, .pattern = "/api/files/:col/:rec/:name", .handler = files_api.serve },
    .{ .method = .POST, .pattern = "/api/files/token", .handler = files_api.token },
};

pub const Server = struct {
    app: *app_mod.App,
    host: [:0]const u8,
    port: u16,

    pub var instance: ?*Server = null;

    pub fn listen(self: *Server) !void {
        instance = self;
        var listener = zap.HttpListener.init(.{ .port = self.port, .on_request = onRequest, .on_upgrade = realtime_ws.handleUpgrade, .log = false, .max_body_size = @intCast(self.app.max_upload_size) });
        try listener.listen();
        std.log.info("zigbase listening on http://{s}:{d}", .{ self.host, self.port });
        realtime_ws.active = true; // reactor about to run; allow broadcast to publish
        zap.start(.{ .threads = 4, .workers = 1 });
    }
};

fn methodFromZap(r: zap.Request) http.Method {
    return switch (r.methodAsEnum()) {
        .GET => .GET,
        .POST => .POST,
        .PUT => .PUT,
        .PATCH => .PATCH,
        .DELETE => .DELETE,
        .OPTIONS => .OPTIONS,
        .HEAD => .HEAD,
        else => .UNKNOWN,
    };
}

/// Pure core of client-IP resolution (F8), testable without a zap.Request.
/// `X-Forwarded-For`/`X-Real-IP` are attacker-controlled on direct exposure, so
/// they are honored ONLY when `trust_proxy` is true. Returns "" when proxy headers
/// are not trusted or absent; the limiter then keys on the submitted identity (still
/// useful, and never spoofable via a forged header).
fn clientIpFrom(trust_proxy: bool, xff: ?[]const u8, xri: ?[]const u8) []const u8 {
    if (!trust_proxy) return "";
    if (xff) |v| {
        // "client, proxy1, proxy2" — take the first, trimmed.
        const first = if (std.mem.indexOfScalar(u8, v, ',')) |c| v[0..c] else v;
        const trimmed = std.mem.trim(u8, first, " \t");
        if (trimmed.len > 0) return trimmed;
    }
    if (xri) |v| {
        const trimmed = std.mem.trim(u8, v, " \t");
        if (trimmed.len > 0) return trimmed;
    }
    return "";
}

/// Client IP for rate-limit keying. zap 0.10.6 exposes no socket-peer accessor on
/// Request, so proxy headers are the only source — and they're trusted only when
/// `trust_proxy` is set (see `clientIpFrom`).
fn clientIp(r: zap.Request, trust_proxy: bool) []const u8 {
    return clientIpFrom(trust_proxy, r.getHeader("x-forwarded-for"), r.getHeader("x-real-ip"));
}

test "clientIpFrom ignores X-Forwarded-For/X-Real-IP unless trust_proxy is set (F8)" {
    // Default (untrusted): spoofable headers are ignored entirely.
    try std.testing.expectEqualStrings("", clientIpFrom(false, "1.2.3.4", null));
    try std.testing.expectEqualStrings("", clientIpFrom(false, "1.2.3.4, 5.6.7.8", "9.9.9.9"));
    try std.testing.expectEqualStrings("", clientIpFrom(false, null, "9.9.9.9"));
    // Trusted proxy: first XFF hop wins, else X-Real-IP, else "".
    try std.testing.expectEqualStrings("1.2.3.4", clientIpFrom(true, "1.2.3.4, 5.6.7.8", "9.9.9.9"));
    try std.testing.expectEqualStrings("9.9.9.9", clientIpFrom(true, null, "9.9.9.9"));
    try std.testing.expectEqualStrings("1.2.3.4", clientIpFrom(true, " 1.2.3.4 ", null));
    try std.testing.expectEqualStrings("", clientIpFrom(true, null, null));
}

/// Map an HTTP status code to zap's `StatusCode` enum.
///
/// `zap.http.StatusCode` is non-exhaustive, so `std.enums.fromInt`/`std.meta.intToEnum`
/// would pass *any* integer straight through (or, for the latter, no longer exists in
/// Zig 0.16). Instead we match `status` against the enum's *named* fields, so every
/// standard code zap defines is recognized — not a hand-maintained subset that silently
/// turns omitted-but-valid codes (e.g. 401 auth rejections, 307 magic-link redirects,
/// 405, 415) into 500s. Anything zap doesn't name falls back to 500.
fn statusToCode(status: u16) zap.http.StatusCode {
    inline for (std.meta.fields(zap.http.StatusCode)) |field| {
        if (field.value == status) return @field(zap.http.StatusCode, field.name);
    }
    return .internal_server_error;
}

test "statusToCode maps named codes and falls back to 500 for unknown" {
    try std.testing.expectEqual(zap.http.StatusCode.ok, statusToCode(200));
    // Previously omitted from the manual map -> regression guard.
    try std.testing.expectEqual(zap.http.StatusCode.unauthorized, statusToCode(401));
    try std.testing.expectEqual(zap.http.StatusCode.temporary_redirect, statusToCode(307));
    try std.testing.expectEqual(zap.http.StatusCode.gone, statusToCode(410));
    try std.testing.expectEqual(zap.http.StatusCode.bad_gateway, statusToCode(502));
    // Codes the manual list never had but zap names are now handled too.
    try std.testing.expectEqual(zap.http.StatusCode.method_not_allowed, statusToCode(405));
    try std.testing.expectEqual(zap.http.StatusCode.unsupported_media_type, statusToCode(415));
    // Genuinely unknown codes fall back to a safe 500.
    try std.testing.expectEqual(zap.http.StatusCode.internal_server_error, statusToCode(799));
}

fn setZapStatus(r: zap.Request, status: u16) void {
    r.setStatus(statusToCode(status));
}

fn forbiddenResp(ctx: *http.RequestCtx) !http.Response {
    return (ApiError{ .status = 403, .message = "Forbidden." }).toResponse(ctx.allocator);
}

/// Try the consumer's custom routes (after built-ins). Resolves auth on a fresh reader,
/// enforces the route's AuthLevel, then calls the handler. Returns null if no custom route
/// matches the path+method. A handler error routes to the error backstop and yields 500.
fn dispatchCustom(ctx: *http.RequestCtx) anyerror!?http.Response {
    const app = ctx.app orelse return null;
    const d = app.dispatch orelse return null;
    if (d.routes.len == 0) return null;
    for (d.routes) |rt| {
        if (rt.method != ctx.method) continue;
        if (try router.matchPath(ctx.allocator, rt.pattern, ctx.path)) |params| {
            ctx.params = params;
            // Resolve auth on a fresh read-only connection (never the writer lock).
            var reader = app.pool.acquireReader() catch return try ApiError.internal().toResponse(ctx.allocator);
            defer app.pool.releaseReader(&reader);
            const authed = auth.authenticate(app.io, ctx.allocator, app, ctx, &reader) catch null;
            switch (rt.auth) {
                .public => {},
                .authed => if (authed == null) return try (ApiError{ .status = 401, .message = "Not authenticated." }).toResponse(ctx.allocator),
                .superuser => if (authed == null or !authed.?.is_superuser) return try forbiddenResp(ctx),
            }
            var rctx = request.RequestContext{
                .auth = if (authed) |a| a.record else null,
                .is_superuser = if (authed) |a| a.is_superuser else false,
                .method = @tagName(ctx.method),
            };
            var ev = events.RouteEvent{ .app = app, .ctx = ctx, .rctx = rctx };
            return rt.handler(&ev) catch |e| {
                var err_ev = events.ErrorEvent{ .app = app, .ctx = &rctx, .err = e, .phase = .request, .message = @errorName(e) };
                events.dispatchError(app, app.dispatch, &err_ev);
                return try ApiError.internal().toResponse(ctx.allocator);
            };
        }
    }
    return null;
}

/// Parse a multipart/form-data body into ctx.form_fields/ctx.files.
/// Returns a 400 response for a malformed multipart body — handled here, at the
/// layer that owns body parsing, so every multipart endpoint (current and future)
/// gets the same clear error instead of falling through to the JSON parser's
/// misleading "Invalid JSON body.". OutOfMemory propagates; it must never
/// masquerade as a client error.
fn applyMultipart(ctx: *http.RequestCtx) error{OutOfMemory}!?http.Response {
    if (!std.mem.startsWith(u8, ctx.content_type, "multipart/form-data")) return null;
    // Hand-rolled parser over the raw body: facil.io's param parsing type-guesses
    // multipart values (text "123" -> int), so it must never see this body.
    const ex = files_multipart.parse(ctx.allocator, ctx.content_type, ctx.body) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadMultipart => return try ApiError.badRequest("Invalid multipart body.").toResponse(ctx.allocator),
    };
    ctx.form_fields = ex.form_fields;
    ctx.files = ex.files;
    return null;
}

test "applyMultipart: malformed multipart body -> 400 'Invalid multipart body.', not the JSON-body error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = http.RequestCtx{
        .method = .POST,
        .path = "/",
        .allocator = arena.allocator(),
        .content_type = "multipart/form-data; boundary=XB",
        .body = "--XB\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nv", // never terminated
    };
    const resp = (try applyMultipart(&ctx)).?;
    try std.testing.expectEqual(@as(u16, 400), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Invalid multipart body.") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Invalid JSON body.") == null);
    try std.testing.expect(ctx.form_fields == null);
}

test "applyMultipart: valid multipart populates ctx and returns null; non-multipart is a no-op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = http.RequestCtx{
        .method = .POST,
        .path = "/",
        .allocator = arena.allocator(),
        .content_type = "multipart/form-data; boundary=XB",
        .body = "--XB\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nv\r\n--XB--\r\n",
    };
    try std.testing.expect((try applyMultipart(&ctx)) == null);
    try std.testing.expectEqualStrings("v", ctx.form_fields.?.object.get("a").?.string);

    var jctx = http.RequestCtx{
        .method = .POST,
        .path = "/",
        .allocator = arena.allocator(),
        .content_type = "application/json",
        .body = "{}",
    };
    try std.testing.expect((try applyMultipart(&jctx)) == null);
    try std.testing.expect(jctx.form_fields == null);
}

/// Last-resort raw error envelope, used only when even building the normal ApiError
/// response fails (allocation failure). Sends a fixed JSON body bypassing the arena.
fn sendRawEnvelope(r: zap.Request, status: u16, body: []const u8) void {
    setZapStatus(r, status);
    r.setContentType(.JSON) catch {};
    r.sendBody(body) catch {};
}

fn onRequest(r: zap.Request) !void {
    const self = Server.instance.?;
    var arena = std.heap.ArenaAllocator.init(self.app.allocator);
    defer arena.deinit();
    var ctx = http.RequestCtx{
        .method = methodFromZap(r),
        .path = r.path orelse "/",
        .query = r.query orelse "",
        .body = r.body orelse "",
        .allocator = arena.allocator(),
        .app = self.app,
    };
    ctx.authorization = r.getHeader("authorization") orelse "";
    ctx.cookie_header = r.getHeader("cookie") orelse "";
    ctx.csrf_token = r.getHeader("x-csrf-token") orelse "";
    ctx.content_type = r.getHeader("content-type") orelse "";
    ctx.if_none_match = r.getHeader("if-none-match") orelse "";
    // Client IP for rate limiting (F8). Proxy hop headers (X-Forwarded-For / X-Real-IP)
    // are spoofable on direct exposure, so they are honored ONLY when trust_proxy is set.
    // Otherwise "" — the limiter keys on the submitted identity (never header-spoofable).
    ctx.remote_ip = clientIp(r, self.app.trust_proxy);
    const multipart_err = try applyMultipart(&ctx);
    const resp = blk: {
        if (multipart_err) |er| break :blk er;
        if (std.mem.startsWith(u8, ctx.path, "/_/") or std.mem.eql(u8, ctx.path, "/_"))
            break :blk admin.serve(&ctx);
        // Built-in API routes win over custom routes.
        const builtin = router.tryDispatch(&routes, &ctx) catch {
            break :blk ApiError.internal().toResponse(arena.allocator()) catch {
                sendRawEnvelope(r, 500, "{\"code\":500,\"message\":\"Something went wrong.\",\"data\":{}}");
                return;
            };
        };
        if (builtin) |hit| break :blk hit;
        if (dispatchCustom(&ctx) catch null) |hit| break :blk hit;
        // The whole /api namespace stays JSON — including the bare "/api" path
        // (mirrors the exact-"/_" handling in the admin guard above).
        if (std.meta.activeTag(self.app.static_source) != .none and
            (ctx.method == .GET or ctx.method == .HEAD) and
            !std.mem.startsWith(u8, ctx.path, "/api/") and
            !std.mem.eql(u8, ctx.path, "/api"))
        {
            if (static_files.serve(self.app.io, &ctx, self.app.static_source) catch null) |hit| break :blk hit;
            // Plain-text 404, deliberately NOT the JSON ApiError envelope: static misses are browser-facing, not API responses.
            break :blk http.Response{ .status = 404, .body = "not found", .content_type = "text/plain; charset=utf-8" };
        }
        break :blk ApiError.notFound().toResponse(arena.allocator()) catch {
            sendRawEnvelope(r, 500, "{\"code\":500,\"message\":\"Something went wrong.\",\"data\":{}}");
            return;
        };
    };
    setZapStatus(r, resp.status);
    for (resp.cookies) |c| {
        r.setCookie(.{
            .name = c.name,
            .value = c.value,
            .path = c.path,
            .max_age_s = @intCast(c.max_age_s),
            .secure = c.secure,
            .http_only = c.http_only,
            .same_site = switch (c.same_site) {
                .default => .Default,
                .lax => .Lax,
                .strict => .Strict,
                .none => .None,
            },
        }) catch {};
    }
    for (resp.extra_headers) |h| r.setHeader(h.name, h.value) catch {};
    if (resp.file_path) |path| {
        r.sendFile(path) catch {
            sendRawEnvelope(r, 404, "{\"code\":404,\"message\":\"Not found.\",\"data\":{}}");
        };
        return;
    }
    r.setHeader("content-type", resp.content_type) catch {};
    r.sendBody(resp.body) catch {};
}
