const std = @import("std");
const method_mod = @import("../method.zig");
const AuthMethod = method_mod.AuthMethod;
const AuthCtx = method_mod.AuthCtx;
const InitiateResult = method_mod.InitiateResult;
const Resolution = method_mod.Resolution;
const oauth = @import("../../api/oauth.zig");
const oauth_client = @import("../../oauth/client.zig");

// ---------------------------------------------------------------------------
// OAuth2Method — stateless; delegates to the shared OAuth2 core in api/oauth.zig
// ---------------------------------------------------------------------------

pub const OAuth2Method = struct {
    pub fn create(_: std.mem.Allocator, _: std.Io, _: anytype) !OAuth2Method {
        return .{};
    }

    pub fn method(self: *OAuth2Method) AuthMethod {
        return .{ .slug = "oauth2", .ctx = self, .vtable = &vtable };
    }

    pub fn deinit(_: *OAuth2Method) void {}
};

// ---------------------------------------------------------------------------
// initiate — parse provider from body, return JSON with authURL + clientId + scopes
// ---------------------------------------------------------------------------

fn strField(obj: std.json.Value, key: []const u8) ?[]const u8 {
    const v = obj.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn initiateImpl(ctx: *anyopaque, ac: *AuthCtx) anyerror!InitiateResult {
    _ = @as(*OAuth2Method, @ptrCast(@alignCast(ctx)));

    // Parse provider from body.
    const parsed = std.json.parseFromSlice(std.json.Value, ac.ctx.allocator, ac.ctx.body, .{}) catch {
        return InitiateResult{ .status = 400, .body = "{\"message\":\"provider is required.\"}" };
    };
    if (parsed.value != .object) {
        return InitiateResult{ .status = 400, .body = "{\"message\":\"provider is required.\"}" };
    }
    const provider_name = strField(parsed.value, "provider") orelse {
        return InitiateResult{ .status = 400, .body = "{\"message\":\"provider is required.\"}" };
    };

    // Look up the provider config.
    const cfg = oauth.findProviderConfig(ac.collection, provider_name) orelse {
        return InitiateResult{ .status = 404, .body = "{\"message\":\"Provider not found.\"}" };
    };

    // Resolve the provider endpoints.
    const provider = oauth.resolveProvider(cfg) orelse {
        return InitiateResult{ .status = 400, .body = "{\"message\":\"Provider misconfigured.\"}" };
    };

    // Optionally mint server-side state (scoped writer — released immediately).
    var state_val: ?[]const u8 = null;
    if (ac.app.oauth_state_server) {
        var w = ac.writer();
        defer w.deinit();
        state_val = try oauth.issueState(ac.ctx, w.conn, ac.collection.name, provider_name);
    }

    // Build the JSON response.
    var root: std.json.ObjectMap = .empty;
    try root.put(ac.ctx.allocator, "authURL", .{ .string = provider.authURL });
    try root.put(ac.ctx.allocator, "clientId", .{ .string = cfg.clientId });
    var scopes_arr = std.json.Array.init(ac.ctx.allocator);
    for (provider.scopes) |s| try scopes_arr.append(.{ .string = s });
    try root.put(ac.ctx.allocator, "scopes", .{ .array = scopes_arr });
    if (state_val) |sv| {
        try root.put(ac.ctx.allocator, "state", .{ .string = sv });
    }
    const body = try std.json.Stringify.valueAlloc(ac.ctx.allocator, std.json.Value{ .object = root }, .{});
    return InitiateResult{ .status = 200, .body = body };
}

// ---------------------------------------------------------------------------
// complete — build real transport then delegate to completeImpl (testable core)
// ---------------------------------------------------------------------------

fn completeVtable(ctx: *anyopaque, ac: *AuthCtx) anyerror!Resolution {
    _ = @as(*OAuth2Method, @ptrCast(@alignCast(ctx)));
    const hc = try oauth_client.httpContext(ac.ctx.allocator, ac.app.io);
    return completeImpl(ac, oauth_client.httpTransport(hc));
}

/// Testable core: accepts an injected transport.
pub fn completeImpl(ac: *AuthCtx, transport: oauth_client.Transport) anyerror!Resolution {
    // Phase 1: validate body + provider config.
    const prep = switch (try oauth.prepareOAuth(ac.ctx, ac.collection)) {
        .fail => |f| return Resolution{ .fail = .{ .status = f.status, .message = f.message } },
        .ok => |p| p,
    };

    // Phase 2: server-side CSRF state (opt-in). Consume the single-use state in a
    // SCOPED writer that is released BEFORE the provider HTTP calls — we must not
    // hold the write lock across network I/O.
    if (ac.app.oauth_state_server) {
        const state = prep.state orelse return Resolution{ .fail = .{ .status = 400, .message = "state is required." } };
        var w = ac.writer();
        defer w.deinit();
        const ok = oauth.consumeState(w.conn, ac.collection.name, prep.provider_name, state) catch {
            return Resolution{ .fail = .{ .status = 500, .message = "State verification failed." } };
        };
        if (!ok) return Resolution{ .fail = .{ .status = 400, .message = "Invalid or expired state." } };
    }

    // Phase 3: provider HTTP calls — NO DB connection held (the writer was
    // released at the end of phase 2), so other writes proceed during the exchange.
    const access_token = oauth_client.exchangeCode(
        transport,
        ac.ctx.allocator,
        prep.provider,
        prep.cfg.clientId,
        prep.secret,
        prep.code,
        prep.verifier,
        prep.redirect_url,
    ) catch return Resolution{ .fail = .{ .status = 400, .message = "OAuth exchange failed." } };

    const identity = oauth_client.fetchIdentity(
        transport,
        ac.ctx.allocator,
        prep.provider,
        access_token,
    ) catch return Resolution{ .fail = .{ .status = 400, .message = "OAuth identity fetch failed." } };

    // Phase 4: link/create decision tree, under a SECOND scoped writer acquired
    // only now that the HTTP exchange is done.
    var w = ac.writer();
    defer w.deinit();
    return switch (try oauth.resolveRecordFromIdentity(ac.ctx, w.conn, ac.collection, prep.provider_name, identity)) {
        .fail => |f| Resolution{ .fail = .{ .status = f.status, .message = f.message } },
        .record => |r| Resolution{ .record = r.rid },
    };
}

const vtable = AuthMethod.VTable{
    .initiate = initiateImpl,
    .complete = completeVtable,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const api_auth = @import("../../api/auth.zig");
const app_mod = @import("../../app.zig");
const db = @import("../../db.zig");
const http = @import("../../http.zig");
const schema = @import("../../schema.zig");
const collections = @import("../../collections.zig");
const migrations = @import("../../migrations.zig");
const oauth_secrets = @import("../../oauth/secrets.zig");

/// Minimal test harness: in-memory DB + an oauth-enabled collection with a google stub.
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
        const blob = try oauth_secrets.encryptSecret(std.testing.io, a, env.app.jwt_secret, "stub-secret");
        const provs = [_]schema.OAuth2Provider{.{
            .name = "google",
            .clientId = "cid",
            .clientSecret = blob,
            .enabled = true,
            .redirectUrls = &.{"https://app/cb"},
        }};
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        _ = try collections.create(a, std.testing.io, w, .{
            .id = "",
            .name = name,
            .type = .auth,
            .fields = &[_]schema.Field{},
            .listRule = "",
            .viewRule = "",
            .createRule = "",
            .updateRule = "",
            .deleteRule = "",
            .options = .{ .auth = .{ .oauth2 = .{ .enabled = true, .providers = &provs } } },
        });
    }

    fn ctx(env: *TestEnv, a: std.mem.Allocator, m: http.Method, body: []const u8, params: []const http.Param) http.RequestCtx {
        return .{ .method = m, .path = "/", .body = body, .allocator = a, .app = &env.app, .params = params };
    }
};

