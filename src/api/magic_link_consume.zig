/// GET email-link passwordless mode for the built-in `magic_link` method.
///
///   GET /api/collections/:col/auth/magic-link/consume?token=...&redirect=/app
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
const RequestArena = @import("../request_arena.zig").RequestArena;
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
/// path: it must start with a single "/", must not begin with "//" or "/\"
/// (protocol-relative URLs that browsers resolve to a remote origin), must not
/// contain any control/whitespace byte that could smuggle a second header or
/// confuse the URL parser, and must not contain a path-traversal (`.`/`..`) or
/// backslash sequence that a browser would normalize to escape an allowed prefix
/// (e.g. `/club/../admin` resolves to `/admin` and would bypass the allow-list).
fn isSafeRelative(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] != '/') return false; // must be origin-relative
    if (path.len >= 2 and (path[1] == '/' or path[1] == '\\')) return false; // "//host" / "/\host"
    for (path) |c| {
        // Reject controls, space, and the CR/LF that header injection relies on.
        if (c <= 0x20 or c == 0x7f) return false;
        // Reject backslashes entirely — browsers normalize "\" to "/", so they
        // enable both protocol-relative and traversal bypasses.
        if (c == '\\') return false;
        // A ':' before the first '/' would be a scheme ("javascript:"); but since
        // we already require path[0]=='/', any ':' here is inside the path and is
        // legal (query strings, matrix params). No extra check needed.
    }

    // Reject path-traversal segments in the path portion (before any '?'). The
    // value is already percent-decoded once, so literal ".." is caught here; the
    // encoded-form checks below catch double-encoded payloads (%2e, %2f, %5c)
    // that would otherwise survive to a second decode.
    const limit = std.mem.indexOfScalar(u8, path, '?') orelse path.len;
    const path_part = path[0..limit];
    if (std.mem.indexOf(u8, path_part, "/../") != null or
        std.mem.indexOf(u8, path_part, "/./") != null or
        std.mem.endsWith(u8, path_part, "/..") or
        std.mem.endsWith(u8, path_part, "/."))
    {
        return false;
    }
    // Defense in depth: refuse any still-encoded dot/slash/backslash anywhere in
    // the target so a double-encoded "%252e" -> "%2e" -> "." can't slip through.
    if (std.ascii.indexOfIgnoreCase(path, "%2e") != null or // '.'
        std.ascii.indexOfIgnoreCase(path, "%2f") != null or // '/'
        std.ascii.indexOfIgnoreCase(path, "%5c") != null) // '\'
    {
        return false;
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

/// GET /api/collections/:col/auth/magic-link/consume — verify+consume a magic
/// link token, set the session cookies, and 302 to the (validated) redirect.
pub fn consume(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app orelse return (ApiError.internal()).toResponse(ctx.allocator.a);

    // Load collection under a brief reader and gate on magic_link being enabled,
    // mirroring the auth-method dispatch (404 for unknown/non-auth/disabled).
    const col_name = ctx.param("col") orelse return (ApiError.notFound()).toResponse(ctx.allocator.a);
    const col = blk: {
        var r = app.pool.acquireReader() catch return (ApiError.internal()).toResponse(ctx.allocator.a);
        defer app.pool.releaseReader(&r);
        break :blk (try collections.get(ctx.allocator.a, &r, col_name)) orelse
            return (ApiError.notFound()).toResponse(ctx.allocator.a);
    };
    if (col.type != .auth) return (ApiError.notFound()).toResponse(ctx.allocator.a);
    const ml = col.options.auth.methods.magic_link orelse return (ApiError.notFound()).toResponse(ctx.allocator.a);

    // Parse the query string (percent-decoded) for token + redirect.
    const qp = try params_mod.parse(ctx.allocator.a, ctx.query);
    const target = resolveRedirect(ml, qp.get("redirect"));
    const token = qp.get("token") orelse
        return (ApiError.badRequest("token is required.")).toResponse(ctx.allocator.a);

    // Verify + consume + the beforeAuthSuccess hook + session issuance all run under ONE
    // writer inside a single transaction. Token consumption is the single-use guard; the
    // transaction makes the whole login atomic, so an aborting hook ROLLS BACK the token
    // consumption (the link stays usable) and its own side-writes, and blocks the session.
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    try w.beginImmediate();
    // Safety net for EVERY error-return after begin (verifyLinkToken/consumeLinkToken DB
    // errors, records.get, the hook, issueSession, commit): roll back so a failed login
    // never leaves an open transaction on the single shared writer (which would poison all
    // subsequent writes). Value-returns below (NULL/replay/gate/veto cases) roll back
    // explicitly since errdefer does not fire on a normal return; the double-rollback that
    // a later error would cause is harmless (no active txn → caught).
    errdefer w.rollback() catch {};

    const claims = (try auth_helpers.verifyLinkToken(ctx, w, col.name, token)) orelse {
        w.rollback() catch {};
        return (ApiError.badRequest("Invalid or expired link.")).toResponse(ctx.allocator.a);
    };
    // Only a genuine replay (the token's jti is already recorded) is a 400. Any
    // other failure (DB prepare/step, I/O) must propagate to the 500 backstop
    // rather than masquerading as "Link already used." (errdefer rolls back the propagation.)
    auth_helpers.consumeLinkToken(w, claims) catch |err| switch (err) {
        error.AlreadyConsumed => {
            w.rollback() catch {};
            return (ApiError.badRequest("Link already used.")).toResponse(ctx.allocator.a);
        },
        else => return err,
    };

    // Fetch the record once for the verification gate, the hook, and session issuance.
    const rec = (try records.get(ctx.allocator.a, w, col, claims.id)) orelse {
        w.rollback() catch {};
        return (ApiError.notFound()).toResponse(ctx.allocator.a);
    };
    // Optional verification gate: refuse to mint a session for an unverified
    // record when the collection requires it (parity with `complete`).
    if (col.options.auth.require_verified and !auth.recordVerified(rec)) {
        w.rollback() catch {};
        return ApiError.withCode(403, .email_not_verified, "Email not verified.").toResponse(ctx.allocator.a);
    }

    if (try @import("../auth/two_factor.zig").beginAuthentication(ctx, w, col, claims.id, .magic_link)) |pending| {
        try w.commit();
        return pending;
    }

    if (try auth.fireBeforeAuthSuccess(ctx, w, col.name, claims.id, .magic_link, rec)) |resp| {
        w.rollback() catch {};
        return resp;
    }

    const issued = try auth.issueSessionNoEmit(ctx, w, col.name, claims.id);
    try w.commit();
    // onAuth fires only AFTER a durable commit (session truly issued).
    auth.emitAuth(ctx, col.name, rec, .magic_link);

    const cookies = try ctx.allocator.a.dupe(http.Cookie, &issued.cookies);
    const headers = try ctx.allocator.a.dupe(http.Header, &[_]http.Header{
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

test "isSafeRelative: rejects path traversal and backslash bypasses" {
    // Literal "../" traversal that browsers normalize to escape an allowed prefix.
    try std.testing.expect(!isSafeRelative("/club/../admin"));
    try std.testing.expect(!isSafeRelative("/../admin"));
    try std.testing.expect(!isSafeRelative("/club/.."));
    try std.testing.expect(!isSafeRelative("/club/./admin"));
    try std.testing.expect(!isSafeRelative("/club/."));
    // Backslash variants (browsers treat "\" as "/").
    try std.testing.expect(!isSafeRelative("/foo/..\\admin"));
    try std.testing.expect(!isSafeRelative("/club\\..\\admin"));
    // Double-encoded forms that would survive to a second decode.
    try std.testing.expect(!isSafeRelative("/club/..%2fadmin"));
    try std.testing.expect(!isSafeRelative("/club/%2e%2e/admin"));
    try std.testing.expect(!isSafeRelative("/club/%2E%2E%2Fadmin")); // uppercase encoded
    try std.testing.expect(!isSafeRelative("/foo%5c..%5cadmin"));
    // A legitimate path with a dot in a filename segment is still fine.
    try std.testing.expect(isSafeRelative("/club/report.v2"));
    try std.testing.expect(isSafeRelative("/files/a.b.c"));
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
fn consumeCtx(env: *api_auth.TestEnv, a: RequestArena, col_name: []const u8, query: []const u8) http.RequestCtx {
    const params = a.a.dupe(http.Param, &[_]http.Param{.{ .key = "col", .value = col_name }}) catch unreachable;
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
    var mint_ctx = consumeCtx(env, RequestArena.from(&arena), "mlconsume1", "");
    const token = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const col = (try collections.get(a, w, "mlconsume1")).?;
        const rid = (try api_auth.findByIdentity(a, w, col, "u@x.io")).?;
        break :blk (try auth_helpers.mintLinkToken(&mint_ctx, w, "mlconsume1", rid, 900, .{})).token;
    };

    // First consume: 302 + Location=/club/me + both cookies.
    const q1 = try std.fmt.allocPrint(a, "token={s}&redirect=%2Fclub%2Fme", .{token});
    var ctx1 = consumeCtx(env, RequestArena.from(&arena), "mlconsume1", q1);
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
    var ctx2 = consumeCtx(env, RequestArena.from(&arena), "mlconsume1", q2);
    const res2 = try consume(&ctx2);
    try std.testing.expectEqual(@as(u16, 400), res2.status);
}

test "#80 consume: aborting beforeAuthSuccess blocks session AND leaves the link token unconsumed" {
    const events = @import("../events.zig");
    const Ctx = @import("../ctx.zig").Ctx;

    var env = try setupConsumeEnv("mlconsume80", &.{}, "/home");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try env.createUser(a, "mlconsume80", "u@x.io", "longenough");

    // Mint a single magic-link token; the same token is reused after the abort to prove
    // the consumption rolled back (the link is still usable).
    var mint_ctx = consumeCtx(env, RequestArena.from(&arena), "mlconsume80", "");
    const token = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const col = (try collections.get(a, w, "mlconsume80")).?;
        const rid = (try api_auth.findByIdentity(a, w, col, "u@x.io")).?;
        break :blk (try auth_helpers.mintLinkToken(&mint_ctx, w, "mlconsume80", rid, 900, .{})).token;
    };

    // Aborting hook: vetoes the login. The transaction must roll back the token
    // consumption so the link stays redeemable on retry.
    const Hook = struct {
        fn abort(ctx: *Ctx, ev: *events.AuthSuccessEvent) anyerror!void {
            _ = ev;
            return ctx.fail(403, "blocked");
        }
    };
    var disp = events.Dispatch{ .before_auth_success = Hook.abort };
    env.app.dispatch = &disp;

    const q1 = try std.fmt.allocPrint(a, "token={s}", .{token});
    var ctx1 = consumeCtx(env, RequestArena.from(&arena), "mlconsume80", q1);
    const res1 = try consume(&ctx1);
    try std.testing.expectEqual(@as(u16, 403), res1.status); // fail closed
    try std.testing.expectEqual(@as(usize, 0), res1.cookies.len); // no session

    // Retry with the SAME token now that the hook permits the login: the token was NOT
    // burned by the aborted attempt, so the consume succeeds (302 + session).
    env.app.dispatch = null;
    const q2 = try std.fmt.allocPrint(a, "token={s}", .{token});
    var ctx2 = consumeCtx(env, RequestArena.from(&arena), "mlconsume80", q2);
    const res2 = try consume(&ctx2);
    try std.testing.expectEqual(@as(u16, 302), res2.status);
    var saw_auth = false;
    for (res2.cookies) |c| {
        if (std.mem.eql(u8, c.name, "zb_auth")) saw_auth = true;
    }
    try std.testing.expect(saw_auth);

    // And now the single-use guard holds: a third attempt with the same token is rejected.
    const q3 = try std.fmt.allocPrint(a, "token={s}", .{token});
    var ctx3 = consumeCtx(env, RequestArena.from(&arena), "mlconsume80", q3);
    const res3 = try consume(&ctx3);
    try std.testing.expectEqual(@as(u16, 400), res3.status);
}

test "L1 consume: a DB error after begin rolls back (writer not poisoned)" {
    var env = try setupConsumeEnv("mlconsumeL1", &.{}, "/home");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try env.createUser(a, "mlconsumeL1", "u@x.io", "longenough");

    const mintToken = struct {
        fn go(e: *api_auth.TestEnv, alloc: RequestArena) ![]const u8 {
            var mc = consumeCtx(e, alloc, "mlconsumeL1", "");
            const w = e.pool.acquireWriter();
            defer e.pool.releaseWriter();
            const col = (try collections.get(alloc.a, w, "mlconsumeL1")).?;
            const rid = (try api_auth.findByIdentity(alloc.a, w, col, "u@x.io")).?;
            return (try auth_helpers.mintLinkToken(&mc, w, "mlconsumeL1", rid, 900, .{})).token;
        }
    }.go;

    const t1 = try mintToken(env, RequestArena.from(&arena));

    // Drop the single-use ledger so consumeLinkToken errors AFTER beginImmediate. Without
    // the errdefer rollback the failed login would leave the writer in an open transaction
    // and poison every subsequent login.
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try w.exec("DROP TABLE \"_consumedTokens\";");
    }
    {
        const q = try std.fmt.allocPrint(a, "token={s}", .{t1});
        var ctx = consumeCtx(env, RequestArena.from(&arena), "mlconsumeL1", q);
        // The error propagates (it is not a replay); we only care that the writer is left clean.
        if (consume(&ctx)) |_| {} else |_| {}
    }
    // Restore the ledger and prove the writer is still usable: a fresh login commits to 302.
    // (If the writer were poisoned, the next beginImmediate would fail and this would not be 302.)
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try w.exec("CREATE TABLE \"_consumedTokens\" (\"jti\" TEXT PRIMARY KEY, \"expires\" INTEGER, \"consumed\" TEXT);");
    }
    const t2 = try mintToken(env, RequestArena.from(&arena));
    const q2 = try std.fmt.allocPrint(a, "token={s}", .{t2});
    var ctx2 = consumeCtx(env, RequestArena.from(&arena), "mlconsumeL1", q2);
    const res = try consume(&ctx2);
    try std.testing.expectEqual(@as(u16, 302), res.status);
}

test "consume: non-whitelisted redirect falls back to default (no open redirect)" {
    const allow = [_][]const u8{"/club/"};
    var env = try setupConsumeEnv("mlconsume2", &allow, "/club/welcome");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try env.createUser(a, "mlconsume2", "u@x.io", "longenough");

    var mint_ctx = consumeCtx(env, RequestArena.from(&arena), "mlconsume2", "");
    const token = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const col = (try collections.get(a, w, "mlconsume2")).?;
        const rid = (try api_auth.findByIdentity(a, w, col, "u@x.io")).?;
        break :blk (try auth_helpers.mintLinkToken(&mint_ctx, w, "mlconsume2", rid, 900, .{})).token;
    };

    // redirect points off-list (and a protocol-relative open-redirect attempt):
    // both must degrade to the configured default, never the attacker's target.
    const q = try std.fmt.allocPrint(a, "token={s}&redirect=%2F%2Fevil.example.com", .{token});
    var ctx = consumeCtx(env, RequestArena.from(&arena), "mlconsume2", q);
    const res = try consume(&ctx);
    try std.testing.expectEqual(@as(u16, 302), res.status);
    try std.testing.expectEqualStrings("/club/welcome", locationHeader(res).?);
}

