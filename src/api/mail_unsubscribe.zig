//! Public one-click unsubscribe endpoint (#154 round 2, RFC 8058). UNAUTHENTICATED by
//! design (mail providers POST it on the user's behalf) — the SIGNED TOKEN is the
//! authorization. Threat posture:
//!   * 404 when `unsubscribe_base_url` is unset — the feature-off binary exposes only
//!     the route-table entry and this branch (the `webhook_secret` pattern).
//!   * ONE generic 400 for every invalid token (bad MAC, malformed, oversized…) — no
//!     oracle distinguishing bad-signature from unknown-account.
//!   * POST success is 204 No Content — ALSO when the suppression row already existed
//!     (no "was this address known" oracle). Repo standard: side-effect success bodies
//!     are 204, not ad-hoc JSON.
//!   * GET NEVER mutates (link prefetchers/scanners must not unsubscribe people) — it
//!     renders a minimal confirmation page whose button POSTs back.
//!   * IP rate-limited via the shared RateLimiter (bounds token-grinding and
//!     suppression-row spam).
//! The suppression row: reason='unsubscribe' (blocks LIST mail only — transactional
//! sends ignore it, see suppression.Kind), source='one_click:<list>' for audit.

const std = @import("std");
const RequestArena = @import("../request_arena.zig").RequestArena;
const http = @import("../http.zig");
const clock = @import("../clock.zig");
const params_mod = @import("../query/params.zig");
const unsubscribe = @import("../mail/unsubscribe.zig");
const suppression = @import("../mail/suppression.zig");
const template = @import("../mail/template.zig");
const ApiError = @import("error.zig").ApiError;

/// Per-IP limit: plenty for humans + providers, hostile for grinders.
pub const rate_max: u32 = 30;
pub const rate_window_s: i64 = 60;

pub fn post(ctx: *http.RequestCtx) anyerror!http.Response {
    return handle(ctx, true);
}

pub fn get(ctx: *http.RequestCtx) anyerror!http.Response {
    return handle(ctx, false);
}

fn handle(ctx: *http.RequestCtx, mutate: bool) anyerror!http.Response {
    const app = ctx.app orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    // Feature off ⇒ the route "does not exist".
    if (app.mail.unsubscribe_base_url.len == 0) return ApiError.notFound().toResponse(ctx.allocator.a);

    // IP rate limit (shared limiter; honors ZIGBASE_TRUST_PROXY via ctx.remote_ip).
    if (app.rate_limiter) |rl| {
        const key = try std.fmt.allocPrint(ctx.allocator.a, "mail_unsub:ip:{s}", .{ctx.remote_ip});
        if (!rl.allowCustom(key, clock.nowUnix(app.io), rate_max, rate_window_s)) {
            return ApiError.withCode(429, .too_many_requests, "Too many requests. Try again later.").toResponse(ctx.allocator.a);
        }
    }

    const qp = params_mod.parse(ctx.allocator.a, ctx.query) catch null;
    const token = if (qp) |q| (q.get("t") orelse "") else "";
    const parts = unsubscribe.verify(ctx.allocator.a, app.jwt_secret, token) orelse
        return ApiError.badRequest("Invalid token.").toResponse(ctx.allocator.a); // ONE generic failure

    if (!mutate) return confirmPage(ctx, token);

    const source = try std.fmt.allocPrint(ctx.allocator.a, "one_click:{s}", .{parts.list});
    {
        const w = app.pool.acquireWriter();
        defer app.pool.releaseWriter();
        try suppression.upsert(app.io, ctx.allocator.a, w, parts.account, parts.recipient, suppression.reason_unsubscribe, source);
    }
    // 204 whether or not the row already existed (idempotent upsert; non-oracle).
    return .{ .status = 204, .body = "" };
}

