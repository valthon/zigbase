const std = @import("std");
const RequestArena = @import("../request_arena.zig").RequestArena;
const http = @import("../http.zig");
const auth = @import("../auth.zig");
const Data = @import("../data.zig").Data;
const ApiError = @import("error.zig").ApiError;
const app_mod = @import("../app.zig");
const db = @import("../db.zig");
const migrations = @import("../migrations.zig");
const crypto = @import("../crypto.zig");
const jwt = @import("../jwt.zig");
const realtime_ws = @import("../realtime/ws.zig");

/// True for the feature-management override keys (`flag:<name>` and `exp:<name>:weights`),
/// the only `_kv` writes that must fan out the realtime `__features` signal. Distinct
/// prefixes mean an arbitrary setting never triggers a broadcast.
fn isFeatureOverrideKey(key: []const u8) bool {
    if (std.mem.startsWith(u8, key, "flag:")) return true;
    if (std.mem.startsWith(u8, key, "exp:") and std.mem.endsWith(u8, key, ":weights")) return true;
    return false;
}

// Superuser-only HTTP surface over the built-in key→value/settings store (#87/#88).
// KV/settings are server-managed and never public by default; every handler here
// gates on a valid superuser token. A consumer who wants to publish a specific value
// (e.g. a feature flag) writes their own custom route calling `ctx.flag`/`ctx.kv`.

/// True if the request carries a valid superuser token. Uses a short-lived reader.
fn isSuperuser(ctx: *http.RequestCtx) bool {
    const app = ctx.app orelse return false;
    var r = app.pool.acquireReader() catch return false;
    defer app.pool.releaseReader(&r);
    const authed = (auth.authenticate(app.io, ctx.allocator.a, app, ctx, &r) catch null) orelse return false;
    return authed.is_superuser;
}

fn requireSuperuser(ctx: *http.RequestCtx) !?http.Response {
    if (isSuperuser(ctx)) return null;
    // Building the 403 body allocates (JSON on the request arena), so OutOfMemory is reachable —
    // propagate it to the server's 500 backstop rather than `catch unreachable` (#29).
    return try ApiError.forbidden().toResponse(ctx.allocator.a);
}

fn dataOnWriter(ctx: *http.RequestCtx) Data {
    const app = ctx.app.?;
    return .{ .app = app, .conn = app.pool.acquireWriter(), .io = app.io, .alloc = ctx.allocator.a };
}

fn entryJson(alloc: std.mem.Allocator, e: Data.KvEntry) !std.json.Value {
    var o: std.json.ObjectMap = .empty;
    try o.put(alloc, "key", .{ .string = e.key });
    try o.put(alloc, "value", .{ .string = e.value });
    try o.put(alloc, "created", .{ .string = e.created });
    try o.put(alloc, "updated", .{ .string = e.updated });
    return .{ .object = o };
}

/// GET /api/settings — list every setting (superuser only).
pub fn list(ctx: *http.RequestCtx) anyerror!http.Response {
    if (try requireSuperuser(ctx)) |resp| return resp;
    const app = ctx.app.?;
    const d = dataOnWriter(ctx);
    defer app.pool.releaseWriter();
    const entries = try d.kvList();
    var arr: std.json.Array = std.json.Array.init(ctx.allocator.a);
    for (entries) |e| try arr.append(try entryJson(ctx.allocator.a, e));
    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator.a, "items", .{ .array = arr });
    const body = try std.json.Stringify.valueAlloc(ctx.allocator.a, std.json.Value{ .object = root }, .{});
    return .{ .status = 200, .body = body };
}

/// GET /api/settings/:key — fetch one setting (superuser only). 404 if absent.
pub fn get(ctx: *http.RequestCtx) anyerror!http.Response {
    if (try requireSuperuser(ctx)) |resp| return resp;
    const app = ctx.app.?;
    const key = ctx.param("key") orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    const d = dataOnWriter(ctx);
    defer app.pool.releaseWriter();
    const value = (try d.kvGet(key)) orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    const body = try std.json.Stringify.valueAlloc(ctx.allocator.a, try entryJsonKeyValue(ctx.allocator.a, key, value), .{});
    return .{ .status = 200, .body = body };
}

