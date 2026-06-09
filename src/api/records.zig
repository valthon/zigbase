const std = @import("std");
const http = @import("../http.zig");
const app_mod = @import("../app.zig");
const db = @import("../db.zig");
const migrations = @import("../migrations.zig");
const collections = @import("../collections.zig");
const schema = @import("../schema.zig");
const records = @import("../records.zig");
const ApiError = @import("error.zig").ApiError;
const FieldError = @import("error.zig").FieldError;
const params_mod = @import("../query/params.zig");
const expand_mod = @import("../query/expand.zig");

// TODO(SP4): enforce the collection's list/view/create/update/delete rules.

fn validationResponse(ctx: *http.RequestCtx) !http.Response {
    const verrs = records.last_errors orelse &[_]schema.ValidationError{};
    const fes = try ctx.allocator.alloc(FieldError, verrs.len);
    for (verrs, 0..) |e, i| fes[i] = .{ .field = e.field, .code = e.code, .message = e.message };
    return ApiError.validation(fes).toResponse(ctx.allocator);
}

fn resolveCollection(ctx: *http.RequestCtx, conn: *db.Db) !?schema.Collection {
    const name = ctx.param("col") orelse return null;
    return collections.get(ctx.allocator, conn, name);
}

fn jsonResponse(ctx: *http.RequestCtx, status: u16, v: std.json.Value) !http.Response {
    return .{ .status = status, .body = try std.json.Stringify.valueAlloc(ctx.allocator, v, .{}) };
}

pub fn view(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    var r = try app.pool.openReader();
    defer r.close();
    const col = (try resolveCollection(ctx, &r)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rid = ctx.param("id") orelse return ApiError.notFound().toResponse(ctx.allocator);
    var rec = (try records.get(ctx.allocator, &r, col, rid)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const qp = try params_mod.parse(ctx.allocator, ctx.query);
    if (qp.get("expand")) |exp| if (exp.len > 0) try expand_mod.expand(ctx.allocator, &r, col, &rec, exp, 0);
    return jsonResponse(ctx, 200, rec);
}

pub fn create(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const data = (std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.body, .{}) catch
        return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator)).value;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col = (try resolveCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rec = records.create(ctx.allocator, app.io, w, col, data) catch |e| switch (e) {
        error.Validation => return validationResponse(ctx),
        error.NotObject => return ApiError.badRequest("Body must be a JSON object.").toResponse(ctx.allocator),
        else => return e,
    };
    return jsonResponse(ctx, 201, rec);
}

pub fn update(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const data = (std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.body, .{}) catch
        return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator)).value;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col = (try resolveCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rid = ctx.param("id") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rec = (records.update(ctx.allocator, w, col, rid, data) catch |e| switch (e) {
        error.Validation => return validationResponse(ctx),
        error.NotObject => return ApiError.badRequest("Body must be a JSON object.").toResponse(ctx.allocator),
        else => return e,
    }) orelse return ApiError.notFound().toResponse(ctx.allocator);
    return jsonResponse(ctx, 200, rec);
}

