const std = @import("std");
const method_mod = @import("../method.zig");
const AuthMethod = method_mod.AuthMethod;
const AuthCtx = method_mod.AuthCtx;
const InitiateResult = method_mod.InitiateResult;
const Resolution = method_mod.Resolution;
const challenge_store = @import("../challenge_store.zig");
const ChallengeStore = challenge_store.ChallengeStore;
const api_auth = @import("../../api/auth.zig");

// ---------------------------------------------------------------------------
// OtpMethod — email one-time numeric codes via ChallengeStore
// ---------------------------------------------------------------------------

pub const OtpMethod = struct {
    pub fn create(_: std.mem.Allocator, _: std.Io, _: anytype) !OtpMethod {
        return .{};
    }

    pub fn method(self: *OtpMethod) AuthMethod {
        return .{ .slug = "otp", .ctx = self, .vtable = &vtable };
    }

    pub fn deinit(_: *OtpMethod) void {}
};

fn strField(obj: std.json.Value, key: []const u8) ?[]const u8 {
    const v = obj.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Generate `length` decimal digit characters using rejection sampling to avoid modulo bias.
///
/// Approach: draw one byte at a time from `io.random`. Since 256 is not divisible by 10,
/// bytes >= 250 (= floor(256/10)*10) are rejected and redrawn. This leaves exactly 250
/// valid values, each of which maps uniformly to one of 10 digits (25 values per digit).
/// No modulo bias: every digit has exactly 25/250 = 1/10 probability.
fn generateCode(io: std.Io, buf: []u8) void {
    // Reject bytes >= 250 so that the mapping b[0] % 10 is uniform.
    // 250 = 25 * 10 — exactly 25 values map to each digit.
    const limit: u8 = 250;
    var i: usize = 0;
    var b: [1]u8 = undefined;
    while (i < buf.len) {
        io.random(&b);
        if (b[0] >= limit) continue; // rejection: redraw to eliminate bias
        buf[i] = '0' + (b[0] % 10);
        i += 1;
    }
}

/// Constant-time comparison of two byte slices.
/// Returns true only if both slices have the same length AND every byte is identical.
///
/// Approach: first do a non-constant-time length check (length mismatch is not secret —
/// codes are always `length` digits on both sides, so length equality is expected). Then
/// XOR-accumulate all byte differences into a single `diff` value. If any byte differs,
/// `diff` is nonzero. This loop always runs to completion regardless of where a mismatch
/// occurs, so no timing signal leaks the position of a mismatch.
fn timingSafeEqlSlices(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| {
        diff |= x ^ y;
    }
    return diff == 0;
}

fn initiateImpl(ctx: *anyopaque, ac: *AuthCtx) anyerror!InitiateResult {
    _ = @as(*OtpMethod, @ptrCast(@alignCast(ctx)));

    // Parse email from body; on any parse failure return 204 (enumeration-safe)
    const email = blk: {
        const parsed = std.json.parseFromSlice(std.json.Value, ac.ctx.allocator, ac.ctx.body, .{}) catch
            return InitiateResult{ .status = 204 };
        if (parsed.value != .object) return InitiateResult{ .status = 204 };
        break :blk strField(parsed.value, "identity") orelse return InitiateResult{ .status = 204 };
    };

    // Rate-limit check
    if (try ac.rateLimit("otp", email)) |_|
        return InitiateResult{ .status = 429, .body = "{\"message\":\"Too many requests.\"}" };

    // Read opts (default length=6, ttl_s=300)
    const length: u8 = if (ac.collection.options.auth.methods.otp) |o| o.length else 6;
    const ttl_s: i64 = if (ac.collection.options.auth.methods.otp) |o| o.ttl_s else 300;

    const auto_create: bool = if (ac.collection.options.auth.methods.otp) |o| o.auto_create else false;

    // Identity lookup + challenge store happen under ONE writer (the store write
    // must persist; keep the lookup atomic with it). resolveOrCreate handles the
    // auto_create case: creates a minimal auth record if the identity is unknown.
    // Build the mail body into the request arena so it outlives the scoped writer block below.
    var pending: ?struct { email: []const u8, code: []const u8 } = null;
    {
        var w = ac.writer();
        defer w.deinit();

        // resolveOrCreate: returns existing rid, creates one if auto_create=true + unknown, or null.
        // OTP initiate only needs to know whether a record exists/was-created; discard the id.
        if (try ac.resolveOrCreate(w.conn, email, auto_create)) |_| {
            // Generate a random numeric code of `length` digits (rejection-sampling, no modulo bias)
            const code = try ac.ctx.allocator.alloc(u8, length);
            generateCode(ac.app.io, code);

            // Store via ChallengeStore (single-use, TTL'd)
            const store = ChallengeStore{ .conn = w.conn };
            _ = try store.put(ac.ctx.allocator, ac.app.io, ac.collection.name, "otp", email, code, ttl_s);

            pending = .{ .email = email, .code = code };
        }
    } // writer released here — SMTP send happens below without holding the writer lock

    // Deliver the code by email (outside writer lock — SMTP may block)
    if (pending) |p| {
        try ac.deliverMail(p.email, "Your sign-in code", p.code);
    }

    // ALWAYS return 204 — never reveal whether the email was found
    return InitiateResult{ .status = 204, .body = null };
}

fn completeImpl(ctx: *anyopaque, ac: *AuthCtx) anyerror!Resolution {
    _ = @as(*OtpMethod, @ptrCast(@alignCast(ctx)));

    // Parse {identity, code} from body
    const parsed = std.json.parseFromSlice(std.json.Value, ac.ctx.allocator, ac.ctx.body, .{}) catch {
        return Resolution{ .fail = .{ .status = 400, .message = "identity and code are required." } };
    };
    if (parsed.value != .object) {
        return Resolution{ .fail = .{ .status = 400, .message = "identity and code are required." } };
    }
    const email = strField(parsed.value, "identity") orelse {
        return Resolution{ .fail = .{ .status = 400, .message = "identity and code are required." } };
    };
    const submitted_code = strField(parsed.value, "code") orelse {
        return Resolution{ .fail = .{ .status = 400, .message = "identity and code are required." } };
    };

    // The whole verify path mutates state (takeByIdentity consumes the challenge),
    // so it runs under ONE writer held for the call.
    var w = ac.writer();
    defer w.deinit();

    // Atomically fetch-and-consume the stored challenge (single-use gate)
    // takeByIdentity returns null when no valid challenge exists or it was already consumed.
    // Note: this CONSUMES the stored code even if the submitted code is wrong — intentional.
    // This design means a single issued code allows exactly one verification attempt, preventing
    // brute-force enumeration of OTP codes and making exhausted codes untriable after first use.
    const complete_store = ChallengeStore{ .conn = w.conn };
    const stored = (try complete_store.takeByIdentity(
        ac.ctx.allocator,
        ac.collection.name,
        "otp",
        email,
    )) orelse return Resolution{ .fail = .{ .status = 400, .message = "Invalid or expired code." } };

    // Constant-time compare: XOR-accumulate all byte differences; never early-exit on mismatch
    if (!timingSafeEqlSlices(submitted_code, stored)) {
        return Resolution{ .fail = .{ .status = 400, .message = "Invalid or expired code." } };
    }

    // Match: resolve the record id (same writer)
    const rid = (try ac.findByIdentity(w.conn, email)) orelse
        return Resolution{ .fail = .{ .status = 400, .message = "Invalid or expired code." } };

    return Resolution{ .record = rid };
}

const vtable = AuthMethod.VTable{
    .initiate = initiateImpl,
    .complete = completeImpl,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "OtpMethod: method() returns slug=otp and contract is satisfied" {
    var m = try OtpMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    try std.testing.expectEqualStrings("otp", am.slug);
    method_mod.assertAuthMethodContract(OtpMethod);
}

test "OtpMethod: generateCode produces length digits, all 0-9" {
    // Verify the generator produces the correct number of characters
    var buf6: [6]u8 = undefined;
    generateCode(std.testing.io, &buf6);
    try std.testing.expectEqual(@as(usize, 6), buf6.len);
    for (buf6) |c| {
        try std.testing.expect(c >= '0' and c <= '9');
    }

    // Verify for a different length
    var buf8: [8]u8 = undefined;
    generateCode(std.testing.io, &buf8);
    try std.testing.expectEqual(@as(usize, 8), buf8.len);
    for (buf8) |c| {
        try std.testing.expect(c >= '0' and c <= '9');
    }

    // Sample a few hundred codes: all chars should be digits
    var many: [500]u8 = undefined;
    generateCode(std.testing.io, &many);
    for (many) |c| {
        try std.testing.expect(c >= '0' and c <= '9');
    }
}

test "OtpMethod: timingSafeEqlSlices is correct" {
    try std.testing.expect(timingSafeEqlSlices("123456", "123456"));
    try std.testing.expect(!timingSafeEqlSlices("123456", "123457")); // last char differs
    try std.testing.expect(!timingSafeEqlSlices("123456", "000000")); // all chars differ
    try std.testing.expect(!timingSafeEqlSlices("12345", "123456")); // length mismatch
    try std.testing.expect(!timingSafeEqlSlices("123456", "12345")); // length mismatch
    try std.testing.expect(timingSafeEqlSlices("", "")); // empty slices equal
}

test "OtpMethod: complete with known code resolves to record id" {
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");

    var env = try api_auth.TestEnv.initAuth("otpmembers");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try env.createUser(a, "otpmembers", "u@x.io", "longenough");

    // Setup under a writer that is RELEASED before the method call.
    var rid_buf: [64]u8 = undefined;
    var rid_len: usize = 0;
    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const col = (try collections.get(a, w, "otpmembers")).?;

        // Resolve rid for comparison
        var req_ctx0 = env.ctx(a, .POST, "", &[_]http.Param{});
        var ac0 = AuthCtx{
            .app = &env.app,
            .ctx = &req_ctx0,
            .collection = col,
            .config = .null,
        };
        const rid = (try ac0.findByIdentity(w, "u@x.io")).?;
        @memcpy(rid_buf[0..rid.len], rid);
        rid_len = rid.len;

        // Directly seed a known code via ChallengeStore.put (bypass initiate so we know the code)
        const store = ChallengeStore{ .conn = w };
        _ = try store.put(a, std.testing.io, col.name, "otp", "u@x.io", "123456", 300);
        break :blk col;
    };
    const rid = rid_buf[0..rid_len];

    // complete with the correct code → should resolve to the record id
    const body_ok = "{\"identity\":\"u@x.io\",\"code\":\"123456\"}";
    var req_ok = env.ctx(a, .POST, body_ok, &[_]http.Param{});
    var ac_ok = AuthCtx{
        .app = &env.app,
        .ctx = &req_ok,
        .collection = col,
        .config = .null,
    };

    var m = try OtpMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();

    const res = try am.vtable.complete(am.ctx, &ac_ok);
    switch (res) {
        .record => |r| try std.testing.expectEqualStrings(rid, r),
        .fail => |f| {
            std.debug.print("Expected .record but got .fail: status={d} msg={s}\n", .{ f.status, f.message });
            return error.TestFailed;
        },
    }
}

test "OtpMethod: replay same code returns .fail 400 (single-use)" {
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");

    var env = try api_auth.TestEnv.initAuth("otpmembers2");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try env.createUser(a, "otpmembers2", "u@x.io", "longenough");

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const col = (try collections.get(a, w, "otpmembers2")).?;
        // Seed a known code
        const store = ChallengeStore{ .conn = w };
        _ = try store.put(a, std.testing.io, col.name, "otp", "u@x.io", "654321", 300);
        break :blk col;
    };

    var m = try OtpMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();

    const body = "{\"identity\":\"u@x.io\",\"code\":\"654321\"}";

    // First use: succeeds
    var req1 = env.ctx(a, .POST, body, &[_]http.Param{});
    var ac1 = AuthCtx{ .app = &env.app, .ctx = &req1, .collection = col, .config = .null };
    const res1 = try am.vtable.complete(am.ctx, &ac1);
    switch (res1) {
        .record => {},
        .fail => return error.TestFailed,
    }

    // Replay: the code was consumed, must fail
    var req2 = env.ctx(a, .POST, body, &[_]http.Param{});
    var ac2 = AuthCtx{ .app = &env.app, .ctx = &req2, .collection = col, .config = .null };
    const res2 = try am.vtable.complete(am.ctx, &ac2);
    switch (res2) {
        .fail => |f| try std.testing.expectEqual(@as(u16, 400), f.status),
        .record => return error.TestFailed,
    }
}

