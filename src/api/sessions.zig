//! Per-device session REST (spec §F3): the canonical HTTP surface over the #99
//! `ctx.auth()` session verbs, for apps opted into `App(.{ .session_store = .table })`.
//!
//! | Route                                            | Mode     | Behavior |
//! |--------------------------------------------------|----------|----------|
//! | GET    /api/collections/:col/auth/sessions       | .table   | 200 {"items":[…]} newest-first, `is_current` marked |
//! | DELETE /api/collections/:col/auth/sessions/:sid  | .table   | 204; non-owned or absent sid → 404 (indistinguishable) |
//! | DELETE /api/collections/:col/auth/sessions       | BOTH     | "log out everywhere": epoch bump (+ wipe `_sessions` rows in table mode) → 204 with CLEARED cookies |
//!
//! In `.epoch` mode the two per-device routes return 404 (feature not enabled — same
//! policy as a disabled auth-method slug; non-oracle). `:col` must match the caller's
//! authenticated collection (else 401, matching authRefresh). No new authz predicate:
//! ownership is a plain WHERE on `_sessions`, never a rule — the records.list/realtime
//! chokepoints are not implicated.
const std = @import("std");
const RequestArena = @import("../request_arena.zig").RequestArena;
const http = @import("../http.zig");
const db = @import("../db.zig");
const auth = @import("../auth.zig");
const api_auth = @import("auth.zig");
const session = @import("../session.zig");
const ApiError = @import("error.zig").ApiError;

fn notAuthed(ctx: *http.RequestCtx) !http.Response {
    return ApiError.withCode(401, .unauthorized, "Not authenticated.").toResponse(ctx.allocator.a);
}

/// Authenticate + require `:col` to match the caller's collection (parity with authRefresh:
/// a cross-collection probe is 401, not 404 — the caller IS authenticated, just not here).
fn requireAuthed(ctx: *http.RequestCtx, conn: *db.Db) !union(enum) { ok: auth.Authed, resp: http.Response } {
    const app = ctx.app.?;
    const authed = (try auth.authenticate(app.io, ctx.allocator.a, app, ctx, conn)) orelse
        return .{ .resp = try notAuthed(ctx) };
    const col_name = ctx.param("col") orelse return .{ .resp = try ApiError.notFound().toResponse(ctx.allocator.a) };
    if (!std.mem.eql(u8, authed.collection, col_name))
        return .{ .resp = try notAuthed(ctx) };
    return .{ .ok = authed };
}

/// GET …/auth/sessions — the caller's own active sessions. Read-only (READER).
pub fn list(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    if (app.session_store != .table) return ApiError.notFound().toResponse(ctx.allocator.a); // .epoch: feature not enabled
    var r = try app.pool.acquireReader();
    defer app.pool.releaseReader(&r);
    const authed = switch (try requireAuthed(ctx, &r)) {
        .resp => |resp| return resp,
        .ok => |a| a,
    };
    const rid = if (authed.record == .object) authed.record.object.get("id").?.string else return notAuthed(ctx);
    const rows = try api_auth.listSessions(ctx.allocator.a, &r, authed.collection, rid);
    var arr = std.json.Array.init(ctx.allocator.a);
    for (rows) |row| {
        var o: std.json.ObjectMap = .empty;
        try o.put(ctx.allocator.a, "id", .{ .string = row.id });
        try o.put(ctx.allocator.a, "created", .{ .string = row.created });
        try o.put(ctx.allocator.a, "last_seen", .{ .string = row.last_seen });
        try o.put(ctx.allocator.a, "user_agent", .{ .string = row.user_agent });
        try o.put(ctx.allocator.a, "ip", .{ .string = row.ip });
        try o.put(ctx.allocator.a, "is_current", .{ .bool = authed.sid.len > 0 and std.mem.eql(u8, row.id, authed.sid) });
        try arr.append(.{ .object = o });
    }
    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator.a, "items", .{ .array = arr }); // {items} envelope (repo-wide list shape)
    return .{
        .status = 200,
        .body = try std.json.Stringify.valueAlloc(ctx.allocator.a, std.json.Value{ .object = root }, .{}),
    };
}

