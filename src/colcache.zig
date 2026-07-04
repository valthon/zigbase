//! Versioned, refcounted collection-metadata cache (R1-4 / audit F4+F7).
//!
//! Every record API request and every realtime fan-out delivery re-read a collection row
//! and re-parsed its schema/indexes/options JSON. This cache keeps the PARSED
//! `schema.Collection` (each entry in its own arena), keyed by the name/id string passed
//! to `collections.get`, including NEGATIVE entries ("not a collection" — realtime custom
//! topics hit that lookup on every event).
//!
//! CONCURRENCY: a spinlock (std.atomic.Mutex, same precedent as the reader pool) guards
//! an O(1) map lookup + refcount bump. No lock is held while an entry is in use: entries
//! are IMMUTABLE (callers must never write through the returned Collection) and
//! refcounted — the map holds one ref, each borrower one. invalidate() bumps `generation`
//! and detaches every entry under the lock, dropping the map refs outside it; the last
//! releaser frees the entry arena, so in-flight requests keep their (now-stale) snapshot
//! safely until they finish. The critical section is ALLOCATION-FREE: entries are threaded
//! onto an intrusive `Entry.next` list (plain pointer writes) rather than pushed into a heap
//! list, and both the entry arenas and the map keys (each entry owns its key) are freed only
//! after the lock is released — so the spinlock never covers an allocator call. The
//! generation counter closes the load/invalidate race: a miss snapshots it BEFORE the DB read
//! and only publishes on an unchanged generation.
//!
//! INVALIDATION CONTRACT: every runtime collection-DDL path must call `invalidate()` —
//! today that is exactly the three api/collections.zig handlers (create/update/delete).
//! Startup provisioning and CLI migrations run before/without a serving cache. The cache
//! is installed ONLY for the SQLite backend (single-process by construction): on Postgres
//! another instance could ALTER collections without this process noticing, so serveImpl
//! skips the cache there (reads stay direct) rather than risk cross-instance staleness.

const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const collections = @import("collections.zig");

pub const Entry = struct {
    arena: std.heap.ArenaAllocator,
    col: ?schema.Collection, // parsed from the entry's own arena; null = negative entry
    refs: std.atomic.Value(usize),
    /// The map key this entry is published under (duped by `publish`). The entry OWNS it
    /// and frees it when the last ref drops, so `invalidate()` can detach without touching
    /// the allocator under the lock. Empty until published; an unpublished entry never
    /// aliases a map key.
    key: []const u8 = &.{},
    /// Intrusive detach chain, threaded ONLY by `invalidate()` while it holds the mutex.
    /// Once an entry is unlinked from the map its `next` is owned exclusively by the
    /// invalidating thread (no other path reads or writes it), so the map-ref drop can
    /// happen after the lock is released without any allocation inside the critical section.
    next: ?*Entry = null,
};

pub const Cache = struct {
    gpa: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,
    map: std.StringHashMapUnmanaged(*Entry) = .empty,
    generation: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) Cache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Cache) void {
        self.invalidate();
        self.map.deinit(self.gpa);
    }

    fn lockC(self: *Cache) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlockC(self: *Cache) void {
        self.mutex.unlock();
    }

    /// Drop the given reference; the LAST holder frees the entry (arena + owned key).
    fn unref(self: *Cache, e: *Entry) void {
        if (e.refs.fetchSub(1, .acq_rel) == 1) {
            if (e.key.len != 0) self.gpa.free(e.key);
            e.arena.deinit();
            self.gpa.destroy(e);
        }
    }

    /// Bump the generation and detach every entry. In-flight borrowers keep theirs
    /// alive via their own ref; the map's refs are dropped outside the lock.
    ///
    /// The critical section is allocation-free: entries are threaded onto an intrusive
    /// list via `Entry.next` (plain pointer writes) instead of being pushed into a heap
    /// ArrayList, and both the map keys and the entry arenas are freed only after the
    /// lock is released. `clearRetainingCapacity` keeps the map's buckets, so publishing
    /// after an invalidation never reallocates the table under the lock either. This
    /// removes the alloc-under-spinlock latency/contention hazard and any risk of a
    /// re-entrant allocator deadlocking while the cache lock is held.
    pub fn invalidate(self: *Cache) void {
        self.lockC();
        self.generation +%= 1;
        var detached: ?*Entry = null;
        var it = self.map.valueIterator();
        while (it.next()) |vp| {
            const e = vp.*;
            e.next = detached;
            detached = e;
        }
        self.map.clearRetainingCapacity();
        self.unlockC();
        // Outside the lock: drop the map's ref on each detached entry. The last holder
        // (here if there are no in-flight borrowers) frees the arena + key.
        while (detached) |e| {
            detached = e.next;
            e.next = null;
            self.unref(e);
        }
    }

    /// Hit path: O(1) lookup + ref bump under the spinlock. null on miss.
    fn acquire(self: *Cache, name: []const u8) ?*Entry {
        self.lockC();
        defer self.unlockC();
        const e = self.map.get(name) orelse return null;
        _ = e.refs.fetchAdd(1, .acq_rel);
        return e;
    }

    /// Publish a freshly-loaded entry unless `gen` is stale or another loader won the
    /// race. Returns true when published (map now holds a ref). Exposed fileprivate for
    /// the race unit test.
    fn publish(self: *Cache, gen: u64, name: []const u8, e: *Entry) bool {
        self.lockC();
        defer self.unlockC();
        if (self.generation != gen) return false; // a DDL invalidation raced our load
        if (self.map.contains(name)) return false; // concurrent loader won; use ours unpublished
        const key = self.gpa.dupe(u8, name) catch return false;
        self.map.put(self.gpa, key, e) catch {
            self.gpa.free(key);
            return false;
        };
        e.key = key; // the entry now owns the key buffer it is mapped under
        _ = e.refs.fetchAdd(1, .acq_rel); // the map's reference
        return true;
    }
};