fn entryJsonKeyValue(alloc: std.mem.Allocator, key: []const u8, value: []const u8) !std.json.Value {
    var o: std.json.ObjectMap = .empty;
    try o.put(alloc, "key", .{ .string = key });
    try o.put(alloc, "value", .{ .string = value });
    return .{ .object = o };
}

const PutBody = struct { value: []const u8 };

/// PUT /api/settings/:key — upsert a setting (superuser only). Body: {"value":"..."}.
pub fn put(ctx: *http.RequestCtx) anyerror!http.Response {
    if (try requireSuperuser(ctx)) |resp| return resp;
    const app = ctx.app.?;
    const key = ctx.param("key") orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    const parsed = std.json.parseFromSlice(PutBody, ctx.allocator.a, ctx.body, .{ .ignore_unknown_fields = true }) catch
        return ApiError.badRequest("Body must be {\"value\": \"...\"}.").toResponse(ctx.allocator.a);
    const d = dataOnWriter(ctx);
    defer app.pool.releaseWriter();
    try d.kvSet(key, parsed.value.value);
    // Feature-override change: invalidate the in-process override cache (#230) so the next
    // resolution re-scans (called unconditionally, NOT gated on the reactor; the write is
    // already committed on the writer) and signal subscribers to re-GET /api/state.
    if (isFeatureOverrideKey(key)) {
        if (app.feature_cache) |fc| fc.invalidate();
        realtime_ws.broadcastFeaturesChanged(app);
    }
    const body = try std.json.Stringify.valueAlloc(ctx.allocator.a, try entryJsonKeyValue(ctx.allocator.a, key, parsed.value.value), .{});
    return .{ .status = 200, .body = body };
}

/// DELETE /api/settings/:key — remove a setting (superuser only). 404 if absent.
pub fn delete(ctx: *http.RequestCtx) anyerror!http.Response {
    if (try requireSuperuser(ctx)) |resp| return resp;
    const app = ctx.app.?;
    const key = ctx.param("key") orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    const d = dataOnWriter(ctx);
    defer app.pool.releaseWriter();
    if (!(try d.kvDelete(key))) return ApiError.notFound().toResponse(ctx.allocator.a);
    // Clearing a feature override reverts to the declared default: invalidate the override
    // cache (#230, unconditional / not reactor-gated; the delete is committed) and signal.
    if (isFeatureOverrideKey(key)) {
        if (app.feature_cache) |fc| fc.invalidate();
        realtime_ws.broadcastFeaturesChanged(app);
    }
    return .{ .status = 204, .body = "" };
}

// ---------------------------------------------------------------------------
// Tests — mirror the TestEnv/superuserToken harness from api/collections.zig.
// ---------------------------------------------------------------------------

const TestEnv = struct {
    tmp: std.testing.TmpDir,
    pool: db.Pool,
    app: app_mod.App,

    fn init() !*TestEnv {
        const env = try std.testing.allocator.create(TestEnv);
        env.tmp = std.testing.tmpDir(.{});
        const dir = try env.tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(dir);
        const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/test.db", .{dir}, 0);
        defer std.testing.allocator.free(path);
        env.pool = try db.Pool.init(std.testing.allocator, std.testing.io, path);
        {
            const w = env.pool.acquireWriter();
            defer env.pool.releaseWriter();
            try migrations.run(w);
        }
        env.app = .{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = &env.pool };
        return env;
    }
    fn deinit(env: *TestEnv) void {
        env.pool.deinit();
        env.tmp.cleanup();
        std.testing.allocator.destroy(env);
    }
    fn superuserToken(env: *TestEnv, a: std.mem.Allocator) ![]const u8 {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try w.exec("INSERT INTO \"_superusers\" (\"id\",\"created\",\"updated\",\"email\",\"username\",\"passwordHash\",\"tokenKey\",\"verified\") VALUES ('su1','','','admin@x.io','','','sutk',1);");
        const key = crypto.deriveKey(env.app.jwt_secret, "sutk");
        return jwt.sign(a, .{ .id = "su1", .collection = "_superusers", .type = .auth, .iat = 0, .exp = 9999999999 }, &key);
    }
};

