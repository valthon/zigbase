const std = @import("std");
const request = @import("../request.zig");

/// Max concurrent subscriptions per connection (bounds per-conn facil.io subscription state).
/// Shared by BOTH realtime transports via hub.subscribeCheck.
pub const MAX_SUBS: usize = 256;

/// F9: global cap on concurrent realtime connections — ONE counter covering WebSocket AND SSE
/// (issue #188: mirror WS knobs — it is the same knob). Deliberately a module-level constant in
/// the realtime layer (NOT config.zig) so an operator can't accidentally disable it and a
/// parallel config workstream doesn't conflict. New upgrades past this cap are rejected with 503.
pub const MAX_CONNECTIONS: usize = 10_000;

/// Live realtime connection count (WS + SSE). Bumped on a successful upgrade, decremented on
/// close. Different sockets run on different threads, so this is an atomic.
var live_connections: std.atomic.Value(usize) = .init(0);

/// Current live realtime connection count (test/introspection helper).
pub fn connectionCount() usize {
    return live_connections.load(.monotonic);
}

/// Atomically reserve a global connection slot (F9). Returns false (and leaves the count
/// unchanged) when the cap is already reached, so the caller must reject the upgrade. Pair a
/// successful reservation with exactly one `releaseConnectionSlot`.
pub fn reserveConnectionSlot() bool {
    if (live_connections.fetchAdd(1, .monotonic) >= MAX_CONNECTIONS) {
        _ = live_connections.fetchSub(1, .monotonic);
        return false;
    }
    return true;
}

pub fn releaseConnectionSlot() void {
    _ = live_connections.fetchSub(1, .monotonic);
}

/// Slow-consumer outbound high-water-mark (issue #203). A WS or SSE peer that reads slowly,
/// opens a tiny TCP window, or stalls without closing causes delivered frames to accumulate in
/// facil.io's per-socket outgoing buffer WITHOUT BOUND — an OOM/DoS risk (MAX_SUBS/MAX_CONNECTIONS
/// bound only subscription/connection *counts*, never a single connection's outbound queue depth).
/// When the queue exceeds this bound the transport DISCONNECTS the consumer (the standard pub/sub
/// choice — dropping individual frames would silently corrupt the client's view of the collection);
/// the client reconnects + re-fetches cleanly. This is the DEFAULT; an operator overrides it via
/// `ZIGBASE_REALTIME_OUTBOUND_HWM` / `--realtime-outbound-hwm`. `0` disables the bound.
///
/// Unit is FRAMES (facil.io counts queued `fio_write` calls, one per delivered frame), NOT bytes.
pub const DEFAULT_OUTBOUND_HWM: u32 = 1024;

/// facil.io `size_t fio_pending(intptr_t uuid)` (fio.h): the number of queued (un-flushed)
/// `fio_write` calls on a socket. One realtime frame == one write, so this is the connection's
/// pending outbound frame count. Safe on a dead/invalid uuid (facil.io returns 0). Linked from the
/// vendored facil.io that zap compiles; only meaningful with the reactor running.
extern fn fio_pending(uuid: isize) usize;

/// Queued outbound frame count for a live realtime socket `uuid` (WS: `websocket_uuid`;
/// SSE: `http_sse2uuid`). Reactor-only — never call from a unit test (no facil.io globals). The
/// pure decision predicate is `outboundOverHwm`, which IS unit-testable.
pub fn pendingOutbound(uuid: isize) usize {
    return fio_pending(uuid);
}

/// Pure predicate (unit-testable): do `pending` queued outbound frames exceed the bound `hwm`?
/// `hwm == 0` disables the bound (always false). Split from `pendingOutbound` so the policy is
/// testable without a running facil.io reactor.
pub fn outboundOverHwm(pending: usize, hwm: u32) bool {
    return hwm != 0 and pending > hwm;
}

/// Two optional filter expressions are equal (both absent, or both present with equal bytes).
fn filtersEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a) |x| if (b) |y| return std.mem.eql(u8, x, y);
    return false;
}