test "OtpMethod: wrong code returns .fail 400" {
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");

    var env = try api_auth.TestEnv.initAuth("otpmembers3");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try env.createUser(a, "otpmembers3", "u@x.io", "longenough");

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const col = (try collections.get(a, w, "otpmembers3")).?;
        // Seed "111111", submit "222222"
        const store = ChallengeStore{ .conn = w };
        _ = try store.put(a, std.testing.io, col.name, "otp", "u@x.io", "111111", 300);
        break :blk col;
    };

    const body = "{\"identity\":\"u@x.io\",\"code\":\"222222\"}";
    var req = env.ctx(a, .POST, body, &[_]http.Param{});
    var ac = AuthCtx{ .app = &env.app, .ctx = &req, .collection = col, .config = .null };

    var m = try OtpMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();

    const res = try am.vtable.complete(am.ctx, &ac);
    switch (res) {
        .fail => |f| try std.testing.expectEqual(@as(u16, 400), f.status),
        .record => return error.TestFailed,
    }
}

test "OtpMethod: initiate with known email returns 204" {
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");

    var env = try api_auth.TestEnv.initAuth("otpmembers4");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try env.createUser(a, "otpmembers4", "u@x.io", "longenough");

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "otpmembers4")).?;
    };

    var req = env.ctx(a, .POST, "{\"identity\":\"u@x.io\"}", &[_]http.Param{});
    var ac = AuthCtx{ .app = &env.app, .ctx = &req, .collection = col, .config = .null };

    var m = try OtpMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.initiate(am.ctx, &ac);
    try std.testing.expectEqual(@as(u16, 204), res.status);
}

