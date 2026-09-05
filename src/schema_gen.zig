//! The schema-generation marker: a one-row counter (`_schema_state.generation`) that every
//! public writer of `_collections` bumps, and that a serving process polls to learn its cached
//! collection metadata is stale.
//!
//! ## Why it exists
//! `colcache.Cache` has no TTL and no revalidation — it is invalidated only by the three REST
//! DDL handlers, i.e. only by writes this process performed. But `zigbase migrate`, `zigbase
//! import`, and `zigbase migrate-db` all mutate a data dir that a server may be serving from,
//! and on a shared data dir another process's write is invisible. The running server then keeps
//! serving stale metadata until it is restarted — and because NEGATIVE entries are cached, a
//! brand-new collection keeps 404-ing rather than merely looking out of date.
//!
//! ## The contract
//! **Every public writer of `_collections` bumps, INSIDE its own transaction.** Being inside the
//! transaction is what makes it sound: a rolled-back DDL cannot leave a bumped marker, and a
//! committed DDL cannot leave an unbumped one. So the invariant is structural — it does not
//! depend on call sites remembering. A bump failure propagates, which rolls the transaction back
//! and fails the DDL loudly; we never commit a schema change without its marker.
//!
//! Physical-only DDL (tenant/search index creation, FTS shadow objects) does NOT bump: it does
//! not change what `collections.get` returns, so no cached metadata goes stale.
//!
//! ## Reading
//! The observer polls on a POOLED READER, never the writer. A bound writer would see its own
//! uncommitted bump and could publish uncommitted schema into the shared cache — state that
//! survives a rollback. `feature_cache.zig` documents the same hazard for the same reason.

const std = @import("std");
const db = @import("db.zig");

/// How often the observer re-reads the marker. Matched to `feature_cache.default_ttl_ms` so the
/// two cross-process staleness bounds are the same number; deliberately NOT a config key or env
/// var (a knob here would be one more thing to get wrong, and the value is not deploy-varying).
pub const poll_interval_ms: u64 = 5_000;

/// Bump the marker. MUST be called inside the caller's open transaction.
///
/// `UPDATE ... SET generation = generation + 1` is evaluated by the database, so concurrent
/// writers cannot lose a bump to a read-modify-write race — and the single writer connection
/// serializes them anyway.
pub fn bump(w: *db.Db) db.DbError!void {
    try w.exec("UPDATE \"_schema_state\" SET \"generation\" = \"generation\" + 1 WHERE \"id\" = 1;");
}

/// Serialize metadata preflight and mutation across processes, without advertising a schema
/// change. Must be inside a transaction; the no-op UPDATE locks the singleton on both DBs.
pub fn lock(w: *db.Db) db.DbError!void {
    try w.exec("UPDATE \"_schema_state\" SET \"generation\" = \"generation\" WHERE \"id\" = 1;");
}

/// Read the current marker value. Returns 0 when the row is somehow absent, which is the same
/// value the migration seeds — an absent row can only mean "nothing has ever bumped".
pub fn read(conn: *db.Db) db.DbError!i64 {
    var st = try conn.prepare("SELECT \"generation\" FROM \"_schema_state\" WHERE \"id\" = 1;");
    defer st.finalize();
    if (!try st.step()) return 0;
    return st.columnInt(0);
}

