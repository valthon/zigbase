/// Auto-mounted auth-method dispatch handlers.
///
/// Two routes drive any enabled auth method for any auth collection:
///   POST /api/collections/:col/auth/:method/initiate
///   POST /api/collections/:col/auth/:method/complete
///
/// The `complete` handler mints a session via the M1 seam (issueSession) on
/// success and fires `onAuth` tagged by method slug (`.password`, `.magic_link`,
/// `.otp`, `.webauthn`, `.oauth2`, or `.custom` for unknown slugs). `initiate`
/// returns whatever the method produced (typically a challenge or 200 OK).
const std = @import("std");
const RequestArena = @import("../request_arena.zig").RequestArena;
const http = @import("../http.zig");
const db = @import("../db.zig");
const collections = @import("../collections.zig");
const schema = @import("../schema.zig");
const events = @import("../events.zig");
const registry_mod = @import("../auth/registry.zig");
const method_mod = @import("../auth/method.zig");
const ApiError = @import("error.zig").ApiError;
const codes = @import("../error_codes.zig");
const auth = @import("auth.zig");
const records = @import("../records.zig");
const ratelimit = @import("../ratelimit.zig");
const Ctx = @import("../ctx.zig").Ctx;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// True when the named slug is enabled on `col` (respects passwordEnabled
/// backward-compat rule and the methods.custom list).
fn methodEnabled(col: schema.Collection, slug: []const u8) bool {
    if (col.type != .auth) return false;
    if (std.mem.eql(u8, slug, "password")) return schema.passwordEnabled(col);
    const m = col.options.auth.methods;
    if (std.mem.eql(u8, slug, "magic_link")) return m.magic_link != null;
    if (std.mem.eql(u8, slug, "otp")) return m.otp != null;
    if (std.mem.eql(u8, slug, "webauthn")) return m.webauthn != null;
    if (std.mem.eql(u8, slug, "oauth2")) return col.options.auth.oauth2.enabled;
    for (m.custom) |cs| {
        if (std.mem.eql(u8, cs, slug)) return true;
    }
    return false;
}

/// Extract the `identity` or `email` field from the request body for rate-limit
/// keying. Returns "" when not parseable or field absent.
fn identityFromBody(ctx: *http.RequestCtx) []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator.a, ctx.body, .{}) catch return "";
    if (parsed.value != .object) return "";
    const obj = parsed.value.object;
    inline for (.{ "identity", "email" }) |key| {
        if (obj.get(key)) |v| {
            if (v == .string and v.string.len > 0) return v.string;
        }
    }
    return "";
}

/// Resolve the rate-limit opt for the named slug from the collection options.
fn rateLimitOptFor(col: schema.Collection, slug: []const u8) schema.RateLimitOpt {
    const m = col.options.auth.methods;
    if (std.mem.eql(u8, slug, "password")) {
        if (m.password) |pw| return pw.rate_limit;
    } else if (std.mem.eql(u8, slug, "magic_link")) {
        if (m.magic_link) |ml| return ml.rate_limit;
    } else if (std.mem.eql(u8, slug, "otp")) {
        if (m.otp) |otp| return otp.rate_limit;
    } else if (std.mem.eql(u8, slug, "webauthn")) {
        if (m.webauthn) |wa| return wa.rate_limit;
    }
    // Custom slugs: no typed opts yet; use default.
    return .default;
}

const DispatchPhase = enum { initiate, complete };

