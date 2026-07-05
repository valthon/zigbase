//! In-process cache of the feature-flag / experiment `_kv` overrides (#230).
//!
//! Steady-state flag/experiment resolution used to hit `_kv` on EVERY request: the
//! `resolveAll` whole-set `flag:*`/`exp:*` scan and the per-key `flag:<name>` /
//! `exp:<name>:weights` reads. This cache serves the CURRENT override snapshot from
//! memory so a hot path costs zero DB reads.
//!
//! ## Relationship to colcache.zig
//! Borrows colcache's discipline — a spinlock (`std.atomic.Mutex` tryLock spin), a
//! monotonic version counter, an explicit `invalidate()` contract called by every
//! override-write path, an allocation-free critical section, and refcounted immutable
//! snapshots so an in-flight reader keeps its snapshot alive after a concurrent rescan
//! swaps `current`. The KEY DIFFERENCE: colcache is SQLite-only (it skips Postgres to
//! avoid cross-instance staleness). This cache installs on BOTH backends, because the
//! override set is tiny and coherence is bounded two ways:
//!   1. **Same-instance writes are instant.** Every override-write site
//!      (`ctx.writeFlagOverride`, `api/settings.put`/`delete`) calls `invalidate()`
//!      unconditionally — NOT gated on the realtime reactor — so the next resolution
//!      re-scans and sees the new value. A kill-switch flip takes effect on the next
//!      request.
//!   2. **Cross-instance (Postgres) writes self-heal in ≤ `ttl_ms`.** A published
//!      snapshot older than the TTL is re-scanned even if no local write bumped the
//!      version, so a remote instance's override becomes visible within the window.
//!
//! ## Transactional reads bypass the cache
//! The cache is consulted/published ONLY for pooled-reader reads. A read on a bound
//! writer connection (inside `ctx.tx` / a before-hook) reads DIRECTLY so it (a) sees the
//! transaction's own uncommitted override writes and (b) never publishes uncommitted
//! state into the shared snapshot. See ctx.zig's read sites.

const std = @import("std");
const db = @import("db.zig");
const Data = @import("data.zig").Data;
const features_resolver = @import("features_resolver.zig");

/// The `_kv` key prefixes that make up the feature-override set. Both the whole-set
/// scan and the per-key lookups operate on exactly these.
pub const override_prefixes: []const []const u8 = &.{ "flag:", "exp:" };

/// Real-time staleness bound (milliseconds) for cross-instance coherence. A published
/// snapshot older than this is re-scanned even with an unchanged version, so another
/// instance's override write self-heals within the window. Named constant; the per-cache
/// `ttl_ms` field defaults to it and is overridable (a test sets a tiny TTL).
///
/// This is a REAL-TIME bound: it is measured on a MONOTONIC clock (`std.Io.Clock.awake`),
/// NOT wall-clock and NOT the framework's `ZIGBASE_FAKE_NOW` logical clock — a frozen test
/// clock must not be able to freeze the staleness window.
pub const default_ttl_ms: i64 = 5_000;

/// Monotonic milliseconds since some unspecified epoch. `Clock.awake` == `CLOCK_MONOTONIC`
/// on Linux / `CLOCK_UPTIME_RAW` on macOS — never affected by wall-clock jumps and never
/// frozen by `ZIGBASE_FAKE_NOW` (which only overrides the `real` clock).
fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// An immutable, refcounted override snapshot: the `flag:*`/`exp:*` `_kv` entries as a
/// key→value map, all allocated on the entry's OWN arena (so it is independent of any
/// request arena). Threaded off the cache's `current` pointer; refcounted so a reader
/// borrowing it survives a concurrent rescan that swaps `current`.
const Entry = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged([]const u8) = .empty,
    refs: std.atomic.Value(usize),
    /// The `version` value this snapshot was scanned at. Served only while it still
    /// equals the live `version` (an override write bumps `version`, forcing a rescan).
    loaded_version: u64,
    /// Monotonic-ms timestamp of the scan; drives the TTL self-heal.
    loaded_at_ms: i64,
};

/// A borrowed handle onto an immutable snapshot. The map behind it is READ-ONLY and owned
/// by the cache entry — do not mutate it, and copy any value you retain past `release()`
/// into your own arena. `release()` drops this borrower's ref (the last holder frees it).
pub const Snapshot = struct {
    cache: *FeatureOverrideCache,
    entry: *Entry,

    /// The override value for `key`, or null if absent. Borrowed from the snapshot arena.
    pub fn get(self: Snapshot, key: []const u8) ?[]const u8 {
        return self.entry.map.get(key);
    }

    /// Iterate every (key, value) override entry (borrowed).
    pub fn iterator(self: Snapshot) std.StringHashMapUnmanaged([]const u8).Iterator {
        return self.entry.map.iterator();
    }

    /// Number of override entries in the snapshot.
    pub fn count(self: Snapshot) usize {
        return self.entry.map.count();
    }

    pub fn release(self: *Snapshot) void {
        self.cache.unref(self.entry);
    }
};

