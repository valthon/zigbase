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

/// Read the record's current session epoch (#99), treating a NULL value (back-compat
/// default) as 0; the column itself is guaranteed present by migration 0010. `table` is the
/// physical auth table (collection name, or "_superusers"). Returns null only when no such
/// row exists.
pub fn tokenEpochFor(alloc: std.mem.Allocator, conn: *db.Db, table: []const u8, rid: []const u8) !?i64 {
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT COALESCE(\"token_epoch\", 0) FROM \"{s}\" WHERE \"id\" = ?1;", .{table}, 0);
    var st = try conn.prepare(sql);
    defer st.finalize();
    try st.bindText(1, rid);
    if (!try st.step()) return null;
    return st.columnInt(0);
}

/// Bump the record's session epoch by 1 — invalidating EVERY outstanding `.auth` token
/// for the principal ("revoke all sessions"/"log out everywhere", #99 Variant A). Must
/// run under the writer lock. `table` is the physical auth table. Returns the new epoch.
pub fn bumpTokenEpoch(alloc: std.mem.Allocator, conn: *db.Db, table: []const u8, rid: []const u8) !i64 {
    const sql = try std.fmt.allocPrintSentinel(alloc, "UPDATE \"{s}\" SET \"token_epoch\" = COALESCE(\"token_epoch\", 0) + 1 WHERE \"id\" = ?1;", .{table}, 0);
    var st = try conn.prepare(sql);
    defer st.finalize();
    try st.bindText(1, rid);
    _ = try st.step();
    return (try tokenEpochFor(alloc, conn, table, rid)) orelse error.NotFound;
}

pub const Issued = struct { token: []const u8, cookies: [2]http.Cookie };

