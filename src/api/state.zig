const std = @import("std");
const http = @import("../http.zig");
const ApiError = @import("error.zig").ApiError;
const app_mod = @import("../app.zig");
const db = @import("../db.zig");
const Data = @import("../data.zig").Data;
const params_mod = @import("../query/params.zig");
const features = @import("../features.zig");
const features_resolver = @import("../features_resolver.zig");

// Public, UNAUTHENTICATED feature-state projection (#130).
//
//   GET /api/state?subject=<id>
//   -> { "flags": { "<name>": <bool>, … }, "experiments": { "<name>": "<variant>", … } }
//
// RESOLVED VALUES ONLY. This endpoint deliberately exposes neither the `_kv` keys,
// the created/updated timestamps, nor ANY admin verb — those stay behind
// `requireSuperuser` in `api/settings.zig`. It is the read-only client-facing
// surface for `App.flag`/`App.experiment`, mirroring `ctx.flags().resolveAll`.
//
// Mount path + enable/disable come from `app.features_public_route` (the `.features`
// config knob): default "/api/state"; a custom path remounts it; `.disabled` → 404.

/// GET <features_public_route>?subject=<id> — resolved flags + experiments, no auth.
pub fn handle(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app orelse return ApiError.internal().toResponse(ctx.allocator);

    // Disabled (`.features = .{ .public_route = .disabled }`) → not found.
    const route = app.features_public_route orelse return ApiError.notFound().toResponse(ctx.allocator);
    // Only serve at the configured path. The static routes table mounts the handler at
    // the default "/api/state"; when the consumer remaps it, that static entry must 404
    // (the real mount is dispatched dynamically in server.zig). Guarding here keeps a
    // single source of truth and prevents a second, unconfigured mount from leaking.
    if (!std.mem.eql(u8, route, ctx.path)) return ApiError.notFound().toResponse(ctx.allocator);

    const subject = blk: {
        const qp = params_mod.parse(ctx.allocator, ctx.query) catch break :blk "";
        break :blk qp.get("subject") orelse "";
    };

    // Resolve every declared flag + experiment from a single batched `_kv` scan.
    // No registry wired (tests/CLI) → a stable empty projection (still 200).
    var resolved: features_resolver.Resolved = .{};
    if (app.features) |reg| {
        var conn = try app.pool.acquireReader();
        defer app.pool.releaseReader(&conn);
        const data = Data{ .app = app, .conn = &conn, .io = app.io, .alloc = ctx.allocator };
        const entries = try data.kvScanPrefix(&.{ "flag:", "exp:" });
        const pairs = try ctx.allocator.alloc(features_resolver.KvPair, entries.len);
        for (entries, 0..) |e, i| pairs[i] = .{ .key = e.key, .value = e.value };
        // Reader-first sticky resolution (#129): `/api/state` is UNAUTHENTICATED with a
        // caller-supplied subject, so a sticky HIT must NOT take the global writer. Reads
        // run on the pooled reader; only a first-time MISS briefly borrows the pool writer
        // to persist the assignment, so the public projection agrees with `App.experiment`.
        const sticky = features_resolver.StickyConns{ .read = &conn, .pool = app.pool };
        resolved = try features_resolver.resolveAll(ctx.allocator, reg.*, pairs, subject, sticky);
    }

    return .{ .status = 200, .body = try renderJson(ctx.allocator, resolved) };
}

/// Serialize to the EXACT public shape: `{"flags":{…bool},"experiments":{…string}}`.
/// `std.json.ObjectMap` (a string array-hashmap) preserves insertion order, so keys
/// come out in declaration order; `Stringify` escapes names/values.
fn renderJson(alloc: std.mem.Allocator, resolved: features_resolver.Resolved) ![]const u8 {
    var flags_obj: std.json.ObjectMap = .empty;
    for (resolved.flags) |f| try flags_obj.put(alloc, f.name, .{ .bool = f.value });
    var exps_obj: std.json.ObjectMap = .empty;
    for (resolved.experiments) |e| try exps_obj.put(alloc, e.name, .{ .string = e.variant });
    var root: std.json.ObjectMap = .empty;
    try root.put(alloc, "flags", .{ .object = flags_obj });
    try root.put(alloc, "experiments", .{ .object = exps_obj });
    return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = root }, .{});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const migrations = @import("../migrations.zig");

const test_registry = features.Registry{
    .flags = &.{
        .{ .name = "checkout_enabled", .default = true },
        .{ .name = "new_dashboard", .default = false },
    },
    .experiments = &.{
        .{ .name = "checkout_layout", .variants = &.{ "control", "compact" }, .weights = &.{ 50, 50 } },
    },
};

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
        env.app = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .pool = &env.pool,
            .features = &test_registry,
            .features_public_route = "/api/state",
        };
        return env;
    }
    fn deinit(env: *TestEnv) void {
        env.pool.deinit();
        env.tmp.cleanup();
        std.testing.allocator.destroy(env);
    }
    fn setKv(env: *TestEnv, key: []const u8, value: []const u8) !void {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const d = Data{ .app = &env.app, .conn = w, .io = std.testing.io, .alloc = std.testing.allocator };
        try d.kvSet(key, value);
    }
};

test "GET /api/state: no auth required, returns resolved flags + experiments" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No Authorization header at all — the endpoint is public.
    var ctx = http.RequestCtx{ .method = .GET, .path = "/api/state", .query = "subject=user-7", .allocator = a, .app = &env.app };
    const resp = try handle(&ctx);
    try std.testing.expectEqual(@as(u16, 200), resp.status);

    // Shape: flags first (declared defaults), then experiments.
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"flags\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"checkout_enabled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"new_dashboard\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"experiments\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"checkout_layout\":") != null);

    // It must NOT leak the raw _kv key surface or admin fields.
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "flag:") == null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "exp:") == null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"created\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"updated\"") == null);
}

test "GET /api/state: reflects a flag + weight override" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Override new_dashboard ON and pin the experiment to "compact".
    try env.setKv("flag:new_dashboard", "true");
    try env.setKv("exp:checkout_layout:weights", "[0,100]");

    var ctx = http.RequestCtx{ .method = .GET, .path = "/api/state", .query = "subject=user-7", .allocator = a, .app = &env.app };
    const resp = try handle(&ctx);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"new_dashboard\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"checkout_layout\":\"compact\"") != null);
}

test "GET /api/state: disabled route → 404" {
    var env = try TestEnv.init();
    defer env.deinit();
    env.app.features_public_route = null; // `.features = .{ .public_route = .disabled }`
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = http.RequestCtx{ .method = .GET, .path = "/api/state", .query = "", .allocator = arena.allocator(), .app = &env.app };
    try std.testing.expectEqual(@as(u16, 404), (try handle(&ctx)).status);
}

test "GET /api/state: static mount 404s when remapped to a custom path" {
    var env = try TestEnv.init();
    defer env.deinit();
    env.app.features_public_route = "/public/features"; // remapped
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The static "/api/state" entry must NOT serve when the mount moved elsewhere.
    var ctx = http.RequestCtx{ .method = .GET, .path = "/api/state", .query = "", .allocator = arena.allocator(), .app = &env.app };
    try std.testing.expectEqual(@as(u16, 404), (try handle(&ctx)).status);
}
