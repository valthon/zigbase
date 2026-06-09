const std = @import("std");
const http = @import("../http.zig");
const app_mod = @import("../app.zig");
const db = @import("../db.zig");
const migrations = @import("../migrations.zig");
const schema = @import("../schema.zig");
const collections = @import("../collections.zig");
const auth = @import("../auth.zig");
const crypto = @import("../crypto.zig");
const jwt = @import("../jwt.zig");
const ApiError = @import("error.zig").ApiError;
const FieldError = @import("error.zig").FieldError;

/// True if the request carries a valid superuser token. Uses a short-lived reader connection.
fn isSuperuser(ctx: *http.RequestCtx) bool {
    const app = ctx.app orelse return false;
    var r = app.pool.openReader() catch return false;
    defer r.close();
    const authed = (auth.authenticate(app.io, ctx.allocator, app, ctx, &r) catch null) orelse return false;
    return authed.is_superuser;
}

fn requireSuperuser(ctx: *http.RequestCtx) ?http.Response {
    if (isSuperuser(ctx)) return null;
    return (ApiError{ .status = 403, .message = "Forbidden." }).toResponse(ctx.allocator) catch
        ApiError.internal().toResponse(ctx.allocator) catch unreachable;
}

fn validationResponse(ctx: *http.RequestCtx) !http.Response {
    const verrs = collections.last_errors orelse &[_]schema.ValidationError{};
    const fes = try ctx.allocator.alloc(FieldError, verrs.len);
    for (verrs, 0..) |e, i| fes[i] = .{ .field = e.field, .code = e.code, .message = e.message };
    return ApiError.validation(fes).toResponse(ctx.allocator);
}

pub fn list(ctx: *http.RequestCtx) anyerror!http.Response {
    if (requireSuperuser(ctx)) |resp| return resp;
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const cols = try collections.list(ctx.allocator, w);
    var arr: std.json.Array = std.json.Array.init(ctx.allocator);
    for (cols) |c| {
        const cj = try schema.collectionToJson(ctx.allocator, c);
        try arr.append((try std.json.parseFromSlice(std.json.Value, ctx.allocator, cj, .{})).value);
    }
    const body = try std.json.Stringify.valueAlloc(ctx.allocator, std.json.Value{ .array = arr }, .{});
    return .{ .status = 200, .body = body };
}

pub fn create(ctx: *http.RequestCtx) anyerror!http.Response {
    if (requireSuperuser(ctx)) |resp| return resp;
    const app = ctx.app.?;
    const def = schema.parseCollectionInput(ctx.allocator, ctx.body) catch
        return ApiError.badRequest("Invalid request body.").toResponse(ctx.allocator);
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const created = collections.create(ctx.allocator, app.io, w, def) catch |e| switch (e) {
        error.Validation => return validationResponse(ctx),
        error.Conflict => return ApiError.conflict("Collection already exists.").toResponse(ctx.allocator),
        else => return e,
    };
    return .{ .status = 201, .body = try schema.collectionToJson(ctx.allocator, created) };
}

pub fn get(ctx: *http.RequestCtx) anyerror!http.Response {
    if (requireSuperuser(ctx)) |resp| return resp;
    const app = ctx.app.?;
    const key = ctx.param("idOrName") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col =(try collections.get(ctx.allocator, w, key)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    return .{ .status = 200, .body = try schema.collectionToJson(ctx.allocator, col) };
}

pub fn update(ctx: *http.RequestCtx) anyerror!http.Response {
    if (requireSuperuser(ctx)) |resp| return resp;
    const app = ctx.app.?;
    const key = ctx.param("idOrName") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const def = schema.parseCollectionInput(ctx.allocator, ctx.body) catch
        return ApiError.badRequest("Invalid request body.").toResponse(ctx.allocator);
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const updated = collections.update(ctx.allocator, app.io, w, key, def) catch |e| switch (e) {
        error.NotFound => return ApiError.notFound().toResponse(ctx.allocator),
        error.Validation => return validationResponse(ctx),
        error.Conflict => return ApiError.conflict("Conflict.").toResponse(ctx.allocator),
        else => return e,
    };
    return .{ .status = 200, .body = try schema.collectionToJson(ctx.allocator, updated) };
}

pub fn delete(ctx: *http.RequestCtx) anyerror!http.Response {
    if (requireSuperuser(ctx)) |resp| return resp;
    const app = ctx.app.?;
    const key = ctx.param("idOrName") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    collections.delete(ctx.allocator, w, key) catch |e| switch (e) {
        error.NotFound => return ApiError.notFound().toResponse(ctx.allocator),
        error.Conflict => return ApiError.conflict("Collection is referenced by a relation.").toResponse(ctx.allocator),
        else => return e,
    };
    return .{ .status = 204, .body = "" };
}

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
        env.pool = try db.Pool.init(std.testing.allocator, path);
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

fn ctxFor(env: *TestEnv, arena: std.mem.Allocator, method: http.Method, path: []const u8, body: []const u8, params: []const http.Param) http.RequestCtx {
    return .{ .method = method, .path = path, .body = body, .allocator = arena, .app = &env.app, .params = params };
}

test "create then get then list a collection over handlers" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const auth_hdr = try std.fmt.allocPrint(a, "Bearer {s}", .{try env.superuserToken(a)});

    const body =
        \\{"name":"posts","fields":[{"id":"","name":"title","type":"text","options":{}}]}
    ;
    var cctx = ctxFor(env, a, .POST, "/api/collections", body, &.{});
    cctx.authorization = auth_hdr;
    const cres = try create(&cctx);
    try std.testing.expectEqual(@as(u16, 201), cres.status);
    try std.testing.expect(std.mem.indexOf(u8, cres.body, "\"name\":\"posts\"") != null);

    var gctx = ctxFor(env, a, .GET, "/api/collections/posts", "", &.{.{ .key = "idOrName", .value = "posts" }});
    gctx.authorization = auth_hdr;
    const gres = try get(&gctx);
    try std.testing.expectEqual(@as(u16, 200), gres.status);

    var lctx = ctxFor(env, a, .GET, "/api/collections", "", &.{});
    lctx.authorization = auth_hdr;
    const lres = try list(&lctx);
    try std.testing.expectEqual(@as(u16, 200), lres.status);
    try std.testing.expect(std.mem.indexOf(u8, lres.body, "\"posts\"") != null);
}

test "create with invalid name returns 400 with field errors" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cctx = ctxFor(env, a, .POST, "/api/collections", "{\"name\":\"1bad\",\"fields\":[]}", &.{});
    cctx.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{try env.superuserToken(a)});
    const res = try create(&cctx);
    try std.testing.expectEqual(@as(u16, 400), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "validation_invalid_name") != null);
}

test "collection management requires a superuser" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var anon = ctxFor(env, a, .GET, "/api/collections", "", &.{});
    try std.testing.expectEqual(@as(u16, 403), (try list(&anon)).status);

    const token = try env.superuserToken(a);
    var su = ctxFor(env, a, .GET, "/api/collections", "", &.{});
    su.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    try std.testing.expectEqual(@as(u16, 200), (try list(&su)).status);
}
