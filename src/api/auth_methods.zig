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
const http = @import("../http.zig");
const db = @import("../db.zig");
const collections = @import("../collections.zig");
const schema = @import("../schema.zig");
const events = @import("../events.zig");
const registry_mod = @import("../auth/registry.zig");
const method_mod = @import("../auth/method.zig");
const ApiError = @import("error.zig").ApiError;
const auth = @import("auth.zig");
const records = @import("../records.zig");

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
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.body, .{}) catch return "";
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
    const app = ctx.app orelse return (ApiError.internal()).toResponse(ctx.allocator);

    // 1. Load collection under a BRIEF reader. We do NOT hold any connection
    //    across the method call — each method acquires its own (a reader for
    //    read-only work, the writer only when it must persist), so OAuth can
    //    release the writer during its HTTP exchange and password verifies
    //    argon2 under a reader.
    const col_name = ctx.param("col") orelse return (ApiError.notFound()).toResponse(ctx.allocator);
    const col = blk: {
        var r = app.pool.acquireReader() catch return (ApiError.internal()).toResponse(ctx.allocator);
        defer app.pool.releaseReader(&r);
        break :blk (try collections.get(ctx.allocator, &r, col_name)) orelse
            return (ApiError.notFound()).toResponse(ctx.allocator);
    };
    if (col.type != .auth) return (ApiError.notFound()).toResponse(ctx.allocator);

    // 2. Method enablement check.
    const slug = ctx.param("method") orelse return (ApiError.notFound()).toResponse(ctx.allocator);
    if (!methodEnabled(col, slug)) return (ApiError.notFound()).toResponse(ctx.allocator);

    // 3. Resolve from registry.
    const reg_ptr = app.auth_methods orelse return (ApiError.notFound()).toResponse(ctx.allocator);
    const reg = @as(*const registry_mod.Registry, @ptrCast(@alignCast(reg_ptr)));
    const am = reg.get(slug) orelse return (ApiError.notFound()).toResponse(ctx.allocator);

    // 4. Rate-limit.
    const rl_opt = rateLimitOptFor(col, slug);
    switch (rl_opt) {
        .off => {}, // disabled
        .default, .custom => {
            // TODO(M3): honor custom RateLimitOpt max/window_s with a per-method limiter; currently falls back to the global limiter.
            // For .custom we fall back to the global limiter with the default scope;
            // a dedicated per-method limiter is a later refinement (noted in report).
            const ident = identityFromBody(ctx);
            const scope = try std.fmt.allocPrint(ctx.allocator, "auth:{s}", .{slug});
            if (try auth.rateLimited(ctx, scope, ident)) |resp| return resp;
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
                    return (ApiError{ .status = f.status, .message = f.message }).toResponse(ctx.allocator);
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
                    // Optional verification gate: refuse to mint a session for a record
                    // whose `verified` field is not true (when the collection requires it).
                    if (col.options.auth.require_verified) {
                        const rec = (try records.get(ctx.allocator, w, col, rid)) orelse
                            return (ApiError.notFound()).toResponse(ctx.allocator);
                        if (!auth.recordVerified(rec))
                            return (ApiError{ .status = 403, .message = "Email not verified." }).toResponse(ctx.allocator);
                    }
                    const issued = try auth.issueSession(ctx, w, col.name, rid, auth_tag);
                    var root: std.json.ObjectMap = .empty;
                    try root.put(ctx.allocator, "token", .{ .string = issued.token });
                    const cookies = try ctx.allocator.dupe(http.Cookie, &issued.cookies);
                    const body = try std.json.Stringify.valueAlloc(ctx.allocator, std.json.Value{ .object = root }, .{});
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
    var ctx_ok = env.ctx(a, .POST, "{\"identity\":\"u@x.io\",\"password\":\"longenough\"}", &params_ok);
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

test "auth-method dispatch: unknown method slug returns 404" {
    const api_auth = @import("auth.zig");

    var env = try api_auth.TestEnv.initAuth("users2");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

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
    var ctx_nope = env.ctx(a, .POST, "{}", &params_nope);
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
    var ctx_base = env.ctx(a, .POST, "{}", &params);
    const res = try complete(&ctx_base);
    try std.testing.expectEqual(@as(u16, 404), res.status);
}

test "auth-method dispatch: initiate returns 200 body for password" {
    const api_auth = @import("auth.zig");

    var env = try api_auth.TestEnv.initAuth("users4");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

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
    var ctx_init = env.ctx(a, .POST, "{}", &params);
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
    var ctx_bad = env.ctx(a, .POST, "{\"identity\":\"u@x.io\",\"password\":\"wrongpass\"}", &params);
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
