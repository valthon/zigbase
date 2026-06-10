const std = @import("std");
const http = @import("../http.zig");
const db = @import("../db.zig");
const collections = @import("../collections.zig");
const records = @import("../records.zig");
const schema = @import("../schema.zig");
const crypto = @import("../crypto.zig");
const jwt = @import("../jwt.zig");
const auth = @import("../auth.zig");
const events = @import("../events.zig");
const request = @import("../request.zig");
const ApiError = @import("error.zig").ApiError;

fn jsonResponse(ctx: *http.RequestCtx, status: u16, v: std.json.Value, cookies: []const http.Cookie) !http.Response {
    return .{ .status = status, .body = try std.json.Stringify.valueAlloc(ctx.allocator, v, .{}), .cookies = cookies };
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

pub fn nowUnix(conn: *db.Db) db.DbError!i64 {
    var st = try conn.prepare("SELECT unixepoch('now');");
    defer st.finalize();
    _ = try st.step();
    return st.columnInt(0);
}

/// Try each identity field in order; return the matching non-empty row id, or null.
fn findByIdentity(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, identity: []const u8) !?[]const u8 {
    for (col.options.auth.identityFields) |idf| {
        const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT \"id\" FROM \"{s}\" WHERE \"{s}\" = ?1 AND \"{s}\" != '' LIMIT 1;", .{ col.name, idf, idf }, 0);
        var st = try conn.prepare(sql);
        defer st.finalize();
        try st.bindText(1, identity);
        if (try st.step()) return try alloc.dupe(u8, st.columnText(0));
    }
    return null;
}

fn passwordHashFor(alloc: std.mem.Allocator, conn: *db.Db, table: []const u8, rid: []const u8) !?[]const u8 {
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT \"passwordHash\" FROM \"{s}\" WHERE \"id\" = ?1;", .{table}, 0);
    var st = try conn.prepare(sql);
    defer st.finalize();
    try st.bindText(1, rid);
    if (!try st.step()) return null;
    return try alloc.dupe(u8, st.columnText(0));
}

pub fn tokenKeyFor(alloc: std.mem.Allocator, conn: *db.Db, table: []const u8, rid: []const u8) !?[]const u8 {
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT \"tokenKey\" FROM \"{s}\" WHERE \"id\" = ?1;", .{table}, 0);
    var st = try conn.prepare(sql);
    defer st.finalize();
    try st.bindText(1, rid);
    if (!try st.step()) return null;
    return try alloc.dupe(u8, st.columnText(0));
}

pub const Issued = struct { token: []const u8, cookies: [2]http.Cookie };

pub fn issue(ctx: *http.RequestCtx, conn: *db.Db, collection: []const u8, rid: []const u8, token_key: []const u8) !Issued {
    const app = ctx.app.?;
    const csrf = try crypto.genToken(app.io, ctx.allocator, 32);
    const now = try nowUnix(conn);
    const claims = jwt.Claims{
        .id = rid,
        .collection = collection,
        .type = .auth,
        .csrf = csrf,
        .iat = now,
        .exp = now + app.auth_token_ttl_s,
    };
    const key = crypto.deriveKey(app.jwt_secret, token_key);
    const token = try jwt.sign(ctx.allocator, claims, &key);
    const max_age: i32 = @intCast(app.auth_token_ttl_s);
    return .{
        .token = token,
        .cookies = .{
            .{ .name = "zb_auth", .value = token, .max_age_s = max_age, .http_only = true, .secure = app.cookie_secure, .same_site = .strict },
            .{ .name = "zb_csrf", .value = csrf, .max_age_s = max_age, .http_only = false, .secure = app.cookie_secure, .same_site = .strict },
        },
    };
}

/// Fire auth.afterAuthSuccess. After-style: never propagates (auth already succeeded).
pub fn emitAuth(ctx: *http.RequestCtx, collection: []const u8, record: ?std.json.Value, method: events.AuthMethod) void {
    const app = ctx.app orelse return;
    const d = app.dispatch orelse return;
    const h = d.on_auth orelse return;
    var rctx = request.RequestContext{ .method = @tagName(ctx.method) };
    var ev = events.AuthEvent{ .app = app, .ctx = &rctx, .collection = collection, .record = record, .method = method };
    h(&ev);
}

