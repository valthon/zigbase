//! Account activation endpoint (multi-tenancy, #156, PR2).
//!
//! `POST /api/accounts/:id/activate` (mounted in server.zig). For BROWSER apps it sets a signed
//! `zb_account` cookie so subsequent requests carry the active account without re-sending the
//! `X-Account-Id` header. API clients can skip this and just send `X-Account-Id`.
//!
//! Activation FAILS CLOSED: the authenticated principal must have an `active` membership of the
//! requested account (verified by the same `tenancy.resolve` path the per-request resolver uses),
//! else 403 — no cookie is set. Membership lifecycle (invite/accept/remove) is PR4.

const std = @import("std");
const http = @import("../http.zig");
const app_mod = @import("../app.zig");
const auth = @import("../auth.zig");
const tenancy = @import("../tenancy/tenancy.zig");
const ApiError = @import("error.zig").ApiError;

/// POST /api/accounts/:id/activate — verify membership, set the `zb_account` cookie, return scope.
pub fn activate(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    if (!app.tenancy.enabled) return ApiError.notFound().toResponse(ctx.allocator.a);

    const account_id = ctx.param("id") orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    if (account_id.len == 0) return ApiError.notFound().toResponse(ctx.allocator.a);

    var r = try app.pool.acquireReader();
    defer app.pool.releaseReader(&r);

    const a = (auth.authenticate(app.io, ctx.allocator.a, app, ctx, &r) catch null) orelse
        return ApiError.withCode(401, .unauthorized, "Authentication required.").toResponse(ctx.allocator.a);
    // Superusers are not account members; they operate cross-tenant and don't activate a scope.
    if (a.is_superuser) return forbidden(ctx);
    if (a.record != .object) return forbidden(ctx);
    const id_v = a.record.object.get("id") orelse return forbidden(ctx);
    if (id_v != .string) return forbidden(ctx);

    // Verify an ACTIVE membership of the requested account (fail closed): resolve returns a
    // matching account_id only when such a membership exists.
    const res = try tenancy.resolve(ctx.allocator.a, &r, a.collection, id_v.string, account_id);
    if (res.account_id.len == 0) return forbidden(ctx);

    // Set the signed, HttpOnly `zb_account` cookie so browser requests carry the active account.
    const signed = try tenancy.signAccount(ctx.allocator.a, app.jwt_secret, res.account_id);
    const cookie = http.Cookie{
        .name = tenancy.account_cookie,
        .value = signed,
        .max_age_s = @intCast(@min(app.auth_token_ttl_s, std.math.maxInt(i32))),
        .http_only = true,
        .secure = app.cookie_secure,
        .same_site = .strict,
        .path = "/",
    };
    const cookies = try ctx.allocator.a.dupe(http.Cookie, &.{cookie});

    var obj: std.json.ObjectMap = .empty;
    try obj.put(ctx.allocator.a, "account", .{ .string = res.account_id });
    try obj.put(ctx.allocator.a, "role", .{ .string = res.account_role });
    return .{
        .status = 200,
        .body = try std.json.Stringify.valueAlloc(ctx.allocator.a, std.json.Value{ .object = obj }, .{}),
        .cookies = cookies,
    };
}

fn forbidden(ctx: *http.RequestCtx) !http.Response {
    return ApiError.withCode(403, .forbidden, "Not a member of this account.").toResponse(ctx.allocator.a);
}
