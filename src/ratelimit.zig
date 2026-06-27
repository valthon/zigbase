const std = @import("std");

/// A thread-safe, fixed-window in-memory rate limiter.
///
/// Keyed on an arbitrary string (e.g. "login:1.2.3.4"). Each window allows up to
/// `max` requests per `window_s` seconds; the `(max+1)`-th request inside the same
/// window is denied. Windows are tracked per key and reset lazily on first access
/// after they expire — there is no background thread.
///
/// Concurrency: a tiny `std.atomic.Mutex` spinlock guards the whole critical section
/// (a single map lookup + update). The limiter is hit by concurrent zap worker
/// threads, so ALL map mutation happens under the lock. The critical section is
/// O(1) in the common path; the bounded-table sweep (below) is the only O(n) path
/// and runs rarely.
///
/// Bounded memory: the map is capped at `max_entries`. When full and a new key
/// arrives, expired entries are swept first; if the table is still full afterward,
/// the limiter FAILS OPEN (allows the request) rather than evicting a live entry or
/// growing unbounded. Failing open keeps the limiter from becoming a DoS vector
/// against itself (a flood of distinct keys can't OOM the process), at the cost of
/// not limiting brand-new keys while the table is saturated with live windows.
///
/// Clock injection: `allow` takes `now_s` from the caller (wall clock in prod), so
/// the limiter is deterministically unit-testable.
pub const RateLimiter = struct {
    // `window_s` is the entry's EFFECTIVE window (the per-call value from allowCustom),
    // stored so the bounded-table sweep expires each bucket by ITS OWN window rather than
    // the limiter's global default — a custom bucket with a longer window must not be
    // reclaimed (and its counter reset) early just because the global window elapsed.
    const Entry = struct { count: u32, window_start: i64, window_s: i64 };

    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(Entry) = .empty,
    mutex: std.atomic.Mutex = .unlocked,
    max: u32,
    window_s: i64,
    max_entries: usize,

    pub fn init(allocator: std.mem.Allocator, max: u32, window_s: i64) RateLimiter {
        return .{
            .allocator = allocator,
            .max = max,
            .window_s = window_s,
            .max_entries = 4096,
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        self.lock();
        defer self.unlock();
        var it = self.map.iterator();
        while (it.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.map.deinit(self.allocator);
    }

    fn lock(self: *RateLimiter) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *RateLimiter) void {
        self.mutex.unlock();
    }

    /// Returns true if the request keyed by `key` is allowed at time `now_s`
    /// (and records it), false if it exceeds the window's `max`.
    ///
    /// A `max` of 0 means "disabled" — always allow (callers also skip wiring the
    /// limiter entirely when max==0, this is just defensive).
    ///
    /// Uses this limiter's configured `max`/`window_s`; for a per-call override (e.g. a
    /// per-auth-method limit sharing this same store/mutex) use `allowCustom`.
    pub fn allow(self: *RateLimiter, key: []const u8, now_s: i64) bool {
        return self.allowCustom(key, now_s, self.max, self.window_s);
    }

    /// Like `allow`, but enforces the caller-supplied `max`/`window_s` against `key`'s
    /// bucket instead of the limiter's configured defaults. This lets a single shared
    /// store (one map + one mutex) host independently-budgeted buckets — e.g. per
    /// auth-method limits whose `key` carries the collection + method slug — without a
    /// separate limiter instance per configuration. Buckets are isolated purely by `key`.
    pub fn allowCustom(self: *RateLimiter, key: []const u8, now_s: i64, max: u32, window_s: i64) bool {
        if (max == 0) return true;
        self.lock();
        defer self.unlock();

        if (self.map.getPtr(key)) |e| {
            if (now_s - e.window_start >= window_s) {
                // Refresh window_s too so a changed config window takes effect on reset.
                e.* = .{ .count = 1, .window_start = now_s, .window_s = window_s };
                return true;
            }
            if (e.count < max) {
                e.count += 1;
                return true;
            }
            return false;
        }

        // New key. Enforce the memory cap before inserting.
        if (self.map.count() >= self.max_entries) {
            self.sweepExpired(now_s);
            // Still full after sweeping out expired windows: fail open. We refuse to
            // evict a live entry (that would let an attacker reset another victim's
            // window) and refuse to grow unbounded (OOM/DoS). Allowing the request is
            // the safe-against-self choice.
            if (self.map.count() >= self.max_entries) return true;
        }

        const owned = self.allocator.dupe(u8, key) catch return true; // alloc fail => fail open
        self.map.put(self.allocator, owned, .{ .count = 1, .window_start = now_s, .window_s = window_s }) catch {
            self.allocator.free(owned);
            return true;
        };
        return true;
    }

    /// Remove every entry whose window has elapsed. Caller must hold the lock.
    fn sweepExpired(self: *RateLimiter, now_s: i64) void {
        var it = self.map.iterator();
        // Collect-then-remove would need an allocation; instead remove during a
        // re-scan. StringHashMap's iterator is invalidated by removal, so loop until
        // a full pass removes nothing.
        var removed_any = true;
        while (removed_any) {
            removed_any = false;
            it = self.map.iterator();
            while (it.next()) |kv| {
                // Expire each entry by ITS OWN effective window, not the global default.
                if (now_s - kv.value_ptr.window_start >= kv.value_ptr.window_s) {
                    const k = kv.key_ptr.*;
                    _ = self.map.remove(k);
                    self.allocator.free(k);
                    removed_any = true;
                    break;
                }
            }
        }
    }
};

test "max requests allowed, max+1 denied within window" {
    var rl = RateLimiter.init(std.testing.allocator, 3, 60);
    defer rl.deinit();
    try std.testing.expect(rl.allow("k", 100));
    try std.testing.expect(rl.allow("k", 101));
    try std.testing.expect(rl.allow("k", 102));
    try std.testing.expect(!rl.allow("k", 103)); // 4th in window => denied
    try std.testing.expect(!rl.allow("k", 159)); // still in window
}

test "window advance resets the counter" {
    var rl = RateLimiter.init(std.testing.allocator, 2, 60);
    defer rl.deinit();
    try std.testing.expect(rl.allow("k", 0));
    try std.testing.expect(rl.allow("k", 30));
    try std.testing.expect(!rl.allow("k", 40)); // denied within window
    try std.testing.expect(rl.allow("k", 60)); // now - window_start = 60 >= 60 => reset
    try std.testing.expect(rl.allow("k", 70));
    try std.testing.expect(!rl.allow("k", 80));
}

test "different keys are independent" {
    var rl = RateLimiter.init(std.testing.allocator, 1, 60);
    defer rl.deinit();
    try std.testing.expect(rl.allow("a", 0));
    try std.testing.expect(rl.allow("b", 0)); // separate key, fresh budget
    try std.testing.expect(!rl.allow("a", 1));
    try std.testing.expect(!rl.allow("b", 1));
}

test "allowCustom honors per-call max/window independent of init defaults" {
    // Init with deliberately different defaults (max=100, window=1) to prove the
    // per-call args win and the limiter's own max/window are ignored.
    var rl = RateLimiter.init(std.testing.allocator, 100, 1);
    defer rl.deinit();
    try std.testing.expect(rl.allowCustom("k", 0, 2, 60));
    try std.testing.expect(rl.allowCustom("k", 10, 2, 60));
    try std.testing.expect(!rl.allowCustom("k", 20, 2, 60)); // 3rd within window => denied
    try std.testing.expect(!rl.allowCustom("k", 59, 2, 60)); // still in window
    try std.testing.expect(rl.allowCustom("k", 60, 2, 60)); // window elapsed => reset
    try std.testing.expect(rl.allowCustom("k", 61, 2, 60));
    try std.testing.expect(!rl.allowCustom("k", 62, 2, 60));
}

test "allowCustom buckets are isolated by key" {
    var rl = RateLimiter.init(std.testing.allocator, 0, 60); // global disabled (max=0)
    defer rl.deinit();
    // Even with the limiter's own max==0 (global off), per-call custom limits apply.
    try std.testing.expect(rl.allowCustom("a", 0, 1, 60));
    try std.testing.expect(rl.allowCustom("b", 0, 1, 60)); // separate key, fresh budget
    try std.testing.expect(!rl.allowCustom("a", 1, 1, 60));
    try std.testing.expect(!rl.allowCustom("b", 1, 1, 60));
}

test "max == 0 disables limiting" {
    var rl = RateLimiter.init(std.testing.allocator, 0, 60);
    defer rl.deinit();
    var i: usize = 0;
    while (i < 100) : (i += 1) try std.testing.expect(rl.allow("k", 0));
}

test "cap + eviction does not crash and fails open when saturated with live windows" {
    var rl = RateLimiter.init(std.testing.allocator, 1, 1000);
    rl.max_entries = 8; // small cap for the test
    defer rl.deinit();

    // Fill the table with distinct live keys.
    var buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const k = try std.fmt.bufPrint(&buf, "k{d}", .{i});
        try std.testing.expect(rl.allow(k, 0));
    }
    try std.testing.expectEqual(@as(usize, 8), rl.map.count());

    // Table full of live windows: a brand-new key fails open (allowed) and is NOT inserted.
    try std.testing.expect(rl.allow("overflow", 0));
    try std.testing.expectEqual(@as(usize, 8), rl.map.count());

    // Advance past the window: a new key now triggers a sweep that frees expired
    // entries, then inserts successfully. Must not crash or leak.
    try std.testing.expect(rl.allow("fresh", 2000));
    try std.testing.expect(rl.map.count() <= 8);
}