pub fn authWithPassword(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const body = parseBody(ctx) orelse return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator);
    const identity = strField(body, "identity") orelse return ApiError.badRequest("identity is required.").toResponse(ctx.allocator);
    const password = strField(body, "password") orelse return ApiError.badRequest("password is required.").toResponse(ctx.allocator);

    // Login is read-only (identity lookup, password hash, tokenKey, unixepoch; issue() only
    // reads + signs). Use a READER so the expensive argon2 verify below does NOT run while
    // holding the single global writer lock — otherwise every login serializes all writes.
    var r = try app.pool.acquireReader();
    defer app.pool.releaseReader(&r);
    const col_name = ctx.param("col") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const col = (try collections.get(ctx.allocator, &r, col_name)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    if (col.type != .auth) return ApiError.notFound().toResponse(ctx.allocator);

    const rid = (try findByIdentity(ctx.allocator, &r, col, identity)) orelse {
        // Unknown identity: run identity-independent argon2 work so the response time matches
        // the known-identity path (defeats account enumeration via timing). L1 fix.
        crypto.dummyVerify(app.io, ctx.allocator);
        return ApiError.badRequest("Invalid credentials.").toResponse(ctx.allocator);
    };
    const phc = (try passwordHashFor(ctx.allocator, &r, col.name, rid)) orelse {
        crypto.dummyVerify(app.io, ctx.allocator);
        return ApiError.badRequest("Invalid credentials.").toResponse(ctx.allocator);
    };
    if (!crypto.verifyPassword(app.io, ctx.allocator, phc, password))
        return ApiError.badRequest("Invalid credentials.").toResponse(ctx.allocator);

    const tk = (try tokenKeyFor(ctx.allocator, &r, col.name, rid)) orelse
        return ApiError.badRequest("Invalid credentials.").toResponse(ctx.allocator);
    const issued = try issue(ctx, &r, col.name, rid, tk);
    const rec = (try records.get(ctx.allocator, &r, col, rid)) orelse
        return ApiError.notFound().toResponse(ctx.allocator);

    emitAuth(ctx, col.name, rec, .password);

    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator, "token", .{ .string = issued.token });
    try root.put(ctx.allocator, "record", rec);
    const cookies = try ctx.allocator.dupe(http.Cookie, &issued.cookies);
    return jsonResponse(ctx, 200, .{ .object = root }, cookies);
}

pub fn authRefresh(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const authed = (try auth.authenticate(app.io, ctx.allocator, app, ctx, w)) orelse
        return (ApiError{ .status = 401, .message = "Not authenticated." }).toResponse(ctx.allocator);
    const col_name = ctx.param("col") orelse return ApiError.notFound().toResponse(ctx.allocator);
    if (!std.mem.eql(u8, authed.collection, col_name))
        return (ApiError{ .status = 401, .message = "Not authenticated." }).toResponse(ctx.allocator);

    const rid = authed.record.object.get("id").?.string;
    const tk = (try tokenKeyFor(ctx.allocator, w, col_name, rid)) orelse
        return (ApiError{ .status = 401, .message = "Not authenticated." }).toResponse(ctx.allocator);
    const issued = try issue(ctx, w, col_name, rid, tk);
    emitAuth(ctx, col_name, authed.record, .password);
    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator, "token", .{ .string = issued.token });
    try root.put(ctx.allocator, "record", authed.record);
    const cookies = try ctx.allocator.dupe(http.Cookie, &issued.cookies);
    return jsonResponse(ctx, 200, .{ .object = root }, cookies);
}

pub fn authLogout(ctx: *http.RequestCtx) anyerror!http.Response {
    const cleared = [_]http.Cookie{
        .{ .name = "zb_auth", .value = "", .max_age_s = -1, .http_only = true, .secure = ctx.app.?.cookie_secure, .same_site = .strict },
        .{ .name = "zb_csrf", .value = "", .max_age_s = -1, .http_only = false, .secure = ctx.app.?.cookie_secure, .same_site = .strict },
    };
    const cookies = try ctx.allocator.dupe(http.Cookie, &cleared);
    return .{ .status = 204, .body = "", .cookies = cookies };
}

// ----------------------------------------------------------------------------
// Email verification & password reset
// ----------------------------------------------------------------------------

