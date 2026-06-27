const std = @import("std");
const http = @import("../http.zig");
const db = @import("../db.zig");
const collections = @import("../collections.zig");
const records = @import("../records.zig");
const schema = @import("../schema.zig");
const crypto = @import("../crypto.zig");
const jwt = @import("../jwt.zig");
const auth = @import("../auth.zig");
const clock = @import("../clock.zig");
const events = @import("../events.zig");
const request = @import("../request.zig");
const session = @import("../session.zig");
const Ctx = @import("../ctx.zig").Ctx;
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

/// True iff the record's `verified` field is truthy. Tolerant of the JSON shapes a
/// bool column can surface as (bool, integer 0/1, or "true"/"false" string).
pub fn recordVerified(rec: std.json.Value) bool {
    if (rec != .object) return false;
    const v = rec.object.get("verified") orelse return false;
    return switch (v) {
        .bool => |b| b,
        .integer => |i| i != 0,
        .string => |s| std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1"),
        else => false,
    };
}

/// Wall-clock seconds (no DB connection needed) for the rate limiter, mirroring
/// scheduler.unixNow — used at the top of the gated endpoints before any conn exists.
/// Honors the dev-only `ZIGBASE_FAKE_NOW` override (see `clock.zig`).
fn wallNowUnix(io: std.Io) i64 {
    return clock.nowUnix(io);
}

/// Rate-limit gate for a sensitive auth endpoint. Returns a 429 Response when the
/// limiter denies the request, else null (proceed). `scope` is the endpoint tag
/// ("login"/"reset"/"verify"). The key is the client IP when known, else falls back
/// to the submitted identity/email so the limiter still functions without a proxy IP.
/// No-op (null) when no limiter is wired (rate_limit_max == 0 / tests).
pub fn rateLimited(ctx: *http.RequestCtx, scope: []const u8, ident: []const u8) !?http.Response {
    const app = ctx.app.?;
    const limiter = app.rate_limiter orelse return null;
    const key = if (ctx.remote_ip.len > 0)
        try std.fmt.allocPrint(ctx.allocator, "{s}:ip:{s}", .{ scope, ctx.remote_ip })
    else
        try std.fmt.allocPrint(ctx.allocator, "{s}:ident:{s}", .{ scope, ident });
    if (limiter.allow(key, wallNowUnix(app.io))) return null;
    return try (ApiError{ .status = 429, .message = "Too many requests. Try again later." }).toResponse(ctx.allocator);
}

/// SQL `now` for framework token logic (iat/exp, consumed-token expiry), honoring the
/// dev-only `ZIGBASE_FAKE_NOW` override so issued tokens agree with the frozen wall clock.
pub fn nowUnix(conn: *db.Db) db.DbError!i64 {
    return clock.sqlNowUnix(conn);
}

/// Try each identity field in order; return the matching non-empty row id, or null.
pub fn findByIdentity(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, identity: []const u8) !?[]const u8 {
    for (col.options.auth.identityFields) |idf| {
        const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT \"id\" FROM \"{s}\" WHERE \"{s}\" = ?1 AND \"{s}\" != '' LIMIT 1;", .{ col.name, idf, idf }, 0);
        var st = try conn.prepare(sql);
        defer st.finalize();
        try st.bindText(1, identity);
        if (try st.step()) return try alloc.dupe(u8, st.columnText(0));
    }
    return null;
}