/// Stub transport: dispatches token vs userinfo by URL substring.
const OAuthStub = struct {
    token_status: u16 = 200,
    token_body: []const u8 = "{\"access_token\":\"AT\"}",
    userinfo_status: u16 = 200,
    pid: []const u8 = "P1",
    email: []const u8 = "u@x.io",
    verified: bool = true,

    fn call(c: *anyopaque, alloc: std.mem.Allocator, m: oauth_client.Method, url: []const u8, h: []const oauth_client.Header, b: ?[]const u8) oauth_client.TransportError!oauth_client.Response {
        _ = m;
        _ = h;
        _ = b;
        const self: *OAuthStub = @ptrCast(@alignCast(c));
        if (std.mem.indexOf(u8, url, "token") != null) {
            return .{ .status = self.token_status, .body = try alloc.dupe(u8, self.token_body) };
        }
        const j = try std.fmt.allocPrint(alloc, "{{\"sub\":\"{s}\",\"email\":\"{s}\",\"email_verified\":{s}}}", .{
            self.pid, self.email, if (self.verified) "true" else "false",
        });
        return .{ .status = self.userinfo_status, .body = j };
    }

    fn transport(self: *OAuthStub) oauth_client.Transport {
        return .{ .ctx = self, .call = call };
    }
};