/// Shared dispatch logic for both initiate and complete.
fn dispatch(ctx: *http.RequestCtx, phase: DispatchPhase) anyerror!http.Response {
    const app = ctx.app orelse return (ApiError.internal()).toResponse(ctx.allocator.a);

    // 1. Load collection under a BRIEF reader. We do NOT hold any connection
    //    across the method call — each method acquires its own (a reader for
    //    read-only work, the writer only when it must persist), so OAuth can
    //    release the writer during its HTTP exchange and password verifies
    //    argon2 under a reader.
    const col_name = ctx.param("col") orelse return (ApiError.notFound()).toResponse(ctx.allocator.a);
    const col = blk: {
        var r = app.pool.acquireReader() catch return (ApiError.internal()).toResponse(ctx.allocator.a);
        defer app.pool.releaseReader(&r);
        break :blk (try collections.get(ctx.allocator.a, &r, col_name)) orelse
            return (ApiError.notFound()).toResponse(ctx.allocator.a);
    };
    if (col.type != .auth) return (ApiError.notFound()).toResponse(ctx.allocator.a);

    // 2. Method enablement check.
    const slug = ctx.param("method") orelse return (ApiError.notFound()).toResponse(ctx.allocator.a);
    if (!methodEnabled(col, slug)) return (ApiError.notFound()).toResponse(ctx.allocator.a);

    // 3. Resolve from registry.
    const reg_ptr = app.auth_methods orelse return (ApiError.notFound()).toResponse(ctx.allocator.a);
    const reg = @as(*const registry_mod.Registry, @ptrCast(@alignCast(reg_ptr)));
    const am = reg.get(slug) orelse return (ApiError.notFound()).toResponse(ctx.allocator.a);

    // 4. Rate-limit.
    const rl_opt = rateLimitOptFor(col, slug);
    switch (rl_opt) {
        .off => {}, // disabled for this method
        .default => {
            // Unconfigured method: keep the prior behavior — the global/default
            // limiter keyed by method slug (collection-agnostic, as before).
            const ident = identityFromBody(ctx);
            const scope = try std.fmt.allocPrint(ctx.allocator.a, "auth:{s}", .{slug});
            if (try auth.rateLimited(ctx, scope, ident)) |resp| return resp;
        },
        .custom => |c| {
            // Per-method limiter: a dedicated bucket scoped by collection + method
            // slug (so different methods/collections never share a budget), honoring
            // this method's configured max/window_s instead of the global default.
            const ident = identityFromBody(ctx);
            const scope = try std.fmt.allocPrint(ctx.allocator.a, "authm:{s}:{s}", .{ col.name, slug });
            if (try auth.rateLimitedCustom(ctx, scope, ident, c.max, c.window_s)) |resp| return resp;
        },
    }

    // 5. Build AuthCtx. No connection is bound — the method acquires its own
    //    via ac.writer()/ac.reader() for exactly as long as it needs it.
    var ac = method_mod.AuthCtx{
        .app = app,
        .ctx = ctx,
        .collection = col,
        .config = .null, // per-method config object — future milestone; .null is safe
    };

    switch (phase) {
        .initiate => {
            // 6a. Run initiate vtable.
            const result = try am.vtable.initiate(am.ctx, &ac);
            // 7a. Turn InitiateResult into http.Response.
            return http.Response{
                .status = result.status,
                .body = result.body orelse "{}",
            };
        },
        .complete => {
            // 6b. Run complete vtable.
            const resolution = try am.vtable.complete(am.ctx, &ac);
            // 7b. Map Resolution.
            switch (resolution) {
                .fail => |f| {
                    // f.status is chosen dynamically by whichever auth-method vtable produced
                    // this Resolution (password/otp/magic_link/webauthn/oauth2) and carries no
                    // code of its own — derive one from the status, same as route_types.zig's
                    // jsonError does for typed routes.
                    const derived = codes.forStatus(f.status);
                    // `internal` promises in the frozen registry that no detail is
                    // leaked, so a 5xx must NOT forward the method's own message —
                    // that text is written for operators, not for an anonymous caller.
                    // Log it (the operator still needs it) and answer generically.
                    if (derived == .internal) {
                        std.log.err("auth method failed with {d}: {s}", .{ f.status, f.message });
                        return ApiError.internal().toResponse(ctx.allocator.a);
                    }
                    return (ApiError{ .status = f.status, .code = codes.s(derived), .message = f.message }).toResponse(ctx.allocator.a);
                },
                .record => |rid| {
                    const auth_tag: events.AuthMethod = if (std.mem.eql(u8, slug, "password"))
                        .password
                    else if (std.mem.eql(u8, slug, "magic_link"))
                        .magic_link
                    else if (std.mem.eql(u8, slug, "oauth2"))
                        .oauth2
                    else if (std.mem.eql(u8, slug, "otp"))
                        .otp
                    else if (std.mem.eql(u8, slug, "webauthn"))
                        .webauthn
                    else
                        .custom;
                    // The method has already released its own connection by the
                    // time `complete` returned, so acquiring the writer here to
                    // mint the session cannot deadlock.
                    const w = app.pool.acquireWriter();
                    defer app.pool.releaseWriter();
                    // Fetch the record once: it feeds the verification gate, the
                    // beforeAuthSuccess hook, and session issuance (no redundant reads).
                    const rec = (try records.get(ctx.allocator.a, w, col, rid)) orelse
                        return (ApiError.notFound()).toResponse(ctx.allocator.a);
                    // Optional verification gate: refuse to mint a session for a record
                    // whose `verified` field is not true (when the collection requires it).
                    if (col.options.auth.require_verified and !auth.recordVerified(rec))
                        return ApiError.withCode(403, .email_not_verified, "Email not verified.").toResponse(ctx.allocator.a);

                    if (try @import("../auth/two_factor.zig").beginAuthentication(ctx, w, col, rid, auth_tag)) |pending|
                        return pending;

                    // Transactional login: the beforeAuthSuccess hook's side-writes commit
                    // atomically with session issuance; an aborting hook rolls everything
                    // back and blocks the session (fail closed).
                    try w.beginImmediate();
                    // Safety net for EVERY error-return after begin (fireBeforeAuthSuccess can
                    // propagate, issueSessionNoEmit, commit): roll back so a failed login never
                    // leaves an open transaction on the single shared writer (which would poison
                    // all subsequent writes). Value-returns below roll back explicitly; the
                    // double-rollback a later error would cause is a harmless no-op (no active txn).
                    errdefer w.rollback() catch {};
                    if (try auth.fireBeforeAuthSuccess(ctx, w, col.name, rid, auth_tag, rec)) |resp| {
                        w.rollback() catch {};
                        return resp;
                    }
                    const issued = auth.issueSessionNoEmit(ctx, w, col.name, rid) catch |e| {
                        w.rollback() catch {};
                        return e;
                    };
                    w.commit() catch |e| {
                        w.rollback() catch {};
                        return e;
                    };
                    // onAuth fires only AFTER a durable commit (session truly issued).
                    auth.emitAuth(ctx, col.name, rec, auth_tag);
                    var root: std.json.ObjectMap = .empty;
                    try root.put(ctx.allocator.a, "token", .{ .string = issued.token });
                    const cookies = try ctx.allocator.a.dupe(http.Cookie, &issued.cookies);
                    const body = try std.json.Stringify.valueAlloc(ctx.allocator.a, std.json.Value{ .object = root }, .{});
                    return http.Response{ .status = 200, .body = body, .cookies = cookies };
                },
            }
        },
    }
}

