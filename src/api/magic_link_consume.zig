/// GET email-link passwordless mode for the built-in `magic_link` method.
///
///   GET /api/collections/:col/auth/magic_link/consume?token=...&redirect=/app
///
/// The classic email UX: the user clicks a plain GET link from their inbox and
/// lands logged-in on an app page. This handler reads the token from the query,
/// verifies + consumes it (single-use, same replay guard as `complete`), mints a
/// session via the shared `issueSession` seam (so `onAuth(.magic_link)` fires and
/// `zb_auth`/`zb_csrf` cookies are set), and returns a 302 to the redirect target.
///
/// The redirect target is validated SERVER-SIDE so no consumer re-implements an
/// open-redirect guard: only same-origin relative paths are ever honored, and an
/// optional per-collection allow-list (`magic_link.redirect_allow`) restricts which
/// of those paths are permitted. Anything off-origin or off-list falls back to the
/// configured default (`magic_link.redirect_default`, "/" by default).
const std = @import("std");
const http = @import("../http.zig");
const schema = @import("../schema.zig");
const collections = @import("../collections.zig");
const params_mod = @import("../query/params.zig");
const auth = @import("auth.zig");
const records = @import("../records.zig");
const auth_helpers = @import("../auth_helpers.zig");
const ApiError = @import("error.zig").ApiError;

// ---------------------------------------------------------------------------
// Redirect whitelist
// ---------------------------------------------------------------------------

/// A candidate redirect target is "safe" only when it is a same-origin relative
/// path: it must start with a single "/", and must not begin with "//" or "/\"
/// (protocol-relative URLs that browsers resolve to a remote origin), nor contain
/// a scheme separator, nor any control/whitespace byte that could smuggle a
/// second header or confuse the URL parser.
fn isSafeRelative(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] != '/') return false; // must be origin-relative
    if (path.len >= 2 and (path[1] == '/' or path[1] == '\\')) return false; // "//host" / "/\host"
    for (path) |c| {
        // Reject controls, space, and the CR/LF that header injection relies on.
        if (c <= 0x20 or c == 0x7f) return false;
        // A ':' before the first '/' would be a scheme ("javascript:"); but since
        // we already require path[0]=='/', any ':' here is inside the path and is
        // legal (query strings, matrix params). No extra check needed.
    }
    return true;
}

/// True when `path` matches an allow-list entry. An entry ending in "/" is a
/// prefix match (e.g. "/club/" matches "/club/me"); any other entry is an exact
/// path match (compared up to the first '?' so a query string does not defeat it).
fn matchesAllow(allow: []const []const u8, path: []const u8) bool {
    const q = std.mem.indexOfScalar(u8, path, '?') orelse path.len;
    const path_no_query = path[0..q];
    for (allow) |entry| {
        if (entry.len == 0) continue;
        if (entry[entry.len - 1] == '/') {
            if (std.mem.startsWith(u8, path, entry)) return true;
        } else if (std.mem.eql(u8, entry, path_no_query)) {
            return true;
        }
    }
    return false;
}