pub fn passwordHashFor(alloc: std.mem.Allocator, conn: *db.Db, table: []const u8, rid: []const u8) !?[]const u8 {
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
        // Built via the shared session-cookie policy (session.zig) so login + logout +
        // clearSession never drift on cookie attributes.
        .cookies = session.sessionCookies(app.cookie_secure, token, csrf, max_age),
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

/// THE session seam: resolve a collection's table + the record's tokenKey, sign a
/// native `.auth` session via `issue()`, then fire `emitAuth(method)`. Every login —
/// password, refresh, magic-link, custom route — mints through here, so `onAuth`
/// ALWAYS fires. `conn` is the caller's already-acquired connection.
pub fn issueSession(
    ctx: *http.RequestCtx,
    conn: *db.Db,
    collection: []const u8,
    record_id: []const u8,
    method: events.AuthMethod,
) !Issued {
    return issueSessionExt(ctx, conn, collection, record_id, method, null);
}

/// Like `issueSession` but accepts a pre-fetched record (`opt_record`) to avoid a
/// redundant DB read when the caller already holds the record. When `opt_record` is
/// null the record is fetched as usual. `onAuth` still fires exactly once.
pub fn issueSessionExt(
    ctx: *http.RequestCtx,
    conn: *db.Db,
    collection: []const u8,
    record_id: []const u8,
    method: events.AuthMethod,
    opt_record: ?std.json.Value,
) !Issued {
    const col = (try collections.get(ctx.allocator, conn, collection)) orelse return error.NotFound;
    if (col.type != .auth) return error.NotFound;
    const tk = (try tokenKeyFor(ctx.allocator, conn, col.name, record_id)) orelse return error.NotFound;
    const issued = try issue(ctx, conn, col.name, record_id, tk);
    const rec: ?std.json.Value = if (opt_record) |r| r else try records.get(ctx.allocator, conn, col, record_id);
    emitAuth(ctx, col.name, rec, method);
    return issued;
}

/// Fire the writable, abortable `beforeAuthSuccess` hook (#80) inside the login's write
/// transaction. `conn` is the in-transaction writer; the hook's `*Ctx` is bound to it so
/// its `ctx.records()` writes participate in (and roll back with) the login.
///
/// Returns `null` to proceed (no hook registered, or the hook returned cleanly). When the
/// hook ABORTS (returns any error) it returns a ready-to-send `http.Response` mapped via
/// the `Ctx` error model (`ctx.fail` status / `error.Forbidden`→403 / else 500) — the
/// CALLER must `ROLLBACK` before returning it, so the session is never issued (fail closed).
pub fn fireBeforeAuthSuccess(
    req: *http.RequestCtx,
    conn: *db.Db,
    col_name: []const u8,
    rid: []const u8,
    method: events.AuthMethod,
    rec: std.json.Value,
) !?http.Response {
    const app = req.app orelse return null;
    const d = app.dispatch orelse return null;
    const h = d.before_auth_success orelse return null;
    // Identity context: the hook's ctx.user() reflects the just-authenticated principal.
    const rctx = request.RequestContext{
        .auth = rec,
        .is_superuser = false,
        .collection = col_name,
        .method = @tagName(req.method),
    };
    var cx = Ctx{ .app = app, .arena = req.allocator, .rctx = rctx, .request = req, .bound_conn = conn };
    defer cx.deinit(); // no-op when bound (reads reuse bound_conn), kept for hygiene
    var ev = events.AuthSuccessEvent{
        .app = app,
        .collection = col_name,
        .record_id = rid,
        .method = method,
        .record = rec,
    };
    h(&cx, &ev) catch |e| return cx.errorResponse(e);
    return null;
}

pub fn authWithPassword(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const body = parseBody(ctx) orelse return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator);
    const identity = strField(body, "identity") orelse return ApiError.badRequest("identity is required.").toResponse(ctx.allocator);
    const password = strField(body, "password") orelse return ApiError.badRequest("password is required.").toResponse(ctx.allocator);

    // Rate-limit gate (brute-force defense): per client IP, falling back to identity.
    if (try rateLimited(ctx, "login", identity)) |resp| return resp;

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

    const rec = (try records.get(ctx.allocator, &r, col, rid)) orelse
        return ApiError.notFound().toResponse(ctx.allocator);
    // Optional verification gate: refuse to mint a session for an unverified record.
    if (col.options.auth.require_verified and !recordVerified(rec))
        return (ApiError{ .status = 403, .message = "Email not verified." }).toResponse(ctx.allocator);
    const issued = issueSessionExt(ctx, &r, col.name, rid, .password, rec) catch |err| switch (err) {
        error.NotFound => return ApiError.badRequest("Invalid credentials.").toResponse(ctx.allocator),
        else => return err,
    };

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
    const issued = issueSessionExt(ctx, w, col_name, rid, .password, authed.record) catch |err| switch (err) {
        error.NotFound => return (ApiError{ .status = 401, .message = "Not authenticated." }).toResponse(ctx.allocator),
        else => return err,
    };
    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator, "token", .{ .string = issued.token });
    try root.put(ctx.allocator, "record", authed.record);
    const cookies = try ctx.allocator.dupe(http.Cookie, &issued.cookies);
    return jsonResponse(ctx, 200, .{ .object = root }, cookies);
}

