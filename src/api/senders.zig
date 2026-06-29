//! Verified per-account sender-identity routes (#154). Mounted in server.zig:
//!   POST /api/senders            — request verification of a From address for the active account
//!                                  (mints a token, EMAILS it to that address) → {id,email,status}.
//!   GET  /api/senders            — list the active account's sender identities.
//!   POST /api/senders/:id/verify — confirm a pending identity with its token → {verified:true}.
//!
//! TENANT-SCOPED + FAIL CLOSED. A non-superuser resolves the active account exactly like the record
//! API (`tenancy.resolve` over a verified `_memberships` row); without an active membership it is
//! 403 — a member can never manage another account's senders. A superuser may target any account via
//! the `X-Account-Id` header (or operate globally with account ""), per the superuser-bypass
//! precedent. The verification token is delivered by EMAIL (a system send that bypasses verified-
//! sender enforcement), never returned in the API response.

const std = @import("std");
const http = @import("../http.zig");
const app_mod = @import("../app.zig");
const auth = @import("../auth.zig");
const tenancy = @import("../tenancy/tenancy.zig");
const senders = @import("../mail/senders.zig");
const mail_send = @import("../mail/send.zig");
const ApiError = @import("error.zig").ApiError;
const db = @import("../db.zig");

/// The resolved account scope for a sender-management request.
const Scope = struct { account: []const u8, is_superuser: bool };

fn unauthorized(ctx: *http.RequestCtx) !http.Response {
    return (ApiError{ .status = 401, .message = "Authentication required." }).toResponse(ctx.allocator);
}
fn forbidden(ctx: *http.RequestCtx) !http.Response {
    return (ApiError{ .status = 403, .message = "Not a member of this account." }).toResponse(ctx.allocator);
}

/// The requested account id (X-Account-Id header, else the signed zb_account cookie).
fn requestedAccount(ctx: *http.RequestCtx, app: *app_mod.App) ?[]const u8 {
    if (ctx.header(tenancy.account_header)) |h| if (h.len > 0) return h;
    if (ctx.cookie(tenancy.account_cookie)) |c| if (c.len > 0) return tenancy.verifyAccount(app.jwt_secret, c);
    return null;
}

/// Resolve the account this request may manage senders for. Returns null + a stashed response on a
/// failure (401/403) that the caller should return.
fn resolveScope(ctx: *http.RequestCtx, app: *app_mod.App, reader: *db.Db, out: *?http.Response) !?Scope {
    const a = (auth.authenticate(app.io, ctx.allocator, app, ctx, reader) catch null) orelse {
        out.* = try unauthorized(ctx);
        return null;
    };
    if (a.is_superuser) {
        // Superuser may target a specific account (header) or operate globally ("").
        return Scope{ .account = requestedAccount(ctx, app) orelse "", .is_superuser = true };
    }
    // Regular principal: require tenancy + an ACTIVE membership of the requested account.
    if (!app.tenancy.enabled) {
        out.* = try forbidden(ctx);
        return null;
    }
    if (a.record != .object) {
        out.* = try forbidden(ctx);
        return null;
    }
    const id_v = a.record.object.get("id") orelse {
        out.* = try forbidden(ctx);
        return null;
    };
    if (id_v != .string) {
        out.* = try forbidden(ctx);
        return null;
    }
    const requested = requestedAccount(ctx, app) orelse "";
    const res = try tenancy.resolve(ctx.allocator, reader, a.collection, id_v.string, requested);
    if (res.account_id.len == 0) {
        out.* = try forbidden(ctx);
        return null;
    }
    return Scope{ .account = res.account_id, .is_superuser = false };
}

/// GET /api/senders — list the active account's sender identities.
pub fn list(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app orelse return ApiError.notFound().toResponse(ctx.allocator);
    var r = try app.pool.acquireReader();
    defer app.pool.releaseReader(&r);

    var early: ?http.Response = null;
    const scope = (try resolveScope(ctx, app, &r, &early)) orelse return early.?;

    const ids = try senders.listForAccount(ctx.allocator, &r, scope.account);
    var arr = std.json.Array.init(ctx.allocator);
    for (ids) |it| {
        var o: std.json.ObjectMap = .empty;
        try o.put(ctx.allocator, "id", .{ .string = it.id });
        try o.put(ctx.allocator, "email", .{ .string = it.email });
        try o.put(ctx.allocator, "status", .{ .string = it.status });
        try o.put(ctx.allocator, "verified_at", .{ .string = it.verified_at });
        try arr.append(.{ .object = o });
    }
    return .{
        .status = 200,
        .content_type = "application/json",
        .body = try std.json.Stringify.valueAlloc(ctx.allocator, std.json.Value{ .array = arr }, .{}),
    };
}