/// Resolve the redirect to actually use. `requested` is the raw (already
/// percent-decoded) `?redirect=` value or null. Returns the requested target
/// only when it is both same-origin-relative AND permitted by the allow-list
/// (an empty allow-list permits any safe relative path); otherwise returns the
/// configured default. The default itself is sanity-checked and degrades to "/".
fn resolveRedirect(ml: schema.MagicLinkMethodOpts, requested: ?[]const u8) []const u8 {
    const fallback = if (isSafeRelative(ml.redirect_default)) ml.redirect_default else "/";
    const want = requested orelse return fallback;
    if (!isSafeRelative(want)) return fallback;
    if (ml.redirect_allow.len > 0 and !matchesAllow(ml.redirect_allow, want)) return fallback;
    return want;
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

/// GET /api/collections/:col/auth/magic_link/consume — verify+consume a magic
/// link token, set the session cookies, and 302 to the (validated) redirect.
pub fn consume(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app orelse return (ApiError.internal()).toResponse(ctx.allocator);

    // Load collection under a brief reader and gate on magic_link being enabled,
    // mirroring the auth-method dispatch (404 for unknown/non-auth/disabled).
    const col_name = ctx.param("col") orelse return (ApiError.notFound()).toResponse(ctx.allocator);
    const col = blk: {
        var r = app.pool.acquireReader() catch return (ApiError.internal()).toResponse(ctx.allocator);
        defer app.pool.releaseReader(&r);
        break :blk (try collections.get(ctx.allocator, &r, col_name)) orelse
            return (ApiError.notFound()).toResponse(ctx.allocator);
    };
    if (col.type != .auth) return (ApiError.notFound()).toResponse(ctx.allocator);
    const ml = col.options.auth.methods.magic_link orelse return (ApiError.notFound()).toResponse(ctx.allocator);

    // Parse the query string (percent-decoded) for token + redirect.
    const qp = try params_mod.parse(ctx.allocator, ctx.query);
    const target = resolveRedirect(ml, qp.get("redirect"));
    const token = qp.get("token") orelse
        return (ApiError.badRequest("token is required.")).toResponse(ctx.allocator);

    // Verify + consume must be atomic against the single-use guard, so they run
    // under ONE writer held across both calls (same contract as `complete`).
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();

    const claims = (try auth_helpers.verifyLinkToken(ctx, w, col.name, token)) orelse
        return (ApiError.badRequest("Invalid or expired link.")).toResponse(ctx.allocator);
    auth_helpers.consumeLinkToken(w, claims) catch
        return (ApiError.badRequest("Link already used.")).toResponse(ctx.allocator);

    // Optional verification gate: refuse to mint a session for an unverified
    // record when the collection requires it (parity with `complete`).
    const rec: ?std.json.Value = if (col.options.auth.require_verified) blk: {
        const r = (try records.get(ctx.allocator, w, col, claims.id)) orelse
            return (ApiError.notFound()).toResponse(ctx.allocator);
        if (!auth.recordVerified(r))
            return (ApiError{ .status = 403, .message = "Email not verified." }).toResponse(ctx.allocator);
        break :blk r;
    } else null;

    const issued = try auth.issueSessionExt(ctx, w, col.name, claims.id, .magic_link, rec);

    const cookies = try ctx.allocator.dupe(http.Cookie, &issued.cookies);
    const headers = try ctx.allocator.dupe(http.Header, &[_]http.Header{
        .{ .name = "Location", .value = target },
    });
    // 302 Found: the browser follows with a GET, which is what an email link wants.
    return http.Response{
        .status = 302,
        .body = "",
        .content_type = "text/plain",
        .cookies = cookies,
        .extra_headers = headers,
    };
}

// ---------------------------------------------------------------------------
// Tests — pure redirect-whitelist logic (no DB)
// ---------------------------------------------------------------------------

test "isSafeRelative: accepts origin-relative, rejects off-origin and injection" {
    try std.testing.expect(isSafeRelative("/app"));
    try std.testing.expect(isSafeRelative("/club/me?next=1"));
    try std.testing.expect(!isSafeRelative(""));
    try std.testing.expect(!isSafeRelative("app")); // no leading slash
    try std.testing.expect(!isSafeRelative("//evil.example.com")); // protocol-relative
    try std.testing.expect(!isSafeRelative("/\\evil.example.com")); // backslash variant
    try std.testing.expect(!isSafeRelative("https://evil.example.com")); // absolute scheme
    try std.testing.expect(!isSafeRelative("/app\r\nSet-Cookie: x=1")); // CRLF injection
    try std.testing.expect(!isSafeRelative("/app path")); // raw space
}

test "matchesAllow: exact and prefix entries" {
    const allow = [_][]const u8{ "/club/", "/dashboard" };
    try std.testing.expect(matchesAllow(&allow, "/club/me"));
    try std.testing.expect(matchesAllow(&allow, "/dashboard"));
    try std.testing.expect(matchesAllow(&allow, "/dashboard?x=1")); // query ignored for exact
    try std.testing.expect(!matchesAllow(&allow, "/dashboardx")); // exact, not prefix
    try std.testing.expect(!matchesAllow(&allow, "/other"));
}

test "resolveRedirect: empty allow-list permits any safe relative path" {
    const ml = schema.MagicLinkMethodOpts{ .redirect_default = "/home" };
    try std.testing.expectEqualStrings("/app", resolveRedirect(ml, "/app"));
    // Off-origin falls back to default.
    try std.testing.expectEqualStrings("/home", resolveRedirect(ml, "https://evil/"));
    // Missing redirect falls back to default.
    try std.testing.expectEqualStrings("/home", resolveRedirect(ml, null));
}

test "resolveRedirect: non-empty allow-list restricts to matching paths" {
    const allow = [_][]const u8{"/club/"};
    const ml = schema.MagicLinkMethodOpts{ .redirect_default = "/club/welcome", .redirect_allow = &allow };
    try std.testing.expectEqualStrings("/club/me", resolveRedirect(ml, "/club/me"));
    // Safe relative but not on the list ⇒ default.
    try std.testing.expectEqualStrings("/club/welcome", resolveRedirect(ml, "/admin"));
    // Off-origin ⇒ default.
    try std.testing.expectEqualStrings("/club/welcome", resolveRedirect(ml, "//evil"));
}

test "resolveRedirect: bad default degrades to /" {
    const ml = schema.MagicLinkMethodOpts{ .redirect_default = "https://evil/" };
    try std.testing.expectEqualStrings("/", resolveRedirect(ml, null));
}

// ---------------------------------------------------------------------------
// Tests — full handler (DB-backed): 302 + cookies, replay, redirect fallback
// ---------------------------------------------------------------------------

const api_auth = @import("auth.zig");

fn locationHeader(resp: http.Response) ?[]const u8 {
    for (resp.extra_headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Location")) return h.value;
    }
    return null;
}

/// Stand up an auth collection with magic_link enabled + a redirect allow-list,
/// seed one verified user, and return its TestEnv. The caller owns `deinit`.
fn setupConsumeEnv(name: []const u8, allow: []const []const u8, default_to: []const u8) !*api_auth.TestEnv {
    const env = try std.testing.allocator.create(api_auth.TestEnv);
    env.tmp = std.testing.tmpDir(.{});
    const dir = try env.tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/test.db", .{dir}, 0);
    defer std.testing.allocator.free(path);
    env.pool = try @import("../db.zig").Pool.init(std.testing.allocator, std.testing.io, path);
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try @import("../migrations.zig").run(w);
        var setup_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer setup_arena.deinit();
        const sa = setup_arena.allocator();
        _ = try collections.create(sa, std.testing.io, w, .{
            .id = "",
            .name = name,
            .type = .auth,
            .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
            .options = .{ .auth = .{ .methods = .{ .magic_link = .{
                .redirect_default = default_to,
                .redirect_allow = allow,
            } } } },
        });
    }
    env.app = .{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = &env.pool };
    return env;
}

