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
const Data = @import("data.zig").Data;

// ---- Re-exports ----------------------------------------------------------------

pub const Issued = api_auth.Issued;

// ---- Types ---------------------------------------------------------------------

pub const LinkToken = struct { token: []const u8 };

/// Options for `mintLinkToken`. `payload` is a small opaque string bound into the
/// signed token (the `pl` claim) and returned verbatim by `verifyLinkToken` as
/// `claims.pl`. Use it to carry tamper-proof state through the link — e.g. a
/// post-login redirect path — instead of an unsigned URL query param.
///
/// Size note: the payload is base64url-encoded inside the JWT payload, so keep it
/// small (a path, an id, a short opaque tag). It is signed but NOT encrypted — do not
/// put secrets in it; treat it as readable-but-tamper-proof, exactly like any other
/// claim.
pub const MintOptions = struct {
    payload: []const u8 = "",
};

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
///
/// `opts.payload` (default empty) attaches a small opaque, signed, tamper-proof
/// payload bound to the token's `jti`; `verifyLinkToken` returns it as `claims.pl`.
/// Use it to carry e.g. a post-login redirect target in the single token instead of an
/// unsigned `&next=` URL param. See `MintOptions` for the size/secrecy caveats.
pub fn mintLinkToken(
    ctx: *http.RequestCtx,
    conn: *db.Db,
    collection: []const u8,
    record_id: []const u8,
    ttl_s: i64,
    opts: MintOptions,
) !LinkToken {
    const tk = (try api_auth.tokenKeyFor(ctx.allocator, conn, collection, record_id)) orelse
        return error.NotFound;
    const token = try api_auth.mintToken(ctx, conn, collection, record_id, tk, .magic_link, ttl_s, opts.payload);
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
    const lt = try mintLinkToken(&ctx, w, "members", rid, 900, .{});
    const claims = (try verifyLinkToken(&ctx, w, "members", lt.token)).?;
    try consumeLinkToken(w, claims);
    try std.testing.expectError(error.AlreadyConsumed, consumeLinkToken(w, claims));

    const issued = try issueSession(&ctx, w, "members", rid);
    try std.testing.expect(issued.cookies.len == 2);
}

test "data.create provisions a usable auth row: mintLinkToken + issueSession succeed" {
    // Regression for #53: a passwordless flow provisions an auth record via the Data
    // facade (no hand-written tokenKey). Plain data.create on an auth collection now runs
    // the credential transforms, so the row carries a tokenKey the auth helpers accept.
    var h = try api_auth.TestEnv.initAuth("members");
    defer h.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const w = h.pool.acquireWriter();
    defer h.pool.releaseWriter();

    // Provision a credential-less (passwordless) auth record via the facade. The Data
    // facade allocates scratch via app.allocator and expects it bulk-freed, so back it
    // with the test arena rather than the leak-checked testing allocator.
    var app = h.app;
    app.allocator = a;
    const d = Data{ .app = &app, .conn = w, .io = app.io, .alloc = a };
    var fields: std.json.ObjectMap = .empty;
    try fields.put(a, "email", .{ .string = "pw-less@x.io" });
    const created = try d.create("members", .{ .object = fields });
    const rid = created.object.get("id").?.string;

    // The provisioned row must carry a tokenKey, so the auth helpers operate on it.
    const tk = (try api_auth.tokenKeyFor(a, w, "members", rid)).?;
    try std.testing.expectEqual(@as(usize, 32), tk.len);

    var ctx = h.ctx(a, .POST, "", &[_]http.Param{});
    const lt = try mintLinkToken(&ctx, w, "members", rid, 900, .{});
    const claims = (try verifyLinkToken(&ctx, w, "members", lt.token)).?;
    try std.testing.expectEqualStrings(rid, claims.id);

    const issued = try issueSession(&ctx, w, "members", rid);
    try std.testing.expect(issued.cookies.len == 2);

    // A non-object value on an auth collection surfaces NotObject (same as the non-auth
    // path), not applyProvision's PasswordTooShort.
    try std.testing.expectError(error.NotObject, d.create("members", .{ .string = "nope" }));
}

