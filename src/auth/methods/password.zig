const std = @import("std");
const method_mod = @import("../method.zig");
const AuthMethod = method_mod.AuthMethod;
const AuthCtx = method_mod.AuthCtx;
const InitiateResult = method_mod.InitiateResult;
const Resolution = method_mod.Resolution;
const api_auth = @import("../../api/auth.zig");
const crypto = @import("../../crypto.zig");

// ---------------------------------------------------------------------------
// PasswordMethod — stateless; verifies identity+password from the request body
// ---------------------------------------------------------------------------

pub const PasswordMethod = struct {
    pub fn create(_: std.mem.Allocator, _: std.Io, _: anytype) !PasswordMethod {
        return .{};
    }

    pub fn method(self: *PasswordMethod) AuthMethod {
        return .{ .slug = "password", .ctx = self, .vtable = &vtable };
    }

    pub fn deinit(_: *PasswordMethod) void {}
};

fn strField(obj: std.json.Value, key: []const u8) ?[]const u8 {
    const v = obj.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn initiateImpl(ctx: *anyopaque, ac: *AuthCtx) anyerror!InitiateResult {
    _ = @as(*PasswordMethod, @ptrCast(@alignCast(ctx)));
    _ = ac;
    return InitiateResult{};
}

fn completeImpl(ctx: *anyopaque, ac: *AuthCtx) anyerror!Resolution {
    _ = @as(*PasswordMethod, @ptrCast(@alignCast(ctx)));

    // Parse JSON body
    const parsed = std.json.parseFromSlice(std.json.Value, ac.ctx.allocator, ac.ctx.body, .{}) catch {
        return Resolution{ .fail = .{ .status = 400, .message = "identity and password are required." } };
    };
    if (parsed.value != .object) {
        return Resolution{ .fail = .{ .status = 400, .message = "identity and password are required." } };
    }
    const body = parsed.value;

    const identity = strField(body, "identity") orelse {
        return Resolution{ .fail = .{ .status = 400, .message = "identity and password are required." } };
    };
    const password = strField(body, "password") orelse {
        return Resolution{ .fail = .{ .status = 400, .message = "identity and password are required." } };
    };

    // Password verification is entirely read-only (identity lookup + hash fetch +
    // argon2 verify), so it runs under a pooled READER — argon2 never blocks writes.
    var r = try ac.reader();
    defer r.deinit();

    // Lookup identity
    const rid = (try ac.findByIdentity(&r.conn, identity)) orelse {
        crypto.dummyVerify(ac.app.io, ac.ctx.allocator);
        return Resolution{ .fail = .{ .status = 400, .message = "Invalid credentials." } };
    };

    // Fetch the password hash
    const phc = (try api_auth.passwordHashFor(ac.ctx.allocator, &r.conn, ac.collection.name, rid)) orelse {
        crypto.dummyVerify(ac.app.io, ac.ctx.allocator);
        return Resolution{ .fail = .{ .status = 400, .message = "Invalid credentials." } };
    };

    // Verify password
    if (!crypto.verifyPassword(ac.app.io, ac.ctx.allocator, phc, password)) {
        return Resolution{ .fail = .{ .status = 400, .message = "Invalid credentials." } };
    }

    return Resolution{ .record = rid };
}

const vtable = AuthMethod.VTable{
    .initiate = initiateImpl,
    .complete = completeImpl,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "PasswordMethod: correct password resolves to record id, wrong password is .fail 400" {
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");

    var env = try api_auth.TestEnv.initAuth("members");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try env.createUser(a, "members", "u@x.io", "longenough");

    // Load the collection under a brief writer that is RELEASED before any
    // method call (the method acquires its own reader).
    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "members")).?;
    };

    // --- correct password ---
    var req_ok = env.ctx(a, .POST, "{\"identity\":\"u@x.io\",\"password\":\"longenough\"}", &[_]http.Param{});
    var ac_ok = AuthCtx{
        .app = &env.app,
        .ctx = &req_ok,
        .collection = col,
        .config = .null,
    };

    var m = try PasswordMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.complete(am.ctx, &ac_ok);
    switch (res) {
        .record => |rid| try std.testing.expect(rid.len > 0),
        .fail => |f| {
            std.debug.print("Expected .record but got .fail: status={d} msg={s}\n", .{ f.status, f.message });
            return error.TestFailed;
        },
    }

    // --- wrong password ---
    var req_bad = env.ctx(a, .POST, "{\"identity\":\"u@x.io\",\"password\":\"wrongwrong\"}", &[_]http.Param{});
    var ac_bad = AuthCtx{
        .app = &env.app,
        .ctx = &req_bad,
        .collection = col,
        .config = .null,
    };

    const res_bad = try am.vtable.complete(am.ctx, &ac_bad);
    switch (res_bad) {
        .fail => |f| try std.testing.expectEqual(@as(u16, 400), f.status),
        .record => return error.TestFailed,
    }
}

test "PasswordMethod: missing identity/password fields returns .fail 400" {
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");

    var env = try api_auth.TestEnv.initAuth("members2");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "members2")).?;
    };

    var req = env.ctx(a, .POST, "{\"identity\":\"u@x.io\"}", &[_]http.Param{});
    var ac = AuthCtx{
        .app = &env.app,
        .ctx = &req,
        .collection = col,
        .config = .null,
    };

    var m = try PasswordMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.complete(am.ctx, &ac);
    switch (res) {
        .fail => |f| {
            try std.testing.expectEqual(@as(u16, 400), f.status);
            try std.testing.expectEqualStrings("identity and password are required.", f.message);
        },
        .record => return error.TestFailed,
    }
}

test "PasswordMethod: unknown identity returns .fail 400 (timing defense)" {
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");

    var env = try api_auth.TestEnv.initAuth("members3");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "members3")).?;
    };

    var req = env.ctx(a, .POST, "{\"identity\":\"nobody@x.io\",\"password\":\"longenough\"}", &[_]http.Param{});
    var ac = AuthCtx{
        .app = &env.app,
        .ctx = &req,
        .collection = col,
        .config = .null,
    };

    var m = try PasswordMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.complete(am.ctx, &ac);
    switch (res) {
        .fail => |f| {
            try std.testing.expectEqual(@as(u16, 400), f.status);
            try std.testing.expectEqualStrings("Invalid credentials.", f.message);
        },
        .record => return error.TestFailed,
    }
}

test "PasswordMethod: method() returns slug=password and contract is satisfied" {
    var m = try PasswordMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    try std.testing.expectEqualStrings("password", am.slug);
    method_mod.assertAuthMethodContract(PasswordMethod);
}