/// Background poller that turns the marker into cache invalidation.
///
/// Wakes every `poll_interval_ms`, re-reads the marker on a POOLED READER, and calls the cache's
/// existing `invalidate()` whenever the value DIFFERS from what it last saw. That is the whole
/// mechanism — routing through `invalidate()` means negative entries are cleared by construction,
/// so a collection created by another process stops 404-ing rather than merely looking stale.
///
/// Design notes that are load-bearing:
///   - **Reader, never the writer.** A bound writer would observe its OWN uncommitted bump and
///     could publish uncommitted schema into the shared cache — state that survives a rollback.
///     `feature_cache.zig` documents the identical hazard.
///   - **`!=`, not `>`.** A `migrate-db` restore can move the counter BACKWARDS; "different" is
///     the property we care about, not "newer".
///   - **A read failure never fails a request.** It cannot: this runs on its own thread. It
///     invalidates (degrading to "no cache benefit", never to "stale data") and warns at most
///     once per failure streak, so a persistently unreadable marker cannot flood the log.
pub const Watcher = struct {
    io: std.Io,
    pool: *db.Pool,
    cache: *@import("colcache.zig").Cache,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    /// Last value observed. Seeded on `start` from the CURRENT marker so a freshly booted server
    /// does not invalidate its (empty) cache on the very first tick.
    last_seen: i64 = 0,
    /// True while reads are failing, so the warning is logged on the transition only.
    read_failing: bool = false,

    pub fn start(self: *Watcher) !void {
        self.last_seen = self.readNow() catch 0;
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    pub fn stop(self: *Watcher) void {
        self.shutdown.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    fn readNow(self: *Watcher) !i64 {
        var reader = try self.pool.acquireReader();
        defer self.pool.releaseReader(&reader);
        return try read(&reader);
    }

    /// Sleep granularity. The poll INTERVAL is `poll_interval_ms`, but the thread must not sleep
    /// that long in one go: `stop()` joins this thread, so an uninterruptible 5s sleep would add
    /// up to 5s to every shutdown — enough to blow the test harness's 5s terminate-and-wait and,
    /// worse, to make a real deployment look hung on restart. Wake often, act rarely.
    const slice_ms: u64 = 250;

    fn loop(self: *Watcher) void {
        var waited: u64 = 0;
        while (!self.shutdown.load(.acquire)) {
            self.io.sleep(std.Io.Duration.fromMilliseconds(slice_ms), .awake) catch {};
            waited += slice_ms;
            if (waited < poll_interval_ms) continue;
            waited = 0;
            if (self.shutdown.load(.acquire)) break;
            self.tick();
        }
    }

    /// One poll. Separated from the sleep loop so tests can drive it deterministically without
    /// spawning a thread or waiting out the interval.
    pub fn tick(self: *Watcher) void {
        const now = self.readNow() catch {
            // Unreadable marker: we can no longer prove the cache is current, so stop trusting
            // it. Invalidating is the safe direction — worst case we re-read from the DB.
            if (!self.read_failing) {
                self.read_failing = true;
                std.log.warn("schema-generation marker unreadable; dropping the collection cache until it reads again", .{});
            }
            self.cache.invalidate();
            return;
        };
        self.read_failing = false;
        if (now != self.last_seen) {
            self.last_seen = now;
            self.cache.invalidate();
        }
    }
};

// ---------------------------------------------------------------------------------------

const testing = std.testing;
const migrations = @import("migrations.zig");

test "schema_gen: the migration seeds exactly one row, and applying migrations bumps once" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);

    var st = try d.prepare("SELECT COUNT(*) FROM \"_schema_state\";");
    defer st.finalize();
    _ = try st.step();
    try testing.expectEqual(@as(i64, 1), st.columnInt(0)); // exactly one marker row

    // A fresh DB applies every system migration, so `run` bumps once on the way out: the row is
    // seeded at 0 and ends at 1. (Migrations can create collections, and they bypass the
    // collections.zig primitives, so the bump is theirs to make.)
    try testing.expectEqual(@as(i64, 1), try read(&d));
}

test "schema_gen: bump increments; an idempotent re-run neither reseeds nor re-bumps" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const base = try read(&d);

    try bump(&d);
    try bump(&d);
    try testing.expectEqual(base + 2, try read(&d));

    // `run` is idempotent: with nothing left to apply it must NOT bump, or every startup would
    // pointlessly invalidate every serving process's cache. The seed must not reset a live
    // counter either.
    try migrations.run(&d);
    try testing.expectEqual(base + 2, try read(&d));
    try d.exec(migrations.schema_state_seed_sql); // even run directly, the seed is a no-op
    try testing.expectEqual(base + 2, try read(&d));
}

test "schema_gen: a rolled-back transaction leaves the marker unbumped" {
    // The whole point of bumping INSIDE the DDL transaction: a failed schema change must not
    // advertise itself as a schema change, or every serving process drops a perfectly good
    // cache for nothing (and, worse, the marker would no longer describe reality).
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const base = try read(&d);

    try d.begin();
    try bump(&d);
    try testing.expectEqual(base + 1, try read(&d)); // visible to ourselves mid-transaction
    try d.rollback();
    try testing.expectEqual(base, try read(&d)); // and gone once rolled back
}

