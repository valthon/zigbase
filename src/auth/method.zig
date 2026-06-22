const std = @import("std");

pub const InitiateResult = struct { status: u16 = 200, body: ?[]const u8 = null };

pub const Resolution = union(enum) {
    record: []const u8, // resolved record id → framework mints session + onAuth
    fail: struct { status: u16, message: []const u8 },
};

pub const AuthCtx = struct {
    app: *@import("../app.zig").App,
    ctx: *@import("../http.zig").RequestCtx,
    collection: @import("../schema.zig").Collection,
    config: std.json.Value, // this method's per-collection config (object; .null if none)

    const http = @import("../http.zig");
    const db = @import("../db.zig");
    const events = @import("../events.zig");
    const jwt = @import("../jwt.zig");
    const auth_helpers = @import("../auth_helpers.zig");
    const api_auth = @import("../api/auth.zig");

    // -----------------------------------------------------------------------
    // RAII DB-access handles. A method acquires its OWN connection for the
    // duration it needs it — NOTHING (not the dispatch, not another method)
    // holds the single non-reentrant pool writer across the method call. This
    // is what lets OAuth release the writer during its provider HTTP exchange
    // and lets password verify argon2 under a read-only connection.
    //
    //   var w = ac.writer();        // acquires the shared pool writer (mutex)
    //   defer w.deinit();           // releases it back to the pool — no leak
    //   ... use w.conn ...
    //
    //   var r = try ac.reader();    // checks out a pooled read-only connection
    //   defer r.deinit();           // returns it to the warm pool — no leak
    //   ... use &r.conn (a *db.Db) ...
    // -----------------------------------------------------------------------

    /// Acquire the pool writer for create/update/delete. Caller MUST `deinit()`
    /// the returned handle (use `defer`). Hold it no longer than necessary —
    /// only one writer exists pool-wide and it is non-reentrant.
    pub fn writer(ac: *AuthCtx) events.WriterData {
        const conn = ac.app.pool.acquireWriter();
        return .{ .app = ac.app, .pool = ac.app.pool, .conn = conn };
    }

    /// Check out a pooled read-only connection for reads. Caller MUST `deinit()`
    /// the returned handle (use `defer`) to return it to the pool. `r.conn` is a
    /// `db.Db` value — pass `&r.conn` where a `*db.Db` is needed.
    pub fn reader(ac: *AuthCtx) db.DbError!events.ReaderData {
        const conn = try ac.app.pool.acquireReader();
        return .{ .app = ac.app, .pool = ac.app.pool, .conn = conn };
    }

    pub fn findByIdentity(ac: *AuthCtx, conn: *db.Db, identity: []const u8) !?[]const u8 {
        return api_auth.findByIdentity(ac.ctx.allocator, conn, ac.collection, identity);
    }

    /// Mint a single-use magic-link token. `opts.payload` (default empty) binds a small
    /// opaque, tamper-proof string into the token's signed `pl` claim (returned by
    /// `verifyLinkToken` as `claims.pl`) — e.g. a post-login redirect carried through the
    /// link. See `auth_helpers.MintOptions`.
    pub fn mintLinkToken(ac: *AuthCtx, conn: *db.Db, record_id: []const u8, ttl_s: i64, opts: auth_helpers.MintOptions) ![]const u8 {
        return (try auth_helpers.mintLinkToken(ac.ctx, conn, ac.collection.name, record_id, ttl_s, opts)).token;
    }

    pub fn verifyLinkToken(ac: *AuthCtx, conn: *db.Db, token: []const u8) !?jwt.Claims {
        return auth_helpers.verifyLinkToken(ac.ctx, conn, ac.collection.name, token);
    }

    pub fn consumeLinkToken(ac: *AuthCtx, conn: *db.Db, claims: jwt.Claims) !void {
        _ = ac;
        return auth_helpers.consumeLinkToken(conn, claims);
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
        .collection = col,
        .config = .null,
    };

    // Exercise the conn-taking helpers against the writer we already hold.
    // (These helpers do not acquire the pool writer themselves, so passing the
    // held writer cannot deadlock.)
    // findByIdentity should return the record id
    const rid = try ac.findByIdentity(w, "u@x.io");
    try std.testing.expect(rid != null);
    try std.testing.expect(rid.?.len > 0);

    // mintLinkToken should return a non-empty token string; an empty payload yields pl="".
    const token = try ac.mintLinkToken(w, rid.?, 900, .{});
    try std.testing.expect(token.len > 0);
    const claims_bare = (try ac.verifyLinkToken(w, token)).?;
    try std.testing.expectEqualStrings("", claims_bare.pl);

    // opts.payload binds an opaque value that verifyLinkToken returns as pl.
    const tok_pl = try ac.mintLinkToken(w, rid.?, 900, .{ .payload = "/dashboard" });
    const claims = (try ac.verifyLinkToken(w, tok_pl)).?;
    try std.testing.expectEqualStrings("/dashboard", claims.pl);
}
