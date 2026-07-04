//! GET /api/mail/config — superuser-only, read-only mail policy state for the admin UI.
//! Booleans only; never exposes the webhook secret or the unsubscribe URL value.
const std = @import("std");
const http = @import("../http.zig");
const auth = @import("../auth.zig");
const ApiError = @import("error.zig").ApiError;

pub fn get(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app orelse return ApiError.notFound().toResponse(ctx.allocator);
    var r = try app.pool.acquireReader();
    defer app.pool.releaseReader(&r);
    const a = (auth.authenticate(app.io, ctx.allocator, app, ctx, &r) catch null) orelse
        return (ApiError{ .status = 401, .message = "Authentication required." }).toResponse(ctx.allocator);
    if (!a.is_superuser)
        return (ApiError{ .status = 403, .message = "Superuser only." }).toResponse(ctx.allocator);

    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator, "require_verified_sender", .{ .bool = app.mail.require_verified_sender });
    try root.put(ctx.allocator, "check_suppression", .{ .bool = app.mail.check_suppression });
    try root.put(ctx.allocator, "webhook_configured", .{ .bool = app.mail.webhook_secret.len > 0 });
    try root.put(ctx.allocator, "unsubscribe_configured", .{ .bool = app.mail.unsubscribe_base_url.len > 0 });
    return .{
        .status = 200,
        .content_type = "application/json",
        .body = try std.json.Stringify.valueAlloc(ctx.allocator, std.json.Value{ .object = root }, .{}),
    };
}

test "mail config reports booleans from app.mail" {
    // Confirm the mapping compiles and the field names match app.mail (mail_cfg.Runtime).
    // A full request test runs in tests/admin/test_email.py; this pins the field names.
    const cfg = @import("../mail/config.zig").Runtime{ .check_suppression = true };
    try std.testing.expect(cfg.check_suppression);
    try std.testing.expect(!cfg.require_verified_sender);
}