fn findByEmail(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, email: []const u8) !?[]const u8 {
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT \"id\" FROM \"{s}\" WHERE \"email\" = ?1 AND \"email\" != '' LIMIT 1;", .{col.name}, 0);
    var st = try conn.prepare(sql);
    defer st.finalize();
    try st.bindText(1, email);
    if (try st.step()) return try alloc.dupe(u8, st.columnText(0));
    return null;
}

/// Deliver a verification/reset token to `email` via the configured mailer. The
/// default mailer (LogMailer) logs the message, preserving the pre-mailer dev/CI
/// behavior; with SMTP configured it sends a real email. Falls back to logging
/// when no mailer is wired (tests/CLI). A real SMTP send failure propagates so it
/// is not silently dropped.
fn deliverToken(app: *@import("../app.zig").App, alloc: std.mem.Allocator, email: []const u8, subject: []const u8, body: []const u8) !void {
    if (app.mailer) |m| {
        try m.send(app.io, alloc, .{ .to = email, .subject = subject, .text_body = body });
    } else {
        std.log.info("[mail:fallback] to={s} subject={s} body={s}", .{ email, subject, body });
    }
}

fn mintToken(ctx: *http.RequestCtx, conn: *db.Db, col_name: []const u8, rid: []const u8, token_key: []const u8, tt: jwt.TokenType, ttl: i64) ![]const u8 {
    const app = ctx.app.?;
    const now = try nowUnix(conn);
    const key = crypto.deriveKey(app.jwt_secret, token_key);
    return jwt.sign(ctx.allocator, .{ .id = rid, .collection = col_name, .type = tt, .iat = now, .exp = now + ttl }, &key);
}

fn loadAuthCollection(ctx: *http.RequestCtx, conn: *db.Db) !?schema.Collection {
    const col_name = ctx.param("col") orelse return null;
    const col = (try collections.get(ctx.allocator, conn, col_name)) orelse return null;
    if (col.type != .auth) return null;
    return col;
}

/// Verify a typed token against the record's derived key. Returns claims on success.
fn verifyTyped(ctx: *http.RequestCtx, conn: *db.Db, col: schema.Collection, token: []const u8, want: jwt.TokenType) !?jwt.Claims {
    const app = ctx.app.?;
    const claims = jwt.peekClaims(ctx.allocator, token) catch return null;
    if (claims.type != want) return null;
    if (!std.mem.eql(u8, claims.collection, col.name)) return null;
    const tk = (try tokenKeyFor(ctx.allocator, conn, col.name, claims.id)) orelse return null;
    const key = crypto.deriveKey(app.jwt_secret, tk);
    const now = try nowUnix(conn);
    const verified = jwt.verify(ctx.allocator, token, &key, now) catch return null;
    return verified;
}

pub fn requestVerification(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col = (try loadAuthCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const body = parseBody(ctx) orelse return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator);
    if (strField(body, "email")) |email| {
        if (try findByEmail(ctx.allocator, w, col, email)) |rid| {
            if (try tokenKeyFor(ctx.allocator, w, col.name, rid)) |tk| {
                const token = try mintToken(ctx, w, col.name, rid, tk, .verification, app.verification_ttl_s);
                const mail_body = try std.fmt.allocPrint(ctx.allocator, "Verify your email ({s}). Your verification token:\n\n{s}\n", .{ col.name, token });
                try deliverToken(app, ctx.allocator, email, "Verify your email", mail_body);
            }
        }
    }
    return .{ .status = 204, .body = "" };
}

pub fn confirmVerification(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col = (try loadAuthCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const body = parseBody(ctx) orelse return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator);
    const token = strField(body, "token") orelse return ApiError.badRequest("token is required.").toResponse(ctx.allocator);
    const claims = (try verifyTyped(ctx, w, col, token, .verification)) orelse
        return ApiError.badRequest("Invalid or expired token.").toResponse(ctx.allocator);
    const sql = try std.fmt.allocPrintSentinel(ctx.allocator, "UPDATE \"{s}\" SET \"verified\" = 1 WHERE \"id\" = ?1;", .{col.name}, 0);
    var st = try w.prepare(sql);
    defer st.finalize();
    try st.bindText(1, claims.id);
    _ = try st.step();
    return .{ .status = 200, .body = "{\"verified\":true}" };
}