pub fn authLogout(ctx: *http.RequestCtx) anyerror!http.Response {
    // Shared policy: the cleared cookies match what `issue()`/`clearSession` produce.
    const cleared = session.clearedCookies(ctx.app.?.cookie_secure);
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
pub fn deliverToken(app: *@import("../app.zig").App, alloc: std.mem.Allocator, email: []const u8, subject: []const u8, body: []const u8) !void {
    if (app.mailer) |m| {
        try m.send(app.io, alloc, .{ .to = email, .subject = subject, .text_body = body });
    } else {
        std.log.info("[mail:fallback] to={s} subject={s} body={s}", .{ email, subject, body });
    }
}

/// Mint a single-use token. `payload` binds an opaque value into the signed `pl` claim;
/// it travels in the same token (bound to its `jti`) and is covered by the HMAC signature,
/// so it cannot be tampered with in transit. Pass `""` when the token carries no payload
/// (verification / password-reset).
pub fn mintToken(ctx: *http.RequestCtx, conn: *db.Db, col_name: []const u8, rid: []const u8, token_key: []const u8, tt: jwt.TokenType, ttl: i64, payload: []const u8) ![]const u8 {
    const app = ctx.app.?;
    const now = try nowUnix(conn);
    const key = crypto.deriveKey(app.jwt_secret, token_key);
    // Random jti makes the token single-use (F7): redemption records it in
    // _consumedTokens; a replay is rejected even within the TTL and independent of
    // the tokenKey-rotation side effect.
    const jti = try crypto.genToken(app.io, ctx.allocator, 32);
    return jwt.sign(ctx.allocator, .{ .id = rid, .collection = col_name, .type = tt, .jti = jti, .pl = payload, .iat = now, .exp = now + ttl }, &key);
}

/// Record a single-use token's `jti` as consumed, or return error.AlreadyConsumed if it
/// was already redeemed. Atomic under the writer lock via the _consumedTokens PRIMARY KEY.
/// A token minted before this mechanism (empty jti) is treated as non-replayable-safe only
/// by the legacy rotation path; we reject an empty jti so every single-use redemption is tracked.
pub fn consumeToken(conn: *db.Db, claims: jwt.Claims) !void {
    if (claims.jti.len == 0) return error.AlreadyConsumed; // no jti => cannot guarantee single-use
    // Classify "already consumed" by the jti's PRESENCE, checked first. consumeToken runs
    // under the single writer lock, so this SELECT-then-INSERT is race-free. This is what
    // lets a genuine INSERT failure below (disk-full, I/O error, etc.) PROPAGATE as an
    // internal error instead of masquerading as error.AlreadyConsumed (a 400).
    {
        var sel = try conn.prepare("SELECT 1 FROM \"_consumedTokens\" WHERE \"jti\" = ?1;");
        defer sel.finalize();
        try sel.bindText(1, claims.jti);
        if (try sel.step()) return error.AlreadyConsumed; // a row exists => already redeemed
    }
    var st = try conn.prepare("INSERT INTO \"_consumedTokens\" (\"jti\",\"expires\",\"consumed\") VALUES (?1,?2,datetime('now'));");
    defer st.finalize();
    try st.bindText(1, claims.jti);
    try st.bindInt(2, claims.exp);
    _ = try st.step(); // a real DB failure propagates (500); it is no longer mistaken for a replay
}

fn loadAuthCollection(ctx: *http.RequestCtx, conn: *db.Db) !?schema.Collection {
    const col_name = ctx.param("col") orelse return null;
    const col = (try collections.get(ctx.allocator, conn, col_name)) orelse return null;
    if (col.type != .auth) return null;
    return col;
}

/// Verify a typed token against the record's derived key. Returns claims on success.
pub fn verifyTyped(ctx: *http.RequestCtx, conn: *db.Db, col: schema.Collection, token: []const u8, want: jwt.TokenType) !?jwt.Claims {
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
    // Rate-limit gate (email-bombing defense): per client IP, falling back to the
    // submitted email. Gated BEFORE the writer lock so a limited request never holds it.
    const rl_email = if (parseBody(ctx)) |b| (strField(b, "email") orelse "") else "";
    if (try rateLimited(ctx, "verify", rl_email)) |resp| return resp;
    // Strings are arena-allocated (ctx.allocator), so they outlive the scoped
    // writer block below and remain valid for the post-lock SMTP send.
    var pending: ?struct { email: []const u8, mail_body: []const u8 } = null;
    {
        const w = app.pool.acquireWriter();
        defer app.pool.releaseWriter();
        const col = (try loadAuthCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
        const body = parseBody(ctx) orelse return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator);
        if (strField(body, "email")) |email| {
            if (try findByEmail(ctx.allocator, w, col, email)) |rid| {
                if (try tokenKeyFor(ctx.allocator, w, col.name, rid)) |tk| {
                    const token = try mintToken(ctx, w, col.name, rid, tk, .verification, app.verification_ttl_s, "");
                    const mail_body = try std.fmt.allocPrint(ctx.allocator, "Verify your email ({s}). Your verification token:\n\n{s}\n", .{ col.name, token });
                    pending = .{ .email = email, .mail_body = mail_body };
                }
            }
        }
    }
    // Writer lock released: do the blocking SMTP send outside the global lock.
    if (pending) |p| {
        try deliverToken(app, ctx.allocator, p.email, "Verify your email", p.mail_body);
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
    // Single-use (F7): redeeming the same token twice fails here even within the TTL.
    consumeToken(w, claims) catch
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
    // Rate-limit gate (email-bombing defense): per client IP, falling back to the
    // submitted email. Gated BEFORE the writer lock so a limited request never holds it.
    const rl_email = if (parseBody(ctx)) |b| (strField(b, "email") orelse "") else "";
    if (try rateLimited(ctx, "reset", rl_email)) |resp| return resp;
    // Strings are arena-allocated (ctx.allocator), so they outlive the scoped
    // writer block below and remain valid for the post-lock SMTP send.
    var pending: ?struct { email: []const u8, mail_body: []const u8 } = null;
    {
        const w = app.pool.acquireWriter();
        defer app.pool.releaseWriter();
        const col = (try loadAuthCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
        const body = parseBody(ctx) orelse return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator);
        if (strField(body, "email")) |email| {
            if (try findByEmail(ctx.allocator, w, col, email)) |rid| {
                if (try tokenKeyFor(ctx.allocator, w, col.name, rid)) |tk| {
                    const token = try mintToken(ctx, w, col.name, rid, tk, .password_reset, app.password_reset_ttl_s, "");
                    const mail_body = try std.fmt.allocPrint(ctx.allocator, "Reset your password ({s}). Your password-reset token:\n\n{s}\n", .{ col.name, token });
                    pending = .{ .email = email, .mail_body = mail_body };
                }
            }
        }
    }
    // Writer lock released: do the blocking SMTP send outside the global lock.
    if (pending) |p| {
        try deliverToken(app, ctx.allocator, p.email, "Reset your password", p.mail_body);
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
    // Validate the new password BEFORE consuming so a too-short password does not burn
    // the (still single-use) token.
    if (password.len < col.options.auth.minPasswordLength)
        return ApiError.badRequest("Password too short.").toResponse(ctx.allocator);
    // Single-use (F7): consume before applying the change so a replay (even within the
    // TTL, before the tokenKey rotation that records.update triggers) is rejected.
    consumeToken(w, claims) catch
        return ApiError.badRequest("Invalid or expired token.").toResponse(ctx.allocator);
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

pub const TestEnv = struct {
    tmp: std.testing.TmpDir,
    pool: db.Pool,
    app: app_mod.App,

    pub fn initAuth(name: []const u8) !*TestEnv {
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

    pub fn deinit(env: *TestEnv) void {
        env.pool.deinit();
        env.tmp.cleanup();
        std.testing.allocator.destroy(env);
    }

    /// Create an auth record the same way the records API would (hash password,
    /// gen tokenKey, force verified=false), then insert via the records engine.
    pub fn createUser(env: *TestEnv, a: std.mem.Allocator, col_name: []const u8, email: []const u8, pw: []const u8) !void {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const col = (try collections.get(a, w, col_name)) orelse return error.NoCollection;
        var data: std.json.ObjectMap = .empty;
        try data.put(a, "email", .{ .string = email });
        try data.put(a, "password", .{ .string = pw });
        const prepared = try auth.applyCreate(env.app.io, a, .{ .object = data }, col.options.auth.minPasswordLength);
        _ = try records.create(a, env.app.io, w, col, prepared);
    }

    pub fn ctx(env: *TestEnv, a: std.mem.Allocator, m: http.Method, body: []const u8, params: []const http.Param) http.RequestCtx {
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
        const jti = try crypto.genToken(self.app.io, a, 32);
        return jwt.sign(a, .{ .id = rid, .collection = col_name, .type = tt, .jti = jti, .iat = now, .exp = now + 100000 }, &key);
    }

    /// Initialize a TestEnv with a webauthn-configured auth collection.
    /// The collection has rp_id="example.test", rp_name="Test App", origin="https://example.test".
    pub fn initWebAuthn(name: []const u8) !*TestEnv {
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
                .fields = &[_]schema.Field{},
                .listRule = "",
                .viewRule = "",
                .createRule = "",
                .updateRule = "",
                .deleteRule = "",
                .options = .{ .auth = .{ .methods = .{ .webauthn = .{
                    .rp_id = "example.test",
                    .rp_name = "Test App",
                    .origin = "https://example.test",
                } } } },
            });
        }
        env.app = .{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = &env.pool };
        return env;
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

// --- F7: strict single-use tokens (independent of tokenKey rotation) ---

test "F7: consumeToken classifies replay by jti presence, not by any INSERT failure" {
    // Normal ledger: a fresh jti is recorded; an identical second redemption is a replay.
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec("CREATE TABLE \"_consumedTokens\" (\"jti\" TEXT PRIMARY KEY, \"expires\" INTEGER, \"consumed\" TEXT);");
    const claims = jwt.Claims{ .id = "u1", .collection = "users", .type = .verification, .jti = "abc123", .iat = 0, .exp = 9_999_999_999 };
    try consumeToken(&d, claims);
    try std.testing.expectError(error.AlreadyConsumed, consumeToken(&d, claims));

    // Regression: a NON-replay INSERT failure (here a CHECK violation on a fresh jti) must
    // PROPAGATE as a DB error, not be misreported as error.AlreadyConsumed — the old
    // `step() catch return error.AlreadyConsumed` swallowed every failure (disk-full, I/O, …).
    var d2 = try db.Db.openMemory();
    defer d2.close();
    try d2.exec("CREATE TABLE \"_consumedTokens\" (\"jti\" TEXT PRIMARY KEY CHECK(length(\"jti\") < 3), \"expires\" INTEGER, \"consumed\" TEXT);");
    try std.testing.expectError(error.StepFailed, consumeToken(&d2, claims));

    // An empty jti is rejected outright (cannot be tracked single-use).
    const nojti = jwt.Claims{ .id = "u1", .collection = "users", .type = .verification, .jti = "", .iat = 0, .exp = 1 };
    try std.testing.expectError(error.AlreadyConsumed, consumeToken(&d2, nojti));
}

test "F7: a verification token cannot be redeemed twice (single-use)" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "v2@x.io", "longenough");
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    const token = try env.mintTyped(a, "users", "v2@x.io", .verification);
    const body = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\"}}", .{token});
    // First redemption succeeds. Verification does NOT rotate tokenKey, so without the
    // single-use ledger this token would remain replayable for its full TTL.
    var c1 = env.ctx(a, .POST, body, &p);
    try std.testing.expectEqual(@as(u16, 200), (try confirmVerification(&c1)).status);
    try std.testing.expect(env.recordVerified(a, "users", "v2@x.io"));
    // Second redemption of the very same (still-unexpired) token must fail.
    var c2 = env.ctx(a, .POST, body, &p);
    try std.testing.expectEqual(@as(u16, 400), (try confirmVerification(&c2)).status);
}

test "F7: a password-reset token cannot be redeemed twice (single-use)" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "r2@x.io", "oldpassword");
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    const token = try env.mintTyped(a, "users", "r2@x.io", .password_reset);
    const body = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\",\"password\":\"newpassword\"}}", .{token});
    var c1 = env.ctx(a, .POST, body, &p);
    try std.testing.expectEqual(@as(u16, 200), (try confirmPasswordReset(&c1)).status);
    // Replay rejected even though we re-send the identical valid-window token.
    var c2 = env.ctx(a, .POST, body, &p);
    try std.testing.expectEqual(@as(u16, 400), (try confirmPasswordReset(&c2)).status);
}