pub fn initiate(ctx: *http.RequestCtx) anyerror!http.Response {
    return dispatch(ctx, .initiate);
}

pub fn complete(ctx: *http.RequestCtx) anyerror!http.Response {
    return dispatch(ctx, .complete);
}

test "every primary method resolution enters the second-factor gate" {
    const env = try auth.TestEnv.initAuth("users");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users", "u@x.io", "longenough");
    const System = @import("two_factor.zig").Subsystem(.{ .enabled = true, .totp = true }, null);
    env.app.two_factor = @ptrCast(&System.runtime);
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        var col = (try collections.get(a, w, "users")).?;
        col.fields = &.{};
        col.options.auth.two_factor = .required;
        col.options.auth.methods = .{ .password = .{}, .otp = .{}, .magic_link = .{}, .webauthn = .{}, .custom = &.{"custom"} };
        col.options.auth.oauth2.enabled = true;
        _ = try collections.update(a, env.app.io, w, "users", col);
    }
    // Stub only primary proof validation; the actual registry dispatch, pending
    // creation, policy decision and lowest session guard remain production code.
    const Proof = struct {
        fn startProof(_: *anyopaque, _: *method_mod.AuthCtx) !method_mod.InitiateResult {
            return .{};
        }
        fn resolve(_: *anyopaque, ac: *method_mod.AuthCtx) !method_mod.Resolution {
            var r = try ac.reader();
            defer r.deinit();
            return .{ .record = (try ac.findByIdentity(&r.conn, "u@x.io")).? };
        }
        const vt = method_mod.AuthMethod.VTable{ .initiate = startProof, .complete = resolve };
    };
    var dummy: u8 = 0;
    for ([_][]const u8{ "password", "oauth2", "magic_link", "otp", "webauthn", "custom" }) |slug| {
        const methods = [_]method_mod.AuthMethod{.{ .slug = slug, .ctx = &dummy, .vtable = &Proof.vt }};
        var reg = registry_mod.Registry{ .methods = &methods };
        env.app.auth_methods = @ptrCast(&reg);
        const params = [_]http.Param{ .{ .key = "col", .value = "users" }, .{ .key = "method", .value = slug } };
        var ctx = env.ctx(RequestArena.from(&arena), .POST, "{}", &params);
        const response = try complete(&ctx);
        try std.testing.expectEqual(@as(u16, 200), response.status);
        try std.testing.expectEqual(@as(usize, 0), response.cookies.len);
        try std.testing.expect(std.mem.indexOf(u8, response.body, "enrollment_required") != null);
        try std.testing.expect(std.mem.indexOf(u8, response.body, "\"token\"") == null);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "auth-method dispatch: password complete succeeds + 2 cookies + onAuth fires" {
    const api_auth = @import("auth.zig");

    var env = try api_auth.TestEnv.initAuth("users");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try env.createUser(a, "users", "u@x.io", "longenough");

    // Build registry with the PasswordMethod.
    const types = comptime registry_mod.assembleTypes(.{});
    var insts: registry_mod.Instances(types) = undefined;
    var views: [types.len]method_mod.AuthMethod = undefined;
    var reg = try registry_mod.build(types, &insts, &views, std.testing.allocator, std.testing.io, .{});
    defer registry_mod.deinit(types, &insts);

    env.app.auth_methods = @ptrCast(&reg);

    // Install onAuth counter.
    const Counter = struct {
        var seen: usize = 0;
        var last_method: events.AuthMethod = .oauth2;
        fn onAuth(ev: *events.AuthEvent) void {
            seen += 1;
            last_method = ev.method;
        }
    };
    Counter.seen = 0;
    var disp = events.Dispatch{ .on_auth = Counter.onAuth };
    env.app.dispatch = &disp;

    const params_ok = [_]http.Param{
        .{ .key = "col", .value = "users" },
        .{ .key = "method", .value = "password" },
    };
    var ctx_ok = env.ctx(RequestArena.from(&arena), .POST, "{\"identity\":\"u@x.io\",\"password\":\"longenough\"}", &params_ok);
    const res = try complete(&ctx_ok);

    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"token\":\"") != null);
    try std.testing.expectEqual(@as(usize, 2), res.cookies.len);
    var saw_auth = false;
    var saw_csrf = false;
    for (res.cookies) |c| {
        if (std.mem.eql(u8, c.name, "zb_auth")) saw_auth = true;
        if (std.mem.eql(u8, c.name, "zb_csrf")) saw_csrf = true;
    }
    try std.testing.expect(saw_auth and saw_csrf);
    try std.testing.expectEqual(@as(usize, 1), Counter.seen);
    try std.testing.expectEqual(events.AuthMethod.password, Counter.last_method);
}

