const std = @import("std");
const RequestArena = @import("../request_arena.zig").RequestArena;
const http = @import("../http.zig");
const auth = @import("../auth.zig");
const Data = @import("../data.zig").Data;
const ApiError = @import("error.zig").ApiError;
const app_mod = @import("../app.zig");
const features = @import("../features.zig");
const db = @import("../db.zig");
const migrations = @import("../migrations.zig");
const crypto = @import("../crypto.zig");
const jwt = @import("../jwt.zig");

// Superuser-only read endpoint for the comptime-declared feature-flag + experiment registry
// plus their current `_kv` overrides. Mirrors the auth guard from api/settings.zig.

fn isSuperuser(ctx: *http.RequestCtx) bool {
    const app = ctx.app orelse return false;
    var r = app.pool.acquireReader() catch return false;
    defer app.pool.releaseReader(&r);
    const authed = (auth.authenticate(app.io, ctx.allocator.a, app, ctx, &r) catch null) orelse return false;
    return authed.is_superuser;
}

fn requireSuperuser(ctx: *http.RequestCtx) !?http.Response {
    if (isSuperuser(ctx)) return null;
    // Building the 403 body allocates (JSON on the request arena), so OutOfMemory is reachable
    // here — propagate it to the server's 500 backstop rather than `catch unreachable` (#29).
    return try (ApiError{ .status = 403, .message = "Forbidden." }).toResponse(ctx.allocator.a);
}

fn dataOnWriter(ctx: *http.RequestCtx) Data {
    const app = ctx.app.?;
    return .{ .app = app, .conn = app.pool.acquireWriter(), .io = app.io, .alloc = ctx.allocator.a };
}

/// GET /api/features — return the declared flag + experiment registry and each entry's
/// current `_kv` override (superuser only). The registry comes from `app.features`
/// (threaded in at comptime by `App(cfg)`); an app with no `.flags`/`.experiments`
/// returns empty arrays.
///
/// Response shape:
/// ```json
/// {
///   "flags": [
///     { "name": "checkout_enabled", "default": true, "description": "…",
///       "override": "true" }          // null when no _kv override is set
///   ],
///   "experiments": [
///     { "name": "checkout_layout", "variants": ["control","compact"],
///       "weights": [50,50], "sticky": false, "description": "…",
///       "weight_override": "[90,10]" }  // null when no _kv override is set
///   ]
/// }
/// ```
pub fn get(ctx: *http.RequestCtx) anyerror!http.Response {
    if (try requireSuperuser(ctx)) |resp| return resp;
    const app = ctx.app.?;

    // Declared registry: threaded in at comptime, null when no flags/experiments declared.
    const empty_reg = features.Registry{};
    const reg: features.Registry = if (app.features) |r| r.* else empty_reg;

    // Read all _kv entries in one scan to look up overrides.
    const d = dataOnWriter(ctx);
    defer app.pool.releaseWriter();
    const all_kv = try d.kvList();

    // ── Flags ──────────────────────────────────────────────────────────────
    var flags_arr = std.json.Array.init(ctx.allocator.a);
    for (reg.flags) |def| {
        const key = try std.fmt.allocPrint(ctx.allocator.a, "flag:{s}", .{def.name});
        var override_val: ?[]const u8 = null;
        for (all_kv) |e| {
            if (std.mem.eql(u8, e.key, key)) {
                override_val = e.value;
                break;
            }
        }

        var o: std.json.ObjectMap = .empty;
        try o.put(ctx.allocator.a, "name", .{ .string = def.name });
        try o.put(ctx.allocator.a, "default", .{ .bool = def.default });
        try o.put(ctx.allocator.a, "description", .{ .string = def.description });
        if (override_val) |v| {
            try o.put(ctx.allocator.a, "override", .{ .string = v });
        } else {
            try o.put(ctx.allocator.a, "override", .null);
        }
        try flags_arr.append(.{ .object = o });
    }

    // ── Experiments ────────────────────────────────────────────────────────
    var exps_arr = std.json.Array.init(ctx.allocator.a);
    for (reg.experiments) |def| {
        const key = try std.fmt.allocPrint(ctx.allocator.a, "exp:{s}:weights", .{def.name});
        var weight_override: ?[]const u8 = null;
        for (all_kv) |e| {
            if (std.mem.eql(u8, e.key, key)) {
                weight_override = e.value;
                break;
            }
        }

        var variants_arr = std.json.Array.init(ctx.allocator.a);
        for (def.variants) |v| try variants_arr.append(.{ .string = v });

        var weights_arr = std.json.Array.init(ctx.allocator.a);
        for (def.weights) |w| try weights_arr.append(.{ .integer = @as(i64, w) });

        var o: std.json.ObjectMap = .empty;
        try o.put(ctx.allocator.a, "name", .{ .string = def.name });
        try o.put(ctx.allocator.a, "variants", .{ .array = variants_arr });
        try o.put(ctx.allocator.a, "weights", .{ .array = weights_arr });
        try o.put(ctx.allocator.a, "sticky", .{ .bool = def.sticky });
        try o.put(ctx.allocator.a, "description", .{ .string = def.description });
        if (weight_override) |w| {
            try o.put(ctx.allocator.a, "weight_override", .{ .string = w });
        } else {
            try o.put(ctx.allocator.a, "weight_override", .null);
        }
        try exps_arr.append(.{ .object = o });
    }

    var resp_obj: std.json.ObjectMap = .empty;
    try resp_obj.put(ctx.allocator.a, "flags", .{ .array = flags_arr });
    try resp_obj.put(ctx.allocator.a, "experiments", .{ .array = exps_arr });
    const body = try std.json.Stringify.valueAlloc(
        ctx.allocator.a,
        std.json.Value{ .object = resp_obj },
        .{},
    );
    return .{ .status = 200, .body = body };
}