pub fn issue(ctx: *http.RequestCtx, conn: *db.Db, collection: []const u8, rid: []const u8, token_key: []const u8) !Issued {
    const app = ctx.app.?;
    const csrf = try crypto.genToken(app.io, ctx.allocator, 32);
    const now = try nowUnix(conn);
    // Embed the record's current session epoch (#99) so verify can reject the token once
    // the epoch is bumped ("revoke all sessions"). 0 when the column is NULL/absent —
    // matching the default claim, so pre-epoch behavior is preserved.
    const epoch = (try tokenEpochFor(ctx.allocator, conn, collection, rid)) orelse 0;
    const claims = jwt.Claims{
        .id = rid,
        .collection = collection,
        .type = .auth,
        .csrf = csrf,
        .token_epoch = epoch,
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

/// Like `issueSessionExt` but does NOT fire `onAuth`. Used by the transactional consume
/// paths (`auth_methods.complete`, `magic_link_consume`) so they can emit the notification
/// AFTER `COMMIT` via `emitAuth`, preserving the invariant that `onAuth` only fires once a
/// session has been durably issued. (`issueSessionExt` keeps emitting inline for the legacy
/// non-transactional callers — `authWithPassword`/`authRefresh`.)
pub fn issueSessionNoEmit(
    ctx: *http.RequestCtx,
    conn: *db.Db,
    collection: []const u8,
    record_id: []const u8,
) !Issued {
    const col = (try collections.get(ctx.allocator, conn, collection)) orelse return error.NotFound;
    if (col.type != .auth) return error.NotFound;
    const tk = (try tokenKeyFor(ctx.allocator, conn, col.name, record_id)) orelse return error.NotFound;
    return issue(ctx, conn, col.name, record_id, tk);
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

/// True iff an auth-lifecycle hook (#98) is registered. Lets a handler skip the
/// heavier writer-acquiring path (e.g. logout) when no hook would fire.
pub fn hasAuthLifecycle(app: *@import("../app.zig").App) bool {
    const d = app.dispatch orelse return false;
    return d.auth_lifecycle != null;
}

/// Fire a BEFORE auth-lifecycle hook (#98) — register/logout/refresh/password-change.
/// Mirrors `fireBeforeAuthSuccess`: the hook's `*Ctx` is bound to `conn` (the action's
/// connection; in-transaction for register/refresh/password-change), so its
/// `ctx.records()` writes participate in (and roll back with) the action.
///
/// Returns `null` to proceed (no hook for this phase, or it returned cleanly). On ABORT
/// (the hook returns any error) returns a ready-to-send `http.Response` mapped via the `Ctx`
/// error model — the CALLER must roll back (where a txn exists) before returning it, so the
/// action is blocked (fail closed). `rec` is the writable record pointer where applicable
/// (`before_register` data); `identity` populates `ctx.user()` for the principal.
pub fn fireAuthLifecycleBefore(
    req: *http.RequestCtx,
    conn: *db.Db,
    col_name: []const u8,
    rid: []const u8,
    phase: events.AuthLifecyclePhase,
    rec: ?*std.json.Value,
    identity: ?std.json.Value,
) !?http.Response {
    const app = req.app orelse return null;
    const d = app.dispatch orelse return null;
    const h = d.auth_lifecycle orelse return null;
    const rctx = request.RequestContext{
        .auth = identity,
        .is_superuser = false,
        .collection = col_name,
        .method = @tagName(req.method),
    };
    var cx = Ctx{ .app = app, .arena = req.allocator, .rctx = rctx, .request = req, .bound_conn = conn };
    defer cx.deinit();
    var ev = events.AuthLifecycleEvent{
        .app = app,
        .collection = col_name,
        .record_id = rid,
        .phase = phase,
        .record = rec,
    };
    h(&cx, &ev) catch |e| return cx.errorResponse(e);
    return null;
}

/// Fire an AFTER auth-lifecycle hook (#98). After-style: never propagates — the action
/// already happened; an error is routed to the framework error backstop (parity with
/// after-record hooks). `conn` binds `ctx.records()` (the still-held writer post-commit).
pub fn emitAuthLifecycle(
    req: *http.RequestCtx,
    conn: *db.Db,
    col_name: []const u8,
    rid: []const u8,
    phase: events.AuthLifecyclePhase,
    rec: ?*std.json.Value,
    identity: ?std.json.Value,
) void {
    const app = req.app orelse return;
    const d = app.dispatch orelse return;
    const h = d.auth_lifecycle orelse return;
    const rctx = request.RequestContext{
        .auth = identity,
        .is_superuser = false,
        .collection = col_name,
        .method = @tagName(req.method),
    };
    var cx = Ctx{ .app = app, .arena = req.allocator, .rctx = rctx, .request = req, .bound_conn = conn };
    defer cx.deinit();
    var ev = events.AuthLifecycleEvent{
        .app = app,
        .collection = col_name,
        .record_id = rid,
        .phase = phase,
        .record = rec,
    };
    h(&cx, &ev) catch |e| {
        var err_ev = events.ErrorEvent{ .app = app, .ctx = &rctx, .err = e, .phase = .after_hook, .message = @errorName(e) };
        events.dispatchError(app, app.dispatch, &err_ev);
    };
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

    // Transactional refresh (#98): a `beforeRefresh` hook's side-writes commit atomically
    // with the new session; an aborting hook rolls back and blocks issuance (fail closed).
    // `onAuth` is emitted only AFTER the durable commit (parity with the consume paths).
    var rec_mut = authed.record;
    try w.beginImmediate();
    // Safety net for every error-return after begin (the hook, issueSessionNoEmit, commit):
    // value-returns below roll back explicitly; a later double-rollback is a harmless no-op.
    errdefer w.rollback() catch {};
    if (try fireAuthLifecycleBefore(ctx, w, col_name, rid, .before_refresh, &rec_mut, authed.record)) |resp| {
        w.rollback() catch {};
        return resp;
    }
    const issued = issueSessionNoEmit(ctx, w, col_name, rid) catch |err| switch (err) {
        error.NotFound => {
            w.rollback() catch {};
            return (ApiError{ .status = 401, .message = "Not authenticated." }).toResponse(ctx.allocator);
        },
        else => return err, // errdefer rolls back
    };
    w.commit() catch |e| {
        w.rollback() catch {};
        return e;
    };
    emitAuth(ctx, col_name, rec_mut, .password);
    emitAuthLifecycle(ctx, w, col_name, rid, .after_refresh, &rec_mut, rec_mut);

    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator, "token", .{ .string = issued.token });
    try root.put(ctx.allocator, "record", rec_mut);
    const cookies = try ctx.allocator.dupe(http.Cookie, &issued.cookies);
    return jsonResponse(ctx, 200, .{ .object = root }, cookies);
}

/// Extract a record's string `id`, or "" when absent/non-string.
fn recordId(rec: std.json.Value) []const u8 {
    if (rec != .object) return "";
    const v = rec.object.get("id") orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

pub fn authLogout(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;

    // #98: auth-lifecycle hooks. Logout performs no DB write, so a `beforeLogout` hook is
    // writable (bound to the writer) and abortable but NOT transactional — an abort returns
    // the mapped response and the session cookies are NOT cleared (nothing to roll back).
    // Only taken when a hook is registered, so the common case keeps the no-writer fast path.
    if (hasAuthLifecycle(app)) {
        const w = app.pool.acquireWriter();
        defer app.pool.releaseWriter();
        var lc_col = ctx.param("col") orelse "";
        // Best-effort identity: an invalid/expired/absent token logs out anonymously (rid="").
        var rid: []const u8 = "";
        var identity: ?std.json.Value = null;
        if (auth.authenticate(app.io, ctx.allocator, app, ctx, w) catch null) |a| {
            rid = recordId(a.record);
            identity = a.record;
            if (lc_col.len == 0) lc_col = a.collection;
        }
        if (try fireAuthLifecycleBefore(ctx, w, lc_col, rid, .before_logout, null, identity)) |resp| return resp;
        const cleared = session.clearedCookies(app.cookie_secure);
        const cookies = try ctx.allocator.dupe(http.Cookie, &cleared);
        emitAuthLifecycle(ctx, w, lc_col, rid, .after_logout, null, identity);
        return .{ .status = 204, .body = "", .cookies = cookies };
    }

    // Fast path (no lifecycle hook): just clear the session cookies. Shared policy: the
    // cleared cookies match what `issue()`/`clearSession` produce.
    const cleared = session.clearedCookies(app.cookie_secure);
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
    // Transactional password change (#98): consume + beforePasswordChange + the password
    // UPDATE commit atomically. An aborting `beforePasswordChange` rolls back BOTH the token
    // consumption (the reset link stays usable) and the password update (fail closed).
    try w.beginImmediate();
    // Safety net for every error-return after begin; value-returns below roll back explicitly.
    errdefer w.rollback() catch {};
    // Single-use (F7): consume before applying the change so a replay (even within the
    // TTL, before the tokenKey rotation that records.update triggers) is rejected.
    consumeToken(w, claims) catch {
        w.rollback() catch {};
        return ApiError.badRequest("Invalid or expired token.").toResponse(ctx.allocator);
    };
    // Existing record snapshot for the hook (read on the same in-transaction conn).
    // Use `try` (not `catch null`): a genuine DB failure must propagate so the errdefer
    // rolls back (token un-consumed, password unchanged → clean 500) rather than feeding a
    // null record/identity to a `before_password_change` authorization hook. `records.get`
    // returns null only for genuine not-found, so that path is preserved below.
    var rec_opt = try records.get(ctx.allocator, w, col, claims.id);
    const rec_ptr: ?*std.json.Value = if (rec_opt) |*r| r else null;
    if (try fireAuthLifecycleBefore(ctx, w, col.name, claims.id, .before_password_change, rec_ptr, rec_opt)) |resp| {
        w.rollback() catch {};
        return resp;
    }
    var data: std.json.ObjectMap = .empty;
    try data.put(ctx.allocator, "password", .{ .string = password });
    const updated = auth.applyUpdate(app.io, ctx.allocator, .{ .object = data }, col.options.auth.minPasswordLength) catch {
        w.rollback() catch {};
        return ApiError.badRequest("Invalid password.").toResponse(ctx.allocator);
    };
    _ = records.update(ctx.allocator, w, col, claims.id, updated) catch {
        w.rollback() catch {};
        return ApiError.internal().toResponse(ctx.allocator);
    };
    w.commit() catch |e| {
        w.rollback() catch {};
        return e;
    };
    emitAuthLifecycle(ctx, w, col.name, claims.id, .after_password_change, rec_ptr, rec_opt);
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

// --- #99: session epoch revocation (Variant A) ---

/// Resolve a user's row id in `col_name`.
fn ridOf(env: *TestEnv, a: std.mem.Allocator, col_name: []const u8, email: []const u8) ![]const u8 {
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    const col = (try collections.get(a, w, col_name)).?;
    return (try findByIdentity(a, w, col, email)).?;
}

test "#99 epoch bump invalidates outstanding tokens; a freshly issued token verifies (revoke-all)" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "ep@x.io", "longenough");
    const rid = try ridOf(env, a, "users", "ep@x.io");

    var hctx = env.ctx(a, .POST, "", &[_]http.Param{});

    // Issue a session token at epoch 0; it verifies.
    const issued0 = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk try issueSession(&hctx, w, "users", rid, .password);
    };
    {
        var r = try env.pool.acquireReader();
        defer env.pool.releaseReader(&r);
        try std.testing.expect(auth.verifyToken(a, &env.app, &r, issued0.token) != null);
    }

    // "Revoke all sessions": bump the record's epoch (0 -> 1).
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try std.testing.expectEqual(@as(i64, 1), try bumpTokenEpoch(a, w, "users", rid));
    }

    // The previously valid token now FAILS verification (fail closed).
    {
        var r = try env.pool.acquireReader();
        defer env.pool.releaseReader(&r);
        try std.testing.expect(auth.verifyToken(a, &env.app, &r, issued0.token) == null);
    }

    // A token issued AFTER the bump carries epoch 1 and verifies again.
    const issued1 = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk try issueSession(&hctx, w, "users", rid, .password);
    };
    {
        var r = try env.pool.acquireReader();
        defer env.pool.releaseReader(&r);
        try std.testing.expect(auth.verifyToken(a, &env.app, &r, issued1.token) != null);
    }
}

