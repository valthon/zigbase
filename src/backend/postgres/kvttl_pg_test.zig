//! Live-PostgreSQL parity tests for the KV store / TTL-style GC / sticky-experiment subsystem
//! (issue #159, PR-4). These exercise the dialect-ized SQL end-to-end against a real PostgreSQL:
//!   * `data.Data.kvSet/kvGet/kvDelete/kvScanPrefix` — the `_kv` upsert (`ON CONFLICT(key) DO
//!     UPDATE`, `nowTextExpr`), the prefix scan (`GLOB`→`LIKE`), and the `$n` renumber chokepoint.
//!   * `features_resolver.gcExpiredAssignments` — the relative-age, fail-safe GC over
//!     `_experiment_assignments` (`agedBeyondDaysPredicate` regex gate + `ctid` batched delete):
//!     an aged row is reaped, a fresh row survives, and a MALFORMED-timestamp row is NOT reaped.
//!   * `features_resolver.resolveExperiment` sticky path — `INSERT … ON CONFLICT DO NOTHING` +
//!     read-back, surviving a weight change, on Postgres.
//!
//! They run only under `-Dpostgres=true` (gated from `root.zig`) and require a reachable
//! PostgreSQL (`ZIGBASE_PG_TEST_URL`); they SKIP when none is configured, like the other live
//! PG tests. Isolation: a fresh per-test SCHEMA (`SET search_path`) dropped CASCADE on teardown,
//! with the full migration set provisioned into it so the real `_kv`/`_experiment_assignments`
//! tables exist exactly as production creates them.

const std = @import("std");
const db = @import("../../db.zig");
const data = @import("../../data.zig");
const app_mod = @import("../../app.zig");
const migrations = @import("../../migrations.zig");
const features_resolver = @import("../../features_resolver.zig");

const Data = data.Data;
const ExperimentDef = features_resolver.ExperimentDef;

fn testUrlZ() ?[:0]const u8 {
    return std.testing.environ.getPosix("ZIGBASE_PG_TEST_URL");
}

/// A live PG `db.Db` on a private, freshly created+migrated schema, or null to skip.
const Ctx = struct {
    conn: db.Db,
    drop_sql: [:0]const u8,

    fn open(a: std.mem.Allocator, io: std.Io, comptime tag: []const u8) !?Ctx {
        const url = testUrlZ() orelse return null;
        var conn = db.Db.openPostgres(a, io, url) catch |e| switch (e) {
            error.OpenFailed => return null,
            else => return e,
        };
        errdefer conn.close();
        const sn = "zb_pr4_" ++ tag;
        const drop = "DROP SCHEMA IF EXISTS " ++ sn ++ " CASCADE;";
        try conn.exec(drop);
        try conn.exec("CREATE SCHEMA " ++ sn ++ ";");
        // Drop the just-created schema if SET search_path / migrations fail (errdefers run LIFO, so
        // this drop runs BEFORE conn.close above), so a partial failure never leaves a schema behind.
        errdefer conn.exec(drop) catch {};
        try conn.exec("SET search_path TO " ++ sn ++ ";");
        try migrations.run(&conn);
        return Ctx{ .conn = conn, .drop_sql = drop };
    }

    fn deinit(self: *Ctx) void {
        self.conn.exec(self.drop_sql) catch {};
        self.conn.close();
    }

    fn w(self: *Ctx) *db.Db {
        return &self.conn;
    }
};

fn scalarCount(w: *db.Db, sql: [:0]const u8) !i64 {
    var st = try w.prepare(sql);
    defer st.finalize();
    _ = try st.step();
    return st.columnInt(0);
}

