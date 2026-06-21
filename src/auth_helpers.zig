/// zigbase.auth — curated consumer-facing helper surface for building magic-link
/// login flows. Each function delegates to the internal api/auth.zig implementation
/// so consumers never touch raw JWT/DB internals.
const std = @import("std");
const http = @import("http.zig");
const db = @import("db.zig");
const jwt = @import("jwt.zig");
const api_auth = @import("api/auth.zig");
const collections = @import("collections.zig");
const app_mod = @import("app.zig");

// ---- Re-exports ----------------------------------------------------------------

pub const Issued = api_auth.Issued;

// ---- Types ---------------------------------------------------------------------

pub const LinkToken = struct { token: []const u8 };

/// Callback type for a custom rate-limit function (optional; not used by the
/// built-in `rateLimit` wrapper, but exported so consumers can type their own hook).
pub const RateLimitFn = *const fn (ctx: *http.RequestCtx, scope: []const u8, ident: []const u8) bool;

// ---- Session -------------------------------------------------------------------

/// Issue a session for a record. Uses `.custom` as the auth-method tag, which is
/// appropriate for magic-link and other custom flows. Returns the signed JWT + 2
/// cookies (zb_auth, zb_csrf). `conn` must be an already-acquired DB connection.
pub fn issueSession(
    ctx: *http.RequestCtx,
    conn: *db.Db,
    collection: []const u8,
    record_id: []const u8,
) !Issued {
    return api_auth.issueSession(ctx, conn, collection, record_id, .custom);
}

// ---- Link-token lifecycle ------------------------------------------------------

/// Mint a single-use verification token for `record_id` in `collection` with the
/// given TTL in seconds. The token carries a random `jti` so it can only be consumed
/// once via `consumeLinkToken`.
pub fn mintLinkToken(
    ctx: *http.RequestCtx,
    conn: *db.Db,
    collection: []const u8,
    record_id: []const u8,
    ttl_s: i64,
) !LinkToken {
    const tk = (try api_auth.tokenKeyFor(ctx.allocator, conn, collection, record_id)) orelse
        return error.NotFound;
    const token = try api_auth.mintToken(ctx, conn, collection, record_id, tk, .magic_link, ttl_s);
    return .{ .token = token };
}

/// Verify a magic-link token. Returns the verified claims on success, null on
/// invalid/expired token. Does NOT consume it — call `consumeLinkToken` after.
pub fn verifyLinkToken(
    ctx: *http.RequestCtx,
    conn: *db.Db,
    collection: []const u8,
    token: []const u8,
) !?jwt.Claims {
    const col = (try collections.get(ctx.allocator, conn, collection)) orelse return null;
    return api_auth.verifyTyped(ctx, conn, col, token, .magic_link);
}

/// Mark the token identified by `claims.jti` as consumed. Returns
/// `error.AlreadyConsumed` if the token has already been redeemed (replay guard).
/// Must be called under the DB writer lock (i.e. with an acquired writer).
pub fn consumeLinkToken(conn: *db.Db, claims: jwt.Claims) !void {
    return api_auth.consumeToken(conn, claims);
}

// ---- Mail delivery -------------------------------------------------------------

/// Deliver an auth-related email (magic link, reset link, etc.) via the app's
/// configured mailer. Falls back to a log line when no mailer is wired (CI/tests).
pub fn deliverAuthMail(
    app: *app_mod.App,
    alloc: std.mem.Allocator,
    to: []const u8,
    subject: []const u8,
    body: []const u8,
) !void {
    return api_auth.deliverToken(app, alloc, to, subject, body);
}

// ---- Rate limiting -------------------------------------------------------------

/// Apply the app's rate limiter for a sensitive auth endpoint. Returns a pre-built
/// 429 `http.Response` when the request should be rejected, otherwise null (proceed).
/// `scope` is a short endpoint tag ("login"/"reset"/"verify"/…).
pub fn rateLimit(
    ctx: *http.RequestCtx,
    scope: []const u8,
    ident: []const u8,
) !?http.Response {
    return api_auth.rateLimited(ctx, scope, ident);
}

// ---- Tests ---------------------------------------------------------------------

test "magic-link helpers: mint -> verify -> consume; replay rejected" {
    var h = try api_auth.TestEnv.initAuth("members");
    defer h.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try h.createUser(a, "members", "m@x.io", "longenough");

    const w = h.pool.acquireWriter();
    defer h.pool.releaseWriter();
    const col = (try collections.get(a, w, "members")).?;
    const rid = (try api_auth.findByIdentity(a, w, col, "m@x.io")).?;

    var ctx = h.ctx(a, .POST, "", &[_]http.Param{});
    const lt = try mintLinkToken(&ctx, w, "members", rid, 900);
    const claims = (try verifyLinkToken(&ctx, w, "members", lt.token)).?;
    try consumeLinkToken(w, claims);
    try std.testing.expectError(error.AlreadyConsumed, consumeLinkToken(w, claims));

    const issued = try issueSession(&ctx, w, "members", rid);
    try std.testing.expect(issued.cookies.len == 2);
}

test "magic-link token type is distinct: email-verification token rejected by verifyLinkToken" {
    // TDD: write test FIRST. Pre-fix this test FAILS because mintToken(.verification)
    // produces the same type=.verification as verifyLinkToken checks, so a
    // verification token IS accepted. Post-fix (with .magic_link), it returns null.
    var h = try api_auth.TestEnv.initAuth("members");
    defer h.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try h.createUser(a, "members", "ml@x.io", "longenough");

    const w = h.pool.acquireWriter();
    defer h.pool.releaseWriter();
    const col = (try collections.get(a, w, "members")).?;
    const rid = (try api_auth.findByIdentity(a, w, col, "ml@x.io")).?;

    var ctx = h.ctx(a, .POST, "", &[_]http.Param{});

    // Mint a standard EMAIL-VERIFICATION token (type=.verification).
    const ver_token = try api_auth.mintToken(&ctx, w, "members", rid,
        (try api_auth.tokenKeyFor(a, w, "members", rid)).?, .verification, 900);

    // verifyLinkToken must REJECT it (null) — cross-type security boundary.
    const result = try verifyLinkToken(&ctx, w, "members", ver_token);
    try std.testing.expectEqual(@as(?jwt.Claims, null), result);

    // Happy path: a token minted by mintLinkToken IS accepted by verifyLinkToken.
    const lt = try mintLinkToken(&ctx, w, "members", rid, 900);
    const ok = try verifyLinkToken(&ctx, w, "members", lt.token);
    try std.testing.expect(ok != null);
}