pub const FeatureOverrideCache = struct {
    gpa: std.mem.Allocator,
    /// Guards `current` (publish/acquire). Same spinlock precedent as colcache / the
    /// reader pool. `version` is a lock-free atomic so `invalidate()` never blocks a reader.
    mutex: std.atomic.Mutex = .unlocked,
    current: ?*Entry = null,
    /// Bumped by `invalidate()` on every override write. A snapshot is served only while
    /// its `loaded_version` equals this, so any write forces the next resolution to rescan.
    version: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Real-time staleness bound (ms). Defaults to `default_ttl_ms`; a test overrides it.
    ttl_ms: i64 = default_ttl_ms,

    pub fn init(gpa: std.mem.Allocator) FeatureOverrideCache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *FeatureOverrideCache) void {
        // Assumes no in-flight borrowers (the server has stopped), like colcache.deinit.
        self.lockC();
        const c = self.current;
        self.current = null;
        self.unlockC();
        if (c) |e| self.unref(e);
    }

    fn lockC(self: *FeatureOverrideCache) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlockC(self: *FeatureOverrideCache) void {
        self.mutex.unlock();
    }

    /// Drop one reference; the LAST holder frees the entry (its arena owns the map + strings).
    fn unref(self: *FeatureOverrideCache, e: *Entry) void {
        if (e.refs.fetchSub(1, .acq_rel) == 1) {
            e.arena.deinit();
            self.gpa.destroy(e);
        }
    }

    /// Bump the version so the next `snapshot`/`get` re-scans. O(1), lock-free, never
    /// blocks a reader. MUST be called by every path that mutates a `flag:*`/`exp:*:weights`
    /// `_kv` entry, AFTER the write is committed (or, on the transactional path, both at the
    /// write site and again post-commit — see ctx.zig). Idempotent and cheap to over-call.
    pub fn invalidate(self: *FeatureOverrideCache) void {
        _ = self.version.fetchAdd(1, .acq_rel);
    }

    /// Return the current override snapshot as a borrowed, refcounted handle. Serves the
    /// cached snapshot when `loaded_version == version` AND its age `< ttl_ms`; otherwise
    /// re-scans `_kv` (`kvScanPrefix(flag:,exp:)`) OUTSIDE the lock into a fresh entry arena
    /// and publishes it under the lock (unless a concurrent `invalidate()` raced the scan,
    /// in which case the fresh scan is returned to THIS caller but not cached).
    ///
    /// The caller MUST `release()` the returned handle. A scan error is propagated so the
    /// caller can degrade to a direct read (it must NEVER fail a flag resolution).
    pub fn snapshot(self: *FeatureOverrideCache, io: std.Io, data: Data) !Snapshot {
        const now_ms = nowMs(io);

        // Fast path: a fresh, version-current cached entry.
        self.lockC();
        if (self.current) |e| {
            if (e.loaded_version == self.version.load(.acquire) and (now_ms - e.loaded_at_ms) < self.ttl_ms) {
                _ = e.refs.fetchAdd(1, .acq_rel);
                self.unlockC();
                return .{ .cache = self, .entry = e };
            }
        }
        const gen = self.version.load(.acquire);
        self.unlockC();

        // Miss: scan OUTSIDE the lock into a fresh entry arena. The entry OWNS its strings
        // (scan results allocated on the entry arena), so it outlives the caller's request.
        const e = try self.gpa.create(Entry);
        errdefer self.gpa.destroy(e);
        e.* = .{
            .arena = std.heap.ArenaAllocator.init(self.gpa),
            .refs = std.atomic.Value(usize).init(1), // the caller's ref
            .loaded_version = gen,
            .loaded_at_ms = now_ms,
        };
        errdefer e.arena.deinit();
        const a = e.arena.allocator();
        const scan_data = Data{ .app = data.app, .conn = data.conn, .io = data.io, .alloc = a };
        const entries = try scan_data.kvScanPrefix(override_prefixes);
        for (entries) |kv| try e.map.put(a, kv.key, kv.value);

        // Publish under the lock unless our scan raced an `invalidate()` (stale generation)
        // or lost to a concurrent publisher. Publishing gives the entry a second (cache) ref
        // and detaches the previous `current`, whose cache ref is dropped OUTSIDE the lock.
        var old: ?*Entry = null;
        self.lockC();
        if (self.version.load(.acquire) == gen) {
            old = self.current;
            _ = e.refs.fetchAdd(1, .acq_rel); // the cache's ref
            self.current = e;
        }
        self.unlockC();
        if (old) |o| self.unref(o);
        return .{ .cache = self, .entry = e };
    }

    /// Per-key override lookup served from the same snapshot (for `resolveFlag` / the
    /// experiment weight override). Returns a copy on `data.alloc` (matching `Data.kvGet`
    /// semantics — lifetime is the caller's arena), so there is no borrow to manage.
    pub fn get(self: *FeatureOverrideCache, io: std.Io, data: Data, key: []const u8) !?[]const u8 {
        var snap = try self.snapshot(io, data);
        defer snap.release();
        const v = snap.get(key) orelse return null;
        return try data.alloc.dupe(u8, v);
    }
};

