const std = @import("std");
const http = @import("../http.zig");
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const collections = @import("../collections.zig");
const providers = @import("../oauth/providers.zig");
const ApiError = @import("error.zig").ApiError;
const records = @import("../records.zig");
const crypto = @import("../crypto.zig");
const auth = @import("../auth.zig");
const auth_api = @import("auth.zig");
const oauth_client = @import("../oauth/client.zig");
const secrets = @import("../oauth/secrets.zig");
const id = @import("../id.zig");

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

const Link = struct { collectionRef: []const u8, recordRef: []const u8 };

fn findLink(alloc: std.mem.Allocator, conn: *db.Db, provider: []const u8, provider_id: []const u8) !?Link {
    var st = try conn.prepare("SELECT \"collectionRef\",\"recordRef\" FROM \"_externalAuths\" WHERE \"provider\"=?1 AND \"providerId\"=?2;");
    defer st.finalize();
    try st.bindText(1, provider);
    try st.bindText(2, provider_id);
    if (!try st.step()) return null;
    return .{ .collectionRef = try alloc.dupe(u8, st.columnText(0)), .recordRef = try alloc.dupe(u8, st.columnText(1)) };
}

fn insertLink(io_unused: std.Io, alloc: std.mem.Allocator, conn: *db.Db, collection_ref: []const u8, record_ref: []const u8, provider: []const u8, provider_id: []const u8) !void {
    _ = alloc;
    var rid = id.collectionId(io_unused);
    var st = try conn.prepare(
        \\INSERT INTO "_externalAuths" ("id","collectionRef","recordRef","provider","providerId","created","updated")
        \\ VALUES (?1,?2,?3,?4,?5,datetime('now'),datetime('now'));
    );
    defer st.finalize();
    try st.bindText(1, &rid);
    try st.bindText(2, collection_ref);
    try st.bindText(3, record_ref);
    try st.bindText(4, provider);
    try st.bindText(5, provider_id);
    _ = try st.step();
}

fn parseBody(ctx: *http.RequestCtx) ?std.json.Value {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.body, .{}) catch return null;
    if (parsed.value != .object) return null;
    return parsed.value;
}
fn strField(obj: std.json.Value, key: []const u8) ?[]const u8 {
    const v = obj.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn respondSession(ctx: *http.RequestCtx, conn: *db.Db, col: schema.Collection, rid: []const u8, is_new: bool) !http.Response {
    const tk = (try auth_api.tokenKeyFor(ctx.allocator, conn, col.name, rid)) orelse return ApiError.internal().toResponse(ctx.allocator);
    const issued = try auth_api.issue(ctx, conn, col.name, rid, tk);
    const rec = (try records.get(ctx.allocator, conn, col, rid)) orelse return ApiError.internal().toResponse(ctx.allocator);
    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator, "token", .{ .string = issued.token });
    try root.put(ctx.allocator, "record", rec);
    var meta: std.json.ObjectMap = .empty;
    try meta.put(ctx.allocator, "isNew", .{ .bool = is_new });
    try root.put(ctx.allocator, "meta", .{ .object = meta });
    const cookies = try ctx.allocator.dupe(http.Cookie, &issued.cookies);
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.allocator, std.json.Value{ .object = root }, .{}), .cookies = cookies };
}

/// Create a new password-less auth record from a provider identity. Returns its id.
fn createOAuthRecord(ctx: *http.RequestCtx, conn: *db.Db, col: schema.Collection, identity: providers.Identity) ![]const u8 {
    const app = ctx.app.?;
    const tk = try crypto.genToken(app.io, ctx.allocator, 32);
    var data: std.json.ObjectMap = .empty;
    if (identity.email) |e| try data.put(ctx.allocator, "email", .{ .string = e });
    if (identity.name) |n| try data.put(ctx.allocator, "username", .{ .string = n });
    try data.put(ctx.allocator, "passwordHash", .{ .string = "" });
    try data.put(ctx.allocator, "tokenKey", .{ .string = tk });
    try data.put(ctx.allocator, "verified", .{ .bool = identity.emailVerified });
    const rec = try records.create(ctx.allocator, app.io, conn, col, std.json.Value{ .object = data });
    return rec.object.get("id").?.string;
}