pub fn requestPasswordReset(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col = (try loadAuthCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const body = parseBody(ctx) orelse return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator);
    if (strField(body, "email")) |email| {
        if (try findByEmail(ctx.allocator, w, col, email)) |rid| {
            if (try tokenKeyFor(ctx.allocator, w, col.name, rid)) |tk| {
                const token = try mintToken(ctx, w, col.name, rid, tk, .password_reset, app.password_reset_ttl_s);
                const mail_body = try std.fmt.allocPrint(ctx.allocator, "Reset your password ({s}). Your password-reset token:\n\n{s}\n", .{ col.name, token });
                try deliverToken(app, ctx.allocator, email, "Reset your password", mail_body);
            }
        }
    }
    return .{ .status = 204, .body = "" };
}

pub fn confirmPasswordReset(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col = (try loadAuthCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const body = parseBody(ctx) orelse return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator);
    const token = strField(body, "token") orelse return ApiError.badRequest("token is required.").toResponse(ctx.allocator);
    const password = strField(body, "password") orelse return ApiError.badRequest("password is required.").toResponse(ctx.allocator);
    const claims = (try verifyTyped(ctx, w, col, token, .password_reset)) orelse
        return ApiError.badRequest("Invalid or expired token.").toResponse(ctx.allocator);
    if (password.len < col.options.auth.minPasswordLength)
        return ApiError.badRequest("Password too short.").toResponse(ctx.allocator);
    var data: std.json.ObjectMap = .empty;
    try data.put(ctx.allocator, "password", .{ .string = password });
    const updated = auth.applyUpdate(app.io, ctx.allocator, .{ .object = data }, col.options.auth.minPasswordLength) catch
        return ApiError.badRequest("Invalid password.").toResponse(ctx.allocator);
    _ = records.update(ctx.allocator, w, col, claims.id, updated) catch
        return ApiError.internal().toResponse(ctx.allocator);
    return .{ .status = 200, .body = "{\"success\":true}" };
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const app_mod = @import("../app.zig");
const migrations = @import("../migrations.zig");

const TestEnv = struct {
    tmp: std.testing.TmpDir,
    pool: db.Pool,
    app: app_mod.App,

    fn initAuth(name: []const u8) !*TestEnv {
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
            var setup_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer setup_arena.deinit();
            const sa = setup_arena.allocator();
            _ = try collections.create(sa, std.testing.io, w, .{
                .id = "",
                .name = name,
                .type = .auth,
                .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
                .listRule = "",
                .viewRule = "",
                .createRule = "",
                .updateRule = "",
                .deleteRule = "",
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

    /// Create an auth record the same way the records API would (hash password,
    /// gen tokenKey, force verified=false), then insert via the records engine.
    fn createUser(env: *TestEnv, a: std.mem.Allocator, col_name: []const u8, email: []const u8, pw: []const u8) !void {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const col = (try collections.get(a, w, col_name)) orelse return error.NoCollection;
        var data: std.json.ObjectMap = .empty;
        try data.put(a, "email", .{ .string = email });
        try data.put(a, "password", .{ .string = pw });
        const prepared = try auth.applyCreate(env.app.io, a, .{ .object = data }, col.options.auth.minPasswordLength);
        _ = try records.create(a, env.app.io, w, col, prepared);
    }

    fn ctx(env: *TestEnv, a: std.mem.Allocator, m: http.Method, body: []const u8, params: []const http.Param) http.RequestCtx {
        return .{ .method = m, .path = "/", .body = body, .allocator = a, .app = &env.app, .params = params };
    }

    /// Mint a typed token (verification/password_reset) for the record matching `email`.
    fn mintTyped(self: *TestEnv, a: std.mem.Allocator, col_name: []const u8, email: []const u8, tt: jwt.TokenType) ![]const u8 {
        const w = self.pool.acquireWriter();
        defer self.pool.releaseWriter();
        const col = (try collections.get(a, w, col_name)).?;
        const rid = (try findByIdentity(a, w, col, email)).?;
        const tk = (try tokenKeyFor(a, w, col.name, rid)).?;
        const now = try nowUnix(w);
        const key = crypto.deriveKey(self.app.jwt_secret, tk);
        return jwt.sign(a, .{ .id = rid, .collection = col_name, .type = tt, .iat = now, .exp = now + 100000 }, &key);
    }

    fn recordVerified(self: *TestEnv, a: std.mem.Allocator, col_name: []const u8, email: []const u8) bool {
        const w = self.pool.acquireWriter();
        defer self.pool.releaseWriter();
        const col = (collections.get(a, w, col_name) catch return false).?;
        const rid = (findByIdentity(a, w, col, email) catch return false) orelse return false;
        const sql = std.fmt.allocPrintSentinel(a, "SELECT \"verified\" FROM \"{s}\" WHERE \"id\" = ?1;", .{col.name}, 0) catch return false;
        var st = w.prepare(sql) catch return false;
        defer st.finalize();
        st.bindText(1, rid) catch return false;
        if (!(st.step() catch return false)) return false;
        return st.columnInt(0) != 0;
    }
};

test "auth-with-password issues a token + cookies, wrong password 400" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "u@x.io", "longenough");

    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var ok = env.ctx(a, .POST, "{\"identity\":\"u@x.io\",\"password\":\"longenough\"}", &p);
    const res = try authWithPassword(&ok);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"token\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"record\":") != null);
    var saw_auth = false;
    var saw_csrf = false;
    for (res.cookies) |c| {
        if (std.mem.eql(u8, c.name, "zb_auth")) {
            saw_auth = true;
            try std.testing.expect(c.http_only);
        }
        if (std.mem.eql(u8, c.name, "zb_csrf")) {
            saw_csrf = true;
            try std.testing.expect(!c.http_only);
        }
    }
    try std.testing.expect(saw_auth and saw_csrf);

    var bad = env.ctx(a, .POST, "{\"identity\":\"u@x.io\",\"password\":\"wrongwrong\"}", &p);
    try std.testing.expectEqual(@as(u16, 400), (try authWithPassword(&bad)).status);
}

