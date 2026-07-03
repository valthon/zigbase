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
const secrets = @import("../oauth/secrets.zig");
const id = @import("../id.zig");
const param_sink = @import("../sql/param_sink.zig");

/// Lower + renumber a curated `_oauthStates`/`_externalAuths` statement for `conn`'s backend, then
/// prepare it. SQLite gets verbatim `?N`/`datetime('now')` (zero-cost); Postgres gets `$n` +
/// `now()`. The lowered SQL lives in a transient arena (`Db.prepare` copies it).
fn prep(conn: *db.Db, sql: [:0]const u8) db.DbError!db.Stmt {
    // Arena over the page allocator: no fixed ceiling (lowerStmtZ makes several intermediate
    // allocations that the arena frees together on return), and on SQLite lowerStmtZ is a no-op
    // returning the input slice, so this costs one empty arena. `Db.prepare` copies the text.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const lowered = param_sink.lowerStmtZ(arena.allocator(), db.dbDialect(conn), sql) catch return db.DbError.PrepareFailed;
    return conn.prepare(lowered);
}

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
pub fn findProviderConfig(col: schema.Collection, name: []const u8) ?schema.OAuth2Provider {
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

/// GET /api/collections/:col/auth/oauth2/providers — public redirect-building info (no secret).
pub fn oauth2Providers(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    // Read-only: only reads the collection + builds a JSON list (no writes).
    // Use a pooled reader so the single global writer lock is not held.
    var r = try app.pool.acquireReader();
    defer app.pool.releaseReader(&r);
    const col_name = ctx.param("col") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const col = (try collections.get(ctx.allocator, &r, col_name)) orelse return ApiError.notFound().toResponse(ctx.allocator);
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

// ----------------------------------------------------------------------------
// Server-side OAuth `state` (F11): optional, opt-in CSRF protection.
// ----------------------------------------------------------------------------

/// Mint + persist a random `state` for (collection, provider), valid for app.oauth_state_ttl_s.
/// Single-use: it is deleted on the first successful callback verification.
pub fn issueState(ctx: *http.RequestCtx, conn: *db.Db, col_name: []const u8, provider: []const u8) ![]const u8 {
    const app = ctx.app.?;
    const state = try crypto.genToken(app.io, ctx.allocator, 40);
    const now = try auth_api.nowUnix(conn);
    var st = try prep(conn,
        \\INSERT INTO "_oauthStates" ("state","collectionRef","provider","expires","created")
        \\ VALUES (?1,?2,?3,?4,datetime('now'));
    );
    defer st.finalize();
    try st.bindText(1, state);
    try st.bindText(2, col_name);
    try st.bindText(3, provider);
    try st.bindInt(4, now + app.oauth_state_ttl_s);
    _ = try st.step();
    return state;
}

/// Verify + consume a server-side `state`. Returns true only if a row exists for the
/// (collection, provider), is unexpired, and is then deleted (single-use — a reuse on a
/// second call finds no row and returns false). Missing/mismatched/expired => false.
pub fn consumeState(conn: *db.Db, col_name: []const u8, provider: []const u8, state: []const u8) !bool {
    const now = try auth_api.nowUnix(conn);
    var st = try prep(conn,
        \\DELETE FROM "_oauthStates"
        \\ WHERE "state"=?1 AND "collectionRef"=?2 AND "provider"=?3 AND "expires" > ?4
        \\ RETURNING "state";
    );
    defer st.finalize();
    try st.bindText(1, state);
    try st.bindText(2, col_name);
    try st.bindText(3, provider);
    try st.bindInt(4, now);
    return try st.step(); // true iff a matching, unexpired row was deleted
}

pub const Link = struct { collectionRef: []const u8, recordRef: []const u8 };

pub fn findLink(alloc: std.mem.Allocator, conn: *db.Db, provider: []const u8, provider_id: []const u8) !?Link {
    var st = try prep(conn, "SELECT \"collectionRef\",\"recordRef\" FROM \"_externalAuths\" WHERE \"provider\"=?1 AND \"providerId\"=?2;");
    defer st.finalize();
    try st.bindText(1, provider);
    try st.bindText(2, provider_id);
    if (!try st.step()) return null;
    return .{ .collectionRef = try alloc.dupe(u8, st.columnText(0)), .recordRef = try alloc.dupe(u8, st.columnText(1)) };
}

pub fn insertLink(io: std.Io, alloc: std.mem.Allocator, conn: *db.Db, collection_ref: []const u8, record_ref: []const u8, provider: []const u8, provider_id: []const u8) !void {
    _ = alloc;
    var rid = id.collectionId(io);
    var st = try prep(conn,
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

/// Create a new password-less auth record from a provider identity. Returns its id.
fn createOAuthRecord(ctx: *http.RequestCtx, conn: *db.Db, col: schema.Collection, identity: providers.Identity) ![]const u8 {
    const app = ctx.app.?;
    const tk = try crypto.genToken(app.io, ctx.allocator, 32);
    var data: std.json.ObjectMap = .empty;
    // SECURITY: only claim the (UNIQUE) email field when the provider VERIFIED it.
    // A provider's unverified email is attacker-controllable, so writing it here would
    // let an attacker squat a victim's address in the namespace. Unverified-email OAuth
    // records are created without an email (verified=false); the user can link/verify later.
    if (identity.emailVerified) {
        if (identity.email) |e| try data.put(ctx.allocator, "email", .{ .string = e });
    }
    if (identity.name) |n| try data.put(ctx.allocator, "username", .{ .string = n });
    try data.put(ctx.allocator, "passwordHash", .{ .string = "" });
    try data.put(ctx.allocator, "tokenKey", .{ .string = tk });
    try data.put(ctx.allocator, "verified", .{ .bool = identity.emailVerified });
    const rec = try records.create(ctx.allocator, app.io, conn, col, std.json.Value{ .object = data });
    return rec.object.get("id").?.string;
}

/// Parsed and validated OAuth2 request inputs (no DB, no HTTP).
pub const Prepared = struct {
    provider_name: []const u8,
    code: []const u8,
    verifier: []const u8,
    redirect_url: []const u8,
    state: ?[]const u8,
    cfg: schema.OAuth2Provider,
    provider: providers.Provider,
    secret: []const u8,
};

/// Result of prepareOAuth: either a fully-validated Prepared or an early-exit error.
pub const PrepareResult = union(enum) {
    ok: Prepared,
    fail: struct { status: u16, message: []const u8 },
};

/// Result of resolveRecordFromIdentity: either a record id+is_new or an error.
pub const Outcome = union(enum) {
    record: struct { rid: []const u8, is_new: bool },
    fail: struct { status: u16, message: []const u8 },
};

/// Body parse + provider resolve + redirect allow-list + secret decrypt. NO DB, NO HTTP.
/// `col` must already be loaded and verified to be of type .auth.
pub fn prepareOAuth(ctx: *http.RequestCtx, col: schema.Collection) !PrepareResult {
    const app = ctx.app.?;
    const body = parseBody(ctx) orelse return PrepareResult{ .fail = .{ .status = 400, .message = "Invalid JSON body." } };
    const provider_name = strField(body, "provider") orelse return PrepareResult{ .fail = .{ .status = 400, .message = "provider is required." } };
    const code = strField(body, "code") orelse return PrepareResult{ .fail = .{ .status = 400, .message = "code is required." } };
    const verifier = strField(body, "codeVerifier") orelse return PrepareResult{ .fail = .{ .status = 400, .message = "codeVerifier is required." } };
    const redirect_url = strField(body, "redirectUrl") orelse return PrepareResult{ .fail = .{ .status = 400, .message = "redirectUrl is required." } };
    const state = strField(body, "state");

    const cfg = findProviderConfig(col, provider_name) orelse return PrepareResult{ .fail = .{ .status = ApiError.notFound().status, .message = ApiError.notFound().message } };
    const provider = resolveProvider(cfg) orelse return PrepareResult{ .fail = .{ .status = 400, .message = "Provider misconfigured." } };
    if (!redirectAllowed(cfg, redirect_url)) return PrepareResult{ .fail = .{ .status = 400, .message = "redirectUrl not allowed." } };
    const secret = secrets.decryptSecret(ctx.allocator, app.jwt_secret, cfg.clientSecret) catch
        return PrepareResult{ .fail = .{ .status = ApiError.internal().status, .message = ApiError.internal().message } };

    return PrepareResult{ .ok = .{
        .provider_name = provider_name,
        .code = code,
        .verifier = verifier,
        .redirect_url = redirect_url,
        .state = state,
        .cfg = cfg,
        .provider = provider,
        .secret = secret,
    } };
}

/// The link/create decision tree given a fetched identity. Uses `conn` (writer).
/// Returns the resolved record id + is_new, or a fail. Does NOT mint a session.
pub fn resolveRecordFromIdentity(ctx: *http.RequestCtx, conn: *db.Db, col: schema.Collection,
    provider_name: []const u8, identity: providers.Identity) !Outcome {
    const app = ctx.app.?;

    const authed = (auth.authenticate(app.io, ctx.allocator, app, ctx, conn) catch null);
    const authed_rid: ?[]const u8 = if (authed) |x|
        (if (std.mem.eql(u8, x.collection, col.name)) x.record.object.get("id").?.string else null)
    else
        null;

    if (try findLink(ctx.allocator, conn, provider_name, identity.providerUserId)) |link| {
        if (authed_rid) |arid| {
            if (!std.mem.eql(u8, arid, link.recordRef))
                return Outcome{ .fail = .{ .status = 409, .message = "Provider already linked to another account." } };
        }
        return Outcome{ .record = .{ .rid = link.recordRef, .is_new = false } };
    }

    if (authed_rid) |arid| {
        insertLink(app.io, ctx.allocator, conn, col.name, arid, provider_name, identity.providerUserId) catch
            return Outcome{ .fail = .{ .status = 409, .message = "Provider already linked." } };
        return Outcome{ .record = .{ .rid = arid, .is_new = false } };
    }

    const new_rid = createOAuthRecord(ctx, conn, col, identity) catch
        return Outcome{ .fail = .{ .status = 409, .message = "Email already registered; sign in and link instead." } };
    insertLink(app.io, ctx.allocator, conn, col.name, new_rid, provider_name, identity.providerUserId) catch
        return Outcome{ .fail = .{ .status = 409, .message = "Provider already linked." } };
    return Outcome{ .record = .{ .rid = new_rid, .is_new = true } };
}

fn linkCount(alloc: std.mem.Allocator, conn: *db.Db, collection_ref: []const u8, record_ref: []const u8) !i64 {
    _ = alloc;
    var st = try prep(conn, "SELECT COUNT(*) FROM \"_externalAuths\" WHERE \"collectionRef\"=?1 AND \"recordRef\"=?2;");
    defer st.finalize();
    try st.bindText(1, collection_ref);
    try st.bindText(2, record_ref);
    _ = try st.step();
    return st.columnInt(0);
}

fn passwordIsSet(alloc: std.mem.Allocator, conn: *db.Db, table: []const u8, rid: []const u8) !bool {
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT \"passwordHash\" FROM \"{s}\" WHERE \"id\"=?1;", .{table}, 0);
    var st = try prep(conn, sql);
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

    var st = try prep(w, "DELETE FROM \"_externalAuths\" WHERE \"collectionRef\"=?1 AND \"recordRef\"=?2 AND \"provider\"=?3 RETURNING \"id\";");
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

test "resolveProvider: a discovery-resolved provider is equivalent to a hand-configured generic one" {
    // What resolveDiscoveryProviders produces: cfg with the three URLs filled + discoveryURL set.
    const discovered = resolveProvider(.{
        .name = "okta",
        .discoveryURL = "https://acme.okta.com/.well-known/openid-configuration",
        .authURL = "https://acme.okta.com/oauth2/v1/authorize",
        .tokenURL = "https://acme.okta.com/oauth2/v1/token",
        .userinfoURL = "https://acme.okta.com/oauth2/v1/userinfo",
    }).?;
    const hand = resolveProvider(.{
        .name = "okta",
        .authURL = "https://acme.okta.com/oauth2/v1/authorize",
        .tokenURL = "https://acme.okta.com/oauth2/v1/token",
        .userinfoURL = "https://acme.okta.com/oauth2/v1/userinfo",
    }).?;
    try std.testing.expectEqualStrings(hand.tokenURL, discovered.tokenURL);
    try std.testing.expectEqualStrings(hand.userinfoURL, discovered.userinfoURL);
    try std.testing.expectEqualStrings("sub", discovered.mapping.id); // fixed OIDC-standard mapping
    try std.testing.expectEqual(@as(usize, 3), discovered.scopes.len); // openid email profile default
    // An UNRESOLVED discovery provider (URLs still null — e.g. a code path that skipped
    // startup resolution) must fail closed: resolveProvider returns null, never a half-provider.
    try std.testing.expect(resolveProvider(.{
        .name = "okta",
        .discoveryURL = "https://acme.okta.com/.well-known/openid-configuration",
    }) == null);
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

test "auth/oauth2/providers lists enabled providers without secrets" {
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

test "auth/oauth2/providers 404 when oauth2 disabled" {
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

test "createOAuthRecord: unverified provider email is NOT claimed (no squat)" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.seedOAuthCollection(a, "users");

    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    const col = (try collections.get(a, w, "users")).?;
    var req = env.ctx(a, .POST, "", &[_]http.Param{});

    // First identity: provider did NOT verify the email -> record created WITHOUT email.
    const rid1 = try createOAuthRecord(&req, w, col, .{
        .providerUserId = "P1", .email = "victim@example.com", .emailVerified = false, .name = "Mallory",
    });
    {
        var st = try w.prepare("SELECT \"email\",\"verified\" FROM \"users\" WHERE \"id\"=?1;");
        defer st.finalize();
        try st.bindText(1, rid1);
        try std.testing.expect(try st.step());
        try std.testing.expectEqualStrings("", st.columnText(0)); // email left unset
        try std.testing.expectEqual(@as(i64, 0), st.columnInt(1)); // verified=false
    }

    // Second identity with the SAME unverified email must NOT collide (no unique email set).
    const rid2 = try createOAuthRecord(&req, w, col, .{
        .providerUserId = "P2", .email = "victim@example.com", .emailVerified = false, .name = "Other",
    });
    try std.testing.expect(!std.mem.eql(u8, rid1, rid2));

    // A verified-email identity DOES claim the email.
    const rid3 = try createOAuthRecord(&req, w, col, .{
        .providerUserId = "P3", .email = "real@example.com", .emailVerified = true, .name = "Real",
    });
    {
        var st = try w.prepare("SELECT \"email\",\"verified\" FROM \"users\" WHERE \"id\"=?1;");
        defer st.finalize();
        try st.bindText(1, rid3);
        try std.testing.expect(try st.step());
        try std.testing.expectEqualStrings("real@example.com", st.columnText(0));
        try std.testing.expectEqual(@as(i64, 1), st.columnInt(1));
    }
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