/// POST /api/senders {"email":"…"} — request verification (mints a token, emails it).
pub fn create(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app orelse return ApiError.notFound().toResponse(ctx.allocator);

    const email = blk: {
        const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.body, .{}) catch
            return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator);
        if (parsed.value != .object) return ApiError.badRequest("Expected a JSON object.").toResponse(ctx.allocator);
        const e = parsed.value.object.get("email") orelse return ApiError.badRequest("Missing 'email'.").toResponse(ctx.allocator);
        if (e != .string) return ApiError.badRequest("'email' must be a string.").toResponse(ctx.allocator);
        break :blk e.string;
    };

    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();

    var early: ?http.Response = null;
    const scope = (try resolveScope(ctx, app, w, &early)) orelse return early.?;

    const req = senders.requestVerification(app.io, ctx.allocator, w, scope.account, email) catch |e| switch (e) {
        error.InvalidSenderEmail => return ApiError.badRequest("Invalid sender email.").toResponse(ctx.allocator),
        // Rate-limited (I3): a (re)send was requested again within the window — do not re-issue/email.
        error.VerificationThrottled => return (ApiError{ .status = 429, .message = "Verification email already sent recently; try again later." }).toResponse(ctx.allocator),
        else => return e,
    };

    // Deliver the token to the (normalized) address being verified — a SYSTEM send (no account/from)
    // so it bypasses verified-sender enforcement (chicken-and-egg). Best-effort: a mail failure must
    // not lose the already-persisted pending identity, so we swallow it (the operator can re-request).
    if (!req.already_verified and req.token.len > 0) {
        const text = std.fmt.allocPrint(ctx.allocator, "Confirm you can send from {s} by submitting this token to /api/senders/{s}/verify:\n\n{s}\n", .{ req.email, req.id, req.token }) catch "";
        mail_send.send(app, ctx.allocator, .{
            .to = req.email,
            .subject = "Verify your sender address",
            .text = text,
        }) catch |e| std.log.warn("sender verification email to {s} failed: {s}", .{ req.email, @errorName(e) });
    }

    var o: std.json.ObjectMap = .empty;
    try o.put(ctx.allocator, "id", .{ .string = req.id });
    try o.put(ctx.allocator, "email", .{ .string = req.email });
    try o.put(ctx.allocator, "status", .{ .string = if (req.already_verified) senders.status_verified else senders.status_pending });
    return .{
        .status = if (req.already_verified) 200 else 201,
        .content_type = "application/json",
        .body = try std.json.Stringify.valueAlloc(ctx.allocator, std.json.Value{ .object = o }, .{}),
    };
}

/// POST /api/senders/:id/verify {"token":"…"} — confirm a pending identity.
pub fn verify(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app orelse return ApiError.notFound().toResponse(ctx.allocator);
    const identity_id = ctx.param("id") orelse return ApiError.notFound().toResponse(ctx.allocator);

    const token = blk: {
        const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.body, .{}) catch
            return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator);
        if (parsed.value != .object) return ApiError.badRequest("Expected a JSON object.").toResponse(ctx.allocator);
        const t = parsed.value.object.get("token") orelse return ApiError.badRequest("Missing 'token'.").toResponse(ctx.allocator);
        if (t != .string) return ApiError.badRequest("'token' must be a string.").toResponse(ctx.allocator);
        break :blk t.string;
    };

    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();

    var early: ?http.Response = null;
    const scope = (try resolveScope(ctx, app, w, &early)) orelse return early.?;

    const ok = try senders.confirm(ctx.allocator, w, scope.account, identity_id, token);
    if (!ok) {
        // Indistinguishable: wrong token, wrong account, or absent id all collapse to 404 (no oracle).
        return ApiError.notFound().toResponse(ctx.allocator);
    }
    var o: std.json.ObjectMap = .empty;
    try o.put(ctx.allocator, "verified", .{ .bool = true });
    return .{
        .status = 200,
        .content_type = "application/json",
        .body = try std.json.Stringify.valueAlloc(ctx.allocator, std.json.Value{ .object = o }, .{}),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "verify requires authentication (401 without auth)" {
    // Unauthenticated POST /api/senders/:id/verify → 401 (resolveScope fails closed). No DB writes
    // happen on this path, but resolveScope reads via the reader; build a real migrated pool.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ga = testing.allocator;
    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", ga);
    defer ga.free(dir_path);
    const db_path = try std.fmt.allocPrintSentinel(ga, "{s}/sapi.db", .{dir_path}, 0);
    defer ga.free(db_path);
    var pool = try db.Pool.init(ga, testing.io, db_path);
    defer pool.deinit();
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try @import("../migrations.zig").run(w);
    }
    // ctx.allocator is a request-scoped arena in production (freed wholesale); mirror that here so
    // the handler's body-parse / response-build allocations are reclaimed (no leak in the test).
    var arena = std.heap.ArenaAllocator.init(ga);
    defer arena.deinit();
    var app = app_mod.App{ .allocator = ga, .io = testing.io, .pool = &pool };
    var ctx = http.RequestCtx{
        .method = .POST,
        .path = "/api/senders/abc/verify",
        .allocator = arena.allocator(),
        .app = &app,
        .body = "{\"token\":\"x\"}",
        .params = &.{.{ .key = "id", .value = "abc" }},
    };
    const res = try verify(&ctx);
    try testing.expectEqual(@as(u16, 401), res.status);
}
