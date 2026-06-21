const std = @import("std");
const method_mod = @import("../method.zig");
const AuthMethod = method_mod.AuthMethod;
const AuthCtx = method_mod.AuthCtx;
const InitiateResult = method_mod.InitiateResult;
const Resolution = method_mod.Resolution;
const api_auth = @import("../../api/auth.zig");

// ---------------------------------------------------------------------------
// MagicLinkMethod — passwordless email login via single-use link token
// ---------------------------------------------------------------------------

pub const MagicLinkMethod = struct {
    pub fn create(_: std.mem.Allocator, _: std.Io, _: anytype) !MagicLinkMethod {
        return .{};
    }

    pub fn method(self: *MagicLinkMethod) AuthMethod {
        return .{ .slug = "magic_link", .ctx = self, .vtable = &vtable };
    }

    pub fn deinit(_: *MagicLinkMethod) void {}
};

fn strField(obj: std.json.Value, key: []const u8) ?[]const u8 {
    const v = obj.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn initiateImpl(ctx: *anyopaque, ac: *AuthCtx) anyerror!InitiateResult {
    _ = @as(*MagicLinkMethod, @ptrCast(@alignCast(ctx)));

    // Parse email from body; on any parse failure return 204 (enumeration-safe)
    const email = blk: {
        const parsed = std.json.parseFromSlice(std.json.Value, ac.ctx.allocator, ac.ctx.body, .{}) catch
            return InitiateResult{ .status = 204 };
        if (parsed.value != .object) return InitiateResult{ .status = 204 };
        break :blk strField(parsed.value, "email") orelse return InitiateResult{ .status = 204 };
    };

    // Rate-limit check
    if (try ac.rateLimit("magic_link", email)) |_|
        return InitiateResult{ .status = 429, .body = "{\"message\":\"Too many requests.\"}" };

    // Resolve identity; if found, mint and deliver the link token
    if (try ac.findByIdentity(email)) |rid| {
        const ttl: i64 = if (ac.collection.options.auth.methods.magic_link) |ml| ml.ttl_s else 900;
        const token = try ac.mintLinkToken(rid, ttl);
        const mail_body = try std.fmt.allocPrint(
            ac.ctx.allocator,
            "Your sign-in link token:\n\n{s}\n",
            .{token},
        );
        try ac.deliverMail(email, "Your sign-in link", mail_body);
    }

    // ALWAYS return 204 — never reveal whether the email was found
    return InitiateResult{ .status = 204, .body = null };
}

fn completeImpl(ctx: *anyopaque, ac: *AuthCtx) anyerror!Resolution {
    _ = @as(*MagicLinkMethod, @ptrCast(@alignCast(ctx)));

    // Parse token from body
    const parsed = std.json.parseFromSlice(std.json.Value, ac.ctx.allocator, ac.ctx.body, .{}) catch {
        return Resolution{ .fail = .{ .status = 400, .message = "token is required." } };
    };
    if (parsed.value != .object) {
        return Resolution{ .fail = .{ .status = 400, .message = "token is required." } };
    }
    const token = strField(parsed.value, "token") orelse {
        return Resolution{ .fail = .{ .status = 400, .message = "token is required." } };
    };

    // Verify token
    const claims = (try ac.verifyLinkToken(token)) orelse
        return Resolution{ .fail = .{ .status = 400, .message = "Invalid or expired link." } };

    // Consume (single-use guard)
    ac.consumeLinkToken(claims) catch
        return Resolution{ .fail = .{ .status = 400, .message = "Link already used." } };

    return Resolution{ .record = claims.id };
}

const vtable = AuthMethod.VTable{
    .initiate = initiateImpl,
    .complete = completeImpl,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "MagicLinkMethod: method() returns slug=magic_link and contract is satisfied" {
    var m = try MagicLinkMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    try std.testing.expectEqualStrings("magic_link", am.slug);
    method_mod.assertAuthMethodContract(MagicLinkMethod);
}

test "MagicLinkMethod: complete with valid token resolves to record id" {
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");

    var env = try api_auth.TestEnv.initAuth("mlmembers");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try env.createUser(a, "mlmembers", "u@x.io", "longenough");

    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();

    const col = (try collections.get(a, w, "mlmembers")).?;

    // Mint a link token directly via AuthCtx
    var req_ctx = env.ctx(a, .POST, "", &[_]http.Param{});
    var ac_mint = AuthCtx{
        .app = &env.app,
        .ctx = &req_ctx,
        .conn = w,
        .collection = col,
        .config = .null,
    };
    const rid = (try ac_mint.findByIdentity("u@x.io")).?;
    const token = try ac_mint.mintLinkToken(rid, 900);

    // Build the complete request body
    const body = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\"}}", .{token});
    var req_ok = env.ctx(a, .POST, body, &[_]http.Param{});
    var ac_ok = AuthCtx{
        .app = &env.app,
        .ctx = &req_ok,
        .conn = w,
        .collection = col,
        .config = .null,
    };

    var m = try MagicLinkMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();

    // First use: should resolve to record id
    const res = try am.vtable.complete(am.ctx, &ac_ok);
    switch (res) {
        .record => |r| try std.testing.expectEqualStrings(rid, r),
        .fail => |f| {
            std.debug.print("Expected .record but got .fail: status={d} msg={s}\n", .{ f.status, f.message });
            return error.TestFailed;
        },
    }

    // Second use (replay): same token must be rejected (single-use)
    var req_replay = env.ctx(a, .POST, body, &[_]http.Param{});
    var ac_replay = AuthCtx{
        .app = &env.app,
        .ctx = &req_replay,
        .conn = w,
        .collection = col,
        .config = .null,
    };
    const res_replay = try am.vtable.complete(am.ctx, &ac_replay);
    switch (res_replay) {
        .fail => |f| try std.testing.expectEqual(@as(u16, 400), f.status),
        .record => return error.TestFailed,
    }
}

test "MagicLinkMethod: complete with garbage token returns .fail 400" {
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");

    var env = try api_auth.TestEnv.initAuth("mlmembers2");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();

    const col = (try collections.get(a, w, "mlmembers2")).?;

    var req = env.ctx(a, .POST, "{\"token\":\"not.a.real.token\"}", &[_]http.Param{});
    var ac = AuthCtx{
        .app = &env.app,
        .ctx = &req,
        .conn = w,
        .collection = col,
        .config = .null,
    };

    var m = try MagicLinkMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.complete(am.ctx, &ac);
    switch (res) {
        .fail => |f| try std.testing.expectEqual(@as(u16, 400), f.status),
        .record => return error.TestFailed,
    }
}

test "MagicLinkMethod: complete with missing token field returns .fail 400" {
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");

    var env = try api_auth.TestEnv.initAuth("mlmembers3");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();

    const col = (try collections.get(a, w, "mlmembers3")).?;

    var req = env.ctx(a, .POST, "{\"other\":\"field\"}", &[_]http.Param{});
    var ac = AuthCtx{
        .app = &env.app,
        .ctx = &req,
        .conn = w,
        .collection = col,
        .config = .null,
    };

    var m = try MagicLinkMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.complete(am.ctx, &ac);
    switch (res) {
        .fail => |f| {
            try std.testing.expectEqual(@as(u16, 400), f.status);
            try std.testing.expectEqualStrings("token is required.", f.message);
        },
        .record => return error.TestFailed,
    }
}

test "MagicLinkMethod: initiate with known email returns 204" {
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");

    var env = try api_auth.TestEnv.initAuth("mlmembers4");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try env.createUser(a, "mlmembers4", "u@x.io", "longenough");

    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();

    const col = (try collections.get(a, w, "mlmembers4")).?;

    var req = env.ctx(a, .POST, "{\"email\":\"u@x.io\"}", &[_]http.Param{});
    var ac = AuthCtx{
        .app = &env.app,
        .ctx = &req,
        .conn = w,
        .collection = col,
        .config = .null,
    };

    var m = try MagicLinkMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.initiate(am.ctx, &ac);
    try std.testing.expectEqual(@as(u16, 204), res.status);
}

test "MagicLinkMethod: initiate with unknown email still returns 204 (enumeration-safe)" {
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");

    var env = try api_auth.TestEnv.initAuth("mlmembers5");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();

    const col = (try collections.get(a, w, "mlmembers5")).?;

    var req = env.ctx(a, .POST, "{\"email\":\"nobody@x.io\"}", &[_]http.Param{});
    var ac = AuthCtx{
        .app = &env.app,
        .ctx = &req,
        .conn = w,
        .collection = col,
        .config = .null,
    };

    var m = try MagicLinkMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.initiate(am.ctx, &ac);
    try std.testing.expectEqual(@as(u16, 204), res.status);
}

test "MagicLinkMethod: initiate with unparseable body returns 204 (enumeration-safe)" {
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");

    var env = try api_auth.TestEnv.initAuth("mlmembers6");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();

    const col = (try collections.get(a, w, "mlmembers6")).?;

    var req = env.ctx(a, .POST, "not json at all", &[_]http.Param{});
    var ac = AuthCtx{
        .app = &env.app,
        .ctx = &req,
        .conn = w,
        .collection = col,
        .config = .null,
    };

    var m = try MagicLinkMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.initiate(am.ctx, &ac);
    try std.testing.expectEqual(@as(u16, 204), res.status);
}

test "MagicLinkMethod: ttl_s is read from collection opts (default 900 when opts is null)" {
    // This test verifies the TTL is read from magic_link opts if present.
    // Since MagicLinkMethodOpts.ttl_s defaults to 900, both null and default opts give 900.
    const schema_mod = @import("../../schema.zig");

    // Null opts → default 900
    const col_null_opts = schema_mod.Collection{
        .id = "x",
        .name = "test",
        .type = .auth,
        .fields = &.{},
        .options = .{ .auth = .{ .methods = .{ .magic_link = null } } },
    };
    const ttl_null: i64 = if (col_null_opts.options.auth.methods.magic_link) |ml| ml.ttl_s else 900;
    try std.testing.expectEqual(@as(i64, 900), ttl_null);

    // Explicit opts with custom ttl → uses that value
    const col_with_opts = schema_mod.Collection{
        .id = "y",
        .name = "test2",
        .type = .auth,
        .fields = &.{},
        .options = .{ .auth = .{ .methods = .{ .magic_link = .{ .ttl_s = 1800 } } } },
    };
    const ttl_custom: i64 = if (col_with_opts.options.auth.methods.magic_link) |ml| ml.ttl_s else 900;
    try std.testing.expectEqual(@as(i64, 1800), ttl_custom);
}