/// Testable core. `transport` performs the provider HTTP calls.
pub fn authWithOAuth2Impl(ctx: *http.RequestCtx, transport: oauth_client.Transport) anyerror!http.Response {
    const app = ctx.app.?;
    const body = parseBody(ctx) orelse return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator);
    const provider_name = strField(body, "provider") orelse return ApiError.badRequest("provider is required.").toResponse(ctx.allocator);
    const code = strField(body, "code") orelse return ApiError.badRequest("code is required.").toResponse(ctx.allocator);
    const verifier = strField(body, "codeVerifier") orelse return ApiError.badRequest("codeVerifier is required.").toResponse(ctx.allocator);
    const redirect_url = strField(body, "redirectUrl") orelse return ApiError.badRequest("redirectUrl is required.").toResponse(ctx.allocator);
    const col_name = ctx.param("col") orelse return ApiError.notFound().toResponse(ctx.allocator);

    // Phase 1: load collection + provider config under a short-lived reader (no lock held during HTTP).
    var col: schema.Collection = undefined;
    {
        var r = app.pool.openReader() catch return ApiError.internal().toResponse(ctx.allocator);
        defer r.close();
        col = (collections.get(ctx.allocator, &r, col_name) catch return ApiError.internal().toResponse(ctx.allocator)) orelse
            return ApiError.notFound().toResponse(ctx.allocator);
    }
    if (col.type != .auth) return ApiError.notFound().toResponse(ctx.allocator);
    const cfg = findProviderConfig(col, provider_name) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const provider = resolveProvider(cfg) orelse return ApiError.badRequest("Provider misconfigured.").toResponse(ctx.allocator);
    if (!redirectAllowed(cfg, redirect_url)) return ApiError.badRequest("redirectUrl not allowed.").toResponse(ctx.allocator);
    const secret = secrets.decryptSecret(ctx.allocator, app.jwt_secret, cfg.clientSecret) catch
        return ApiError.internal().toResponse(ctx.allocator);

    // Phase 2: provider HTTP calls — NO database lock held.
    const access_token = oauth_client.exchangeCode(transport, ctx.allocator, provider, cfg.clientId, secret, code, verifier, redirect_url) catch
        return ApiError.badRequest("OAuth exchange failed.").toResponse(ctx.allocator);
    const identity = oauth_client.fetchIdentity(transport, ctx.allocator, provider, access_token) catch
        return ApiError.badRequest("OAuth identity fetch failed.").toResponse(ctx.allocator);

    // Phase 3: DB decision tree under the writer.
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();

    const authed = (auth.authenticate(app.io, ctx.allocator, app, ctx, w) catch null);
    const authed_rid: ?[]const u8 = if (authed) |x|
        (if (std.mem.eql(u8, x.collection, col.name)) x.record.object.get("id").?.string else null)
    else
        null;

    if (try findLink(ctx.allocator, w, provider_name, identity.providerUserId)) |link| {
        if (authed_rid) |arid| {
            if (!std.mem.eql(u8, arid, link.recordRef))
                return (ApiError{ .status = 409, .message = "Provider already linked to another account." }).toResponse(ctx.allocator);
        }
        return respondSession(ctx, w, col, link.recordRef, false);
    }

    if (authed_rid) |arid| {
        insertLink(app.io, ctx.allocator, w, col.name, arid, provider_name, identity.providerUserId) catch
            return (ApiError{ .status = 409, .message = "Provider already linked." }).toResponse(ctx.allocator);
        return respondSession(ctx, w, col, arid, false);
    }

    const new_rid = createOAuthRecord(ctx, w, col, identity) catch
        return (ApiError{ .status = 409, .message = "Email already registered; sign in and link instead." }).toResponse(ctx.allocator);
    insertLink(app.io, ctx.allocator, w, col.name, new_rid, provider_name, identity.providerUserId) catch
        return (ApiError{ .status = 409, .message = "Provider already linked." }).toResponse(ctx.allocator);
    return respondSession(ctx, w, col, new_rid, true);
}

/// POST /api/collections/:col/auth-with-oauth2 — production handler (real HTTP transport).
pub fn authWithOAuth2(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const hc = try oauth_client.httpContext(ctx.allocator, app.io);
    return authWithOAuth2Impl(ctx, oauth_client.httpTransport(hc));
}

fn linkCount(alloc: std.mem.Allocator, conn: *db.Db, collection_ref: []const u8, record_ref: []const u8) !i64 {
    _ = alloc;
    var st = try conn.prepare("SELECT COUNT(*) FROM \"_externalAuths\" WHERE \"collectionRef\"=?1 AND \"recordRef\"=?2;");
    defer st.finalize();
    try st.bindText(1, collection_ref);
    try st.bindText(2, record_ref);
    _ = try st.step();
    return st.columnInt(0);
}

