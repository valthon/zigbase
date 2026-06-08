const std = @import("std");
const zap = @import("zap");
const http = @import("http.zig");
const db = @import("db.zig");
const health = @import("api/health.zig");
const ApiError = @import("api/error.zig").ApiError;

pub const Server = struct {
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    host: [:0]const u8,
    port: u16,

    /// Single-process (workers=1) makes this global pointer safe to share
    /// across zap's worker threads.
    var instance: ?*Server = null;

    pub fn listen(self: *Server) !void {
        instance = self;
        var listener = zap.HttpListener.init(.{
            .port = self.port,
            .on_request = onRequest,
            .log = false,
        });
        try listener.listen();
        std.log.info("zigbase listening on http://{s}:{d}", .{ self.host, self.port });
        zap.start(.{ .threads = 4, .workers = 1 });
    }

    /// Pure routing over a RequestCtx. Independent of zap.
    pub fn route(ctx: *http.RequestCtx) !http.Response {
        if (ctx.method == .GET and std.mem.eql(u8, ctx.path, "/api/health"))
            return health.handle(ctx);
        return ApiError.notFound().toResponse(ctx.allocator);
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
        404 => .not_found,
        else => .internal_server_error,
    };
    r.setStatus(code);
}

fn onRequest(r: zap.Request) !void {
    const self = Server.instance.?;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    var ctx = http.RequestCtx{
        .method = methodFromZap(r),
        .path = r.path orelse "/",
        .query = r.query orelse "",
        .body = r.body orelse "",
        .allocator = arena.allocator(),
    };

    const resp = Server.route(&ctx) catch
        ApiError.internal().toResponse(arena.allocator()) catch {
            setZapStatus(r, 500);
            r.setContentType(.JSON) catch {};
            r.sendBody("{\"code\":500,\"message\":\"Something went wrong.\",\"data\":{}}") catch {};
            return;
        };

    setZapStatus(r, resp.status);
    r.setContentType(.JSON) catch {};
    r.sendBody(resp.body) catch {};
}