test "F7: a too-short password does not consume the reset token" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "r3@x.io", "oldpassword");
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    const token = try env.mintTyped(a, "users", "r3@x.io", .password_reset);
    const short = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\",\"password\":\"x\"}}", .{token});
    var bad = env.ctx(a, .POST, short, &p);
    try std.testing.expectEqual(@as(u16, 400), (try confirmPasswordReset(&bad)).status); // too short
    // The token survives the failed attempt and still works once.
    const ok = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\",\"password\":\"newpassword\"}}", .{token});
    var good = env.ctx(a, .POST, ok, &p);
    try std.testing.expectEqual(@as(u16, 200), (try confirmPasswordReset(&good)).status);
}

test "require_verified gates password login: unverified 403, verified 200" {
    var env = try TestEnv.initAuth("gated");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Recreate the collection with require_verified = true (initAuth made a default one).
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const existing = (try collections.get(a, w, "gated")).?;
        try collections.delete(a, w, existing.id);
        _ = try collections.create(a, std.testing.io, w, .{
            .id = "", .name = "gated", .type = .auth,
            .fields = &[_]schema.Field{},
            .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "",
            .options = .{ .auth = .{ .require_verified = true } },
        });
    }
    try env.createUser(a, "gated", "g@x.io", "longenough"); // created verified=false

    const p = [_]http.Param{.{ .key = "col", .value = "gated" }};
    var login = env.ctx(a, .POST, "{\"identity\":\"g@x.io\",\"password\":\"longenough\"}", &p);
    try std.testing.expectEqual(@as(u16, 403), (try authWithPassword(&login)).status);

    // Mark verified, then login succeeds.
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try w.exec("UPDATE \"gated\" SET \"verified\" = 1 WHERE \"email\" = 'g@x.io';");
    }
    var login2 = env.ctx(a, .POST, "{\"identity\":\"g@x.io\",\"password\":\"longenough\"}", &p);
    try std.testing.expectEqual(@as(u16, 200), (try authWithPassword(&login2)).status);
}