fn loadRecord(env: *TestEnv, a: std.mem.Allocator, col_name: []const u8, rid: []const u8) !std.json.Value {
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    const col = (try collections.get(a, w, col_name)).?;
    return (try records.get(a, w, col, rid)).?;
}

test "#99 ctx.auth().revokeAllSessions invalidates the principal's tokens" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "rv@x.io", "longenough");
    const rid = try ridOf(env, a, "users", "rv@x.io");
    const rec = try loadRecord(env, a, "users", rid);

    var hctx = env.ctx(a, .POST, "", &[_]http.Param{});
    const issued = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk try issueSession(&hctx, w, "users", rid, .password);
    };

    var cx = Ctx{ .app = &env.app, .arena = a, .rctx = .{ .auth = rec, .collection = "users" }, .request = &hctx };
    defer cx.deinit();
    try cx.auth().revokeAllSessions(); // acquires the writer internally

    var r = try env.pool.acquireReader();
    defer env.pool.releaseReader(&r);
    try std.testing.expect(auth.verifyToken(a, &env.app, &r, issued.token) == null);
}

test "#99 ctx.auth().refresh keeps other sessions valid; rotate kills them" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "rr@x.io", "longenough");
    const rid = try ridOf(env, a, "users", "rr@x.io");
    const rec = try loadRecord(env, a, "users", rid);

    var hctx = env.ctx(a, .POST, "", &[_]http.Param{});
    // An existing session token (epoch 0).
    const existing = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk try issueSession(&hctx, w, "users", rid, .password);
    };

    var cx = Ctx{ .app = &env.app, .arena = a, .rctx = .{ .auth = rec, .collection = "users" }, .request = &hctx };
    defer cx.deinit();

    // refresh: a new token is minted AND the existing one stays valid (same epoch).
    const refreshed = try cx.auth().refresh();
    {
        var r = try env.pool.acquireReader();
        defer env.pool.releaseReader(&r);
        try std.testing.expect(auth.verifyToken(a, &env.app, &r, refreshed.token) != null);
        try std.testing.expect(auth.verifyToken(a, &env.app, &r, existing.token) != null);
    }

    // rotate: returns a fresh valid token, but every PRIOR token (existing + refreshed) dies.
    const rotated = try cx.auth().rotate();
    {
        var r = try env.pool.acquireReader();
        defer env.pool.releaseReader(&r);
        try std.testing.expect(auth.verifyToken(a, &env.app, &r, rotated.token) != null);
        try std.testing.expect(auth.verifyToken(a, &env.app, &r, existing.token) == null);
        try std.testing.expect(auth.verifyToken(a, &env.app, &r, refreshed.token) == null);
    }
}

