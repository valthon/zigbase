const std = @import("std");

pub const InitiateResult = struct { status: u16 = 200, body: ?[]const u8 = null };

pub const Resolution = union(enum) {
    record: []const u8, // resolved record id → framework mints session + onAuth
    fail: struct { status: u16, message: []const u8 },
};

pub const AuthCtx = struct { // FIELDS ONLY in this task; helper methods land in Task 3
    app: *@import("../app.zig").App,
    ctx: *@import("../http.zig").RequestCtx,
    conn: *@import("../db.zig").Db,
    collection: @import("../schema.zig").Collection,
    config: std.json.Value, // this method's per-collection config (object; .null if none)

    const http = @import("../http.zig");
    const jwt = @import("../jwt.zig");
    const auth_helpers = @import("../auth_helpers.zig");
    const api_auth = @import("../api/auth.zig");

    pub fn findByIdentity(ac: *AuthCtx, identity: []const u8) !?[]const u8 {
        return api_auth.findByIdentity(ac.ctx.allocator, ac.conn, ac.collection, identity);
    }

    pub fn mintLinkToken(ac: *AuthCtx, record_id: []const u8, ttl_s: i64) ![]const u8 {
        return (try auth_helpers.mintLinkToken(ac.ctx, ac.conn, ac.collection.name, record_id, ttl_s)).token;
    }

    pub fn verifyLinkToken(ac: *AuthCtx, token: []const u8) !?jwt.Claims {
        return auth_helpers.verifyLinkToken(ac.ctx, ac.conn, ac.collection.name, token);
    }

    pub fn consumeLinkToken(ac: *AuthCtx, claims: jwt.Claims) !void {
        return auth_helpers.consumeLinkToken(ac.conn, claims);
    }

    pub fn deliverMail(ac: *AuthCtx, to: []const u8, subject: []const u8, body: []const u8) !void {
        return auth_helpers.deliverAuthMail(ac.app, ac.ctx.allocator, to, subject, body);
    }

    pub fn rateLimit(ac: *AuthCtx, scope: []const u8, ident: []const u8) !?http.Response {
        return auth_helpers.rateLimit(ac.ctx, scope, ident);
    }
};

pub const AuthMethod = struct {
    slug: []const u8,
    ctx: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        initiate: *const fn (ctx: *anyopaque, ac: *AuthCtx) anyerror!InitiateResult,
        complete: *const fn (ctx: *anyopaque, ac: *AuthCtx) anyerror!Resolution,
    };
};

/// Mirrors framework.assertPluginContract: a method TYPE must declare create/method/deinit.
pub fn assertAuthMethodContract(comptime P: type) void {
    inline for (.{ "create", "method", "deinit" }) |decl| {
        if (!@hasDecl(P, decl))
            @compileError("'.auth_methods' type '" ++ @typeName(P) ++ "' is missing '" ++ decl ++
                "'; a method must declare create(gpa, io, cfg) !Self / method(*Self) AuthMethod / deinit(*Self) void");
    }
}

test "assertAuthMethodContract accepts a well-formed method type and a Resolution round-trips" {
    const Good = struct {
        pub fn create(_: std.mem.Allocator, _: std.Io, _: anytype) !@This() { return .{}; }
        pub fn method(self: *@This()) AuthMethod { return .{ .slug = "x", .ctx = self, .vtable = &vt }; }
        pub fn deinit(_: *@This()) void {}
        const vt = AuthMethod.VTable{ .initiate = undefined, .complete = undefined };
    };
    assertAuthMethodContract(Good); // compiles ⇒ pass
    const r: Resolution = .{ .record = "rec123" };
    try std.testing.expectEqualStrings("rec123", r.record);
    const f: Resolution = .{ .fail = .{ .status = 400, .message = "no" } };
    try std.testing.expectEqual(@as(u16, 400), f.fail.status);
}

test "AuthCtx helpers: findByIdentity and mintLinkToken delegate correctly" {
    const api_auth = @import("../api/auth.zig");
    const collections = @import("../collections.zig");
    const http = @import("../http.zig");

    var env = try api_auth.TestEnv.initAuth("members");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try env.createUser(a, "members", "u@x.io", "longenough");

    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();

    const col = (try collections.get(a, w, "members")).?;
    var req_ctx = env.ctx(a, .POST, "", &[_]http.Param{});

    var ac = AuthCtx{
        .app = &env.app,
        .ctx = &req_ctx,
        .conn = w,
        .collection = col,
        .config = .null,
    };

    // findByIdentity should return the record id
    const rid = try ac.findByIdentity("u@x.io");
    try std.testing.expect(rid != null);
    try std.testing.expect(rid.?.len > 0);

    // mintLinkToken should return a non-empty token string
    const token = try ac.mintLinkToken(rid.?, 900);
    try std.testing.expect(token.len > 0);
}
