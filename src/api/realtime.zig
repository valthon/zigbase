//! POST /api/realtime/sse/:clientId — the SSE uplink (#188). The body is the SAME JSON verb
//! grammar the WS socket speaks (protocol.parseClient: auth/subscribe/unsubscribe); the
//! response body is the exact protocol frame WS would have written. One uplink protocol, two
//! framings. Error-frame outcomes return 200 deliberately — WS keeps the connection open and
//! replies a frame, and the SDK shares one frame-handling path across transports.
//! SECURITY: the clientId is a 32-char crypto-random capability delivered only on the
//! Origin-gated stream; no CORS headers are emitted; the auth token rides the body (never a
//! URL). Unknown, expired, and just-closed ids answer BYTE-IDENTICAL 404s (non-oracle).
const std = @import("std");
const http = @import("../http.zig");
const ApiError = @import("error.zig").ApiError;
const sse = @import("../realtime/sse.zig");

pub fn sseUplink(ctx: *http.RequestCtx) anyerror!http.Response {
    const cid = ctx.param("clientId") orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    const sc = sse.pin(cid) orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    defer sse.unref(sc);
    const reply = (try sse.handleUplink(sc, ctx.allocator, ctx.body)) orelse
        return ApiError.notFound().toResponse(ctx.allocator.a); // just-closed == unknown (non-oracle)
    return .{ .status = reply.status, .content_type = "application/json", .body = reply.frame };
}

test {
    // The verb/registry behavior is tested in realtime/sse.zig (pool-backed) and e2e in
    // tests/admin; this file is a thin non-oracle shell. Reference it so root.zig's test
    // discovery compiles it.
    std.testing.refAllDecls(@This());
}