/// DELETE …/auth/sessions/:sid — "log out THIS device". Owner-or-superuser; a non-owner
/// gets the SAME 404 as an absent id (no probing other users' session ids — parity with
/// ctx.auth().revoke). Revoking your CURRENT session is allowed (cookies are not cleared;
/// the token simply stops verifying).
pub fn revoke(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    if (app.session_store != .table) return ApiError.notFound().toResponse(ctx.allocator.a);
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const authed = switch (try requireAuthed(ctx, w)) {
        .resp => |resp| return resp,
        .ok => |a| a,
    };
    const rid = if (authed.record == .object) authed.record.object.get("id").?.string else return notAuthed(ctx);
    const sid = ctx.param("sid") orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    const owner = (try api_auth.sessionOwner(ctx.allocator.a, w, sid)) orelse
        return ApiError.notFound().toResponse(ctx.allocator.a);
    const is_owner = std.mem.eql(u8, owner.collection, authed.collection) and std.mem.eql(u8, owner.record, rid);
    if (!authed.is_superuser and !is_owner) return ApiError.notFound().toResponse(ctx.allocator.a); // indistinguishable
    _ = try api_auth.deleteSession(w, sid);
    return .{ .status = 204, .body = "" }; // side-effect success: 204, no body
}

/// DELETE …/auth/sessions — "log out everywhere". Works in BOTH modes: bumps the token
/// epoch (kills every outstanding token, incl. long-lived ones minted before .table mode
/// was enabled) and, in table mode, wipes the principal's `_sessions` rows. The CURRENT
/// session dies too, by design — the response clears the session cookies.
pub fn revokeAll(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const authed = switch (try requireAuthed(ctx, w)) {
        .resp => |resp| return resp,
        .ok => |a| a,
    };
    const rid = if (authed.record == .object) authed.record.object.get("id").?.string else return notAuthed(ctx);
    _ = try api_auth.bumpTokenEpoch(ctx.allocator.a, w, authed.collection, rid);
    if (app.session_store == .table) try api_auth.deleteSessionsForPrincipal(w, authed.collection, rid);
    const cleared = session.clearedCookies(app.cookie_secure);
    const cookies = try ctx.allocator.a.dupe(http.Cookie, &cleared);
    return .{ .status = 204, .body = "", .cookies = cookies };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const jwt = @import("../jwt.zig");
const collections = @import("../collections.zig");
const app_mod = @import("../app.zig");

/// Login via the real HTTP handler and return the bearer token.
fn login(env: *api_auth.TestEnv, a: RequestArena, col_name: []const u8, email: []const u8, pw: []const u8) ![]const u8 {
    const p = [_]http.Param{.{ .key = "col", .value = col_name }};
    const body = try std.fmt.allocPrint(a.a, "{{\"identity\":\"{s}\",\"password\":\"{s}\"}}", .{ email, pw });
    var req = env.ctx(a, .POST, body, &p);
    const res = try api_auth.authWithPassword(&req);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    const parsed = try std.json.parseFromSlice(std.json.Value, a.a, res.body, .{});
    return parsed.value.object.get("token").?.string;
}

fn bearerCtx(env: *api_auth.TestEnv, a: RequestArena, m: http.Method, col_name: []const u8, token: []const u8, extra: []const http.Param) !http.RequestCtx {
    var params: std.ArrayList(http.Param) = .empty;
    try params.append(a.a, .{ .key = "col", .value = col_name });
    try params.appendSlice(a.a, extra);
    var c = env.ctx(a, m, "", try params.toOwnedSlice(a.a));
    c.authorization = try std.fmt.allocPrint(a.a, "Bearer {s}", .{token});
    return c;
}

test "sessions REST: list in .table mode → {items} newest-first with is_current" {
    var env = try api_auth.TestEnv.initAuth("users");
    defer env.deinit();
    env.app.session_store = .table;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "list@x.io", "longenough");

    _ = try login(env, RequestArena.from(&arena), "users", "list@x.io", "longenough");
    const tok2 = try login(env, RequestArena.from(&arena), "users", "list@x.io", "longenough");
    const sid2 = (try jwt.peekClaims(a, tok2)).sid.?;

    var req = try bearerCtx(env, RequestArena.from(&arena), .GET, "users", tok2, &.{});
    const res = try list(&req);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expect(std.mem.startsWith(u8, res.body, "{\"items\":["));

    const parsed = try std.json.parseFromSlice(std.json.Value, a, res.body, .{});
    const items = parsed.value.object.get("items").?.array;
    try std.testing.expectEqual(@as(usize, 2), items.items.len);

    var current_count: usize = 0;
    var current_id: []const u8 = "";
    for (items.items) |it| {
        if (it.object.get("is_current").?.bool) {
            current_count += 1;
            current_id = it.object.get("id").?.string;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), current_count);
    try std.testing.expectEqualStrings(sid2, current_id);

    // Position, not just presence: the SECOND login (sid2) must lead `items[0]`. Both
    // sessions share the same second-resolution `created` (datetime('now')) when the two
    // logins land in the same wall-clock second, so this only holds if listSessions breaks
    // the tie deterministically (rowid DESC) rather than relying on insertion-order luck.
    try std.testing.expectEqualStrings(sid2, items.items[0].object.get("id").?.string);
}