fn oauthBody(a: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"provider\":\"google\",\"code\":\"c\",\"codeVerifier\":\"v\",\"redirectUrl\":\"https://app/cb\"}}", .{});
}

fn oauthBodyWithState(a: std.mem.Allocator, state: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"provider\":\"google\",\"code\":\"c\",\"codeVerifier\":\"v\",\"redirectUrl\":\"https://app/cb\",\"state\":\"{s}\"}}", .{state});
}

test "OAuth2Method: completeImpl creates a new record (isNew) with valid stub" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    env.app.oauth_state_server = false; // exercise the no-state (client-driven) path explicitly
    try env.seedOAuthCollection(a, "oauth2users");

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "oauth2users")).?;
    };
    var req = env.ctx(a, .POST, try oauthBody(a), &[_]http.Param{});
    var ac = AuthCtx{
        .app = &env.app,
        .ctx = &req,
        .collection = col,
        .config = .null,
    };

    var stub = OAuthStub{};
    const res = try completeImpl(&ac, stub.transport());
    switch (res) {
        .record => |rid| try std.testing.expect(rid.len > 0),
        .fail => |f| {
            std.debug.print("Expected .record but got .fail: status={d} msg={s}\n", .{ f.status, f.message });
            return error.TestFailed;
        },
    }
}

test "OAuth2Method: completeImpl second login returns same rid (not new)" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    env.app.oauth_state_server = false; // exercise the no-state (client-driven) path explicitly
    try env.seedOAuthCollection(a, "oauth2users2");

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "oauth2users2")).?;
    };

    // First login. completeImpl acquires its own writer, so we hold none here.
    var rid1: []const u8 = "";
    {
        var req = env.ctx(a, .POST, try oauthBody(a), &[_]http.Param{});
        var ac = AuthCtx{ .app = &env.app, .ctx = &req, .collection = col, .config = .null };
        var stub = OAuthStub{};
        const res = try completeImpl(&ac, stub.transport());
        rid1 = switch (res) {
            .record => |rid| try a.dupe(u8, rid),
            .fail => return error.TestFailed,
        };
    }

    // Second login — same identity.
    {
        var req = env.ctx(a, .POST, try oauthBody(a), &[_]http.Param{});
        var ac = AuthCtx{ .app = &env.app, .ctx = &req, .collection = col, .config = .null };
        var stub = OAuthStub{};
        const res = try completeImpl(&ac, stub.transport());
        switch (res) {
            .record => |rid2| try std.testing.expectEqualStrings(rid1, rid2),
            .fail => return error.TestFailed,
        }
    }
}

