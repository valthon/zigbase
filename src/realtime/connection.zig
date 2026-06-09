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

    pub fn setAuth(self: *Conn, ident: AuthIdentity) void {
        self.auth = ident;
    }
    pub fn clearAuth(self: *Conn) void {
        self.auth = null;
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
    /// identity yields an anonymous context.
    pub fn requestContext(self: *const Conn, now: i64) request.RequestContext {
        if (self.auth) |ident| {
            if (ident.exp > now)
                return .{ .auth = ident.record, .is_superuser = ident.is_superuser, .method = "" };
        }
        return .{ .auth = null, .is_superuser = false, .method = "" };
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