test "RouteEvent.issueSession mints a session and fires onAuth(custom)" {
    var env = try TestEnv.initAuth("members");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "members", "r@x.io", "longenough");
    // resolve rid
    const w0 = env.pool.acquireWriter();
    const col = (try collections.get(a, w0, "members")).?;
    const rid = (try findByIdentity(a, w0, col, "r@x.io")).?;
    env.pool.releaseWriter();

    const Counter = struct { var seen: usize = 0; var m: events.AuthMethod = .password;
        fn h(ev: *events.AuthEvent) void { seen += 1; m = ev.method; } };
    Counter.seen = 0;
    var disp = events.Dispatch{ .on_auth = Counter.h };
    env.app.dispatch = &disp;

    var hctx = env.ctx(a, .POST, "", &[_]http.Param{});
    var rctx = events.RouteEvent{ .app = &env.app, .ctx = &hctx, .rctx = .{} };
    const issued = try rctx.issueSession("members", rid);
    try std.testing.expectEqual(@as(usize, 2), issued.cookies.len);
    try std.testing.expectEqual(@as(usize, 1), Counter.seen);
    try std.testing.expectEqual(events.AuthMethod.custom, Counter.m);
}

test "issueSession is the mint+emit seam: emits onAuth once with the method tag" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "seam@x.io", "longenough");

    // Install a counting onAuth handler on the test app's dispatch.
    const Counter = struct {
        var seen: usize = 0;
        var last_method: events.AuthMethod = .oauth2;
        fn onAuth(ev: *events.AuthEvent) void { seen += 1; last_method = ev.method; }
    };
    Counter.seen = 0;
    var disp = events.Dispatch{ .on_auth = Counter.onAuth };
    env.app.dispatch = &disp;

    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var login = env.ctx(a, .POST, "{\"identity\":\"seam@x.io\",\"password\":\"longenough\"}", &p);
    const res = try authWithPassword(&login);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqual(@as(usize, 1), Counter.seen);
    try std.testing.expectEqual(events.AuthMethod.password, Counter.last_method);
}
