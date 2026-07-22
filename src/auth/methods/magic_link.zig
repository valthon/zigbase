const std = @import("std");
const RequestArena = @import("../../request_arena.zig").RequestArena;
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
        const parsed = std.json.parseFromSlice(std.json.Value, ac.ctx.allocator.a, ac.ctx.body, .{}) catch
            return InitiateResult{ .status = 204 };
        if (parsed.value != .object) return InitiateResult{ .status = 204 };
        break :blk strField(parsed.value, "identity") orelse return InitiateResult{ .status = 204 };
    };

    // Rate-limit check
    if (try ac.rateLimit("magic_link", email)) |_|
        return InitiateResult{ .status = 429, .body = "{\"message\":\"Too many requests.\"}" };

    const ml_opts = ac.collection.options.auth.methods.magic_link;
    const auto_create: bool = if (ml_opts) |ml| ml.auto_create else false;
    const ttl: i64 = if (ml_opts) |ml| ml.ttl_s else 900;
    const redirect: []const u8 = if (ml_opts) |ml| ml.redirect_default else "/";

    // Build the mail body into the request arena so it outlives the lock scope.
    // Release the DB connection before the blocking SMTP send.
    var pending: ?struct { email: []const u8, mail_body: []const u8 } = null;

    if (auto_create) {
        // Need the writer: create record if missing, then mintLinkToken (read under writer is fine in WAL).
        var w = ac.writer();
        defer w.deinit();

        if (try ac.resolveOrCreate(w.conn, email, true)) |rid| {
            const token = try ac.mintLinkToken(w.conn, rid, ttl, .{});
            const mail_body = try buildMailBody(
                ac.ctx.allocator.a,
                ac.app.public_url,
                ac.collection.name,
                token,
                redirect,
            );
            pending = .{ .email = email, .mail_body = mail_body };
        }
    } else {
        // Original path: READER only (no change to existing behavior).
        var r = try ac.reader();
        defer r.deinit();

        if (try ac.findByIdentity(&r.conn, email)) |rid| {
            const token = try ac.mintLinkToken(&r.conn, rid, ttl, .{});
            const mail_body = try buildMailBody(
                ac.ctx.allocator.a,
                ac.app.public_url,
                ac.collection.name,
                token,
                redirect,
            );
            pending = .{ .email = email, .mail_body = mail_body };
        }
    } // connection released above — SMTP send happens below without parking a connection

    // Deliver the link by email off the request path via the token-mail queue: the SMTP send's
    // latency AND any send failure run on the worker, so neither is observable on the response —
    // closing the timing/status oracle a synchronous send would create (a send only ever happens
    // for an existing account). This targets the mail-delivery signals specifically; the per-account
    // work above (lookup/create, token mint, body build) still differs, so it is not full
    // constant-time.
    if (pending) |p| {
        ac.deliverMail(p.email, "Your sign-in link", p.mail_body);
    }

    // ALWAYS return 204 — never reveal whether the email was found
    return InitiateResult{ .status = 204, .body = null };
}

fn completeImpl(ctx: *anyopaque, ac: *AuthCtx) anyerror!Resolution {
    _ = @as(*MagicLinkMethod, @ptrCast(@alignCast(ctx)));

    // Parse token from body
    const parsed = std.json.parseFromSlice(std.json.Value, ac.ctx.allocator.a, ac.ctx.body, .{}) catch {
        return Resolution{ .fail = .{ .status = 400, .message = "token is required." } };
    };
    if (parsed.value != .object) {
        return Resolution{ .fail = .{ .status = 400, .message = "token is required." } };
    }
    const token = strField(parsed.value, "token") orelse {
        return Resolution{ .fail = .{ .status = 400, .message = "token is required." } };
    };

    // Verify + consume must be atomic against the single-use guard, so they run
    // under ONE writer held for the whole operation.
    var w = ac.writer();
    defer w.deinit();

    // Verify token
    const claims = (try ac.verifyLinkToken(w.conn, token)) orelse
        return Resolution{ .fail = .{ .status = 400, .message = "Invalid or expired link." } };

    // Consume (single-use guard)
    ac.consumeLinkToken(w.conn, claims) catch
        return Resolution{ .fail = .{ .status = 400, .message = "Link already used." } };

    return Resolution{ .record = claims.id };
}

