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
const rules = @import("../rules.zig");
const request = @import("../request.zig");
const auth = @import("../auth.zig");
const realtime_ws = @import("../realtime/ws.zig");
const file_plan = @import("../files/plan.zig");

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

/// Fills auth/superuser from the verified bearer/cookie token (anonymous if absent/invalid).
fn buildContext(ctx: *http.RequestCtx, conn: *db.Db, data: ?std.json.Value) request.RequestContext {
    if (ctx.app) |app| {
        if (auth.authenticate(app.io, ctx.allocator, app, ctx, conn) catch null) |a| {
            return .{ .auth = a.record, .is_superuser = a.is_superuser, .data = data, .method = @tagName(ctx.method) };
        }
    }
    return .{ .auth = null, .is_superuser = false, .data = data, .method = @tagName(ctx.method) };
}

fn forbidden(ctx: *http.RequestCtx) !http.Response {
    return (ApiError{ .status = 403, .message = "Forbidden." }).toResponse(ctx.allocator);
}

/// For auth collections, transform request data through auth.applyCreate/applyUpdate
/// (hash password, gen/rotate tokenKey, strip plaintext, force verified=false on create).
/// For non-auth collections, returns `data` unchanged. Maps a bad/short/missing password to BadPassword.
const AuthPrepError = error{BadPassword} || std.mem.Allocator.Error;

fn prepAuthData(ctx: *http.RequestCtx, col: schema.Collection, data: std.json.Value, comptime is_create: bool) AuthPrepError!std.json.Value {
    if (col.type != .auth) return data;
    const app = ctx.app.?;
    const min_len = col.options.auth.minPasswordLength;
    const out = if (is_create)
        auth.applyCreate(app.io, ctx.allocator, data, min_len)
    else
        auth.applyUpdate(app.io, ctx.allocator, data, min_len);
    return out catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadPassword, // PasswordTooShort and rare hashing/token failures -> bad request
    };
}

/// Write the planned uploads for `record_id` via Storage, then delete replaced/removed files.
/// On a write failure, deletes the files written so far and returns error.StorageFailed (caller
/// rolls back the record). No-op when no storage is configured (unit tests).
fn writeUploads(ctx: *http.RequestCtx, col: schema.Collection, record_id: []const u8, writes: []const file_plan.FieldWrite, deletes: []const []const u8) !void {
    const app = ctx.app.?;
    const storage = app.storage orelse return;
    var written: usize = 0;
    for (writes) |wr| {
        storage.put(app.io, col.name, record_id, wr.filename, wr.bytes) catch {
            for (writes[0..written]) |dw| storage.delete(app.io, col.name, record_id, dw.filename) catch {};
            return error.StorageFailed;
        };
        written += 1;
    }
    for (deletes) |d| storage.delete(app.io, col.name, record_id, d) catch {};
}

pub fn view(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    var r = try app.pool.openReader();
    defer r.close();
    const col = (try resolveCollection(ctx, &r)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rid = ctx.param("id") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rctx = buildContext(ctx, &r, null);
    switch (rules.decide(col.viewRule, &rctx)) {
        .deny_locked => return ApiError.notFound().toResponse(ctx.allocator),
        .allow => {},
        .check => if (!try rules.matches(ctx.allocator, &r, col, rid, col.viewRule.?, &rctx)) return ApiError.notFound().toResponse(ctx.allocator),
    }
    var rec = (try records.get(ctx.allocator, &r, col, rid)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const qp = try params_mod.parse(ctx.allocator, ctx.query);
    if (qp.get("expand")) |exp| if (exp.len > 0) try expand_mod.expand(ctx.allocator, &r, col, &rec, exp, 0);
    return jsonResponse(ctx, 200, rec);
}

pub fn create(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const raw = if (ctx.form_fields) |ff| ff else (std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.body, .{}) catch
        return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator)).value;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col = (try resolveCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);

    const all = file_plan.planAllFileFields(app.io, ctx.allocator, col, raw, ctx.files, null) catch |e| switch (e) {
        error.TooLarge => return (ApiError{ .status = 413, .message = "File too large." }).toResponse(ctx.allocator),
        error.TooMany => return ApiError.badRequest("Too many files for the field.").toResponse(ctx.allocator),
        error.BadMimeType => return ApiError.badRequest("File type not allowed.").toResponse(ctx.allocator),
        error.OutOfMemory => return e,
    };
    const data = all.data;

    const data2 = prepAuthData(ctx, col, data, true) catch |e| switch (e) {
        error.BadPassword => return ApiError.badRequest("A password of the required length is required.").toResponse(ctx.allocator),
        error.OutOfMemory => return e,
    };
    const rctx = buildContext(ctx, w, data);
    const rec = switch (rules.decide(col.createRule, &rctx)) {
        .deny_locked => return forbidden(ctx),
        .allow => records.create(ctx.allocator, app.io, w, col, data2),
        .check => records.createGuarded(ctx.allocator, app.io, w, col, data2, try rules.compileGuard(ctx.allocator, w, col, col.createRule.?, &rctx)),
    } catch |e| switch (e) {
        error.Validation => return validationResponse(ctx),
        error.NotObject => return ApiError.badRequest("Body must be a JSON object.").toResponse(ctx.allocator),
        error.Forbidden => return forbidden(ctx),
        else => return e,
    };
    const rid = rec.object.get("id").?.string;
    writeUploads(ctx, col, rid, all.writes, all.deletes) catch {
        _ = records.delete(ctx.allocator, w, col, rid) catch {};
        return ApiError.internal().toResponse(ctx.allocator);
    };
    realtime_ws.broadcast(app, col, .create, rid, rec);
    return jsonResponse(ctx, 201, rec);
}

