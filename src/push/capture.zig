//! Dev-only in-memory capture of outbound Web Push sends (#223), so an e2e/integration suite
//! can deterministically assert what `ctx.push().send` handed to the sender — mirroring the
//! mail outbox in `testcapture.zig`. Recording is written from the send path; the HTTP bytes
//! that actually go over the wire are separately assertable via `testcapture.http`.
//!
//! Gated by the same `dev_clock` build option as the rest of `testcapture`: on a production
//! build `enabled` is comptime-false, every `record` call is comptime-dead, and this carries
//! no runtime cost. The backing arena is over `page_allocator` (untracked by leak detection).

const std = @import("std");
const sender = @import("sender.zig");

/// Comptime gate — true only on a `dev_clock` build (Debug by default; never prod).
pub const enabled = @import("../testcapture.zig").enabled;

/// A captured push send: the target endpoint plus the notification title/body.
pub const CapturePush = struct {
    endpoint: []const u8,
    title: []const u8,
    body: []const u8,
};

fn lockMutex(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

const State = struct {
    mutex: std.atomic.Mutex = .unlocked,
    arena: ?std.heap.ArenaAllocator = null,
    list: std.ArrayListUnmanaged(CapturePush) = .empty,
    capturing: bool = false,

    fn alloc(self: *State) std.mem.Allocator {
        if (self.arena == null) self.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        return self.arena.?.allocator();
    }
};

var g: State = .{};

/// Begin capturing outbound push sends. Does not clear prior entries (use `reset`).
pub fn enable() void {
    if (!enabled) return;
    lockMutex(&g.mutex);
    defer g.mutex.unlock();
    g.capturing = true;
}

/// Stop capturing (keep already-captured entries readable).
pub fn disable() void {
    if (!enabled) return;
    lockMutex(&g.mutex);
    defer g.mutex.unlock();
    g.capturing = false;
}

/// Clear all captured entries, stop capturing, and free the backing arena.
pub fn reset() void {
    if (!enabled) return;
    lockMutex(&g.mutex);
    defer g.mutex.unlock();
    if (g.arena) |*a| a.deinit();
    g.arena = null;
    g.list = .empty;
    g.capturing = false;
}

/// Number of captured sends.
pub fn count() usize {
    if (!enabled) return 0;
    lockMutex(&g.mutex);
    defer g.mutex.unlock();
    return g.list.items.len;
}

/// The i-th captured send (slices live until the next `reset`), or null.
pub fn get(i: usize) ?CapturePush {
    if (!enabled) return null;
    lockMutex(&g.mutex);
    defer g.mutex.unlock();
    if (i >= g.list.items.len) return null;
    return g.list.items[i];
}

/// Hook called from the send path. No-op unless capture is on; OOM is swallowed so a
/// test-capture hiccup never breaks a send.
pub fn record(sub: sender.PushSubscription, msg: sender.PushMessage) void {
    if (!enabled) return;
    lockMutex(&g.mutex);
    defer g.mutex.unlock();
    if (!g.capturing) return;
    const a = g.alloc();
    const entry = CapturePush{
        .endpoint = a.dupe(u8, sub.endpoint) catch return,
        .title = a.dupe(u8, msg.title) catch return,
        .body = a.dupe(u8, msg.body) catch return,
    };
    g.list.append(a, entry) catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "capture records endpoint/title/body when enabled; no-op otherwise" {
    if (!enabled) return error.SkipZigTest;
    reset();
    defer reset();

    // Not capturing → no-op.
    record(.{ .endpoint = "https://p/x", .p256dh = "a", .auth = "b" }, .{ .title = "t" });
    try std.testing.expectEqual(@as(usize, 0), count());

    enable();
    record(.{ .endpoint = "https://push.example.com/x", .p256dh = "a", .auth = "b" }, .{ .title = "Ping", .body = "hi" });
    try std.testing.expectEqual(@as(usize, 1), count());
    const e = get(0).?;
    try std.testing.expectEqualStrings("https://push.example.com/x", e.endpoint);
    try std.testing.expectEqualStrings("Ping", e.title);
    try std.testing.expectEqualStrings("hi", e.body);
}