/// A borrowed view of a collection's parsed metadata. `col == null` means "not a
/// collection". The memory behind `col` belongs to the cache entry (or to
/// `fallback_alloc` on the uncached path) — treat it as READ-ONLY and do not retain it
/// past `release()`.
pub const Lease = struct {
    col: ?schema.Collection,
    entry: ?*Entry = null,
    cache: ?*Cache = null,

    pub fn release(self: *Lease) void {
        if (self.cache) |c| if (self.entry) |e| c.unref(e);
        self.entry = null;
        self.cache = null;
    }
};

/// Cached `collections.get`. With `cache == null` (unit tests, CLI, Postgres backend)
/// this is a plain direct load into `fallback_alloc` and release() is a no-op.
pub fn lease(cache: ?*Cache, conn: *db.Db, fallback_alloc: std.mem.Allocator, name: []const u8) !Lease {
    const c = cache orelse
        return .{ .col = try collections.get(fallback_alloc, conn, name) };
    if (c.acquire(name)) |e|
        return .{ .col = e.col, .entry = e, .cache = c };
    // Miss: snapshot the generation, load OUTSIDE the lock into a fresh entry arena.
    c.lockC();
    const gen = c.generation;
    c.unlockC();
    const e = try c.gpa.create(Entry);
    errdefer c.gpa.destroy(e);
    e.* = .{ .arena = std.heap.ArenaAllocator.init(c.gpa), .col = null, .refs = std.atomic.Value(usize).init(1) };
    errdefer e.arena.deinit();
    e.col = try collections.get(e.arena.allocator(), conn, name);
    _ = c.publish(gen, name, e); // unpublished-on-race is fine: the caller still uses it
    return .{ .col = e.col, .entry = e, .cache = c };
}

// ---------------------------------------------------------------------------------------

const testing = std.testing;
const migrations = @import("migrations.zig");

fn testDbWithPosts(a: std.mem.Allocator) !db.Db {
    var d = try db.Db.openMemory();
    errdefer d.close();
    try migrations.run(&d);
    _ = try collections.create(a, std.testing.io, &d, .{
        .id = "",
        .name = "posts",
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }},
    });
    return d;
}

test "colcache: miss loads + publishes; second lease is the same entry (hit)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d = try testDbWithPosts(arena.allocator());
    defer d.close();
    var cache = Cache.init(testing.allocator);
    defer cache.deinit();

    var l1 = try lease(&cache, &d, arena.allocator(), "posts");
    defer l1.release();
    try testing.expect(l1.col != null);
    try testing.expectEqualStrings("posts", l1.col.?.name);
    var l2 = try lease(&cache, &d, arena.allocator(), "posts");
    defer l2.release();
    try testing.expect(l1.entry.? == l2.entry.?); // served from cache, not re-parsed
}

test "colcache: negative entries are cached and cleared by invalidate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d = try testDbWithPosts(arena.allocator());
    defer d.close();
    var cache = Cache.init(testing.allocator);
    defer cache.deinit();

    var miss1 = try lease(&cache, &d, arena.allocator(), "nope");
    try testing.expect(miss1.col == null);
    const neg_entry = miss1.entry.?;
    miss1.release();
    var miss2 = try lease(&cache, &d, arena.allocator(), "nope");
    try testing.expect(miss2.entry.? == neg_entry); // negative HIT
    miss2.release();
    cache.invalidate();
    var miss3 = try lease(&cache, &d, arena.allocator(), "nope");
    defer miss3.release();
    try testing.expect(miss3.entry.? != neg_entry); // reloaded after DDL
}

test "colcache: invalidate keeps in-flight leases alive (refcount) and reloads after" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d = try testDbWithPosts(arena.allocator());
    defer d.close();
    var cache = Cache.init(testing.allocator);
    defer cache.deinit();

    var held = try lease(&cache, &d, arena.allocator(), "posts");
    cache.invalidate();
    // The detached entry is still fully usable by its holder.
    try testing.expectEqualStrings("posts", held.col.?.name);
    try testing.expectEqualStrings("title", held.col.?.fields[held.col.?.fields.len - 1].name);
    var fresh = try lease(&cache, &d, arena.allocator(), "posts");
    defer fresh.release();
    try testing.expect(fresh.entry.? != held.entry.?);
    held.release(); // last ref on the detached entry frees it (leak check = the allocator)
}