/// A verified connection identity. `exp` is the token's unix expiry; past it the connection is
/// treated as anonymous until a fresh `auth` message.
pub const AuthIdentity = struct {
    record: std.json.Value,
    is_superuser: bool,
    exp: i64,
    /// Owned by the identity arena; retained for current-policy verification.
    token: []const u8 = "",
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

    /// Update the stored filter for an ALREADY-subscribed `topic` in place, returning false when
    /// the topic isn't subscribed (the caller then does a fresh `addSub` + transport subscribe).
    /// This is the dedup path for a REPEATED subscribe (#3): it reuses the existing subscription
    /// slot and the single transport-side subscription instead of stacking a second one — which
    /// bypassed `MAX_SUBS` (`subs.put` overwrote the entry, so the count never grew) and made every
    /// published event fan out N× to the same client. It re-dupes the filter ONLY when it actually
    /// changed, so a client re-subscribing to the same topic+filter in a loop allocates nothing.
    pub fn updateFilter(self: *Conn, alloc: std.mem.Allocator, topic: []const u8, filter: ?[]const u8) !bool {
        const vp = self.subs.getPtr(topic) orelse return false;
        if (filtersEqual(vp.*, filter)) return true;
        if (vp.*) |old| alloc.free(old); // release the replaced filter before overwriting it
        vp.* = if (filter) |f| try alloc.dupe(u8, f) else null;
        return true;
    }
    /// Drop `topic`'s subscription, freeing the dupe'd key/filter it was holding (matching
    /// `updateFilter`'s discipline). `alloc` must be the SAME allocator `addSub`/`updateFilter` used
    /// to dupe them (the connection-durable arena in production; safe as a no-op free on it, and a
    /// real free under a plain allocator in tests). Returns false when `topic` wasn't subscribed.
    pub fn removeSub(self: *Conn, alloc: std.mem.Allocator, topic: []const u8) bool {
        const kv = self.subs.fetchRemove(topic) orelse return false;
        alloc.free(kv.key);
        if (kv.value) |f| alloc.free(f);
        return true;
    }

    /// Free every remaining subscription's dupe'd key/filter plus the map's own storage. `alloc`
    /// must match what `addSub`/`updateFilter` used. Production connections never call this (the
    /// whole connection-durable arena is torn down at once instead); it exists for standalone/test
    /// use of a `Conn` under a plain allocator.
    pub fn deinit(self: *Conn, alloc: std.mem.Allocator) void {
        var it = self.subs.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            if (e.value_ptr.*) |f| alloc.free(f);
        }
        self.subs.deinit(alloc);
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
    const a = std.testing.allocator;
    var conn = Conn{};
    defer conn.deinit(a);
    try conn.addSub(a, "posts", "status='x'");
    try conn.addSub(a, "users/REC1", null);
    try std.testing.expect(conn.hasSub("posts"));
    try std.testing.expectEqualStrings("status='x'", conn.subFilter("posts").?.*.?);
    try std.testing.expect(conn.subFilter("users/REC1").?.* == null);
    try std.testing.expect(conn.removeSub(a, "posts"));
    try std.testing.expect(!conn.hasSub("posts"));
    try std.testing.expect(!conn.removeSub(a, "missing"));
}

test "updateFilter: dedup path replaces the filter in place without growing subs.count (#3)" {
    const a = std.testing.allocator;
    var conn = Conn{};
    defer conn.deinit(a);
    // A topic that isn't subscribed yet: updateFilter is a no-op miss (caller does addSub).
    try std.testing.expect(!(try conn.updateFilter(a, "posts", "status='x'")));
    try std.testing.expectEqual(@as(usize, 0), conn.subs.count());

    try conn.addSub(a, "posts", "status='x'");
    try std.testing.expectEqual(@as(usize, 1), conn.subs.count());

    // Re-subscribe with the SAME filter: hit, count unchanged, filter unchanged.
    try std.testing.expect(try conn.updateFilter(a, "posts", "status='x'"));
    try std.testing.expectEqual(@as(usize, 1), conn.subs.count());
    try std.testing.expectEqualStrings("status='x'", conn.subFilter("posts").?.*.?);

    // Re-subscribe with a DIFFERENT filter: hit, count still unchanged, filter replaced.
    try std.testing.expect(try conn.updateFilter(a, "posts", "status='y'"));
    try std.testing.expectEqual(@as(usize, 1), conn.subs.count());
    try std.testing.expectEqualStrings("status='y'", conn.subFilter("posts").?.*.?);

    // Re-subscribe dropping the filter (null): hit, filter cleared.
    try std.testing.expect(try conn.updateFilter(a, "posts", null));
    try std.testing.expect(conn.subFilter("posts").?.* == null);
}

test "requestContext: anonymous, authed, expired" {
    const a = std.testing.allocator;
    var conn = Conn{};
    defer conn.deinit(a);
    try std.testing.expect(conn.requestContext(1000).auth == null);
    var rec: std.json.ObjectMap = .empty;
    defer rec.deinit(a);
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

test "outboundOverHwm: disconnect decision boundary (issue #203)" {
    // At/under the bound: keep delivering. Strictly over: disconnect.
    try std.testing.expect(!outboundOverHwm(0, DEFAULT_OUTBOUND_HWM));
    try std.testing.expect(!outboundOverHwm(DEFAULT_OUTBOUND_HWM, DEFAULT_OUTBOUND_HWM)); // == is NOT over
    try std.testing.expect(outboundOverHwm(DEFAULT_OUTBOUND_HWM + 1, DEFAULT_OUTBOUND_HWM));
    // A small explicit bound (as an e2e test / tight operator config would set).
    try std.testing.expect(!outboundOverHwm(2, 2));
    try std.testing.expect(outboundOverHwm(3, 2));
    // hwm == 0 disables the bound entirely — never disconnects, even at a huge queue depth.
    try std.testing.expect(!outboundOverHwm(0, 0));
    try std.testing.expect(!outboundOverHwm(1_000_000, 0));
}

test "F9: global connection cap reserves/releases and rejects past MAX_CONNECTIONS" {
    // Drive the count up to the cap, confirm the next reservation is rejected, then release.
    const start = connectionCount();
    try std.testing.expectEqual(@as(usize, 0), start); // tests run single-threaded; clean slate
    // Pre-load to one below the cap without spinning MAX_CONNECTIONS times.
    live_connections.store(MAX_CONNECTIONS - 1, .monotonic);
    try std.testing.expect(reserveConnectionSlot()); // fills the last slot
    try std.testing.expectEqual(MAX_CONNECTIONS, connectionCount());
    try std.testing.expect(!reserveConnectionSlot()); // at cap -> rejected, count unchanged
    try std.testing.expectEqual(MAX_CONNECTIONS, connectionCount());
    releaseConnectionSlot();
    try std.testing.expectEqual(MAX_CONNECTIONS - 1, connectionCount());
    try std.testing.expect(reserveConnectionSlot()); // a freed slot is reusable
    // Clean up the counter so a later test sees a clean slate.
    live_connections.store(0, .monotonic);
}