test "sweepExpired expires each entry by its own window, not the global default" {
    var rl = RateLimiter.init(std.testing.allocator, 1, 60); // global window_s = 60
    defer rl.deinit();

    // Two buckets created at t=0: a short custom window (10) and a long custom window (10000).
    try std.testing.expect(rl.allowCustom("short", 0, 1, 10));
    try std.testing.expect(rl.allowCustom("long", 0, 1, 10000));
    try std.testing.expectEqual(@as(usize, 2), rl.map.count());

    // t=100 is past the GLOBAL window (60) and the short entry's window (10), but well
    // within the long entry's window (10000). A sweep keyed on the global window would
    // wrongly evict "long"; per-entry windows must reclaim ONLY "short".
    rl.sweepExpired(100);
    try std.testing.expect(rl.map.get("short") == null); // own window elapsed => reclaimed
    try std.testing.expect(rl.map.get("long") != null); // own window NOT elapsed => kept

    // The kept long bucket still enforces its (max=1) budget — its counter was NOT reset
    // by an early eviction, so a second attempt inside the long window is still denied.
    try std.testing.expect(!rl.allowCustom("long", 100, 1, 10000));

    // Past the long window too: now it is reclaimable.
    rl.sweepExpired(20000);
    try std.testing.expect(rl.map.get("long") == null);
}
