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

/// Read the current marker value. Returns 0 when the row is somehow absent, which is the same
/// value the migration seeds — an absent row can only mean "nothing has ever bumped".
pub fn read(conn: *db.Db) db.DbError!i64 {
    var st = try conn.prepare("SELECT \"generation\" FROM \"_schema_state\" WHERE \"id\" = 1;");
    defer st.finalize();
    if (!try st.step()) return 0;
    return st.columnInt(0);
}

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