/// Build a GET consume RequestCtx with the given query string.
fn consumeCtx(env: *api_auth.TestEnv, a: std.mem.Allocator, col_name: []const u8, query: []const u8) http.RequestCtx {
    const params = a.dupe(http.Param, &[_]http.Param{.{ .key = "col", .value = col_name }}) catch unreachable;
    return .{ .method = .GET, .path = "/", .query = query, .allocator = a, .app = &env.app, .params = params };
}

test "consume: valid token → 302 with session cookies + allowed redirect; replay rejected" {
    const allow = [_][]const u8{"/club/"};
    var env = try setupConsumeEnv("mlconsume1", &allow, "/club/welcome");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try env.createUser(a, "mlconsume1", "u@x.io", "longenough");

    // Mint a magic-link token for the user.
    var mint_ctx = consumeCtx(env, a, "mlconsume1", "");
    const token = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const col = (try collections.get(a, w, "mlconsume1")).?;
        const rid = (try api_auth.findByIdentity(a, w, col, "u@x.io")).?;
        break :blk (try auth_helpers.mintLinkToken(&mint_ctx, w, "mlconsume1", rid, 900)).token;
    };

    // First consume: 302 + Location=/club/me + both cookies.
    const q1 = try std.fmt.allocPrint(a, "token={s}&redirect=%2Fclub%2Fme", .{token});
    var ctx1 = consumeCtx(env, a, "mlconsume1", q1);
    const res1 = try consume(&ctx1);
    try std.testing.expectEqual(@as(u16, 302), res1.status);
    try std.testing.expectEqualStrings("/club/me", locationHeader(res1).?);
    var saw_auth = false;
    var saw_csrf = false;
    for (res1.cookies) |c| {
        if (std.mem.eql(u8, c.name, "zb_auth")) saw_auth = true;
        if (std.mem.eql(u8, c.name, "zb_csrf")) saw_csrf = true;
    }
    try std.testing.expect(saw_auth and saw_csrf);

    // Replay: same token must be rejected (single-use), 400, no redirect.
    const q2 = try std.fmt.allocPrint(a, "token={s}&redirect=%2Fclub%2Fme", .{token});
    var ctx2 = consumeCtx(env, a, "mlconsume1", q2);
    const res2 = try consume(&ctx2);
    try std.testing.expectEqual(@as(u16, 400), res2.status);
}

test "consume: non-whitelisted redirect falls back to default (no open redirect)" {
    const allow = [_][]const u8{"/club/"};
    var env = try setupConsumeEnv("mlconsume2", &allow, "/club/welcome");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try env.createUser(a, "mlconsume2", "u@x.io", "longenough");

    var mint_ctx = consumeCtx(env, a, "mlconsume2", "");
    const token = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const col = (try collections.get(a, w, "mlconsume2")).?;
        const rid = (try api_auth.findByIdentity(a, w, col, "u@x.io")).?;
        break :blk (try auth_helpers.mintLinkToken(&mint_ctx, w, "mlconsume2", rid, 900)).token;
    };

    // redirect points off-list (and a protocol-relative open-redirect attempt):
    // both must degrade to the configured default, never the attacker's target.
    const q = try std.fmt.allocPrint(a, "token={s}&redirect=%2F%2Fevil.example.com", .{token});
    var ctx = consumeCtx(env, a, "mlconsume2", q);
    const res = try consume(&ctx);
    try std.testing.expectEqual(@as(u16, 302), res.status);
    try std.testing.expectEqualStrings("/club/welcome", locationHeader(res).?);
}

test "consume: missing token → 400; magic_link disabled → 404" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // magic_link enabled, but no token in the query → 400.
    {
        var env = try setupConsumeEnv("mlconsume3", &.{}, "/");
        defer env.deinit();
        var ctx = consumeCtx(env, a, "mlconsume3", "redirect=%2Fapp");
        const res = try consume(&ctx);
        try std.testing.expectEqual(@as(u16, 400), res.status);
    }

    // Collection without magic_link enabled → 404 (parity with dispatch).
    {
        var env = try api_auth.TestEnv.initAuth("mlconsume4");
        defer env.deinit();
        var ctx = consumeCtx(env, a, "mlconsume4", "token=whatever");
        const res = try consume(&ctx);
        try std.testing.expectEqual(@as(u16, 404), res.status);
    }
}