pub fn update(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const raw = if (ctx.form_fields) |ff| ff else (std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.body, .{}) catch
        return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator)).value;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col = (try resolveCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rid = ctx.param("id") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const existing = (try records.get(ctx.allocator, w, col, rid)) orelse return ApiError.notFound().toResponse(ctx.allocator);

    const all = file_plan.planAllFileFields(app.io, ctx.allocator, col, raw, ctx.files, existing) catch |e| switch (e) {
        error.TooLarge => return (ApiError{ .status = 413, .message = "File too large." }).toResponse(ctx.allocator),
        error.TooMany => return ApiError.badRequest("Too many files for the field.").toResponse(ctx.allocator),
        error.BadMimeType => return ApiError.badRequest("File type not allowed.").toResponse(ctx.allocator),
        error.OutOfMemory => return e,
    };
    const data = all.data;

    const data2 = prepAuthData(ctx, col, data, false) catch |e| switch (e) {
        error.BadPassword => return ApiError.badRequest("A password of the required length is required.").toResponse(ctx.allocator),
        error.OutOfMemory => return e,
    };
    const rctx = buildContext(ctx, w, data);
    const updated = switch (rules.decide(col.updateRule, &rctx)) {
        .deny_locked => return forbidden(ctx),
        .allow => records.update(ctx.allocator, w, col, rid, data2),
        .check => records.updateGuarded(ctx.allocator, w, col, rid, data2, try rules.compileGuard(ctx.allocator, w, col, col.updateRule.?, &rctx)),
    } catch |e| switch (e) {
        error.Validation => return validationResponse(ctx),
        error.NotObject => return ApiError.badRequest("Body must be a JSON object.").toResponse(ctx.allocator),
        error.Forbidden => return ApiError.notFound().toResponse(ctx.allocator),
        else => return e,
    };
    const ur = updated orelse return ApiError.notFound().toResponse(ctx.allocator);
    writeUploads(ctx, col, ur.object.get("id").?.string, all.writes, all.deletes) catch {};
    realtime_ws.broadcast(app, col, .update, ur.object.get("id").?.string, ur);
    return jsonResponse(ctx, 200, ur);
}