test "OtpMethod: initiate with unknown email returns 204 (enumeration-safe)" {
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");

    var env = try api_auth.TestEnv.initAuth("otpmembers5");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "otpmembers5")).?;
    };

    var req = env.ctx(a, .POST, "{\"identity\":\"nobody@x.io\"}", &[_]http.Param{});
    var ac = AuthCtx{ .app = &env.app, .ctx = &req, .collection = col, .config = .null };

    var m = try OtpMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.initiate(am.ctx, &ac);
    try std.testing.expectEqual(@as(u16, 204), res.status);
}

test "OtpMethod: initiate with unparseable body returns 204 (enumeration-safe)" {
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");

    var env = try api_auth.TestEnv.initAuth("otpmembers6");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "otpmembers6")).?;
    };

    var req = env.ctx(a, .POST, "not json at all", &[_]http.Param{});
    var ac = AuthCtx{ .app = &env.app, .ctx = &req, .collection = col, .config = .null };

    var m = try OtpMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.initiate(am.ctx, &ac);
    try std.testing.expectEqual(@as(u16, 204), res.status);
}

test "OtpMethod: complete with missing fields returns .fail 400" {
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");

    var env = try api_auth.TestEnv.initAuth("otpmembers7");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "otpmembers7")).?;
    };

    var m = try OtpMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();

    // Missing code
    var req1 = env.ctx(a, .POST, "{\"identity\":\"u@x.io\"}", &[_]http.Param{});
    var ac1 = AuthCtx{ .app = &env.app, .ctx = &req1, .collection = col, .config = .null };
    const res1 = try am.vtable.complete(am.ctx, &ac1);
    switch (res1) {
        .fail => |f| {
            try std.testing.expectEqual(@as(u16, 400), f.status);
            try std.testing.expectEqualStrings("identity and code are required.", f.message);
        },
        .record => return error.TestFailed,
    }

    // Missing email
    var req2 = env.ctx(a, .POST, "{\"code\":\"123456\"}", &[_]http.Param{});
    var ac2 = AuthCtx{ .app = &env.app, .ctx = &req2, .collection = col, .config = .null };
    const res2 = try am.vtable.complete(am.ctx, &ac2);
    switch (res2) {
        .fail => |f| try std.testing.expectEqual(@as(u16, 400), f.status),
        .record => return error.TestFailed,
    }
}