test "OAuth2Method: completeImpl token exchange fail returns .fail 400" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    env.app.oauth_state_server = false; // exercise the no-state (client-driven) path explicitly
    try env.seedOAuthCollection(a, "oauth2users3");

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "oauth2users3")).?;
    };
    var req = env.ctx(a, .POST, try oauthBody(a), &[_]http.Param{});
    var ac = AuthCtx{
        .app = &env.app,
        .ctx = &req,
        .collection = col,
        .config = .null,
    };

    // Stub returns a 400 on token exchange.
    var stub = OAuthStub{ .token_status = 400, .token_body = "{\"error\":\"invalid_grant\"}" };
    const res = try completeImpl(&ac, stub.transport());
    switch (res) {
        .fail => |f| try std.testing.expectEqual(@as(u16, 400), f.status),
        .record => return error.TestFailed,
    }
}

test "OAuth2Method: completeImpl unknown provider returns .fail 404" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.seedOAuthCollection(a, "oauth2users4");

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "oauth2users4")).?;
    };
    var req = env.ctx(a, .POST, "{\"provider\":\"github\",\"code\":\"c\",\"codeVerifier\":\"v\",\"redirectUrl\":\"https://app/cb\"}", &[_]http.Param{});
    var ac = AuthCtx{
        .app = &env.app,
        .ctx = &req,
        .collection = col,
        .config = .null,
    };

    var stub = OAuthStub{};
    const res = try completeImpl(&ac, stub.transport());
    switch (res) {
        .fail => |f| try std.testing.expectEqual(@as(u16, 404), f.status),
        .record => return error.TestFailed,
    }
}

test "OAuth2Method: method() returns slug=oauth2 and contract satisfied" {
    var m = try OAuth2Method.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    try std.testing.expectEqualStrings("oauth2", am.slug);
    method_mod.assertAuthMethodContract(OAuth2Method);
}

test "OAuth2Method: initiate returns 200 JSON with authURL+clientId+scopes" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.seedOAuthCollection(a, "oauth2init1");

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "oauth2init1")).?;
    };
    var req = env.ctx(a, .POST, "{\"provider\":\"google\"}", &[_]http.Param{});
    var ac = AuthCtx{
        .app = &env.app,
        .ctx = &req,
        .collection = col,
        .config = .null,
    };

    var m = try OAuth2Method.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    const result = try am.vtable.initiate(am.ctx, &ac);
    try std.testing.expectEqual(@as(u16, 200), result.status);
    try std.testing.expect(result.body != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body.?, "authURL") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body.?, "clientId") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body.?, "scopes") != null);
    // Secure-by-default: server-side state is ON, so initiate issues a `state`.
    try std.testing.expect(std.mem.indexOf(u8, result.body.?, "\"state\"") != null);
}

test "OAuth2Method: initiate omits state when oauth_state_server is disabled" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    env.app.oauth_state_server = false;
    try env.seedOAuthCollection(a, "oauth2initnostate");

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "oauth2initnostate")).?;
    };
    var req = env.ctx(a, .POST, "{\"provider\":\"google\"}", &[_]http.Param{});
    var ac = AuthCtx{ .app = &env.app, .ctx = &req, .collection = col, .config = .null };

    var m = try OAuth2Method.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    const result = try am.vtable.initiate(am.ctx, &ac);
    try std.testing.expectEqual(@as(u16, 200), result.status);
    // No state field when server-side state is opted out.
    try std.testing.expect(std.mem.indexOf(u8, result.body.?, "\"state\"") == null);
}

test "OAuth2Method: initiate missing provider returns 400" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.seedOAuthCollection(a, "oauth2init2");

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "oauth2init2")).?;
    };
    var req = env.ctx(a, .POST, "{}", &[_]http.Param{});
    var ac = AuthCtx{
        .app = &env.app,
        .ctx = &req,
        .collection = col,
        .config = .null,
    };

    var m = try OAuth2Method.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    const result = try am.vtable.initiate(am.ctx, &ac);
    try std.testing.expectEqual(@as(u16, 400), result.status);
}

