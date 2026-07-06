//! Error-report TTL dedup (#244 stage 2). A tiny, bounded, in-process suppression cache
//! consulted by `events.dispatchError` BEFORE it enqueues a `"report"` job: two identical
//! reports — same `(message, phase)` — within `window_s` produce only ONE delivery. It
//! prevents a hot loop (a request path erroring thousands of times a second) from
//! flooding the reporter backend (Sentry) with the same event.
//!
//! COMPTIME-GATED / ZERO-COST WHEN OFF: the window is a comptime knob (`.reporter_dedup`).
//! When `.off`, `serveImpl` never constructs a `Dedup` and leaves `app.report_dedup` null,
//! so `dispatchError`'s dedup check is a single null-pointer branch and NO map is ever
//! allocated (no heap, no timer). When enabled (the default), one `Dedup` lives on the
//! boot holder for the app's lifetime.
//!
//! THREAD-SAFE: `dispatchError` fires from many threads (HTTP workers, the scheduler, the
//! memory-queue pool). A small `std.atomic.Mutex` spinlock guards the whole map — the
//! critical section is a single hashmap lookup + insert, so contention is negligible and
//! it never blocks on I/O.
//!
//! BOUNDED: the map holds at most `max_entries` distinct keys; on overflow it is coarsely
//! cleared (best-effort dedup beats unbounded growth — the worst case is a few extra
//! reports right after a clear). Expired entries are not swept eagerly: a stale entry only
//! wastes a slot until its key recurs (at which point the age check reports and refreshes
//! it) or the map overflows and clears — a stale entry NEVER causes a false suppression.

const std = @import("std");
const clock = @import("../clock.zig");

/// Default dedup window (seconds) when `.reporter_dedup` is omitted: dedup is ON by
/// default with a modest 60s window.
pub const default_window_s: i64 = 60;

/// Hard cap on distinct tracked keys. 1024 * (u64 key + i64 ts) ≈ 16 KiB of entries —
/// trivial, and coarse-cleared on overflow so memory is bounded regardless of error
/// cardinality.
pub const max_entries: usize = 1024;