test "#99 per-device verbs are stubbed: epoch mode reports SessionStoreNotEnabled" {
    var env = try TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var hctx = env.ctx(a, .POST, "", &[_]http.Param{});
    var cx = Ctx{ .app = &env.app, .arena = a, .rctx = .{}, .request = &hctx };
    defer cx.deinit();
    // Default app.session_store == .epoch -> per-device inventory is unavailable.
    try std.testing.expectError(error.SessionStoreNotEnabled, cx.auth().listActiveSessions());
    try std.testing.expectError(error.SessionStoreNotEnabled, cx.auth().revoke("s1"));
    // In table mode the verbs report the not-yet-implemented store instead.
    env.app.session_store = .table;
    try std.testing.expectError(error.SessionTableNotImplemented, cx.auth().listActiveSessions());
    try std.testing.expectError(error.SessionTableNotImplemented, cx.auth().revoke("s1"));
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

// ---------------------------------------------------------------------------
// #98 — auth lifecycle hooks: logout / refresh / password-change
// ---------------------------------------------------------------------------

/// Create a base `posts` collection so a lifecycle hook can do a side-write.
fn createBasePosts(env: *TestEnv, a: std.mem.Allocator) !void {
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    _ = try collections.create(a, std.testing.io, w, .{
        .id = "", .name = "posts", .type = .base,
        .fields = &[_]schema.Field{.{ .id = "t1", .name = "title", .options = .{ .text = .{} } }},
        .listRule = null, .viewRule = null, .createRule = null, .updateRule = null, .deleteRule = null,
    });
}

fn countTable(env: *TestEnv, table: []const u8) !i64 {
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    const sql = try std.fmt.allocPrintSentinel(std.testing.allocator, "SELECT COUNT(*) FROM \"{s}\";", .{table}, 0);
    defer std.testing.allocator.free(sql);
    var st = try w.prepare(sql);
    defer st.finalize();
    _ = try st.step();
    return st.columnInt(0);
}

/// Login and return the issued bearer token (arena-owned).
fn loginToken(env: *TestEnv, a: std.mem.Allocator, col: []const u8, identity: []const u8, pw: []const u8) ![]const u8 {
    const p = [_]http.Param{.{ .key = "col", .value = col }};
    const body = try std.fmt.allocPrint(a, "{{\"identity\":\"{s}\",\"password\":\"{s}\"}}", .{ identity, pw });
    var login = env.ctx(a, .POST, body, &p);
    const res = try authWithPassword(&login);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, res.body, .{});
    return parsed.value.object.get("token").?.string;
}