/// Minimal self-contained confirmation page. The button POSTs back to this same
/// endpoint with the same token; the token is interpolated HTML-ESCAPED (its
/// base64url+'.' alphabet is inert anyway — defense in depth via the template engine).
fn confirmPage(ctx: *http.RequestCtx, token: []const u8) !http.Response {
    const page_tpl =
        \\<!doctype html><html><head><meta charset="utf-8"><title>Unsubscribe</title></head>
        \\<body style="font-family:sans-serif;max-width:32em;margin:4em auto">
        \\<h1>Unsubscribe</h1>
        \\<p>Click the button below to stop receiving this mailing list. Transactional
        \\messages (password resets, receipts) are not affected.</p>
        \\<form method="post" action="?t={{ token }}"><button type="submit">Unsubscribe</button></form>
        \\</body></html>
    ;
    const body = try template.renderHtml(ctx.allocator.a, page_tpl, &.{.{ .key = "token", .value = token }}, &.{});
    return .{ .status = 200, .content_type = "text/html; charset=utf-8", .body = body };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const db = @import("../db.zig");
const migrations = @import("../migrations.zig");
const App = @import("../app.zig").App;
const ratelimit = @import("../ratelimit.zig");

const jwt_secret = "test-secret";

/// tmp-dir pool + migrations, mirroring mail/inbound.zig's mutating-path test setup.
const Env = struct {
    tmp: std.testing.TmpDir,
    db_path: [:0]u8,
    pool: db.Pool,
    app: App,

    fn init() !*Env {
        const ga = testing.allocator;
        const env = try ga.create(Env);
        errdefer ga.destroy(env);
        env.tmp = testing.tmpDir(.{});
        errdefer env.tmp.cleanup();
        const dir_path = try env.tmp.dir.realPathFileAlloc(testing.io, ".", ga);
        defer ga.free(dir_path);
        env.db_path = try std.fmt.allocPrintSentinel(ga, "{s}/unsub.db", .{dir_path}, 0);
        errdefer ga.free(env.db_path);
        env.pool = try db.Pool.init(ga, testing.io, env.db_path);
        errdefer env.pool.deinit();
        {
            const w = env.pool.acquireWriter();
            defer env.pool.releaseWriter();
            try migrations.run(w);
        }
        env.app = App{
            .allocator = ga,
            .io = testing.io,
            .pool = &env.pool,
            .jwt_secret = jwt_secret,
            .mail = .{ .unsubscribe_base_url = "https://app.example" },
        };
        return env;
    }
    fn deinit(env: *Env) void {
        const ga = testing.allocator;
        env.pool.deinit();
        ga.free(env.db_path);
        env.tmp.cleanup();
        ga.destroy(env);
    }
};

fn suppressionCount(env: *Env) !i64 {
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    var st = try w.prepare("SELECT COUNT(*) FROM \"_suppressions\";");
    defer st.finalize();
    _ = try st.step();
    return st.columnInt(0);
}

test "POST valid token -> 204, list-suppresses only, correct reason/source" {
    const env = try Env.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const token = try unsubscribe.mint(a, jwt_secret, "acc1", "news", "u@x.io");
    const query = try std.fmt.allocPrint(a, "t={s}", .{token});
    var ctx = http.RequestCtx{ .method = .POST, .path = "/api/mail/unsubscribe", .query = query, .allocator = RequestArena.from(&arena), .app = &env.app };
    const res = try post(&ctx);
    try testing.expectEqual(@as(u16, 204), res.status);

    var r = try env.pool.acquireReader();
    defer env.pool.releaseReader(&r);
    try testing.expect(try suppression.isSuppressed(a, &r, "acc1", "u@x.io", .list));
    try testing.expect(!try suppression.isSuppressed(a, &r, "acc1", "u@x.io", .transactional));

    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    var st = try w.prepare("SELECT \"reason\",\"source\" FROM \"_suppressions\" WHERE \"email\"='u@x.io';");
    defer st.finalize();
    try testing.expect(try st.step());
    try testing.expectEqualStrings("unsubscribe", st.columnText(0));
    try testing.expectEqualStrings("one_click:news", st.columnText(1));
}

test "repeat POST -> 204 again, idempotent (exactly one row, non-oracle)" {
    const env = try Env.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const token = try unsubscribe.mint(a, jwt_secret, "acc1", "news", "u@x.io");
    const query = try std.fmt.allocPrint(a, "t={s}", .{token});

    var ctx1 = http.RequestCtx{ .method = .POST, .path = "/api/mail/unsubscribe", .query = query, .allocator = RequestArena.from(&arena), .app = &env.app };
    const res1 = try post(&ctx1);
    try testing.expectEqual(@as(u16, 204), res1.status);

    var ctx2 = http.RequestCtx{ .method = .POST, .path = "/api/mail/unsubscribe", .query = query, .allocator = RequestArena.from(&arena), .app = &env.app };
    const res2 = try post(&ctx2);
    try testing.expectEqual(@as(u16, 204), res2.status);

    try testing.expectEqual(@as(i64, 1), try suppressionCount(env));
}

test "invalid/tampered/absent token -> 400, generic message, no row written" {
    const env = try Env.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx_bad = http.RequestCtx{ .method = .POST, .path = "/api/mail/unsubscribe", .query = "t=not-a-real-token", .allocator = RequestArena.from(&arena), .app = &env.app };
    const res_bad = try post(&ctx_bad);
    try testing.expectEqual(@as(u16, 400), res_bad.status);

    var ctx_absent = http.RequestCtx{ .method = .POST, .path = "/api/mail/unsubscribe", .query = "", .allocator = RequestArena.from(&arena), .app = &env.app };
    const res_absent = try post(&ctx_absent);
    try testing.expectEqual(@as(u16, 400), res_absent.status);

    const token = try unsubscribe.mint(a, jwt_secret, "acc1", "news", "u@x.io");
    const bad = try a.dupe(u8, token);
    bad[0] = if (bad[0] == 'A') 'B' else 'A';
    const query = try std.fmt.allocPrint(a, "t={s}", .{bad});
    var ctx_tampered = http.RequestCtx{ .method = .POST, .path = "/api/mail/unsubscribe", .query = query, .allocator = RequestArena.from(&arena), .app = &env.app };
    const res_tampered = try post(&ctx_tampered);
    try testing.expectEqual(@as(u16, 400), res_tampered.status);

    try testing.expectEqual(@as(i64, 0), try suppressionCount(env));
}

test "GET never mutates: valid token -> 200 HTML confirmation, suppression count stays 0" {
    const env = try Env.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const token = try unsubscribe.mint(a, jwt_secret, "acc1", "news", "u@x.io");
    const query = try std.fmt.allocPrint(a, "t={s}", .{token});
    var ctx = http.RequestCtx{ .method = .GET, .path = "/api/mail/unsubscribe", .query = query, .allocator = RequestArena.from(&arena), .app = &env.app };
    const res = try get(&ctx);
    try testing.expectEqual(@as(u16, 200), res.status);
    try testing.expect(std.mem.indexOf(u8, res.body, "method=\"post\"") != null);

    try testing.expectEqual(@as(i64, 0), try suppressionCount(env));
}

test "feature off -> 404 for both verbs even with a valid token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Pure-rejection path: the 404 branch never touches the pool.
    var app = App{ .allocator = a, .io = testing.io, .pool = undefined, .jwt_secret = jwt_secret, .mail = .{} };

    const token = try unsubscribe.mint(a, jwt_secret, "acc1", "news", "u@x.io");
    const query = try std.fmt.allocPrint(a, "t={s}", .{token});

    var ctx_post = http.RequestCtx{ .method = .POST, .path = "/api/mail/unsubscribe", .query = query, .allocator = RequestArena.from(&arena), .app = &app };
    try testing.expectEqual(@as(u16, 404), (try post(&ctx_post)).status);

    var ctx_get = http.RequestCtx{ .method = .GET, .path = "/api/mail/unsubscribe", .query = query, .allocator = RequestArena.from(&arena), .app = &app };
    try testing.expectEqual(@as(u16, 404), (try get(&ctx_get)).status);
}

test "rate limit: rate_max allowed calls then 429" {
    const env = try Env.init();
    defer env.deinit();
    var rl = ratelimit.RateLimiter.init(testing.allocator, 1000, 60);
    defer rl.deinit();
    env.app.rate_limiter = &rl;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var i: u32 = 0;
    while (i < rate_max) : (i += 1) {
        var ctx = http.RequestCtx{ .method = .GET, .path = "/api/mail/unsubscribe", .query = "t=whatever", .allocator = RequestArena.from(&arena), .app = &env.app, .remote_ip = "1.2.3.4" };
        const res = try get(&ctx);
        try testing.expect(res.status != 429);
    }
    var ctx = http.RequestCtx{ .method = .GET, .path = "/api/mail/unsubscribe", .query = "t=whatever", .allocator = RequestArena.from(&arena), .app = &env.app, .remote_ip = "1.2.3.4" };
    const res = try get(&ctx);
    try testing.expectEqual(@as(u16, 429), res.status);
}