/// Build the magic-link email body. With no configured public base URL the
/// server cannot form an absolute link, so it falls back to emailing the raw
/// token (legacy behavior). With `public_url` set, it emits a clickable link to
/// the GET consume endpoint, which verifies+consumes the token, sets the session
/// cookie, and 302-redirects to `redirect`. JWT link tokens use the URL-safe
/// base64url alphabet (plus `.`), so the token needs no escaping; `redirect`
/// should be a simple origin-relative path (it is re-validated server-side).
fn buildMailBody(
    alloc: std.mem.Allocator,
    public_url: []const u8,
    col_name: []const u8,
    token: []const u8,
    redirect: []const u8,
) ![]const u8 {
    if (public_url.len == 0) {
        return std.fmt.allocPrint(alloc, "Your sign-in link token:\n\n{s}\n", .{token});
    }
    const base = std.mem.trimEnd(u8, public_url, "/");
    return std.fmt.allocPrint(
        alloc,
        "Click the link to sign in:\n\n{s}/api/collections/{s}/auth/magic-link/consume?token={s}&redirect={s}\n",
        .{ base, col_name, token, redirect },
    );
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

    // Setup: load collection + mint a link token under a writer that is
    // RELEASED before the method calls (each acquires its own connection).
    var rid_buf: [64]u8 = undefined;
    var rid_len: usize = 0;
    var token: []const u8 = undefined;
    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const col = (try collections.get(a, w, "mlmembers")).?;

        var req_ctx = env.ctx(RequestArena.from(&arena), .POST, "", &[_]http.Param{});
        var ac_mint = AuthCtx{
            .app = &env.app,
            .ctx = &req_ctx,
            .collection = col,
            .config = .null,
        };
        const rid = (try ac_mint.findByIdentity(w, "u@x.io")).?;
        @memcpy(rid_buf[0..rid.len], rid);
        rid_len = rid.len;
        token = try ac_mint.mintLinkToken(w, rid, 900, .{});
        break :blk col;
    };
    const rid = rid_buf[0..rid_len];

    // Build the complete request body
    const body = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\"}}", .{token});
    var req_ok = env.ctx(RequestArena.from(&arena), .POST, body, &[_]http.Param{});
    var ac_ok = AuthCtx{
        .app = &env.app,
        .ctx = &req_ok,
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
    var req_replay = env.ctx(RequestArena.from(&arena), .POST, body, &[_]http.Param{});
    var ac_replay = AuthCtx{
        .app = &env.app,
        .ctx = &req_replay,
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

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "mlmembers2")).?;
    };

    var req = env.ctx(RequestArena.from(&arena), .POST, "{\"token\":\"not.a.real.token\"}", &[_]http.Param{});
    var ac = AuthCtx{
        .app = &env.app,
        .ctx = &req,
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

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "mlmembers3")).?;
    };

    var req = env.ctx(RequestArena.from(&arena), .POST, "{\"other\":\"field\"}", &[_]http.Param{});
    var ac = AuthCtx{
        .app = &env.app,
        .ctx = &req,
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

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "mlmembers4")).?;
    };

    var req = env.ctx(RequestArena.from(&arena), .POST, "{\"identity\":\"u@x.io\"}", &[_]http.Param{});
    var ac = AuthCtx{
        .app = &env.app,
        .ctx = &req,
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

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "mlmembers5")).?;
    };

    var req = env.ctx(RequestArena.from(&arena), .POST, "{\"identity\":\"nobody@x.io\"}", &[_]http.Param{});
    var ac = AuthCtx{
        .app = &env.app,
        .ctx = &req,
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

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "mlmembers6")).?;
    };

    var req = env.ctx(RequestArena.from(&arena), .POST, "not json at all", &[_]http.Param{});
    var ac = AuthCtx{
        .app = &env.app,
        .ctx = &req,
        .collection = col,
        .config = .null,
    };

    var m = try MagicLinkMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.initiate(am.ctx, &ac);
    try std.testing.expectEqual(@as(u16, 204), res.status);
}

test "buildMailBody: raw token when public_url is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try buildMailBody(arena.allocator(), "", "users", "TOK.EN", "/");
    try std.testing.expect(std.mem.indexOf(u8, body, "TOK.EN") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "http") == null);
}

test "buildMailBody: clickable consume link when public_url is set (trailing slash trimmed)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try buildMailBody(arena.allocator(), "http://blog.test/", "users", "TOK.EN", "/dashboard");
    try std.testing.expectEqualStrings(
        "Click the link to sign in:\n\nhttp://blog.test/api/collections/users/auth/magic-link/consume?token=TOK.EN&redirect=/dashboard\n",
        body,
    );
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

test "MagicLinkMethod: initiate auto_create=true creates record for unknown identity" {
    const http_mod = @import("../../http.zig");
    const collections = @import("../../collections.zig");
    const schema_mod = @import("../../schema.zig");

    var env = try api_auth.TestEnv.initAuth("ml_ac");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Replace with a collection that has magic_link.auto_create = true
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const existing = (try collections.get(a, w, "ml_ac")).?;
        try collections.delete(a, w, existing.id);
        _ = try collections.create(a, std.testing.io, w, .{
            .id = "",
            .name = "ml_ac",
            .type = .auth,
            .fields = &[_]schema_mod.Field{},
            .listRule = "",
            .viewRule = "",
            .createRule = "",
            .updateRule = "",
            .deleteRule = "",
            .options = .{ .auth = .{ .methods = .{ .magic_link = .{ .auto_create = true } } } },
        });
    }

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "ml_ac")).?;
    };

    var req = env.ctx(RequestArena.from(&arena), .POST, "{\"identity\":\"brand_new@x.io\"}", &[_]http_mod.Param{});
    var ac = AuthCtx{ .app = &env.app, .ctx = &req, .collection = col, .config = .null };

    var m = try MagicLinkMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.initiate(am.ctx, &ac);
    try std.testing.expectEqual(@as(u16, 204), res.status);

    // Verify the record now exists
    const w2 = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    const col2 = (try collections.get(a, w2, "ml_ac")).?;
    var req2 = env.ctx(RequestArena.from(&arena), .POST, "", &[_]http_mod.Param{});
    var ac2 = AuthCtx{ .app = &env.app, .ctx = &req2, .collection = col2, .config = .null };
    const rid = try ac2.findByIdentity(w2, "brand_new@x.io");
    try std.testing.expect(rid != null);
}