test "#98 refresh: before/after refresh hooks fire on a valid refresh" {
    var env = try TestEnv.initAuth("refreshu");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "refreshu", "rf@x.io", "longenough");
    const token = try loginToken(env, a, "refreshu", "rf@x.io", "longenough");

    const Hook = struct {
        var before_seen: usize = 0;
        var after_seen: usize = 0;
        var phase_ok = false;
        var rid_seen: []const u8 = "";
        fn before(ctx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
            _ = ctx;
            before_seen += 1;
            if (ev.phase == .before_refresh) phase_ok = true;
            rid_seen = ev.record_id;
        }
        fn after(ctx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
            _ = ctx;
            _ = ev;
            after_seen += 1;
        }
    };
    Hook.before_seen = 0;
    Hook.after_seen = 0;
    var disp = events.Dispatch{ .auth_lifecycle = events.buildAuthLifecycleDispatcher(.{
        .beforeRefresh = Hook.before,
        .afterRefresh = Hook.after,
    }) };
    env.app.dispatch = &disp;

    const p = [_]http.Param{.{ .key = "col", .value = "refreshu" }};
    var refresh = env.ctx(a, .POST, "", &p);
    refresh.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    const res = try authRefresh(&refresh);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqual(@as(usize, 1), Hook.before_seen);
    try std.testing.expectEqual(@as(usize, 1), Hook.after_seen);
    try std.testing.expect(Hook.phase_ok);
    try std.testing.expect(Hook.rid_seen.len > 0);
}