/// Build the `flag:*` / `exp:*:weights` override `KvPair` list that `features_resolver.resolveAll`
/// consumes, consulting the cache when one is installed AND this is a pooled-reader read
/// (`bound == false`); otherwise a direct `_kv` scan. Degrade-safe: a cache-scan error falls back
/// to the direct scan (resolution never fails on the cache). SHARED by `ctx.flags().resolveAll`
/// and the `/api/state` projection so BOTH get zero-read steady-state resolution — the public
/// projection is the motivating hot path (#230), so it must route through the cache too.
pub fn overridePairs(alloc: std.mem.Allocator, io: std.Io, fc: ?*FeatureOverrideCache, bound: bool, data: Data) ![]features_resolver.KvPair {
    if (!bound) {
        if (fc) |c| {
            if (c.snapshot(io, data)) |snap_val| {
                var snap = snap_val;
                defer snap.release();
                const pairs = try alloc.alloc(features_resolver.KvPair, snap.count());
                var it = snap.iterator();
                var i: usize = 0;
                while (it.next()) |ent| : (i += 1) {
                    pairs[i] = .{
                        .key = try alloc.dupe(u8, ent.key_ptr.*),
                        .value = try alloc.dupe(u8, ent.value_ptr.*),
                    };
                }
                return pairs;
            } else |_| {
                // Cache scan failed → degrade to a direct scan (never fail resolution).
            }
        }
    }
    const entries = try data.kvScanPrefix(&.{ "flag:", "exp:" });
    const pairs = try alloc.alloc(features_resolver.KvPair, entries.len);
    for (entries, 0..) |e, i| pairs[i] = .{ .key = e.key, .value = e.value };
    return pairs;
}

// ---------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------

const testing = std.testing;
const migrations = @import("migrations.zig");

fn testDb() !db.Db {
    var d = try db.Db.openMemory();
    errdefer d.close();
    try migrations.run(&d);
    return d;
}

fn dataFor(d: *db.Db, a: std.mem.Allocator) Data {
    return .{ .app = undefined, .conn = d, .io = testing.io, .alloc = a };
}

test "feature_cache: instant local invalidation makes the next snapshot see the write" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try testDb();
    defer d.close();
    var cache = FeatureOverrideCache.init(testing.allocator);
    defer cache.deinit();

    const data = dataFor(&d, a);

    // No override → absent.
    {
        var s = try cache.snapshot(testing.io, data);
        defer s.release();
        try testing.expect(s.get("flag:beta") == null);
    }

    // Write an override + invalidate (mirrors the ctx.writeFlagOverride site).
    try data.kvSet("flag:beta", "true");
    cache.invalidate();

    // The very next snapshot re-scans and sees it — NO TTL wait.
    var s2 = try cache.snapshot(testing.io, data);
    defer s2.release();
    try testing.expectEqualStrings("true", s2.get("flag:beta").?);
}

test "feature_cache: a version-current snapshot is served WITHOUT re-scanning (cache hit)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try testDb();
    defer d.close();
    var cache = FeatureOverrideCache.init(testing.allocator);
    defer cache.deinit();

    try d.exec("INSERT INTO \"_kv\"(key,value,created,updated) VALUES ('flag:beta','true','x','x');");
    const data = dataFor(&d, a);

    var s1 = try cache.snapshot(testing.io, data);
    const first_entry = s1.entry;
    s1.release();

    // Prove the second snapshot does NOT touch the DB: rename `_kv` so any re-scan would
    // fail with "no such table". A clean hit (same entry pointer) proves it served from cache.
    try d.exec("ALTER TABLE \"_kv\" RENAME TO \"_kv_hidden\";");
    var s2 = try cache.snapshot(testing.io, data);
    defer s2.release();
    try testing.expect(s2.entry == first_entry); // same cached entry — no re-scan
    try testing.expectEqualStrings("true", s2.get("flag:beta").?);
}