test "pg: _kv set/get/delete round-trip, upsert preserves created, prefix scan (LIKE)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var ctx = (try Ctx.open(a, io, "kv")) orelse return error.SkipZigTest;
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();
    var app = app_mod.App{ .allocator = al, .io = io, .pool = undefined };
    const d = Data{ .app = &app, .conn = ctx.w(), .io = io, .alloc = al };

    // Missing key → null.
    try std.testing.expect((try d.kvGet("missing")) == null);

    // Set then get round-trips (INSERT … ON CONFLICT(key) DO UPDATE on PG).
    try d.kvSet("greeting", "hello");
    try std.testing.expectEqualStrings("hello", (try d.kvGet("greeting")).?);

    // Capture created, update value, assert created preserved + updated bumped is value-changed.
    const created0 = blk: {
        var st = try ctx.w().prepare("SELECT created FROM \"_kv\" WHERE key='greeting';");
        defer st.finalize(); // scoped: finalized even if step/dupe fails
        try std.testing.expect(try st.step());
        break :blk try al.dupe(u8, st.columnText(0));
    };
    // created is the ISO-8601 `Z` shape from nowTextExpr (to_char) on PG.
    try std.testing.expectEqual(@as(usize, 20), created0.len);
    try std.testing.expectEqual(@as(u8, 'Z'), created0[19]);

    try d.kvSet("greeting", "world");
    try std.testing.expectEqualStrings("world", (try d.kvGet("greeting")).?);
    var st2 = try ctx.w().prepare("SELECT created FROM \"_kv\" WHERE key='greeting';");
    defer st2.finalize();
    try std.testing.expect(try st2.step());
    try std.testing.expectEqualStrings(created0, st2.columnText(0)); // created unchanged

    // Prefix scan (key LIKE 'flag:%' / 'exp:%' on PG) returns only matching keys, ordered by key.
    try d.kvSet("flag:beta", "true");
    try d.kvSet("exp:layout:weights", "[90,10]");
    try d.kvSet("welcome_banner", "hi"); // unrelated — must NOT match
    const hits = try d.kvScanPrefix(&.{ "flag:", "exp:" });
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqualStrings("exp:layout:weights", hits[0].key); // "exp:" < "flag:"
    try std.testing.expectEqualStrings("flag:beta", hits[1].key);
    try std.testing.expectEqualStrings("true", hits[1].value);
    try std.testing.expectEqual(@as(usize, 0), (try d.kvScanPrefix(&.{})).len);

    // Delete reports existence then absence.
    try std.testing.expect(try d.kvDelete("greeting"));
    try std.testing.expect((try d.kvGet("greeting")) == null);
    try std.testing.expect(!(try d.kvDelete("greeting")));
}

test "pg: gcExpiredAssignments reaps aged rows, keeps fresh + malformed (fail-safe via regex+ctid)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var ctx = (try Ctx.open(a, io, "gc")) orelse return error.SkipZigTest;
    defer ctx.deinit();
    const w = ctx.w();

    // Four rows: an ancient one (reaped), a far-future one (kept), a non-ISO malformed timestamp
    // (kept), and a well-SHAPED but out-of-RANGE timestamp `2024-99-99T99:99:99Z` (kept — the
    // range-bounded regex rejects it, so a lexically-"old" garbage value is never aged out).
    try w.exec(
        \\INSERT INTO "_experiment_assignments" ("experiment","subject","variant","created") VALUES
        \\  ('layout','old','control','2000-01-01T00:00:00Z'),
        \\  ('layout','fresh','compact','2999-01-01T00:00:00Z'),
        \\  ('layout','bad','control','not-a-timestamp'),
        \\  ('layout','oor','control','2024-99-99T99:99:99Z');
    );

    const reaped = try features_resolver.gcExpiredAssignments(w, 90);
    try std.testing.expectEqual(@as(usize, 1), reaped); // only the 2000 row aged out

    try std.testing.expectEqual(@as(i64, 3), try scalarCount(w, "SELECT count(*) FROM \"_experiment_assignments\";"));
    // The malformed + out-of-range rows specifically survived (fail-safe), as did the future one.
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(w, "SELECT count(*) FROM \"_experiment_assignments\" WHERE \"subject\"='bad';"));
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(w, "SELECT count(*) FROM \"_experiment_assignments\" WHERE \"subject\"='oor';"));
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(w, "SELECT count(*) FROM \"_experiment_assignments\" WHERE \"subject\"='fresh';"));
    try std.testing.expectEqual(@as(i64, 0), try scalarCount(w, "SELECT count(*) FROM \"_experiment_assignments\" WHERE \"subject\"='old';"));
}

test "pg: sticky experiment persists + survives a weight change (INSERT…ON CONFLICT, $n)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var ctx = (try Ctx.open(a, io, "sticky")) orelse return error.SkipZigTest;
    defer ctx.deinit();
    const w = ctx.w();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    const def = ExperimentDef{
        .name = "checkout_layout",
        .variants = &.{ "control", "compact" },
        .weights = &.{ 50, 50 },
        .sticky = true,
    };

    // First resolve persists an assignment (INSERT … ON CONFLICT DO NOTHING + read-back).
    const first = try features_resolver.resolveExperiment(al, .{ .read = w }, null, def, "user-42");
    // A weight override that would force everyone the other way must NOT move an assigned subject.
    const opposite = if (std.mem.eql(u8, first, "control")) "[0,100]" else "[100,0]";
    const after = try features_resolver.resolveExperiment(al, .{ .read = w }, opposite, def, "user-42");
    try std.testing.expectEqualStrings(first, after);
    // A brand-new subject under the override DOES follow the new weights.
    const newcomer = try features_resolver.resolveExperiment(al, .{ .read = w }, opposite, def, "newcomer-1");
    const forced = if (std.mem.eql(u8, first, "control")) "compact" else "control";
    try std.testing.expectEqualStrings(forced, newcomer);

    // Exactly one row persisted for the sticky subject.
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(w, "SELECT count(*) FROM \"_experiment_assignments\" WHERE \"subject\"='user-42';"));
}
