const std = @import("std");
const zap = @import("zap");
const http = @import("http.zig");
const app_mod = @import("app.zig");
const router = @import("router.zig");
const health = @import("api/health.zig");
const collections_api = @import("api/collections.zig");
const records_api = @import("api/records.zig");
const auth_api = @import("api/auth.zig");
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
    .{ .method = .GET, .pattern = "/api/collections/:col/oauth2-providers", .handler = oauth_api.oauth2Providers },
    .{ .method = .POST, .pattern = "/api/collections/:col/auth-with-oauth2", .handler = oauth_api.authWithOAuth2 },
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

/// Best-effort client IP from reverse-proxy headers, for rate-limit keying.
/// Prefers the first hop of `X-Forwarded-For` (the original client), then
/// `X-Real-IP`. Returns "" when neither header is present (direct connection /
/// no proxy); the limiter then falls back to keying on the submitted identity.
fn clientIp(r: zap.Request) []const u8 {
    if (r.getHeader("x-forwarded-for")) |xff| {
        // "client, proxy1, proxy2" — take the first, trimmed.
        const first = if (std.mem.indexOfScalar(u8, xff, ',')) |c| xff[0..c] else xff;
        const trimmed = std.mem.trim(u8, first, " \t");
        if (trimmed.len > 0) return trimmed;
    }
    if (r.getHeader("x-real-ip")) |xri| {
        const trimmed = std.mem.trim(u8, xri, " \t");
        if (trimmed.len > 0) return trimmed;
    }
    return "";
}

fn setZapStatus(r: zap.Request, status: u16) void {
    const code: zap.http.StatusCode = switch (status) {
        200 => .ok,
        201 => .created,
        204 => .no_content,
        304 => .not_modified,
        400 => .bad_request,
        403 => .forbidden,
        404 => .not_found,
        409 => .conflict,
        422 => .unprocessable_content,
        429 => .too_many_requests,
        else => .internal_server_error,
    };
    r.setStatus(code);
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
    // Best-effort client IP for rate limiting. zap (0.10.6) exposes no peer-address
    // accessor on Request, so we trust the reverse-proxy hop headers: the FIRST hop in
    // X-Forwarded-For (the original client), else X-Real-IP. "" when neither is present.
    ctx.remote_ip = clientIp(r);
    if (std.mem.startsWith(u8, ctx.content_type, "multipart/form-data")) {
        // Hand-rolled parser over the raw body: facil.io's param parsing type-guesses
        // multipart values (text "123" -> int), so it must never see this body.
        if (files_multipart.parse(arena.allocator(), ctx.content_type, ctx.body)) |ex| {
            ctx.form_fields = ex.form_fields;
            ctx.files = ex.files;
        } else |_| {}
    }
    const resp = blk: {
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