// ---------------------------------------------------------------------------
// #80 — beforeAuthSuccess: writable, transactional, abortable
// ---------------------------------------------------------------------------

/// Create a base `posts` collection so a beforeAuthSuccess hook has somewhere to
/// write (the "claim anonymous records" use case writes through ctx.records()).
fn createPostsCollection(env: *@import("auth.zig").TestEnv, a: std.mem.Allocator) !void {
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    _ = try collections.create(a, std.testing.io, w, .{
        .id = "",
        .name = "posts",
        .type = .base,
        .fields = &[_]schema.Field{.{ .id = "t1", .name = "title", .options = .{ .text = .{} } }},
        .listRule = null,
        .viewRule = null,
        .createRule = null,
        .updateRule = null,
        .deleteRule = null,
    });
}

/// COUNT(*) of posts rows on a fresh writer (sees committed rows only).
fn countPosts(env: *@import("auth.zig").TestEnv) !i64 {
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    var st = try w.prepare("SELECT COUNT(*) FROM \"posts\";");
    defer st.finalize();
    _ = try st.step();
    return st.columnInt(0);
}

test "#80 beforeAuthSuccess fires on complete with a writable, committing ctx" {
    const api_auth = @import("auth.zig");
    var env = try api_auth.TestEnv.initAuth("users80a");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users80a", "u@x.io", "longenough");
    try createPostsCollection(env, a);

    const types = comptime registry_mod.assembleTypes(.{});
    var insts: registry_mod.Instances(types) = undefined;
    var views: [types.len]method_mod.AuthMethod = undefined;
    var reg = try registry_mod.build(types, &insts, &views, std.testing.allocator, std.testing.io, .{});
    defer registry_mod.deinit(types, &insts);
    env.app.auth_methods = @ptrCast(&reg);

    // Hook writes a marker post through the bound (transactional) connection and records
    // what it saw. A clean return commits with the session.
    const Hook = struct {
        var seen: usize = 0;
        var method: events.AuthMethod = .custom;
        var rid: []const u8 = "";
        fn write(ctx: *Ctx, ev: *events.AuthSuccessEvent) anyerror!void {
            seen += 1;
            method = ev.method;
            rid = ev.record_id;
            var o: std.json.ObjectMap = .empty;
            try o.put(ctx.arena.a, "title", .{ .string = "claimed" });
            _ = try ctx.records().create("posts", .{ .object = o });
        }
    };
    Hook.seen = 0;
    var disp = events.Dispatch{ .before_auth_success = Hook.write };
    env.app.dispatch = &disp;

    const params = [_]http.Param{
        .{ .key = "col", .value = "users80a" },
        .{ .key = "method", .value = "password" },
    };
    var ctx = env.ctx(RequestArena.from(&arena), .POST, "{\"identity\":\"u@x.io\",\"password\":\"longenough\"}", &params);
    const res = try complete(&ctx);

    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqual(@as(usize, 1), Hook.seen);
    try std.testing.expectEqual(events.AuthMethod.password, Hook.method);
    try std.testing.expect(Hook.rid.len > 0);
    try std.testing.expectEqual(@as(usize, 2), res.cookies.len); // session issued
    try std.testing.expectEqual(@as(i64, 1), try countPosts(env)); // hook's write committed
}