/// In-process, mutex-guarded, TTL-windowed suppression cache keyed by an FNV-1a hash of
/// `(message ++ 0x00 ++ phase)`. Installed on `app.report_dedup` by `serveImpl` only when
/// the configured window is > 0.
pub const Dedup = struct {
    mutex: std.atomic.Mutex = .unlocked,
    /// key (hash of message+phase) -> last-reported unix timestamp (seconds).
    seen: std.AutoHashMapUnmanaged(u64, i64) = .empty,
    window_s: i64,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, window_s: i64) Dedup {
        return .{ .alloc = alloc, .window_s = window_s };
    }

    pub fn deinit(self: *Dedup) void {
        self.lock();
        defer self.unlock();
        self.seen.deinit(self.alloc);
        self.seen = .empty;
    }

    fn lock(self: *Dedup) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Dedup) void {
        self.mutex.unlock();
    }

    /// Hash `(message, phase)` into the dedup key. The 0x00 separator prevents a
    /// `message="ab"/phase="c"` vs `message="a"/phase="bc"` collision.
    pub fn key(message: []const u8, phase: []const u8) u64 {
        var h = std.hash.Fnv1a_64.init();
        h.update(message);
        h.update("\x00");
        h.update(phase);
        return h.final();
    }

    /// Returns true iff this report should be DELIVERED now — the first sighting of
    /// `(message, phase)`, or one whose previous sighting is older than `window_s`.
    /// Returns false for a duplicate seen within the window (suppress). Thread-safe.
    /// Reads "now" through the framework clock seam (honors a frozen dev clock).
    ///
    /// Fails OPEN: any allocation failure inserting the key returns true (report). Dedup is
    /// a best-effort noise reducer — it must never DROP a report because it ran out of memory.
    pub fn shouldReport(self: *Dedup, io: std.Io, message: []const u8, phase: []const u8) bool {
        return self.shouldReportAt(clock.nowUnix(io), message, phase);
    }

    /// `shouldReport` with an explicit `now` (unix seconds). The timestamp-injecting core;
    /// unit tests drive it directly for deterministic window math with no clock dependency.
    pub fn shouldReportAt(self: *Dedup, now: i64, message: []const u8, phase: []const u8) bool {
        const k = key(message, phase);
        self.lock();
        defer self.unlock();
        if (self.seen.get(k)) |last| {
            // Within the window → a duplicate. Do NOT slide `last`: a steady stream of the
            // same error still reports exactly once per window rather than being suppressed
            // forever.
            //
            // Guard `now < last` explicitly before subtracting: if the wall clock jumps
            // BACKWARD (e.g. an NTP correction), `now - last` would be negative and always
            // `< window_s`, silently suppressing the report until wall time catches back up.
            // Dedup is fail-OPEN/best-effort — a clock going backward must never cause a
            // drop, so treat it as a fresh sighting (report, and the code below refreshes
            // the stored timestamp to `now`).
            if (now >= last and now - last < self.window_s) return false;
        }
        // Bound growth: on overflow, coarsely clear. Cheaper than per-entry sweeping and
        // acceptable for a best-effort cache (worst case: a few dupes slip right after).
        if (self.seen.count() >= max_entries) self.seen.clearRetainingCapacity();
        self.seen.put(self.alloc, k, now) catch return true; // fail open
        return true;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "dedup: identical (message,phase) within the window reports once; window expiry re-reports" {
    var dd = Dedup.init(testing.allocator, 60);
    defer dd.deinit();

    // First sighting reports; immediate repeat is suppressed.
    try testing.expect(dd.shouldReportAt(1_000, "boom", "request"));
    try testing.expect(!dd.shouldReportAt(1_000, "boom", "request"));
    try testing.expect(!dd.shouldReportAt(1_030, "boom", "request"));

    // A different message reports (distinct key).
    try testing.expect(dd.shouldReportAt(1_000, "other", "request"));
    // Same message, different phase → distinct key → reports.
    try testing.expect(dd.shouldReportAt(1_000, "boom", "job"));

    // Past the window (>= 60s after the last delivery) → the original key reports again.
    try testing.expect(dd.shouldReportAt(1_061, "boom", "request"));
    // ...and is suppressed again immediately after.
    try testing.expect(!dd.shouldReportAt(1_061, "boom", "request"));
}

test "dedup: a steady stream still reports once per window, not forever-suppressed" {
    var dd = Dedup.init(testing.allocator, 10);
    defer dd.deinit();

    var reports: usize = 0;
    // 100 seconds, one hit per second, window 10s.
    var s: i64 = 0;
    while (s < 100) : (s += 1) {
        if (dd.shouldReportAt(s, "loop", "request")) reports += 1;
    }
    // Report at t=0, then every time 10s have elapsed since the last report: t=10,20,...,90 → 10.
    try testing.expectEqual(@as(usize, 10), reports);
}

test "dedup: key distinguishes message vs phase boundary" {
    // The 0x00 separator must make these two distinct.
    try testing.expect(Dedup.key("ab", "c") != Dedup.key("a", "bc"));
    // Identical inputs hash equal.
    try testing.expectEqual(Dedup.key("x", "request"), Dedup.key("x", "request"));
}

test "dedup: backward clock skew never suppresses (fail-open, no drop)" {
    var dd = Dedup.init(testing.allocator, 60);
    defer dd.deinit();

    // Establish the key at t=100_000.
    try testing.expect(dd.shouldReportAt(100_000, "boom", "request"));
    // Normal in-window repeat is suppressed, as usual.
    try testing.expect(!dd.shouldReportAt(100_010, "boom", "request"));

    // Clock jumps far BACKWARD (e.g. an NTP correction) — `now < last`. Must NOT be
    // suppressed: a naive `now - last < window_s` would underflow-negative and always
    // read as "within window", dropping the report forever until wall time caught up.
    try testing.expect(dd.shouldReportAt(1_000, "boom", "request"));
    // The timestamp is refreshed to the new (earlier) `now`, so an immediate repeat at
    // that same clock reading is suppressed again — dedup resumes normally post-skew.
    try testing.expect(!dd.shouldReportAt(1_000, "boom", "request"));
}

test "dedup: overflow clears the map (bounded) without false-suppressing new keys" {
    var dd = Dedup.init(testing.allocator, 3600);
    defer dd.deinit();

    // Insert exactly max_entries distinct keys — all report (all first sightings).
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < max_entries) : (i += 1) {
        const msg = std.fmt.bufPrint(&buf, "err-{d}", .{i}) catch unreachable;
        try testing.expect(dd.shouldReportAt(0, msg, "request"));
    }
    try testing.expectEqual(max_entries, dd.seen.count());
    // The next distinct key overflows → clear → still reports (never suppressed by overflow).
    try testing.expect(dd.shouldReportAt(0, "overflow-key", "request"));
    // Map was cleared then got the one new key.
    try testing.expectEqual(@as(usize, 1), dd.seen.count());
}