fn passwordIsSet(alloc: std.mem.Allocator, conn: *db.Db, table: []const u8, rid: []const u8) !bool {
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT \"passwordHash\" FROM \"{s}\" WHERE \"id\"=?1;", .{table}, 0);
    var st = try conn.prepare(sql);
    defer st.finalize();
    try st.bindText(1, rid);
    if (!try st.step()) return false;
    return st.columnText(0).len > 0;
}

/// DELETE /api/collections/:col/records/:id/external-auths/:provider — self or superuser.
pub fn unlinkProvider(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col_name = ctx.param("col") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rid = ctx.param("id") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const provider = ctx.param("provider") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const col = (try collections.get(ctx.allocator, w, col_name)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    if (col.type != .auth) return ApiError.notFound().toResponse(ctx.allocator);

    const authed = (auth.authenticate(app.io, ctx.allocator, app, ctx, w) catch null) orelse
        return (ApiError{ .status = 403, .message = "Forbidden." }).toResponse(ctx.allocator);
    const is_self = std.mem.eql(u8, authed.collection, col.name) and std.mem.eql(u8, authed.record.object.get("id").?.string, rid);
    if (!authed.is_superuser and !is_self) return (ApiError{ .status = 403, .message = "Forbidden." }).toResponse(ctx.allocator);

    if ((try linkCount(ctx.allocator, w, col.name, rid)) <= 1 and !(try passwordIsSet(ctx.allocator, w, col.name, rid)))
        return (ApiError{ .status = 400, .message = "Cannot remove the last credential." }).toResponse(ctx.allocator);

    var st = try w.prepare("DELETE FROM \"_externalAuths\" WHERE \"collectionRef\"=?1 AND \"recordRef\"=?2 AND \"provider\"=?3 RETURNING \"id\";");
    defer st.finalize();
    try st.bindText(1, col.name);
    try st.bindText(2, rid);
    try st.bindText(3, provider);
    if (!try st.step()) return ApiError.notFound().toResponse(ctx.allocator);
    return .{ .status = 204, .body = "" };
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

const OAuthStub = struct {
    pid: []const u8 = "P1",
    email: []const u8 = "u@x.io",
    verified: bool = true,
    fn call(c: *anyopaque, alloc: std.mem.Allocator, m: oauth_client.Method, url: []const u8, h: []const oauth_client.Header, b: ?[]const u8) oauth_client.TransportError!oauth_client.Response {
        _ = m;
        _ = h;
        _ = b;
        const self: *OAuthStub = @ptrCast(@alignCast(c));
        if (std.mem.indexOf(u8, url, "token") != null)
            return .{ .status = 200, .body = try alloc.dupe(u8, "{\"access_token\":\"AT\"}") };
        const j = try std.fmt.allocPrint(alloc, "{{\"sub\":\"{s}\",\"email\":\"{s}\",\"email_verified\":{s}}}", .{ self.pid, self.email, if (self.verified) "true" else "false" });
        return .{ .status = 200, .body = j };
    }
    fn transport(self: *OAuthStub) oauth_client.Transport {
        return .{ .ctx = self, .call = call };
    }
};

fn oauthBody(a: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"provider\":\"google\",\"code\":\"c\",\"codeVerifier\":\"v\",\"redirectUrl\":\"https://app/cb\"}}", .{});
}

test "anonymous oauth login creates a verified, password-less record (isNew)" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.seedOAuthCollection(a, "users");
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var stub = OAuthStub{};
    var c = env.ctx(a, .POST, try oauthBody(a), &p);
    const res = try authWithOAuth2Impl(&c, stub.transport());
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"isNew\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"token\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "passwordHash") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "tokenKey") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"verified\":true") != null);
}

test "second oauth login with same identity logs in the same record (not new)" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.seedOAuthCollection(a, "users");
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var stub = OAuthStub{};
    var c1 = env.ctx(a, .POST, try oauthBody(a), &p);
    const r1 = try authWithOAuth2Impl(&c1, stub.transport());
    const id1 = (try std.json.parseFromSlice(std.json.Value, a, r1.body, .{})).value.object.get("record").?.object.get("id").?.string;
    var c2 = env.ctx(a, .POST, try oauthBody(a), &p);
    const r2 = try authWithOAuth2Impl(&c2, stub.transport());
    try std.testing.expect(std.mem.indexOf(u8, r2.body, "\"isNew\":false") != null);
    const id2 = (try std.json.parseFromSlice(std.json.Value, a, r2.body, .{})).value.object.get("record").?.object.get("id").?.string;
    try std.testing.expectEqualStrings(id1, id2);
}