test "#80 aborting beforeAuthSuccess blocks the session AND rolls back its side-writes" {
    const api_auth = @import("auth.zig");
    var env = try api_auth.TestEnv.initAuth("users80b");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try env.createUser(a, "users80b", "u@x.io", "longenough");
    try createPostsCollection(env, a);

    const types = comptime registry_mod.assembleTypes(.{});
    var insts: registry_mod.Instances(types) = undefined;
    var views: [types.len]method_mod.AuthMethod = undefined;
    var reg = try registry_mod.build(types, &insts, &views, std.testing.allocator, std.testing.io, .{});
    defer registry_mod.deinit(types, &insts);
    env.app.auth_methods = @ptrCast(&reg);

    // Hook writes a marker post, THEN vetoes the login via ctx.fail(403). The write must
    // roll back (atomic with the login) and no session may be issued.
    const Hook = struct {
        fn writeThenAbort(ctx: *Ctx, ev: *events.AuthSuccessEvent) anyerror!void {
            _ = ev;
            var o: std.json.ObjectMap = .empty;
            try o.put(ctx.arena.a, "title", .{ .string = "should-roll-back" });
            _ = try ctx.records().create("posts", .{ .object = o });
            return ctx.fail(403, "not allowed");
        }
    };
    var disp = events.Dispatch{ .before_auth_success = Hook.writeThenAbort };
    env.app.dispatch = &disp;

    const params = [_]http.Param{
        .{ .key = "col", .value = "users80b" },
        .{ .key = "method", .value = "password" },
    };
    var ctx = env.ctx(RequestArena.from(&arena), .POST, "{\"identity\":\"u@x.io\",\"password\":\"longenough\"}", &params);
    const res = try complete(&ctx);

    // Fail closed: the hook's chosen status, no session cookies.
    try std.testing.expectEqual(@as(u16, 403), res.status);
    try std.testing.expectEqual(@as(usize, 0), res.cookies.len);
    // Atomicity: the hook's side-write rolled back with the blocked login.
    try std.testing.expectEqual(@as(i64, 0), try countPosts(env));
}