test "sessions REST: per-device routes 404 in .epoch mode (non-oracle: same as a disabled slug)" {
    var env = try api_auth.TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "ep@x.io", "longenough");
    const tok = try login(env, RequestArena.from(&arena), "users", "ep@x.io", "longenough");

    var get_req = try bearerCtx(env, RequestArena.from(&arena), .GET, "users", tok, &.{});
    const get_res = try list(&get_req);
    try std.testing.expectEqual(@as(u16, 404), get_res.status);
    const expected = try ApiError.notFound().renderBody(a);
    try std.testing.expectEqualStrings(expected, get_res.body);

    var del_req = try bearerCtx(env, RequestArena.from(&arena), .DELETE, "users", tok, &[_]http.Param{.{ .key = "sid", .value = "whatever" }});
    const del_res = try revoke(&del_req);
    try std.testing.expectEqual(@as(u16, 404), del_res.status);
    try std.testing.expectEqualStrings(expected, del_res.body);
}

test "sessions REST: anonymous → 401; cross-collection token → 401 (parity with authRefresh)" {
    var env = try api_auth.TestEnv.initAuth("users");
    defer env.deinit();
    env.app.session_store = .table;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "anon@x.io", "longenough");

    var no_auth = env.ctx(RequestArena.from(&arena), .GET, "", &[_]http.Param{.{ .key = "col", .value = "users" }});
    const res1 = try list(&no_auth);
    try std.testing.expectEqual(@as(u16, 401), res1.status);
    const parsed1 = try std.json.parseFromSlice(std.json.Value, a, res1.body, .{});
    try std.testing.expectEqualStrings("Not authenticated.", parsed1.value.object.get("message").?.string);

    // A second auth collection.
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        _ = try collections.create(a, env.app.io, w, .{
            .id = "",
            .name = "admins",
            .type = .auth,
            .fields = &[_]@import("../schema.zig").Field{},
            .listRule = "",
            .viewRule = "",
            .createRule = "",
            .updateRule = "",
            .deleteRule = "",
        });
    }

    const tok = try login(env, RequestArena.from(&arena), "users", "anon@x.io", "longenough");
    var cross = try bearerCtx(env, RequestArena.from(&arena), .GET, "admins", tok, &.{});
    const res2 = try list(&cross);
    try std.testing.expectEqual(@as(u16, 401), res2.status);
    const parsed2 = try std.json.parseFromSlice(std.json.Value, a, res2.body, .{});
    try std.testing.expectEqualStrings("Not authenticated.", parsed2.value.object.get("message").?.string);
}