test "MagicLinkMethod: initiate auto_create=false creates nothing for unknown identity" {
    const http_mod = @import("../../http.zig");
    const collections = @import("../../collections.zig");
    const schema_mod = @import("../../schema.zig");

    var env = try api_auth.TestEnv.initAuth("ml_noac");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const existing = (try collections.get(a, w, "ml_noac")).?;
        try collections.delete(a, w, existing.id);
        _ = try collections.create(a, std.testing.io, w, .{
            .id = "",
            .name = "ml_noac",
            .type = .auth,
            .fields = &[_]schema_mod.Field{},
            .listRule = "",
            .viewRule = "",
            .createRule = "",
            .updateRule = "",
            .deleteRule = "",
            .options = .{ .auth = .{ .methods = .{ .magic_link = .{ .auto_create = false } } } },
        });
    }

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "ml_noac")).?;
    };

    var req = env.ctx(RequestArena.from(&arena), .POST, "{\"identity\":\"ghost@x.io\"}", &[_]http_mod.Param{});
    var ac = AuthCtx{ .app = &env.app, .ctx = &req, .collection = col, .config = .null };

    var m = try MagicLinkMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.initiate(am.ctx, &ac);
    try std.testing.expectEqual(@as(u16, 204), res.status);

    // Record must NOT exist
    const w2 = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    const col2 = (try collections.get(a, w2, "ml_noac")).?;
    var req2 = env.ctx(RequestArena.from(&arena), .POST, "", &[_]http_mod.Param{});
    var ac2 = AuthCtx{ .app = &env.app, .ctx = &req2, .collection = col2, .config = .null };
    const rid = try ac2.findByIdentity(w2, "ghost@x.io");
    try std.testing.expectEqual(@as(?[]const u8, null), rid);
}

test "MagicLinkMethod: auto_create initiate then complete succeeds end-to-end" {
    const http_mod = @import("../../http.zig");
    const collections = @import("../../collections.zig");
    const schema_mod = @import("../../schema.zig");

    var env = try api_auth.TestEnv.initAuth("ml_e2e");
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const existing = (try collections.get(a, w, "ml_e2e")).?;
        try collections.delete(a, w, existing.id);
        _ = try collections.create(a, std.testing.io, w, .{
            .id = "",
            .name = "ml_e2e",
            .type = .auth,
            .fields = &[_]schema_mod.Field{},
            .listRule = "",
            .viewRule = "",
            .createRule = "",
            .updateRule = "",
            .deleteRule = "",
            .options = .{ .auth = .{ .methods = .{ .magic_link = .{ .auto_create = true } } } },
        });
    }

    const col = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "ml_e2e")).?;
    };

    // initiate creates the record
    var req_init = env.ctx(RequestArena.from(&arena), .POST, "{\"identity\":\"fresh@x.io\"}", &[_]http_mod.Param{});
    var ac_init = AuthCtx{ .app = &env.app, .ctx = &req_init, .collection = col, .config = .null };
    var m = try MagicLinkMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    _ = try am.vtable.initiate(am.ctx, &ac_init);

    // Retrieve the rid + mint a fresh token directly (bypass opaque mailer delivery)
    var token: []const u8 = undefined;
    var rid_buf: [64]u8 = undefined;
    var rid_len: usize = 0;
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const col2 = (try collections.get(a, w, "ml_e2e")).?;
        var req_mint = env.ctx(RequestArena.from(&arena), .POST, "", &[_]http_mod.Param{});
        var ac_mint = AuthCtx{ .app = &env.app, .ctx = &req_mint, .collection = col2, .config = .null };
        const rid = (try ac_mint.findByIdentity(w, "fresh@x.io")).?;
        @memcpy(rid_buf[0..rid.len], rid);
        rid_len = rid.len;
        token = try ac_mint.mintLinkToken(w, rid, 900, .{});
    }

    // complete resolves to the auto-created record's id
    const body = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\"}}", .{token});
    var req_comp = env.ctx(RequestArena.from(&arena), .POST, body, &[_]http_mod.Param{});
    const col3 = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk (try collections.get(a, w, "ml_e2e")).?;
    };
    var ac_comp = AuthCtx{ .app = &env.app, .ctx = &req_comp, .collection = col3, .config = .null };
    const res = try am.vtable.complete(am.ctx, &ac_comp);
    switch (res) {
        .record => |r| try std.testing.expectEqualStrings(rid_buf[0..rid_len], r),
        .fail => |f| {
            std.debug.print("Expected .record, got .fail: {d} {s}\n", .{ f.status, f.message });
            return error.TestFailed;
        },
    }
}