pub fn delete(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col = (try resolveCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rid = ctx.param("id") orelse return ApiError.notFound().toResponse(ctx.allocator);
    if ((try records.get(ctx.allocator, w, col, rid)) == null) return ApiError.notFound().toResponse(ctx.allocator);
    const rctx = buildContext(ctx, w, null);
    switch (rules.decide(col.deleteRule, &rctx)) {
        .deny_locked => return forbidden(ctx),
        .allow => {},
        .check => if (!try rules.matches(ctx.allocator, w, col, rid, col.deleteRule.?, &rctx)) return ApiError.notFound().toResponse(ctx.allocator),
    }
    if (!try records.delete(ctx.allocator, w, col, rid)) return ApiError.notFound().toResponse(ctx.allocator);
    if (col.type == .auth) {
        var st = try w.prepare("DELETE FROM \"_externalAuths\" WHERE \"collectionRef\"=?1 AND \"recordRef\"=?2;");
        defer st.finalize();
        try st.bindText(1, col.name);
        try st.bindText(2, rid);
        _ = try st.step();
    }
    if (app.storage) |storage| storage.deleteRecord(app.io, col.name, rid) catch {};
    realtime_ws.broadcast(app, col, .delete, rid, null);
    return .{ .status = 204, .body = "" };
}

pub fn list(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    var r = try app.pool.openReader();
    defer r.close();
    const col = (try resolveCollection(ctx, &r)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rctx = buildContext(ctx, &r, null);
    var rule_expr: ?[]const u8 = null;
    switch (rules.decide(col.listRule, &rctx)) {
        .deny_locked => return forbidden(ctx),
        .allow => {},
        .check => rule_expr = col.listRule,
    }
    const qp = try params_mod.parse(ctx.allocator, ctx.query);
    const page = parseU32(qp.get("page"), 1);
    const perPage = parseU32(qp.get("perPage"), 30);

    const result = records.list(ctx.allocator, &r, col, .{
        .filter = qp.get("filter"),
        .sort = qp.get("sort"),
        .page = page,
        .perPage = perPage,
        .rule = rule_expr,
        .rctx = &rctx,
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
            _ = try collections.create(sa, std.testing.io, w, .{
                .id = "", .name = "posts",
                .fields = &[_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }},
                .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "",
            });
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

fn seedRuled(env: *TestEnv, name: []const u8, listR: ?[]const u8, viewR: ?[]const u8, createR: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    _ = try collections.create(a, std.testing.io, w, .{
        .id = "", .name = name,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }},
        .listRule = listR, .viewRule = viewR, .createRule = createR,
    });
}

test "locked (null) collection: list 403, create 403" {
    var env = try TestEnv.init();
    defer env.deinit();
    try seedRuled(env, "locked", null, null, null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = [_]http.Param{.{ .key = "col", .value = "locked" }};
    var lctx = http.RequestCtx{ .method = .GET, .path = "/", .query = "", .allocator = a, .app = &env.app, .params = &p };
    try std.testing.expectEqual(@as(u16, 403), (try list(&lctx)).status);
    var cctx = ctxFor(env, a, .POST, "{\"title\":\"x\"}", &p);
    try std.testing.expectEqual(@as(u16, 403), (try create(&cctx)).status);
}

test "createRule on request data: empty title -> 403, nonempty -> 201" {
    var env = try TestEnv.init();
    defer env.deinit();
    try seedRuled(env, "guarded", "", "", "@request.data.title != \"\"");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = [_]http.Param{.{ .key = "col", .value = "guarded" }};
    var bad = ctxFor(env, a, .POST, "{\"title\":\"\"}", &p);
    try std.testing.expectEqual(@as(u16, 403), (try create(&bad)).status);
    var ok = ctxFor(env, a, .POST, "{\"title\":\"hello\"}", &p);
    try std.testing.expectEqual(@as(u16, 201), (try create(&ok)).status);
}

fn seedAuth(env: *TestEnv, name: []const u8, createR: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    _ = try collections.create(a, std.testing.io, w, .{
        .id = "", .name = name, .type = .auth,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
        .listRule = "", .viewRule = "", .createRule = createR, .updateRule = "", .deleteRule = "",
    });
}

test "creating an auth record hashes the password, hides secrets, forces verified=false" {
    var env = try TestEnv.init();
    defer env.deinit();
    try seedAuth(env, "users", "");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var cctx = ctxFor(env, a, .POST, "{\"email\":\"u@x.io\",\"password\":\"longenough\",\"verified\":true}", &p);
    const res = try create(&cctx);
    try std.testing.expectEqual(@as(u16, 201), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "passwordHash") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "tokenKey") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "password") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"verified\":false") != null);
}

test "creating an auth record without a password is a 400" {
    var env = try TestEnv.init();
    defer env.deinit();
    try seedAuth(env, "users2", "");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = [_]http.Param{.{ .key = "col", .value = "users2" }};
    var cctx = ctxFor(env, a, .POST, "{\"email\":\"u@x.io\"}", &p);
    const res = try create(&cctx);
    try std.testing.expectEqual(@as(u16, 400), res.status);
}