test "feature_cache: an entry older than the TTL is re-scanned (cross-instance self-heal)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try testDb();
    defer d.close();
    var cache = FeatureOverrideCache.init(testing.allocator);
    cache.ttl_ms = 5; // tiny injected TTL
    defer cache.deinit();

    const data = dataFor(&d, a);

    // Load a snapshot with no override.
    {
        var s = try cache.snapshot(testing.io, data);
        defer s.release();
        try testing.expect(s.get("flag:beta") == null);
    }

    // Simulate a REMOTE instance's write that did NOT invalidate this process: change `_kv`
    // directly WITHOUT calling invalidate() (version stays the same).
    try data.kvSet("flag:beta", "true");

    // Before the window elapses, the stale snapshot is still served (no override seen).
    {
        var s = try cache.snapshot(testing.io, data);
        defer s.release();
        try testing.expect(s.get("flag:beta") == null);
    }

    // Age the cached entry past the TTL (deterministic — no sleeping) and re-snapshot: the
    // TTL forces a re-scan even though the version is unchanged, picking up the remote write.
    cache.current.?.loaded_at_ms -= cache.ttl_ms + 1000;
    var s3 = try cache.snapshot(testing.io, data);
    defer s3.release();
    try testing.expectEqualStrings("true", s3.get("flag:beta").?);
}

test "feature_cache: get() serves per-key lookups and is invalidated instantly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try testDb();
    defer d.close();
    var cache = FeatureOverrideCache.init(testing.allocator);
    defer cache.deinit();

    const data = dataFor(&d, a);

    try testing.expect((try cache.get(testing.io, data, "flag:beta")) == null);
    try data.kvSet("flag:beta", "true");
    cache.invalidate();
    try testing.expectEqualStrings("true", (try cache.get(testing.io, data, "flag:beta")).?);
    // exp:*:weights lookups are served from the same snapshot.
    try data.kvSet("exp:layout:weights", "[10,90]");
    cache.invalidate();
    try testing.expectEqualStrings("[10,90]", (try cache.get(testing.io, data, "exp:layout:weights")).?);
}

test "feature_cache: only flag:/exp: keys are cached; unrelated settings are ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try testDb();
    defer d.close();
    var cache = FeatureOverrideCache.init(testing.allocator);
    defer cache.deinit();

    const data = dataFor(&d, a);
    try data.kvSet("flag:beta", "true");
    try data.kvSet("exp:layout:weights", "[1,2]");
    try data.kvSet("smtp_host", "mail.example.com"); // unrelated setting

    var s = try cache.snapshot(testing.io, data);
    defer s.release();
    try testing.expectEqual(@as(usize, 2), s.count());
    try testing.expect(s.get("smtp_host") == null);
    try testing.expectEqualStrings("true", s.get("flag:beta").?);
    try testing.expectEqualStrings("[1,2]", s.get("exp:layout:weights").?);
}

test "feature_cache: a scan error is surfaced (caller degrades to a direct read)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try db.Db.openMemory(); // NO migrations → no `_kv` table
    defer d.close();
    var cache = FeatureOverrideCache.init(testing.allocator);
    defer cache.deinit();

    const data = dataFor(&d, a);
    // The scan errors (missing table) rather than panicking — the ctx call site catches
    // this and falls back to a direct read, so a flag resolution never fails on the cache.
    try testing.expectError(error.PrepareFailed, cache.snapshot(testing.io, data));
}

test "feature_cache: in-flight snapshot survives a concurrent invalidate + rescan (refcount)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try testDb();
    defer d.close();
    var cache = FeatureOverrideCache.init(testing.allocator);
    defer cache.deinit();

    try d.exec("INSERT INTO \"_kv\"(key,value,created,updated) VALUES ('flag:beta','true','x','x');");
    const data = dataFor(&d, a);

    // Hold a borrow, then invalidate + take a fresh snapshot (swaps `current`, drops the
    // old cache ref). The held borrow must stay valid (refcount keeps the detached entry).
    var held = try cache.snapshot(testing.io, data);
    cache.invalidate();
    var fresh = try cache.snapshot(testing.io, data);
    try testing.expect(fresh.entry != held.entry); // a new snapshot was published
    try testing.expectEqualStrings("true", held.get("flag:beta").?); // still usable
    held.release(); // last ref on the detached entry frees it (leak check = the allocator)
    fresh.release();
}