test "data.create on a non-auth collection inserts plainly (no provisioning)" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("PRAGMA foreign_keys=ON;");
    try @import("migrations.zig").run(&conn);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    _ = try collections.create(a, io, &conn, .{
        .id = "",
        .name = "posts",
        .fields = &[_]@import("schema.zig").Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }},
    });

    var app = app_mod.App{ .allocator = a, .io = io, .pool = undefined };
    const d = Data{ .app = &app, .conn = &conn, .io = io, .alloc = a };
    var fields: std.json.ObjectMap = .empty;
    try fields.put(a, "title", .{ .string = "hi" });
    // Non-auth: plain insert, no tokenKey transform — the value is stored as given.
    const created = try d.create("posts", .{ .object = fields });
    try std.testing.expectEqualStrings("hi", created.object.get("title").?.string);
    try std.testing.expect(created.object.get("tokenKey") == null);
    // Unknown collection still errors.
    try std.testing.expectError(error.UnknownCollection, d.create("nope", .{ .object = fields }));
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
        (try api_auth.tokenKeyFor(a, w, "members", rid)).?, .verification, 900, "");

    // verifyLinkToken must REJECT it (null) — cross-type security boundary.
    const result = try verifyLinkToken(&ctx, w, "members", ver_token);
    try std.testing.expectEqual(@as(?jwt.Claims, null), result);

    // Happy path: a token minted by mintLinkToken IS accepted by verifyLinkToken.
    const lt = try mintLinkToken(&ctx, w, "members", rid, 900, .{});
    const ok = try verifyLinkToken(&ctx, w, "members", lt.token);
    try std.testing.expect(ok != null);
}

test "magic-link payload: opaque bound payload round-trips, is tamper-proof, replay-rejected" {
    var h = try api_auth.TestEnv.initAuth("members");
    defer h.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try h.createUser(a, "members", "p@x.io", "longenough");

    const w = h.pool.acquireWriter();
    defer h.pool.releaseWriter();
    const col = (try collections.get(a, w, "members")).?;
    const rid = (try api_auth.findByIdentity(a, w, col, "p@x.io")).?;

    var ctx = h.ctx(a, .POST, "", &[_]http.Param{});

    // Mint with an opaque payload (e.g. a post-login redirect target).
    const lt = try mintLinkToken(&ctx, w, "members", rid, 900, .{ .payload = "/club/profile" });

    // verifyLinkToken returns the same payload, verbatim, in claims.pl.
    const claims = (try verifyLinkToken(&ctx, w, "members", lt.token)).?;
    try std.testing.expectEqualStrings("/club/profile", claims.pl);

    // Tampering with the payload (flip a byte in the JWT payload segment) fails verification:
    // the pl claim is covered by the HMAC signature.
    const buf = try a.dupe(u8, lt.token);
    const first_dot = std.mem.indexOfScalar(u8, buf, '.').?;
    buf[first_dot + 1] = if (buf[first_dot + 1] == 'A') 'B' else 'A';
    try std.testing.expectEqual(@as(?jwt.Claims, null), try verifyLinkToken(&ctx, w, "members", buf));

    // Replay guard still holds: consume once, then a second consume is rejected.
    try consumeLinkToken(w, claims);
    try std.testing.expectError(error.AlreadyConsumed, consumeLinkToken(w, claims));

    // Back-compat: minting without a payload yields an empty pl claim.
    const lt2 = try mintLinkToken(&ctx, w, "members", rid, 900, .{});
    const claims2 = (try verifyLinkToken(&ctx, w, "members", lt2.token)).?;
    try std.testing.expectEqualStrings("", claims2.pl);
}