test "OAuth2Method: initiate unknown provider returns 404" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.seedOAuthCollection(a, "oauth2init3");

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "oauth2init3")).?;
    };
    var req = env.ctx(a, .POST, "{\"provider\":\"github\"}", &[_]http.Param{});
    var ac = AuthCtx{
        .app = &env.app,
        .ctx = &req,
        .collection = col,
        .config = .null,
    };

    var m = try OAuth2Method.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    const result = try am.vtable.initiate(am.ctx, &ac);
    try std.testing.expectEqual(@as(u16, 404), result.status);
}

// ---------------------------------------------------------------------------
// Server-side CSRF state enforcement tests (oauth_state_server = true)
// ---------------------------------------------------------------------------

test "OAuth2Method: server-state — missing state returns .fail 400" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    env.app.oauth_state_server = true;
    try env.seedOAuthCollection(a, "oauth2csrf1");

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "oauth2csrf1")).?;
    };
    // Body has no "state" field — should fail closed before any exchange.
    var req = env.ctx(a, .POST, try oauthBody(a), &[_]http.Param{});
    var ac = AuthCtx{ .app = &env.app, .ctx = &req, .collection = col, .config = .null };

    var stub = OAuthStub{};
    const res = try completeImpl(&ac, stub.transport());
    switch (res) {
        .fail => |f| {
            try std.testing.expectEqual(@as(u16, 400), f.status);
            try std.testing.expectEqualStrings("state is required.", f.message);
        },
        .record => return error.TestFailed,
    }
}

test "OAuth2Method: server-state — valid issued state returns .record" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    env.app.oauth_state_server = true;
    try env.seedOAuthCollection(a, "oauth2csrf2");

    // Mint a state token via issueState (needs a request ctx for the jwt_secret).
    const state = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        var req = env.ctx(a, .POST, "", &[_]http.Param{});
        break :blk try oauth.issueState(&req, w, "oauth2csrf2", "google");
    };

    // Use the state in the complete body.
    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "oauth2csrf2")).?;
    };
    var req = env.ctx(a, .POST, try oauthBodyWithState(a, state), &[_]http.Param{});
    var ac = AuthCtx{ .app = &env.app, .ctx = &req, .collection = col, .config = .null };

    var stub = OAuthStub{};
    const res = try completeImpl(&ac, stub.transport());
    switch (res) {
        .record => |rid| try std.testing.expect(rid.len > 0),
        .fail => |f| {
            std.debug.print("Expected .record but got .fail: status={d} msg={s}\n", .{ f.status, f.message });
            return error.TestFailed;
        },
    }
}

test "OAuth2Method: server-state — replayed (consumed) state returns .fail 400" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    env.app.oauth_state_server = true;
    try env.seedOAuthCollection(a, "oauth2csrf3");

    // Mint state.
    const state = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        var req = env.ctx(a, .POST, "", &[_]http.Param{});
        break :blk try oauth.issueState(&req, w, "oauth2csrf3", "google");
    };

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "oauth2csrf3")).?;
    };

    // First use — consumes the state (should succeed and produce a record).
    {
        var req = env.ctx(a, .POST, try oauthBodyWithState(a, state), &[_]http.Param{});
        var ac = AuthCtx{ .app = &env.app, .ctx = &req, .collection = col, .config = .null };
        var stub = OAuthStub{};
        const res = try completeImpl(&ac, stub.transport());
        switch (res) {
            .record => {},
            .fail => return error.TestFailed,
        }
    }

    // Second use — state already consumed; must fail 400.
    {
        var req = env.ctx(a, .POST, try oauthBodyWithState(a, state), &[_]http.Param{});
        var ac = AuthCtx{ .app = &env.app, .ctx = &req, .collection = col, .config = .null };
        var stub = OAuthStub{};
        const res = try completeImpl(&ac, stub.transport());
        switch (res) {
            .fail => |f| {
                try std.testing.expectEqual(@as(u16, 400), f.status);
                try std.testing.expectEqualStrings("Invalid or expired state.", f.message);
            },
            .record => return error.TestFailed,
        }
    }
}
