//! Shared request-body plumbing for the JSON API handlers.
//!
//! `parseBody` / `strField` / `jsonResponse` were copy-pasted across the auth-adjacent
//! handlers (`api/auth.zig`, `api/oauth.zig`, …) (#47); this is the single home so a
//! body-parsing policy change (a size limit, a duplicate-key policy) lands in one place
//! instead of drifting between copies.

const std = @import("std");
const http = @import("../http.zig");

/// Parse the request body as a JSON object, or null when it is absent / malformed / not an
/// object. The parsed value is owned by `ctx.allocator` (the request arena).
pub fn parseBody(ctx: *http.RequestCtx) ?std.json.Value {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator.a, ctx.body, .{}) catch return null;
    if (parsed.value != .object) return null;
    return parsed.value;
}

/// The string value of `key` in a JSON object, or null when the key is absent or not a string.
pub fn strField(obj: std.json.Value, key: []const u8) ?[]const u8 {
    const v = obj.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// A JSON response with an explicit status + cookies; the body is stringified onto
/// `ctx.allocator`.
pub fn jsonResponse(ctx: *http.RequestCtx, status: u16, v: std.json.Value, cookies: []const http.Cookie) !http.Response {
    return .{ .status = status, .body = try std.json.Stringify.valueAlloc(ctx.allocator.a, v, .{}), .cookies = cookies };
}