test "auth-method dispatch: unknown method slug returns 404" {
    const api_auth = @import("auth.zig");

    var env = try api_auth.TestEnv.initAuth("users2");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const types = comptime registry_mod.assembleTypes(.{});
    var insts: registry_mod.Instances(types) = undefined;
    var views: [types.len]method_mod.AuthMethod = undefined;
    var reg = try registry_mod.build(types, &insts, &views, std.testing.allocator, std.testing.io, .{});
    defer registry_mod.deinit(types, &insts);
    env.app.auth_methods = @ptrCast(&reg);

    const params_nope = [_]http.Param{
        .{ .key = "col", .value = "users2" },
        .{ .key = "method", .value = "nope" },
    };
    var ctx_nope = env.ctx(RequestArena.from(&arena), .POST, "{}", &params_nope);
    const res = try complete(&ctx_nope);
    try std.testing.expectEqual(@as(u16, 404), res.status);
}

test "auth-method dispatch: non-auth collection returns 404" {
    const api_auth = @import("auth.zig");
    const col_mod = @import("../collections.zig");
    const migrations = @import("../migrations.zig");

    var env = try api_auth.TestEnv.initAuth("users3");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Create a base (non-auth) collection.
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        _ = try col_mod.create(a, std.testing.io, w, .{
            .id = "",
            .name = "posts",
            .type = .base,
            .fields = &[_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }},
            .listRule = null,
            .viewRule = null,
            .createRule = null,
            .updateRule = null,
            .deleteRule = null,
        });
        _ = migrations;
    }

    const types = comptime registry_mod.assembleTypes(.{});
    var insts: registry_mod.Instances(types) = undefined;
    var views: [types.len]method_mod.AuthMethod = undefined;
    var reg = try registry_mod.build(types, &insts, &views, std.testing.allocator, std.testing.io, .{});
    defer registry_mod.deinit(types, &insts);
    env.app.auth_methods = @ptrCast(&reg);

    const params = [_]http.Param{
        .{ .key = "col", .value = "posts" },
        .{ .key = "method", .value = "password" },
    };
    var ctx_base = env.ctx(RequestArena.from(&arena), .POST, "{}", &params);
    const res = try complete(&ctx_base);
    try std.testing.expectEqual(@as(u16, 404), res.status);
}

test "auth-method dispatch: initiate returns 200 body for password" {
    const api_auth = @import("auth.zig");

    var env = try api_auth.TestEnv.initAuth("users4");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const types = comptime registry_mod.assembleTypes(.{});
    var insts: registry_mod.Instances(types) = undefined;
    var views: [types.len]method_mod.AuthMethod = undefined;
    var reg = try registry_mod.build(types, &insts, &views, std.testing.allocator, std.testing.io, .{});
    defer registry_mod.deinit(types, &insts);
    env.app.auth_methods = @ptrCast(&reg);

    const params = [_]http.Param{
        .{ .key = "col", .value = "users4" },
        .{ .key = "method", .value = "password" },
    };
    var ctx_init = env.ctx(RequestArena.from(&arena), .POST, "{}", &params);
    const res = try initiate(&ctx_init);
    try std.testing.expectEqual(@as(u16, 200), res.status);
}

test "auth-method dispatch: wrong password returns 400" {
    const api_auth = @import("auth.zig");

    var env = try api_auth.TestEnv.initAuth("users5");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try env.createUser(a, "users5", "u@x.io", "longenough");

    const types = comptime registry_mod.assembleTypes(.{});
    var insts: registry_mod.Instances(types) = undefined;
    var views: [types.len]method_mod.AuthMethod = undefined;
    var reg = try registry_mod.build(types, &insts, &views, std.testing.allocator, std.testing.io, .{});
    defer registry_mod.deinit(types, &insts);
    env.app.auth_methods = @ptrCast(&reg);

    const params = [_]http.Param{
        .{ .key = "col", .value = "users5" },
        .{ .key = "method", .value = "password" },
    };
    var ctx_bad = env.ctx(RequestArena.from(&arena), .POST, "{\"identity\":\"u@x.io\",\"password\":\"wrongpass\"}", &params);
    const res = try complete(&ctx_bad);
    try std.testing.expectEqual(@as(u16, 400), res.status);
}