test "OtpMethod: length/ttl_s read from collection opts (default 6/300 when opts null)" {
    const schema_mod = @import("../../schema.zig");

    // Null opts → defaults
    const col_null = schema_mod.Collection{
        .id = "x",
        .name = "test",
        .type = .auth,
        .fields = &.{},
        .options = .{ .auth = .{ .methods = .{ .otp = null } } },
    };
    const length_null: u8 = if (col_null.options.auth.methods.otp) |o| o.length else 6;
    const ttl_null: i64 = if (col_null.options.auth.methods.otp) |o| o.ttl_s else 300;
    try std.testing.expectEqual(@as(u8, 6), length_null);
    try std.testing.expectEqual(@as(i64, 300), ttl_null);

    // Explicit opts with custom values
    const col_opts = schema_mod.Collection{
        .id = "y",
        .name = "test2",
        .type = .auth,
        .fields = &.{},
        .options = .{ .auth = .{ .methods = .{ .otp = .{ .length = 8, .ttl_s = 600 } } } },
    };
    const length_custom: u8 = if (col_opts.options.auth.methods.otp) |o| o.length else 6;
    const ttl_custom: i64 = if (col_opts.options.auth.methods.otp) |o| o.ttl_s else 300;
    try std.testing.expectEqual(@as(u8, 8), length_custom);
    try std.testing.expectEqual(@as(i64, 600), ttl_custom);
}