test "schema_gen: Watcher clears a cached NEGATIVE entry after another connection creates the collection" {
    // THE BUG THIS FEATURE EXISTS FOR. `zigbase import` / `zigbase migrate` mutate a live data
    // dir from a SECOND process; the serving process's colcache has no TTL and is invalidated
    // only by its own REST DDL handlers, so it never notices. Worse, negative entries are cached
    // — so a collection that did not exist when first looked up keeps 404-ing forever, not merely
    // looking stale. Two connections to one on-disk DB reproduce exactly that.
    const a = testing.allocator;
    const colcache = @import("colcache.zig");
    const collections = @import("collections.zig");
    const schema = @import("schema.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    defer a.free(path);
    const dbpath = try std.fmt.allocPrintSentinel(a, "{s}/wt.db", .{path}, 0);
    defer a.free(dbpath);

    // The "server": a real pool, so the watcher exercises the actual pooled-READER path rather
    // than a hand-held connection (reading on a pooled reader instead of the writer is the
    // design-critical detail — see the Watcher doc comment).
    var pool = try db.Pool.init(a, testing.io, dbpath);
    defer pool.deinit();
    try migrations.run(pool.acquireWriter());
    pool.releaseWriter();

    // A SEPARATE connection standing in for the `zigbase import` / `migrate` process.
    var cli_conn = try db.Db.open(dbpath);
    defer cli_conn.close();

    var cache = colcache.Cache.init(a);
    defer cache.deinit();
    var server_reader = try pool.acquireReader();
    defer pool.releaseReader(&server_reader);

    // The server looks up a collection that does not exist yet -> a cached NEGATIVE entry.
    {
        var l = try colcache.lease(&cache, &server_reader, a, "posts");
        defer l.release();
        try testing.expect(l.col == null);
    }

    // A watcher already in sync with the current generation. No thread: drive `tick` directly.
    var w = Watcher{ .io = testing.io, .pool = &pool, .cache = &cache };
    w.last_seen = try w.readNow();

    // The CLI process creates the collection. The serving process knows nothing about it.
    const created = try collections.create(a, testing.io, &cli_conn, .{
        .id = "",
        .name = "posts",
        .fields = &[_]schema.Field{.{ .id = "f_title", .name = "title", .options = .{ .text = .{} } }},
    });
    created.deinit(a);

    // Before the poll the server still serves the stale NEGATIVE entry — this is the bug.
    {
        var l = try colcache.lease(&cache, &server_reader, a, "posts");
        defer l.release();
        try testing.expect(l.col == null);
    }

    // One poll notices the marker moved and drops the cache (negative entries included, because
    // it routes through the existing invalidate() which detaches every entry).
    w.tick();

    // ...and the very same lookup now resolves, with no restart.
    {
        var l = try colcache.lease(&cache, &server_reader, a, "posts");
        defer l.release();
        try testing.expect(l.col != null);
        try testing.expectEqualStrings("posts", l.col.?.name);
    }
}

test "schema_gen: each collections.zig primitive bumps, and a failed one does not" {
    // The invariant the whole design rests on: EVERY public writer of _collections bumps. If a
    // new primitive is added without a bump, or an existing bump is dropped, this goes red.
    const a = testing.allocator;
    const collections = @import("collections.zig");
    const schema = @import("schema.zig");

    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);

    const fields = [_]schema.Field{.{ .id = "f_title", .name = "title", .options = .{ .text = .{} } }};

    var g = try read(&d);
    const created = try collections.create(a, testing.io, &d, .{ .id = "", .name = "posts", .fields = &fields });
    defer created.deinit(a);
    try testing.expectEqual(g + 1, try read(&d));

    g = try read(&d);
    try collections.updateRules(a, &d, created.id, .{ .list = "@public" });
    try testing.expectEqual(g + 1, try read(&d));

    g = try read(&d);
    const updated = try collections.update(a, testing.io, &d, created.id, .{
        .id = "",
        .name = "posts",
        .fields = &[_]schema.Field{
            .{ .id = "f_title", .name = "title", .options = .{ .text = .{} } },
            .{ .id = "f_body", .name = "body", .options = .{ .text = .{} } },
        },
    });
    defer updated.deinit(a);
    try testing.expectEqual(g + 1, try read(&d));

    // A FAILED write must not bump: create() rejects the duplicate name before its transaction,
    // so the marker must be untouched (otherwise every rejected request invalidates every cache).
    g = try read(&d);
    try testing.expectError(error.Conflict, collections.create(a, testing.io, &d, .{ .id = "", .name = "posts", .fields = &fields }));
    try testing.expectEqual(g, try read(&d));

    g = try read(&d);
    try collections.delete(a, &d, created.id);
    try testing.expectEqual(g + 1, try read(&d));
}