test "methodEnabled: backward-compat and explicit opts" {
    const base_col = schema.Collection{
        .id = "c1",
        .name = "posts",
        .type = .base,
        .fields = &.{},
    };
    try std.testing.expect(!methodEnabled(base_col, "password"));

    const auth_default = schema.Collection{
        .id = "c2",
        .name = "users",
        .type = .auth,
        .fields = &.{},
    };
    try std.testing.expect(methodEnabled(auth_default, "password"));
    try std.testing.expect(!methodEnabled(auth_default, "nope"));

    const auth_ml = schema.Collection{
        .id = "c3",
        .name = "users",
        .type = .auth,
        .fields = &.{},
        .options = .{ .auth = .{ .methods = .{ .magic_link = .{} } } },
    };
    // When magic_link is explicit and password is null, passwordEnabled returns false.
    try std.testing.expect(!methodEnabled(auth_ml, "password"));
    try std.testing.expect(methodEnabled(auth_ml, "magic_link"));

    const auth_custom = schema.Collection{
        .id = "c4",
        .name = "users",
        .type = .auth,
        .fields = &.{},
        .options = .{ .auth = .{ .methods = .{ .custom = &.{"mymethod"} } } },
    };
    try std.testing.expect(methodEnabled(auth_custom, "mymethod"));
    try std.testing.expect(!methodEnabled(auth_custom, "other"));

    const auth_oauth2_enabled = schema.Collection{
        .id = "c5",
        .name = "users",
        .type = .auth,
        .fields = &.{},
        .options = .{ .auth = .{ .oauth2 = .{ .enabled = true } } },
    };
    try std.testing.expect(methodEnabled(auth_oauth2_enabled, "oauth2"));

    const auth_oauth2_disabled = schema.Collection{
        .id = "c6",
        .name = "users",
        .type = .auth,
        .fields = &.{},
        .options = .{ .auth = .{ .oauth2 = .{ .enabled = false } } },
    };
    try std.testing.expect(!methodEnabled(auth_oauth2_disabled, "oauth2"));
}

// ---------------------------------------------------------------------------
// Per-method rate limiting (M3): honor a method's custom RateLimitOpt
// ---------------------------------------------------------------------------

/// Create an auth collection whose `password` method carries a custom rate limit.
/// The limit is persisted in the collection options and re-read by dispatch.
fn createAuthColWithPwLimit(
    env: *@import("auth.zig").TestEnv,
    a: std.mem.Allocator,
    name: []const u8,
    max: u32,
    window_s: i64,
) !void {
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
        .options = .{ .auth = .{ .methods = .{
            .password = .{ .rate_limit = .{ .custom = .{ .max = max, .window_s = window_s } } },
        } } },
    });
}

/// Build a registry with the default (PasswordMethod) types and bind it to env.app.
/// The caller keeps the returned `insts` alive (the Registry view points into it) and
/// must call `registry_mod.deinit(types, insts)`.
fn bindDefaultRegistry(
    env: *@import("auth.zig").TestEnv,
    comptime types: []const type,
    insts: *registry_mod.Instances(types),
    views: *[types.len]method_mod.AuthMethod,
    reg: *registry_mod.Registry,
) !void {
    reg.* = try registry_mod.build(types, insts, views, std.testing.allocator, std.testing.io, .{});
    env.app.auth_methods = @ptrCast(reg);
}

test "per-method rate limit: custom max rejects after the budget within the window" {
    const api_auth = @import("auth.zig");
    var env = try api_auth.TestEnv.initAuth("rl_users"); // base default collection (unused here)
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A long window so all attempts land in one bucket regardless of wall clock.
    try createAuthColWithPwLimit(env, a, "rl_strict", 2, 3600);

    const types = comptime registry_mod.assembleTypes(.{});
    var insts: registry_mod.Instances(types) = undefined;
    var views: [types.len]method_mod.AuthMethod = undefined;
    var reg: registry_mod.Registry = undefined;
    try bindDefaultRegistry(env, types, &insts, &views, &reg);
    defer registry_mod.deinit(types, &insts);

    // Wire a shared limiter store (global default off: max=0). Per-method limit must
    // still apply against this store.
    var rl = ratelimit.RateLimiter.init(std.testing.allocator, 0, 60);
    defer rl.deinit();
    env.app.rate_limiter = &rl;

    const params = [_]http.Param{
        .{ .key = "col", .value = "rl_strict" },
        .{ .key = "method", .value = "password" },
    };
    // No such user => method returns 400; the rate-limit gate runs BEFORE the method.
    const body = "{\"identity\":\"nobody@x.io\",\"password\":\"whatever123\"}";

    var c1 = env.ctx(RequestArena.from(&arena), .POST, body, &params);
    try std.testing.expectEqual(@as(u16, 400), (try complete(&c1)).status);
    var c2 = env.ctx(RequestArena.from(&arena), .POST, body, &params);
    try std.testing.expectEqual(@as(u16, 400), (try complete(&c2)).status);
    // 3rd attempt within the window exceeds max=2 => 429.
    var c3 = env.ctx(RequestArena.from(&arena), .POST, body, &params);
    try std.testing.expectEqual(@as(u16, 429), (try complete(&c3)).status);
}