fn ctxFor(env: *TestEnv, arena: RequestArena, method: http.Method, path: []const u8, body: []const u8, params: []const http.Param) http.RequestCtx {
    return .{ .method = method, .path = path, .body = body, .allocator = arena, .app = &env.app, .params = params };
}

test "isFeatureOverrideKey matches flag:/exp:*:weights only" {
    try std.testing.expect(isFeatureOverrideKey("flag:checkout_enabled"));
    try std.testing.expect(isFeatureOverrideKey("exp:layout:weights"));
    // Not a feature key: arbitrary settings never trigger a broadcast.
    try std.testing.expect(!isFeatureOverrideKey("beta"));
    try std.testing.expect(!isFeatureOverrideKey("exp:layout")); // no :weights suffix
    try std.testing.expect(!isFeatureOverrideKey("smtp_host"));
}

test "settings API requires a superuser" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // No auth header -> 403 on every verb.
    var lctx = ctxFor(env, RequestArena.from(&arena), .GET, "/api/settings", "", &.{});
    try std.testing.expectEqual(@as(u16, 403), (try list(&lctx)).status);
    var pctx = ctxFor(env, RequestArena.from(&arena), .PUT, "/api/settings/x", "{\"value\":\"1\"}", &.{.{ .key = "key", .value = "x" }});
    try std.testing.expectEqual(@as(u16, 403), (try put(&pctx)).status);
}

test "settings API put/get/list/delete round-trips for a superuser" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const auth_hdr = try std.fmt.allocPrint(a, "Bearer {s}", .{try env.superuserToken(a)});

    // Absent key -> 404.
    var g0 = ctxFor(env, RequestArena.from(&arena), .GET, "/api/settings/beta", "", &.{.{ .key = "key", .value = "beta" }});
    g0.authorization = auth_hdr;
    try std.testing.expectEqual(@as(u16, 404), (try get(&g0)).status);

    // PUT upserts.
    var p = ctxFor(env, RequestArena.from(&arena), .PUT, "/api/settings/beta", "{\"value\":\"true\"}", &.{.{ .key = "key", .value = "beta" }});
    p.authorization = auth_hdr;
    const pres = try put(&p);
    try std.testing.expectEqual(@as(u16, 200), pres.status);

    // GET returns it.
    var g = ctxFor(env, RequestArena.from(&arena), .GET, "/api/settings/beta", "", &.{.{ .key = "key", .value = "beta" }});
    g.authorization = auth_hdr;
    const gres = try get(&g);
    try std.testing.expectEqual(@as(u16, 200), gres.status);
    try std.testing.expect(std.mem.indexOf(u8, gres.body, "\"value\":\"true\"") != null);

    // LIST includes it.
    var l = ctxFor(env, RequestArena.from(&arena), .GET, "/api/settings", "", &.{});
    l.authorization = auth_hdr;
    const lres = try list(&l);
    try std.testing.expectEqual(@as(u16, 200), lres.status);
    try std.testing.expect(std.mem.startsWith(u8, lres.body, "{\"items\":["));
    try std.testing.expect(std.mem.indexOf(u8, lres.body, "\"beta\"") != null);

    // Bad body -> 400.
    var pb = ctxFor(env, RequestArena.from(&arena), .PUT, "/api/settings/beta", "not json", &.{.{ .key = "key", .value = "beta" }});
    pb.authorization = auth_hdr;
    try std.testing.expectEqual(@as(u16, 400), (try put(&pb)).status);

    // DELETE removes (204), then 404.
    var d1 = ctxFor(env, RequestArena.from(&arena), .DELETE, "/api/settings/beta", "", &.{.{ .key = "key", .value = "beta" }});
    d1.authorization = auth_hdr;
    try std.testing.expectEqual(@as(u16, 204), (try delete(&d1)).status);
    var d2 = ctxFor(env, RequestArena.from(&arena), .DELETE, "/api/settings/beta", "", &.{.{ .key = "key", .value = "beta" }});
    d2.authorization = auth_hdr;
    try std.testing.expectEqual(@as(u16, 404), (try delete(&d2)).status);
}