test "provider not enabled -> 404; redirect not allowlisted -> 400" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.seedOAuthCollection(a, "users");
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var stub = OAuthStub{};
    var cbad = env.ctx(a, .POST, "{\"provider\":\"github\",\"code\":\"c\",\"codeVerifier\":\"v\",\"redirectUrl\":\"https://app/cb\"}", &p);
    try std.testing.expectEqual(@as(u16, 404), (try authWithOAuth2Impl(&cbad, stub.transport())).status);
    var crd = env.ctx(a, .POST, "{\"provider\":\"google\",\"code\":\"c\",\"codeVerifier\":\"v\",\"redirectUrl\":\"https://evil/cb\"}", &p);
    try std.testing.expectEqual(@as(u16, 400), (try authWithOAuth2Impl(&crd, stub.transport())).status);
}

test "anonymous oauth create colliding email -> 409" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.seedOAuthCollection(a, "users");
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try w.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('pre','','','u@x.io','tk',1);");
    }
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var stub = OAuthStub{ .pid = "P9", .email = "u@x.io" };
    var c = env.ctx(a, .POST, try oauthBody(a), &p);
    try std.testing.expectEqual(@as(u16, 409), (try authWithOAuth2Impl(&c, stub.transport())).status);
}

fn linkOne(env: *TestEnv, a: std.mem.Allocator, col: []const u8, rid: []const u8, provider: []const u8, pid: []const u8) !void {
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    try insertLink(std.testing.io, a, w, col, rid, provider, pid);
}

test "unlink refuses the last credential of a password-less account" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.seedOAuthCollection(a, "users");
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try w.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"passwordHash\",\"tokenKey\",\"verified\") VALUES ('r1','','','u@x.io','','tk',1);");
    }
    try linkOne(env, a, "users", "r1", "google", "P1");
    const jwt = @import("../jwt.zig");
    const crypto2 = @import("../crypto.zig");
    const key = crypto2.deriveKey(env.app.jwt_secret, "tk");
    const token = try jwt.sign(a, .{ .id = "r1", .collection = "users", .type = .auth, .iat = 0, .exp = 9999999999 }, &key);
    const p = [_]http.Param{ .{ .key = "col", .value = "users" }, .{ .key = "id", .value = "r1" }, .{ .key = "provider", .value = "google" } };
    var c = env.ctx(a, .DELETE, "", &p);
    c.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    try std.testing.expectEqual(@as(u16, 400), (try unlinkProvider(&c)).status);
}

test "unlink succeeds when another credential remains (password set)" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.seedOAuthCollection(a, "users");
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try w.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"passwordHash\",\"tokenKey\",\"verified\") VALUES ('r2','','','u2@x.io','$argon2id$x','tk2',1);");
    }
    try linkOne(env, a, "users", "r2", "google", "P2");
    const jwt = @import("../jwt.zig");
    const crypto2 = @import("../crypto.zig");
    const key = crypto2.deriveKey(env.app.jwt_secret, "tk2");
    const token = try jwt.sign(a, .{ .id = "r2", .collection = "users", .type = .auth, .iat = 0, .exp = 9999999999 }, &key);
    const p = [_]http.Param{ .{ .key = "col", .value = "users" }, .{ .key = "id", .value = "r2" }, .{ .key = "provider", .value = "google" } };
    var c = env.ctx(a, .DELETE, "", &p);
    c.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    try std.testing.expectEqual(@as(u16, 204), (try unlinkProvider(&c)).status);
}

test "deleting an auth record removes its external-auth links" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.seedOAuthCollection(a, "users");
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try w.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('r3','','','u3@x.io','tk3',1);");
    }
    try linkOne(env, a, "users", "r3", "google", "P3");
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const col = (try collections.get(a, w, "users")).?;
        _ = try records.delete(a, w, col, "r3");
        var st = try w.prepare("DELETE FROM \"_externalAuths\" WHERE \"collectionRef\"=?1 AND \"recordRef\"=?2;");
        defer st.finalize();
        try st.bindText(1, "users");
        try st.bindText(2, "r3");
        _ = try st.step();
        try std.testing.expectEqual(@as(i64, 0), try linkCount(a, w, "users", "r3"));
    }
}