test "per-method rate limit: different collections do not share a bucket" {
    const api_auth = @import("auth.zig");
    var env = try api_auth.TestEnv.initAuth("rl_users2");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try createAuthColWithPwLimit(env, a, "rl_a", 1, 3600);
    try createAuthColWithPwLimit(env, a, "rl_b", 1, 3600);

    const types = comptime registry_mod.assembleTypes(.{});
    var insts: registry_mod.Instances(types) = undefined;
    var views: [types.len]method_mod.AuthMethod = undefined;
    var reg: registry_mod.Registry = undefined;
    try bindDefaultRegistry(env, types, &insts, &views, &reg);
    defer registry_mod.deinit(types, &insts);

    var rl = ratelimit.RateLimiter.init(std.testing.allocator, 0, 60);
    defer rl.deinit();
    env.app.rate_limiter = &rl;

    const body = "{\"identity\":\"nobody@x.io\",\"password\":\"whatever123\"}";
    const params_a = [_]http.Param{
        .{ .key = "col", .value = "rl_a" },
        .{ .key = "method", .value = "password" },
    };
    const params_b = [_]http.Param{
        .{ .key = "col", .value = "rl_b" },
        .{ .key = "method", .value = "password" },
    };

    // Exhaust collection A's budget (max=1): 1st OK-ish (400), 2nd => 429.
    var a1 = env.ctx(RequestArena.from(&arena), .POST, body, &params_a);
    try std.testing.expectEqual(@as(u16, 400), (try complete(&a1)).status);
    var a2 = env.ctx(RequestArena.from(&arena), .POST, body, &params_a);
    try std.testing.expectEqual(@as(u16, 429), (try complete(&a2)).status);

    // Collection B has its own bucket: its first attempt must NOT be rate limited.
    var b1 = env.ctx(RequestArena.from(&arena), .POST, body, &params_b);
    try std.testing.expectEqual(@as(u16, 400), (try complete(&b1)).status);
}

test "unconfigured method uses the global/default limiter (no regression)" {
    const api_auth = @import("auth.zig");
    // Default users collection => password rate_limit is .default.
    var env = try api_auth.TestEnv.initAuth("rl_default");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const types = comptime registry_mod.assembleTypes(.{});
    var insts: registry_mod.Instances(types) = undefined;
    var views: [types.len]method_mod.AuthMethod = undefined;
    var reg: registry_mod.Registry = undefined;
    try bindDefaultRegistry(env, types, &insts, &views, &reg);
    defer registry_mod.deinit(types, &insts);

    // Global limiter active (max=2). A .default method must be limited by it.
    var rl = ratelimit.RateLimiter.init(std.testing.allocator, 2, 3600);
    defer rl.deinit();
    env.app.rate_limiter = &rl;

    const params = [_]http.Param{
        .{ .key = "col", .value = "rl_default" },
        .{ .key = "method", .value = "password" },
    };
    const body = "{\"identity\":\"nobody@x.io\",\"password\":\"whatever123\"}";

    var d1 = env.ctx(RequestArena.from(&arena), .POST, body, &params);
    try std.testing.expectEqual(@as(u16, 400), (try complete(&d1)).status);
    var d2 = env.ctx(RequestArena.from(&arena), .POST, body, &params);
    try std.testing.expectEqual(@as(u16, 400), (try complete(&d2)).status);
    // 3rd exceeds the GLOBAL max=2 (proves the default path still routes through it).
    var d3 = env.ctx(RequestArena.from(&arena), .POST, body, &params);
    try std.testing.expectEqual(@as(u16, 429), (try complete(&d3)).status);
}