test "#98 refresh: aborting beforeRefresh blocks the session AND rolls back side-writes" {
    var env = try TestEnv.initAuth("refreshb");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "refreshb", "rf@x.io", "longenough");
    try createBasePosts(env, a);
    const token = try loginToken(env, a, "refreshb", "rf@x.io", "longenough");

    const Hook = struct {
        fn writeThenAbort(ctx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
            _ = ev;
            var o: std.json.ObjectMap = .empty;
            try o.put(ctx.arena, "title", .{ .string = "rollme" });
            _ = try ctx.records().create("posts", .{ .object = o });
            return ctx.fail(403, "no refresh");
        }
    };
    var disp = events.Dispatch{ .auth_lifecycle = events.buildAuthLifecycleDispatcher(.{ .beforeRefresh = Hook.writeThenAbort }) };
    env.app.dispatch = &disp;

    const p = [_]http.Param{.{ .key = "col", .value = "refreshb" }};
    var refresh = env.ctx(a, .POST, "", &p);
    refresh.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    const res = try authRefresh(&refresh);
    try std.testing.expectEqual(@as(u16, 403), res.status); // fail closed
    try std.testing.expectEqual(@as(usize, 0), res.cookies.len); // no new session
    try std.testing.expectEqual(@as(i64, 0), try countTable(env, "posts")); // side-write rolled back
}

test "#98 logout: before/after logout hooks fire; session cookies still cleared" {
    var env = try TestEnv.initAuth("logoutu");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "logoutu", "lo@x.io", "longenough");
    const token = try loginToken(env, a, "logoutu", "lo@x.io", "longenough");

    const Hook = struct {
        var before_seen: usize = 0;
        var after_seen: usize = 0;
        var rid_seen: []const u8 = "";
        fn before(ctx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
            _ = ctx;
            before_seen += 1;
            rid_seen = ev.record_id;
        }
        fn after(ctx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
            _ = ctx;
            _ = ev;
            after_seen += 1;
        }
    };
    Hook.before_seen = 0;
    Hook.after_seen = 0;
    var disp = events.Dispatch{ .auth_lifecycle = events.buildAuthLifecycleDispatcher(.{
        .beforeLogout = Hook.before,
        .afterLogout = Hook.after,
    }) };
    env.app.dispatch = &disp;

    const p = [_]http.Param{.{ .key = "col", .value = "logoutu" }};
    var logout = env.ctx(a, .POST, "", &p);
    logout.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    const res = try authLogout(&logout);
    try std.testing.expectEqual(@as(u16, 204), res.status);
    var cleared: usize = 0;
    for (res.cookies) |c| if (c.max_age_s < 0) {
        cleared += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), cleared);
    try std.testing.expectEqual(@as(usize, 1), Hook.before_seen);
    try std.testing.expectEqual(@as(usize, 1), Hook.after_seen);
    try std.testing.expect(Hook.rid_seen.len > 0); // identity resolved from the bearer
}