test "auth-logout clears the cookies" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var ctx = env.ctx(a, .POST, "", &p);
    const res = try authLogout(&ctx);
    try std.testing.expectEqual(@as(u16, 204), res.status);
    var cleared: usize = 0;
    for (res.cookies) |c| if (c.max_age_s < 0) {
        cleared += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), cleared);
}

test "auth-with-password then authenticate round-trips the issued token (bearer)" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "rt@x.io", "longenough");
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var login = env.ctx(a, .POST, "{\"identity\":\"rt@x.io\",\"password\":\"longenough\"}", &p);
    const res = try authWithPassword(&login);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, res.body, .{});
    const token = parsed.value.object.get("token").?.string;
    // refresh with the bearer token should succeed (200)
    var refresh = env.ctx(a, .POST, "", &p);
    refresh.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    try std.testing.expectEqual(@as(u16, 200), (try authRefresh(&refresh)).status);
}

test "verification: request always 204; confirm sets verified=true" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "v@x.io", "longenough");
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};

    var req = env.ctx(a, .POST, "{\"email\":\"v@x.io\"}", &p);
    try std.testing.expectEqual(@as(u16, 204), (try requestVerification(&req)).status);
    var req_missing = env.ctx(a, .POST, "{\"email\":\"nobody@x.io\"}", &p);
    try std.testing.expectEqual(@as(u16, 204), (try requestVerification(&req_missing)).status);

    const token = try env.mintTyped(a, "users", "v@x.io", .verification);
    const body = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\"}}", .{token});
    var conf = env.ctx(a, .POST, body, &p);
    try std.testing.expectEqual(@as(u16, 200), (try confirmVerification(&conf)).status);
    try std.testing.expect(env.recordVerified(a, "users", "v@x.io"));
}

test "password reset: confirm changes the password and rotates the token" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "r@x.io", "oldpassword");
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    const token = try env.mintTyped(a, "users", "r@x.io", .password_reset);
    const body = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\",\"password\":\"newpassword\"}}", .{token});
    var conf = env.ctx(a, .POST, body, &p);
    try std.testing.expectEqual(@as(u16, 200), (try confirmPasswordReset(&conf)).status);
    var conf2 = env.ctx(a, .POST, body, &p);
    try std.testing.expectEqual(@as(u16, 400), (try confirmPasswordReset(&conf2)).status);
}
