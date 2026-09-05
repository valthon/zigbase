//! Shared two-factor policy and session boundary. Factor-specific cryptography
//! is installed by the comptime-selected subsystem, not imported here.
const std = @import("std");
const db = @import("../db.zig");
const http = @import("../http.zig");
const schema = @import("../schema.zig");
const records = @import("../records.zig");
const collections = @import("../collections.zig");
const RequestArena = @import("../request_arena.zig").RequestArena;
const policy = @import("two_factor_policy.zig");

/// Read-only policy facade. Query results live for the evaluation's arena.
/// Application code uses current roles/group membership to add a requirement.
pub const PolicyContext = struct {
    arena: RequestArena,
    collection: []const u8,
    record: std.json.Value,
    connection: *db.Db,

    pub fn findById(self: *PolicyContext, name: []const u8, id: []const u8) !?std.json.Value {
        const col = (try collections.get(self.arena.a, self.connection, name)) orelse return null;
        return records.get(self.arena.a, self.connection, col, id);
    }

    pub fn list(self: *PolicyContext, name: []const u8, query: records.ListQuery) !records.ListResult {
        const col = (try collections.get(self.arena.a, self.connection, name)) orelse return error.UnknownCollection;
        return records.list(self.arena.a, self.connection, col, query);
    }
};

pub const PolicyHook = *const fn (*PolicyContext) anyerror!bool;

pub const Runtime = struct {
    policy_hook: ?PolicyHook = null,
    evaluate: *const fn (RequestArena, *db.Db, *const Runtime, schema.Collection, std.json.Value, bool) anyerror!policy.Decision,
    begin: *const fn (*http.RequestCtx, *db.Db, schema.Collection, []const u8, @import("../events.zig").AuthMethod) anyerror!?http.Response,
    dispatch: *const fn (*http.RequestCtx) anyerror!http.Response,
};

pub fn runtime(app: anytype) ?*const Runtime {
    // Minimal token-verification test apps intentionally omit optional systems.
    const T = @TypeOf(app);
    const AppType = if (@typeInfo(T) == .pointer) @typeInfo(T).pointer.child else T;
    if (comptime !@hasField(AppType, "two_factor")) return null;
    const ptr = app.two_factor orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub fn decision(arena: RequestArena, conn: *db.Db, rt: *const Runtime, col: schema.Collection, rec: std.json.Value, verified: bool) !policy.Decision {
    return rt.evaluate(arena, conn, rt, col, rec, verified);
}

/// Existing custom session helpers fail closed; a custom primary method should
/// use beginAuthentication to obtain the same pending response as built-ins.
pub fn guardIssue(ctx: *http.RequestCtx, conn: *db.Db, collection: []const u8, principal: []const u8) !void {
    const col = (try collections.get(ctx.allocator.a, conn, collection)) orelse return error.NotFound;
    const rt = runtime(ctx.app.?) orelse {
        if (col.options.auth.two_factor != .disabled) return error.TwoFactorUnavailable;
        return;
    };
    const rec = (try records.get(ctx.allocator.a, conn, col, principal)) orelse return error.NotFound;
    const verified = if (ctx.two_factor_assurance) |assurance|
        std.mem.eql(u8, assurance.collection, collection) and std.mem.eql(u8, assurance.principal, principal)
    else
        false;
    if (try decision(ctx.allocator, conn, rt, col, rec, verified) != .authenticated)
        return error.SecondFactorRequired;
}

pub fn beginAuthentication(ctx: *http.RequestCtx, conn: *db.Db, col: schema.Collection, principal: []const u8, method: @import("../events.zig").AuthMethod) !?http.Response {
    const rt = runtime(ctx.app.?) orelse {
        if (col.options.auth.two_factor != .disabled) return error.TwoFactorUnavailable;
        return null;
    };
    return rt.begin(ctx, conn, col, principal, method);
}

test "optional runtime accepts pointer and value token-verification contexts" {
    const value = .{ .jwt_secret = "test" };
    try std.testing.expectEqual(null, runtime(value));
    try std.testing.expectEqual(null, runtime(&value));
    const disabled = .{ .two_factor = @as(?*anyopaque, null) };
    try std.testing.expectEqual(null, runtime(disabled));
    try std.testing.expectEqual(null, runtime(&disabled));
}
