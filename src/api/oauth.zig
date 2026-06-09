const std = @import("std");
const http = @import("../http.zig");
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const collections = @import("../collections.zig");
const providers = @import("../oauth/providers.zig");
const ApiError = @import("error.zig").ApiError;

/// Build the effective provider endpoints for a configured provider:
/// presets supply endpoints (optionally overridden); generic providers must supply all three.
/// Returns null if a generic provider is missing an endpoint, or any effective URL is not https.
pub fn resolveProvider(cfg: schema.OAuth2Provider) ?providers.Provider {
    var p: providers.Provider = undefined;
    if (providers.lookup(cfg.name)) |preset| {
        p = preset;
        if (cfg.authURL) |u| p.authURL = u;
        if (cfg.tokenURL) |u| p.tokenURL = u;
        if (cfg.userinfoURL) |u| p.userinfoURL = u;
        if (cfg.scopes) |s| p.scopes = s;
    } else {
        const au = cfg.authURL orelse return null;
        const tu = cfg.tokenURL orelse return null;
        const uu = cfg.userinfoURL orelse return null;
        p = .{
            .name = cfg.name, .authURL = au, .tokenURL = tu, .userinfoURL = uu,
            .scopes = cfg.scopes orelse &.{ "openid", "email", "profile" },
            .mapping = .{ .id = "sub", .email = "email", .emailVerified = "email_verified", .name = "name", .avatar = "picture" },
        };
    }
    if (!isHttps(p.authURL) or !isHttps(p.tokenURL) or !isHttps(p.userinfoURL)) return null;
    return p;
}

fn isHttps(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://");
}

/// Find an enabled provider config by name in a collection's oauth2 options.
fn findProviderConfig(col: schema.Collection, name: []const u8) ?schema.OAuth2Provider {
    if (!col.options.auth.oauth2.enabled) return null;
    for (col.options.auth.oauth2.providers) |p| {
        if (p.enabled and std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

fn redirectAllowed(cfg: schema.OAuth2Provider, redirect_url: []const u8) bool {
    for (cfg.redirectUrls) |u| if (std.mem.eql(u8, u, redirect_url)) return true;
    return false;
}

/// GET /api/collections/:col/oauth2-providers — public redirect-building info (no secret).
pub fn oauth2Providers(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col_name = ctx.param("col") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const col = (try collections.get(ctx.allocator, w, col_name)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    if (col.type != .auth or !col.options.auth.oauth2.enabled) return ApiError.notFound().toResponse(ctx.allocator);

    var arr = std.json.Array.init(ctx.allocator);
    for (col.options.auth.oauth2.providers) |cfg| {
        if (!cfg.enabled) continue;
        const prov = resolveProvider(cfg) orelse continue;
        var o: std.json.ObjectMap = .empty;
        try o.put(ctx.allocator, "name", .{ .string = cfg.name });
        try o.put(ctx.allocator, "authURL", .{ .string = prov.authURL });
        try o.put(ctx.allocator, "clientId", .{ .string = cfg.clientId });
        var scopes = std.json.Array.init(ctx.allocator);
        for (prov.scopes) |s| try scopes.append(.{ .string = s });
        try o.put(ctx.allocator, "scopes", .{ .array = scopes });
        try arr.append(.{ .object = o });
    }
    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator, "providers", .{ .array = arr });
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.allocator, std.json.Value{ .object = root }, .{}) };
}

const app_mod = @import("../app.zig");
const migrations = @import("../migrations.zig");

test "resolveProvider: preset, generic, and https rejection" {
    const g = resolveProvider(.{ .name = "google", .clientId = "c", .clientSecret = "" }).?;
    try std.testing.expectEqualStrings("https://oauth2.googleapis.com/token", g.tokenURL);
    const gen = resolveProvider(.{ .name = "acme", .authURL = "https://a/auth", .tokenURL = "https://a/tok", .userinfoURL = "https://a/ui" }).?;
    try std.testing.expectEqualStrings("https://a/tok", gen.tokenURL);
    try std.testing.expect(resolveProvider(.{ .name = "acme", .authURL = "https://a/auth" }) == null);
    try std.testing.expect(resolveProvider(.{ .name = "google", .tokenURL = "http://evil/tok" }) == null);
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
        const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/t.db", .{dir}, 0);
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

    fn seedOAuthCollection(env: *TestEnv, a: std.mem.Allocator, name: []const u8) !void {
        const secrets = @import("../oauth/secrets.zig");
        const blob = try secrets.encryptSecret(std.testing.io, a, env.app.jwt_secret, "stub-secret");
        const provs = [_]schema.OAuth2Provider{.{
            .name = "google", .clientId = "cid", .clientSecret = blob, .enabled = true,
            .redirectUrls = &.{"https://app/cb"},
        }};
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        _ = try collections.create(a, std.testing.io, w, .{
            .id = "", .name = name, .type = .auth,
            .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
            .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "",
            .options = .{ .auth = .{ .oauth2 = .{ .enabled = true, .providers = &provs } } },
        });
    }

    fn ctx(env: *TestEnv, a: std.mem.Allocator, m: http.Method, body: []const u8, params: []const http.Param) http.RequestCtx {
        return .{ .method = m, .path = "/", .body = body, .allocator = a, .app = &env.app, .params = params };
    }
};

test "oauth2-providers lists enabled providers without secrets" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.seedOAuthCollection(a, "users");
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var c = env.ctx(a, .GET, "", &p);
    const res = try oauth2Providers(&c);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"name\":\"google\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"clientId\":\"cid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "stub-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "clientSecret") == null);
}

test "oauth2-providers 404 when oauth2 disabled" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = env.pool.acquireWriter();
    {
        defer env.pool.releaseWriter();
        _ = try collections.create(a, std.testing.io, w, .{ .id = "", .name = "plain", .type = .auth, .fields = &.{}, .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "" });
    }
    const p = [_]http.Param{.{ .key = "col", .value = "plain" }};
    var c = env.ctx(a, .GET, "", &p);
    try std.testing.expectEqual(@as(u16, 404), (try oauth2Providers(&c)).status);
}
