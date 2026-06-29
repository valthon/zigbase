const std = @import("std");
const request = @import("../request.zig");

/// A verified connection identity. `exp` is the token's unix expiry; past it the connection is
/// treated as anonymous until a fresh `auth` message.
pub const AuthIdentity = struct {
    record: std.json.Value,
    is_superuser: bool,
    exp: i64,
};

/// Per-connection realtime state. In 7a this is the pure data model; 7b adds the live WS handle,
/// settings, clientId, and allocator. `subs` maps topic -> optional filter expression.
pub const Conn = struct {
    auth: ?AuthIdentity = null,
    subs: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    /// Multi-tenancy scope for this connection (#156). `tenancy_enabled` mirrors `app.tenancy.enabled`
    /// and is set at upgrade so the realtime `RequestContext` ALWAYS carries it (fail-closed: with no
    /// resolved account the tenant predicate binds `tenant_field = ''` → zero rows, never a leak).
    /// `account_id`/`memberships` are the resolved active scope, filled at `auth`-frame time from a
    /// verified `_memberships` row; both live on the connection-durable arena (persist across frames).
    tenancy_enabled: bool = false,
    account_id: []const u8 = "",
    memberships: []const request.Membership = &.{},

    pub fn setAuth(self: *Conn, ident: AuthIdentity) void {
        self.auth = ident;
    }
    pub fn clearAuth(self: *Conn) void {
        self.auth = null;
        // Drop the resolved account scope with the identity it belonged to (the durable-arena
        // slices are reclaimed when the connection closes; clearing the refs is enough).
        self.account_id = "";
        self.memberships = &.{};
    }

    /// Store the resolved active-account scope (durable-arena slices) for this connection.
    pub fn setTenancyScope(self: *Conn, account_id: []const u8, memberships: []const request.Membership) void {
        self.account_id = account_id;
        self.memberships = memberships;
    }

    pub fn addSub(self: *Conn, alloc: std.mem.Allocator, topic: []const u8, filter: ?[]const u8) !void {
        const k = try alloc.dupe(u8, topic);
        const f: ?[]const u8 = if (filter) |x| try alloc.dupe(u8, x) else null;
        try self.subs.put(alloc, k, f);
    }
    pub fn removeSub(self: *Conn, topic: []const u8) bool {
        return self.subs.remove(topic);
    }
    pub fn hasSub(self: *const Conn, topic: []const u8) bool {
        return self.subs.contains(topic);
    }
    /// Returns a pointer to the stored optional filter for `topic`, or null if not subscribed.
    pub fn subFilter(self: *const Conn, topic: []const u8) ?*const ?[]const u8 {
        return self.subs.getPtr(topic);
    }

    /// Build the access-rules context for an event at unix time `now`. An absent or expired
    /// identity yields an anonymous context. `tenancy_enabled` is ALWAYS propagated (fail-closed),
    /// but the resolved `account_id`/`memberships` are carried ONLY while the identity is live — an
    /// expired token becomes anonymous with no account, so tenant-owned data fails closed (deny)
    /// rather than leaking under a stale scope.
    pub fn requestContext(self: *const Conn, now: i64) request.RequestContext {
        const live = if (self.auth) |ident| ident.exp > now else false;
        var ctx: request.RequestContext = if (live)
            .{ .auth = self.auth.?.record, .is_superuser = self.auth.?.is_superuser, .method = "" }
        else
            .{ .auth = null, .is_superuser = false, .method = "" };
        ctx.tenancy_enabled = self.tenancy_enabled;
        if (live) {
            ctx.account_id = self.account_id;
            ctx.memberships = self.memberships;
        }
        return ctx;
    }
};

test "subscriptions add/remove/get filter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var conn = Conn{};
    try conn.addSub(a, "posts", "status='x'");
    try conn.addSub(a, "users/REC1", null);
    try std.testing.expect(conn.hasSub("posts"));
    try std.testing.expectEqualStrings("status='x'", conn.subFilter("posts").?.*.?);
    try std.testing.expect(conn.subFilter("users/REC1").?.* == null);
    try std.testing.expect(conn.removeSub("posts"));
    try std.testing.expect(!conn.hasSub("posts"));
    try std.testing.expect(!conn.removeSub("missing"));
}

test "requestContext: anonymous, authed, expired" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var conn = Conn{};
    try std.testing.expect(conn.requestContext(1000).auth == null);
    var rec: std.json.ObjectMap = .empty;
    try rec.put(a, "id", .{ .string = "u1" });
    conn.setAuth(.{ .record = .{ .object = rec }, .is_superuser = false, .exp = 2000 });
    const c1 = conn.requestContext(1500);
    try std.testing.expect(c1.auth != null);
    try std.testing.expectEqualStrings("u1", c1.auth.?.object.get("id").?.string);
    try std.testing.expect(conn.requestContext(2000).auth == null);
    try std.testing.expect(conn.requestContext(2001).auth == null);
    conn.setAuth(.{ .record = .{ .object = rec }, .is_superuser = true, .exp = 2000 });
    try std.testing.expect(conn.requestContext(1500).is_superuser);
}