test "#98 logout: aborting beforeLogout returns the mapped status and does NOT clear cookies" {
    var env = try TestEnv.initAuth("logoutb");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Hook = struct {
        fn abort(ctx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
            _ = ev;
            return ctx.fail(409, "logout blocked");
        }
    };
    var disp = events.Dispatch{ .auth_lifecycle = events.buildAuthLifecycleDispatcher(.{ .beforeLogout = Hook.abort }) };
    env.app.dispatch = &disp;

    const p = [_]http.Param{.{ .key = "col", .value = "logoutb" }};
    var logout = env.ctx(a, .POST, "", &p);
    const res = try authLogout(&logout);
    try std.testing.expectEqual(@as(u16, 409), res.status);
    try std.testing.expectEqual(@as(usize, 0), res.cookies.len); // cookies NOT cleared
}

test "#98 password-change: before/after hooks fire on confirm-password-reset" {
    var env = try TestEnv.initAuth("pcu");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "pcu", "pc@x.io", "oldpassword");
    const token = try env.mintTyped(a, "pcu", "pc@x.io", .password_reset);

    const Hook = struct {
        var before_seen: usize = 0;
        var after_seen: usize = 0;
        var rid_seen: []const u8 = "";
        fn before(ctx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
            _ = ctx;
            before_seen += 1;
            rid_seen = ev.record_id;
        }
        fn after(ctx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
            _ = ctx;
            _ = ev;
            after_seen += 1;
        }
    };
    Hook.before_seen = 0;
    Hook.after_seen = 0;
    var disp = events.Dispatch{ .auth_lifecycle = events.buildAuthLifecycleDispatcher(.{
        .beforePasswordChange = Hook.before,
        .afterPasswordChange = Hook.after,
    }) };
    env.app.dispatch = &disp;

    const p = [_]http.Param{.{ .key = "col", .value = "pcu" }};
    const body = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\",\"password\":\"newpassword\"}}", .{token});
    var conf = env.ctx(a, .POST, body, &p);
    try std.testing.expectEqual(@as(u16, 200), (try confirmPasswordReset(&conf)).status);
    try std.testing.expectEqual(@as(usize, 1), Hook.before_seen);
    try std.testing.expectEqual(@as(usize, 1), Hook.after_seen);
    try std.testing.expect(Hook.rid_seen.len > 0);
}

test "#98 password-change: aborting beforePasswordChange leaves password + reset token intact" {
    var env = try TestEnv.initAuth("pcb");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "pcb", "pc@x.io", "oldpassword");
    const token = try env.mintTyped(a, "pcb", "pc@x.io", .password_reset);

    const Hook = struct {
        fn abort(ctx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
            _ = ev;
            return ctx.fail(403, "password change blocked");
        }
    };
    var disp = events.Dispatch{ .auth_lifecycle = events.buildAuthLifecycleDispatcher(.{ .beforePasswordChange = Hook.abort }) };
    env.app.dispatch = &disp;

    const p = [_]http.Param{.{ .key = "col", .value = "pcb" }};
    const body = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\",\"password\":\"newpassword\"}}", .{token});
    var conf = env.ctx(a, .POST, body, &p);
    try std.testing.expectEqual(@as(u16, 403), (try confirmPasswordReset(&conf)).status);

    // Password unchanged: the old password still authenticates.
    env.app.dispatch = null;
    const old_token = loginToken(env, a, "pcb", "pc@x.io", "oldpassword") catch "";
    try std.testing.expect(old_token.len > 0);

    // Reset token un-consumed: with the hook removed, the SAME token now succeeds.
    var conf2 = env.ctx(a, .POST, body, &p);
    try std.testing.expectEqual(@as(u16, 200), (try confirmPasswordReset(&conf2)).status);
    // And the new password now works.
    const new_token = loginToken(env, a, "pcb", "pc@x.io", "newpassword") catch "";
    try std.testing.expect(new_token.len > 0);
}