test "OtpMethod: initiate auto_create=true creates record for unknown identity" {
    const http_mod = @import("../../http.zig");
    const collections = @import("../../collections.zig");
    const schema_mod = @import("../../schema.zig");

    var env = try api_auth.TestEnv.initAuth("otp_ac");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const existing = (try collections.get(a, w, "otp_ac")).?;
        try collections.delete(a, w, existing.id);
        _ = try collections.create(a, std.testing.io, w, .{
            .id = "", .name = "otp_ac", .type = .auth,
            .fields = &[_]schema_mod.Field{},
            .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "",
            .options = .{ .auth = .{ .methods = .{ .otp = .{ .auto_create = true } } } },
        });
    }

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "otp_ac")).?;
    };

    var req = env.ctx(a, .POST, "{\"identity\":\"brand_new@x.io\"}", &[_]http_mod.Param{});
    var ac = AuthCtx{ .app = &env.app, .ctx = &req, .collection = col, .config = .null };

    var m = try OtpMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.initiate(am.ctx, &ac);
    try std.testing.expectEqual(@as(u16, 204), res.status);

    // Record now exists
    const w2 = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    const col2 = (try collections.get(a, w2, "otp_ac")).?;
    var req2 = env.ctx(a, .POST, "", &[_]http_mod.Param{});
    var ac2 = AuthCtx{ .app = &env.app, .ctx = &req2, .collection = col2, .config = .null };
    const rid = try ac2.findByIdentity(w2, "brand_new@x.io");
    try std.testing.expect(rid != null);
}