// ---------------------------------------------------------------------------
// Tests
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

fn ctxFor(env: *TestEnv, arena: RequestArena, method: http.Method, path: []const u8, params: []const http.Param) http.RequestCtx {
    return .{ .method = method, .path = path, .body = "", .allocator = arena, .app = &env.app, .params = params };
}

test "GET /api/features requires a superuser" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = ctxFor(env, RequestArena.from(&arena), .GET, "/api/features", &.{});
    const res = try get(&ctx);
    try std.testing.expectEqual(@as(u16, 403), res.status);
}

test "GET /api/features returns empty arrays when no registry is wired" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const auth_hdr = try std.fmt.allocPrint(a, "Bearer {s}", .{try env.superuserToken(a)});

    var ctx = ctxFor(env, RequestArena.from(&arena), .GET, "/api/features", &.{});
    ctx.authorization = auth_hdr;
    const res = try get(&ctx);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    // Empty registry → both arrays present but empty.
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"flags\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"experiments\":[]") != null);
}

test "GET /api/features returns declared flags with overrides" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const auth_hdr = try std.fmt.allocPrint(a, "Bearer {s}", .{try env.superuserToken(a)});

    // Wire a registry with one flag.
    const reg = features.Registry{
        .flags = &.{.{ .name = "dark_mode", .default = false, .description = "Dark theme" }},
        .experiments = &.{},
    };
    env.app.features = &reg;

    // No override yet → "override":null.
    var ctx1 = ctxFor(env, RequestArena.from(&arena), .GET, "/api/features", &.{});
    ctx1.authorization = auth_hdr;
    const r1 = try get(&ctx1);
    try std.testing.expectEqual(@as(u16, 200), r1.status);
    try std.testing.expect(std.mem.indexOf(u8, r1.body, "\"dark_mode\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.body, "\"override\":null") != null);

    // Seed an override. Release the writer via defer so a kvSet error can't leak the
    // mutex (which would deadlock a later acquire).
    {
        const conn = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const d = Data{ .app = &env.app, .conn = conn, .io = std.testing.io, .alloc = a };
        try d.kvSet("flag:dark_mode", "true");
    }

    // Now override should be "true".
    var ctx2 = ctxFor(env, RequestArena.from(&arena), .GET, "/api/features", &.{});
    ctx2.authorization = auth_hdr;
    const r2 = try get(&ctx2);
    try std.testing.expectEqual(@as(u16, 200), r2.status);
    try std.testing.expect(std.mem.indexOf(u8, r2.body, "\"override\":\"true\"") != null);
}

test "GET /api/features returns declared experiments with weight_override" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const auth_hdr = try std.fmt.allocPrint(a, "Bearer {s}", .{try env.superuserToken(a)});

    // Wire a registry with one experiment.
    const reg = features.Registry{
        .flags = &.{},
        .experiments = &.{.{
            .name = "onboarding",
            .variants = &.{ "control", "streamlined" },
            .weights = &.{ 70, 30 },
            .description = "Onboarding A/B",
        }},
    };
    env.app.features = &reg;

    var ctx1 = ctxFor(env, RequestArena.from(&arena), .GET, "/api/features", &.{});
    ctx1.authorization = auth_hdr;
    const r1 = try get(&ctx1);
    try std.testing.expectEqual(@as(u16, 200), r1.status);
    try std.testing.expect(std.mem.indexOf(u8, r1.body, "\"onboarding\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.body, "\"weight_override\":null") != null);

    // Seed a weight override. Release the writer via defer so a kvSet error can't leak
    // the mutex (which would deadlock a later acquire).
    {
        const conn = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const d = Data{ .app = &env.app, .conn = conn, .io = std.testing.io, .alloc = a };
        try d.kvSet("exp:onboarding:weights", "[90,10]");
    }

    var ctx2 = ctxFor(env, RequestArena.from(&arena), .GET, "/api/features", &.{});
    ctx2.authorization = auth_hdr;
    const r2 = try get(&ctx2);
    try std.testing.expectEqual(@as(u16, 200), r2.status);
    try std.testing.expect(std.mem.indexOf(u8, r2.body, "\"weight_override\":\"[90,10]\"") != null);
}