test "colcache: a load that raced an invalidation is NOT published (generation guard)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d = try testDbWithPosts(arena.allocator());
    defer d.close();
    var cache = Cache.init(testing.allocator);
    defer cache.deinit();

    const stale_gen = cache.generation;
    cache.invalidate(); // DDL happens between our gen snapshot and publish
    const e = try cache.gpa.create(Entry);
    e.* = .{ .arena = std.heap.ArenaAllocator.init(cache.gpa), .col = null, .refs = std.atomic.Value(usize).init(1) };
    try testing.expect(!cache.publish(stale_gen, "posts", e));
    cache.unref(e);
    try testing.expect(cache.acquire("posts") == null); // nothing stale was cached
}

test "colcache: concurrent lease/invalidate/release stress (no UAF, no leak)" {
    // N threads allocate/free THROUGH the cache concurrently (key dupes in publish, entry
    // frees in unref). `std.testing.allocator` is a DebugAllocator whose `thread_safe`
    // config defaults to `!single_threaded`, i.e. it is mutex-guarded in the (multi-threaded)
    // test build — so this exercises the cache's OWN locking, not a racy allocator, while
    // still catching leaks at scope exit and any use-after-free / double-free the cache
    // might commit.
    var cache = Cache.init(testing.allocator);
    defer cache.deinit();

    const n_threads = 8;

    // Each thread gets its OWN sqlite connection (mirrors the production reader pool). Built
    // single-threaded here so collection provisioning never races; the connections are then
    // only READ concurrently.
    var setup_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer setup_arena.deinit();
    var dbs: [n_threads]db.Db = undefined;
    var opened: usize = 0;
    defer for (dbs[0..opened]) |*d| d.close();
    while (opened < n_threads) : (opened += 1) dbs[opened] = try testDbWithPosts(setup_arena.allocator());

    const Worker = struct {
        cache: *Cache,
        conn: *db.Db,
        seed: u64,
        failed: *std.atomic.Value(bool),

        fn run(self: @This()) void {
            var prng = std.Random.DefaultPrng.init(self.seed);
            const rnd = prng.random();
            var i: usize = 0;
            while (i < 4000) : (i += 1) {
                if (rnd.uintLessThan(u8, 8) == 0) {
                    self.cache.invalidate();
                    continue;
                }
                const want_posts = rnd.boolean();
                const name: []const u8 = if (want_posts) "posts" else "nope";
                // fallback_alloc is unused on the cached path (misses load into the entry's
                // own arena, hits reuse it), so any allocator works here.
                var l = lease(self.cache, self.conn, std.heap.page_allocator, name) catch {
                    self.failed.store(true, .seq_cst);
                    continue;
                };
                defer l.release();
                // Touch the borrowed, immutable snapshot: a wrongly-freed/reused entry would
                // surface here as a content mismatch (or a crash under a sanitizer).
                if (want_posts) {
                    if (l.col == null or !std.mem.eql(u8, l.col.?.name, "posts")) self.failed.store(true, .seq_cst);
                } else {
                    if (l.col != null) self.failed.store(true, .seq_cst);
                }
            }
        }
    };

    var failed = std.atomic.Value(bool).init(false);
    var threads: [n_threads]std.Thread = undefined;
    var spawned: usize = 0;
    while (spawned < n_threads) : (spawned += 1) {
        threads[spawned] = try std.Thread.spawn(.{}, Worker.run, .{Worker{
            .cache = &cache,
            .conn = &dbs[spawned],
            .seed = @as(u64, spawned) *% 0x9e3779b97f4a7c15 +% 1,
            .failed = &failed,
        }});
    }
    for (threads[0..spawned]) |t| t.join();
    try testing.expect(!failed.load(.seq_cst));

    // Deterministic invalidation-correctness check on the just-hammered cache: a lease taken
    // AFTER an invalidate must observe a fresh entry (not the detached one). Holding `held`
    // pins its address so the pointer comparison can't be fooled by an allocator reusing it.
    var held = try lease(&cache, &dbs[0], std.heap.page_allocator, "posts");
    cache.invalidate();
    var fresh = try lease(&cache, &dbs[0], std.heap.page_allocator, "posts");
    try testing.expect(fresh.entry.? != held.entry.?);
    try testing.expectEqualStrings("posts", fresh.col.?.name);
    fresh.release();
    held.release();
}

test "colcache: null cache falls back to a direct uncached load" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d = try testDbWithPosts(arena.allocator());
    defer d.close();
    var l = try lease(null, &d, arena.allocator(), "posts");
    defer l.release(); // no-op
    try testing.expect(l.col != null and l.entry == null);
}
