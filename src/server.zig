const std = @import("std");
const zap = @import("zap");
const http = @import("http.zig");
const app_mod = @import("app.zig");
const router = @import("router.zig");
const health = @import("api/health.zig");
const collections_api = @import("api/collections.zig");
const records_api = @import("api/records.zig");
const auth_api = @import("api/auth.zig");
const ApiError = @import("api/error.zig").ApiError;

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
};

pub const Server = struct {
    app: *app_mod.App,
    host: [:0]const u8,
    port: u16,

    var instance: ?*Server = null;

    pub fn listen(self: *Server) !void {
        instance = self;
        var listener = zap.HttpListener.init(.{ .port = self.port, .on_request = onRequest, .log = false });
        try listener.listen();
        std.log.info("zigbase listening on http://{s}:{d}", .{ self.host, self.port });
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

fn setZapStatus(r: zap.Request, status: u16) void {
    const code: zap.http.StatusCode = switch (status) {
        200 => .ok,
        201 => .created,
        204 => .no_content,
        400 => .bad_request,
        403 => .forbidden,
        404 => .not_found,
        409 => .conflict,
        422 => .unprocessable_content,
        else => .internal_server_error,
    };
    r.setStatus(code);
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
    const resp = router.dispatch(&routes, &ctx) catch
        ApiError.internal().toResponse(arena.allocator()) catch {
            setZapStatus(r, 500);
            r.setContentType(.JSON) catch {};
            r.sendBody("{\"code\":500,\"message\":\"Something went wrong.\",\"data\":{}}") catch {};
            return;
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
    r.setContentType(.JSON) catch {};
    r.sendBody(resp.body) catch {};
}
