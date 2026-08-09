const std = @import("std");
const RequestArena = @import("../../request_arena.zig").RequestArena;
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
    const parsed = std.json.parseFromSlice(std.json.Value, ac.ctx.allocator.a, ac.ctx.body, .{}) catch {
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
        crypto.dummyVerify(ac.app.io, ac.ctx.allocator.a);
        return Resolution{ .fail = .{ .status = 400, .message = "Invalid credentials." } };
    };

    // Fetch the password hash
    const phc = (try api_auth.passwordHashFor(ac.ctx.allocator.a, &r.conn, ac.collection.name, rid)) orelse {
        crypto.dummyVerify(ac.app.io, ac.ctx.allocator.a);
        return Resolution{ .fail = .{ .status = 400, .message = "Invalid credentials." } };
    };

    // Verify password (transparently upgrading a legacy-imported hash to argon2id on success)
    if (!api_auth.verifyPasswordUpgrading(ac.app, ac.ctx.allocator.a, ac.collection.name, rid, phc, password)) {
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
    var req_ok = env.ctx(RequestArena.from(&arena), .POST, "{\"identity\":\"u@x.io\",\"password\":\"longenough\"}", &[_]http.Param{});
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
    var req_bad = env.ctx(RequestArena.from(&arena), .POST, "{\"identity\":\"u@x.io\",\"password\":\"wrongwrong\"}", &[_]http.Param{});
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

test "PasswordMethod: a legacy-tagged hash verifies and is upgraded to argon2id" {
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");

    var env = try api_auth.TestEnv.initAuth("members2");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try env.createUser(a, "members2", "legacy@x.io", "placeholder-unused-1");

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "members2")).?;
    };

    const rid = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try api_auth.findByIdentity(a, w, col, "legacy@x.io")).?;
    };

    // Overwrite the stored hash with a tagged legacy value, exactly as `zigbase import
    // --legacy-hashes` would leave it.
    const bc = "$2b$04$gKLlzqBYq6vyAUzUTYq/f.2na5B02QSMuFv75B374EKmX3m3Kt1UG"; // "abc"
    const tagged = try crypto.wrapLegacy(a, "bcrypt", bc);
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        var st = try w.prepare("UPDATE \"members2\" SET \"passwordHash\" = ?1 WHERE \"id\" = ?2;");
        defer st.finalize();
        try st.bindText(1, tagged);
        try st.bindText(2, rid);
        _ = try st.step();
    }

    var req = env.ctx(RequestArena.from(&arena), .POST, "{\"identity\":\"legacy@x.io\",\"password\":\"abc\"}", &[_]http.Param{});
    var ac = AuthCtx{ .app = &env.app, .ctx = &req, .collection = col, .config = .null };

    var m = try PasswordMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.complete(am.ctx, &ac);
    switch (res) {
        .record => |got_rid| try std.testing.expectEqualStrings(rid, got_rid),
        .fail => |f| {
            std.debug.print("Expected .record but got .fail: status={d} msg={s}\n", .{ f.status, f.message });
            return error.TestFailed;
        },
    }

    const after = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try api_auth.passwordHashFor(a, w, "members2", rid)).?;
    };
    try std.testing.expect(!crypto.isLegacyHash(after));
    try std.testing.expect(std.mem.startsWith(u8, after, "$argon2"));
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

    var req = env.ctx(RequestArena.from(&arena), .POST, "{\"identity\":\"u@x.io\"}", &[_]http.Param{});
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

    var req = env.ctx(RequestArena.from(&arena), .POST, "{\"identity\":\"nobody@x.io\",\"password\":\"longenough\"}", &[_]http.Param{});
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