pub fn delete(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col = (try resolveCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rid = ctx.param("id") orelse return ApiError.notFound().toResponse(ctx.allocator);
    if (!try records.delete(ctx.allocator, w, col, rid)) return ApiError.notFound().toResponse(ctx.allocator);
    return .{ .status = 204, .body = "" };
}

pub fn list(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    var r = try app.pool.openReader();
    defer r.close();
    const col = (try resolveCollection(ctx, &r)) orelse return ApiError.notFound().toResponse(ctx.allocator);

    const qp = try params_mod.parse(ctx.allocator, ctx.query);
    const page = parseU32(qp.get("page"), 1);
    const perPage = parseU32(qp.get("perPage"), 30);

    const result = records.list(ctx.allocator, &r, col, .{
        .filter = qp.get("filter"),
        .sort = qp.get("sort"),
        .page = page,
        .perPage = perPage,
    }) catch |e| switch (e) {
        error.UnknownField, error.NotARelation, error.MultiRelationTraversal, error.BadFilter, error.BadSort, error.BadValue, error.UnexpectedToken, error.BadOperand, error.Empty, error.UnexpectedChar, error.UnterminatedString =>
            return ApiError.badRequest("Invalid filter or sort.").toResponse(ctx.allocator),
        else => return e,
    };

    if (qp.get("expand")) |exp| if (exp.len > 0) {
        for (result.items) |*item| try expand_mod.expand(ctx.allocator, &r, col, item, exp, 0);
    };

    const total_pages: i64 = if (result.perPage == 0) 0 else @divTrunc(result.totalItems + @as(i64, result.perPage) - 1, @as(i64, result.perPage));
    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator, "page", .{ .integer = @intCast(result.page) });
    try root.put(ctx.allocator, "perPage", .{ .integer = @intCast(result.perPage) });
    try root.put(ctx.allocator, "totalItems", .{ .integer = result.totalItems });
    try root.put(ctx.allocator, "totalPages", .{ .integer = total_pages });
    var arr = std.json.Array.init(ctx.allocator);
    for (result.items) |it| try arr.append(it);
    try root.put(ctx.allocator, "items", .{ .array = arr });
    return jsonResponse(ctx, 200, .{ .object = root });
}

fn parseU32(s: ?[]const u8, default: u32) u32 {
    const v = s orelse return default;
    return std.fmt.parseInt(u32, v, 10) catch default;
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
            var setup_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer setup_arena.deinit();
            const sa = setup_arena.allocator();
            const fields = [_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }};
            _ = try collections.create(sa, std.testing.io, w, .{ .id = "", .name = "posts", .fields = &fields });
        }
        env.app = .{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = &env.pool };
        return env;
    }

    fn deinit(env: *TestEnv) void {
        env.pool.deinit();
        env.tmp.cleanup();
        std.testing.allocator.destroy(env);
    }
};

fn ctxFor(env: *TestEnv, a: std.mem.Allocator, m: http.Method, body: []const u8, params: []const http.Param) http.RequestCtx {
    return .{ .method = m, .path = "/", .body = body, .allocator = a, .app = &env.app, .params = params };
}

test "create then view a record over handlers" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col_param = [_]http.Param{.{ .key = "col", .value = "posts" }};

    var cctx = ctxFor(env, a, .POST, "{\"title\":\"hi\"}", &col_param);
    const cres = try create(&cctx);
    try std.testing.expectEqual(@as(u16, 201), cres.status);
    try std.testing.expect(std.mem.indexOf(u8, cres.body, "\"title\":\"hi\"") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, cres.body, .{});
    const rid = parsed.value.object.get("id").?.string;
    const view_params = [_]http.Param{ .{ .key = "col", .value = "posts" }, .{ .key = "id", .value = rid } };
    var vctx = ctxFor(env, a, .GET, "", &view_params);
    const vres = try view(&vctx);
    try std.testing.expectEqual(@as(u16, 200), vres.status);
}

test "view nonexistent collection -> 404" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const params = [_]http.Param{ .{ .key = "col", .value = "ghosts" }, .{ .key = "id", .value = "x" } };
    var ctx = ctxFor(env, arena.allocator(), .GET, "", &params);
    const res = try view(&ctx);
    try std.testing.expectEqual(@as(u16, 404), res.status);
}

test "list handler returns the page envelope" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col_param = [_]http.Param{.{ .key = "col", .value = "posts" }};
    var c1 = ctxFor(env, a, .POST, "{\"title\":\"a\"}", &col_param);
    _ = try create(&c1);
    var c2 = ctxFor(env, a, .POST, "{\"title\":\"b\"}", &col_param);
    _ = try create(&c2);

    var lctx = http.RequestCtx{ .method = .GET, .path = "/", .query = "perPage=1", .allocator = a, .app = &env.app, .params = &col_param };
    const res = try list(&lctx);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"totalItems\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"page\":1") != null);
}