test "sessions REST: revoke own → 204 empty body + token dead; non-owner and absent sid → identical 404" {
    var env = try api_auth.TestEnv.initAuth("users");
    defer env.deinit();
    env.app.session_store = .table;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "u1@x.io", "longenough");
    try env.createUser(a, "users", "u2@x.io", "longenough");

    const tok1a = try login(env, RequestArena.from(&arena), "users", "u1@x.io", "longenough");
    const tok1b = try login(env, RequestArena.from(&arena), "users", "u1@x.io", "longenough");
    const sid1b = (try jwt.peekClaims(a, tok1b)).sid.?;
    const tok2 = try login(env, RequestArena.from(&arena), "users", "u2@x.io", "longenough");

    // user1 revokes user1's OTHER session (sid1b) using tok1a.
    var rev_req = try bearerCtx(env, RequestArena.from(&arena), .DELETE, "users", tok1a, &[_]http.Param{.{ .key = "sid", .value = sid1b }});
    const rev_res = try revoke(&rev_req);
    try std.testing.expectEqual(@as(u16, 204), rev_res.status);
    try std.testing.expectEqual(@as(usize, 0), rev_res.body.len);

    // The revoked token (tok1b) now fails authRefresh.
    {
        var refresh_req = env.ctx(RequestArena.from(&arena), .POST, "", &[_]http.Param{.{ .key = "col", .value = "users" }});
        refresh_req.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{tok1b});
        const refresh_res = try api_auth.authRefresh(&refresh_req);
        try std.testing.expectEqual(@as(u16, 401), refresh_res.status);
    }

    // user2 revoking user1's sid (sid1b, already gone) → 404.
    var non_owner_req = try bearerCtx(env, RequestArena.from(&arena), .DELETE, "users", tok2, &[_]http.Param{.{ .key = "sid", .value = sid1b }});
    const non_owner_res = try revoke(&non_owner_req);
    try std.testing.expectEqual(@as(u16, 404), non_owner_res.status);

    // Revoking a definitely-nonexistent sid → identical 404.
    var absent_req = try bearerCtx(env, RequestArena.from(&arena), .DELETE, "users", tok2, &[_]http.Param{.{ .key = "sid", .value = "nonexistent0000" }});
    const absent_res = try revoke(&absent_req);
    try std.testing.expectEqual(@as(u16, 404), absent_res.status);
    try std.testing.expectEqualStrings(non_owner_res.body, absent_res.body);
}

test "sessions REST: revoke-all works in BOTH modes — 204 + cleared cookies + epoch bump kills old tokens" {
    // Epoch mode.
    {
        var env = try api_auth.TestEnv.initAuth("users");
        defer env.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        try env.createUser(a, "users", "e@x.io", "longenough");
        const tok = try login(env, RequestArena.from(&arena), "users", "e@x.io", "longenough");

        var req = try bearerCtx(env, RequestArena.from(&arena), .DELETE, "users", tok, &.{});
        const res = try revokeAll(&req);
        try std.testing.expectEqual(@as(u16, 204), res.status);
        try std.testing.expectEqual(@as(usize, 0), res.body.len);
        try std.testing.expectEqual(@as(usize, 2), res.cookies.len);
        for (res.cookies) |c| {
            try std.testing.expectEqual(@as(usize, 0), c.value.len);
            try std.testing.expect(c.max_age_s < 0);
        }

        var refresh_req = env.ctx(RequestArena.from(&arena), .POST, "", &[_]http.Param{.{ .key = "col", .value = "users" }});
        refresh_req.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{tok});
        const refresh_res = try api_auth.authRefresh(&refresh_req);
        try std.testing.expectEqual(@as(u16, 401), refresh_res.status);
    }

    // Table mode.
    {
        var env = try api_auth.TestEnv.initAuth("users");
        defer env.deinit();
        env.app.session_store = .table;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        try env.createUser(a, "users", "t@x.io", "longenough");
        const tok = try login(env, RequestArena.from(&arena), "users", "t@x.io", "longenough");

        var req = try bearerCtx(env, RequestArena.from(&arena), .DELETE, "users", tok, &.{});
        const res = try revokeAll(&req);
        try std.testing.expectEqual(@as(u16, 204), res.status);
        try std.testing.expectEqual(@as(usize, 2), res.cookies.len);

        var refresh_req = env.ctx(RequestArena.from(&arena), .POST, "", &[_]http.Param{.{ .key = "col", .value = "users" }});
        refresh_req.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{tok});
        const refresh_res = try api_auth.authRefresh(&refresh_req);
        try std.testing.expectEqual(@as(u16, 401), refresh_res.status);

        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        var st = try w.prepare("SELECT COUNT(*) FROM \"_sessions\" WHERE \"collectionRef\"='users';");
        defer st.finalize();
        try std.testing.expect(try st.step());
        try std.testing.expectEqual(@as(i64, 0), st.columnInt(0));
    }
}