test "consume: traversal redirect cannot escape an allowed prefix" {
    const allow = [_][]const u8{"/club/"};
    var env = try setupConsumeEnv("mlconsume5", &allow, "/club/welcome");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try env.createUser(a, "mlconsume5", "u@x.io", "longenough");

    // Each attack uses a freshly minted token (consume is single-use).
    const attacks = [_][]const u8{
        "%2Fclub%2F..%2Fadmin", // /club/../admin
        "%2Fclub%2F..%252fadmin", // /club/..%2fadmin (double-encoded slash)
        "%2Ffoo%2F..%5Cadmin", // /foo/..\admin (backslash)
    };
    for (attacks) |atk| {
        var mint_ctx = consumeCtx(env, RequestArena.from(&arena), "mlconsume5", "");
        const token = blk: {
            const w = env.pool.acquireWriter();
            defer env.pool.releaseWriter();
            const col = (try collections.get(a, w, "mlconsume5")).?;
            const rid = (try api_auth.findByIdentity(a, w, col, "u@x.io")).?;
            break :blk (try auth_helpers.mintLinkToken(&mint_ctx, w, "mlconsume5", rid, 900, .{})).token;
        };
        const q = try std.fmt.allocPrint(a, "token={s}&redirect={s}", .{ token, atk });
        var ctx = consumeCtx(env, RequestArena.from(&arena), "mlconsume5", q);
        const res = try consume(&ctx);
        // Login still succeeds (302) but the target is forced to the default —
        // never the traversed "/admin".
        try std.testing.expectEqual(@as(u16, 302), res.status);
        try std.testing.expectEqualStrings("/club/welcome", locationHeader(res).?);
    }
}

test "consume: missing token → 400; magic_link disabled → 404" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // magic_link enabled, but no token in the query → 400.
    {
        var env = try setupConsumeEnv("mlconsume3", &.{}, "/");
        defer env.deinit();
        var ctx = consumeCtx(env, RequestArena.from(&arena), "mlconsume3", "redirect=%2Fapp");
        const res = try consume(&ctx);
        try std.testing.expectEqual(@as(u16, 400), res.status);
    }

    // Collection without magic_link enabled → 404 (parity with dispatch).
    {
        var env = try api_auth.TestEnv.initAuth("mlconsume4");
        defer env.deinit();
        var ctx = consumeCtx(env, RequestArena.from(&arena), "mlconsume4", "token=whatever");
        const res = try consume(&ctx);
        try std.testing.expectEqual(@as(u16, 404), res.status);
    }
}