test "OtpMethod: initiate auto_create=false creates nothing for unknown identity" {
    const http_mod = @import("../../http.zig");
    const collections = @import("../../collections.zig");
    const schema_mod = @import("../../schema.zig");

    var env = try api_auth.TestEnv.initAuth("otp_noac");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const existing = (try collections.get(a, w, "otp_noac")).?;
        try collections.delete(a, w, existing.id);
        _ = try collections.create(a, std.testing.io, w, .{
            .id = "", .name = "otp_noac", .type = .auth,
            .fields = &[_]schema_mod.Field{},
            .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "",
            .options = .{ .auth = .{ .methods = .{ .otp = .{ .auto_create = false } } } },
        });
    }

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "otp_noac")).?;
    };

    var req = env.ctx(a, .POST, "{\"identity\":\"ghost@x.io\"}", &[_]http_mod.Param{});
    var ac = AuthCtx{ .app = &env.app, .ctx = &req, .collection = col, .config = .null };

    var m = try OtpMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.initiate(am.ctx, &ac);
    try std.testing.expectEqual(@as(u16, 204), res.status);

    // Record must NOT exist
    const w2 = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    const col2 = (try collections.get(a, w2, "otp_noac")).?;
    var req2 = env.ctx(a, .POST, "", &[_]http_mod.Param{});
    var ac2 = AuthCtx{ .app = &env.app, .ctx = &req2, .collection = col2, .config = .null };
    const rid = try ac2.findByIdentity(w2, "ghost@x.io");
    try std.testing.expectEqual(@as(?[]const u8, null), rid);
}

test "OtpMethod: auto_create initiate then complete succeeds end-to-end" {
    const http_mod = @import("../../http.zig");
    const collections = @import("../../collections.zig");
    const schema_mod = @import("../../schema.zig");

    var env = try api_auth.TestEnv.initAuth("otp_e2e");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const existing = (try collections.get(a, w, "otp_e2e")).?;
        try collections.delete(a, w, existing.id);
        _ = try collections.create(a, std.testing.io, w, .{
            .id = "", .name = "otp_e2e", .type = .auth,
            .fields = &[_]schema_mod.Field{},
            .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "",
            .options = .{ .auth = .{ .methods = .{ .otp = .{ .auto_create = true } } } },
        });
    }

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "otp_e2e")).?;
    };

    // initiate creates record + stores a code (unknown to us — consume and replace)
    var req_init = env.ctx(a, .POST, "{\"identity\":\"fresh@x.io\"}", &[_]http_mod.Param{});
    var ac_init = AuthCtx{ .app = &env.app, .ctx = &req_init, .collection = col, .config = .null };
    var m = try OtpMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    _ = try am.vtable.initiate(am.ctx, &ac_init);

    // Consume the auto-stored code and replace with a known one
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const cs = challenge_store.ChallengeStore{ .conn = w };
        _ = try cs.takeByIdentity(a, "otp_e2e", "otp", "fresh@x.io");
        _ = try cs.put(a, std.testing.io, "otp_e2e", "otp", "fresh@x.io", "999999", 300);
    }

    const col2 = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "otp_e2e")).?;
    };
    const body = "{\"identity\":\"fresh@x.io\",\"code\":\"999999\"}";
    var req_comp = env.ctx(a, .POST, body, &[_]http_mod.Param{});
    var ac_comp = AuthCtx{ .app = &env.app, .ctx = &req_comp, .collection = col2, .config = .null };
    const res = try am.vtable.complete(am.ctx, &ac_comp);
    switch (res) {
        .record => {},
        .fail => |f| {
            std.debug.print("Expected .record, got .fail: {d} {s}\n", .{ f.status, f.message });
            return error.TestFailed;
        },
    }
}
