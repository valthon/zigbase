//! Product analytics (#158): event capture + declarative rollups.
//!
//! Two cooperating halves backed by the `_events` table (migration `0015_events`):
//!
//!   1. CAPTURE — `ctx.track(name, payload)` (see `ctx.zig`) calls `insertEvent` to append one
//!      immutable row. Actor / account / timestamp are resolved SERVER-SIDE by the caller and
//!      passed in; this module never trusts client input.
//!
//!   2. ROLLUP — a declarative `.analytics = .{ .rollups = .{ … } }` spec (lowered at comptime by
//!      `config.zig`) registers one scheduled job per rollup. Each run (`runRollup`) provisions a
//!      `_rollup_<name>` summary table (identifiers gated via `schema.isValidIdentifier`) and
//!      INCREMENTALLY aggregates only the events newer than a persisted watermark (`_kv`), so a run
//!      is idempotent and cheap.
//!
//! Reads (the activity feed + the aggregates) are served tenant-scoped + fail-closed by `api.zig`.
//!
//! Back-compat: with no `.analytics` config the `_events` table is still seeded (harmless) but no
//! rollup job is scheduled; `ctx.track` works standalone.

const std = @import("std");
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const schedule = @import("../schedule.zig");
const id_gen = @import("../id.zig");
const App = @import("../app.zig").App;

/// The aggregate computed by a rollup. Only `count` ships; the enum leaves room for `sum`/`avg`
/// over a numeric payload field later without reshaping the config surface.
pub const Metric = enum { count };

/// Time-bucket granularity for a rollup's `bucket` key. `none` aggregates across all time into a
/// single `"all"` bucket; `day`/`hour` truncate `occurred_at` (ISO-8601 UTC) to that boundary.
pub const TimeBucket = enum { none, day, hour };

/// One lowered rollup spec (runtime view of a `.analytics.rollups.<name>` entry). Built at comptime
/// by `config.rollupSpecs`; `every` drives the scheduled job's cadence.
pub const RollupSpec = struct {
    /// The rollup name — also the `_rollup_<name>` summary-table suffix and `_rollup:<name>` job
    /// name. A valid SQL identifier (enforced at comptime by `config.zig` and re-checked here).
    name: []const u8,
    /// The `_events.name` this rollup aggregates.
    event: []const u8,
    /// Aggregation cadence (cron or interval), reusing the framework scheduler's `Schedule`.
    every: schedule.Schedule,
    /// Whether to bucket by `account` (the tenant id).
    group_account: bool,
    /// Whether to bucket by `actor` (the principal id).
    group_actor: bool,
    /// Time-bucket granularity for the `bucket` column.
    time_bucket: TimeBucket,
    /// The aggregate metric.
    metric: Metric,
};

/// The lowered rollup registry, pointed at by `app.analytics` (type-erased). `byName` resolves a
/// rollup for the scheduled job + the read endpoint.
pub const Registry = struct {
    rollups: []const RollupSpec = &.{},

    pub fn byName(self: *const Registry, name: []const u8) ?RollupSpec {
        for (self.rollups) |r| if (std.mem.eql(u8, r.name, name)) return r;
        return null;
    }
};

/// Recover the analytics `Registry` from the type-erased `app.analytics` pointer (stored opaque to
/// avoid an app→analytics import cycle, mirroring `app.queues`). null when no `.analytics` config.
pub fn registryFromApp(app: *const App) ?*const Registry {
    const p = app.analytics orelse return null;
    return @ptrCast(@alignCast(p));
}

/// The server-resolved context for one tracked event. The caller (`ctx.track`) fills these from the
/// authenticated principal + the request's tenant scope — NEVER from client input.
pub const EventContext = struct {
    name: []const u8,
    payload_json: []const u8,
    actor: []const u8 = "",
    actor_collection: []const u8 = "",
    account: []const u8 = "",
};

/// Append one immutable `_events` row on `conn`. `created`/`updated`/`occurred_at` are stamped
/// server-side via SQLite's `now` (which honors `ZIGBASE_FAKE_NOW` through the clock VFS), so the
/// timestamp is never client-supplied. `payload_json` is bound (opaque text), never interpolated.
pub fn insertEvent(conn: *db.Db, io: std.Io, ev: EventContext) !void {
    var idbuf: [15]u8 = undefined;
    id_gen.generate(io, &idbuf);
    var st = try conn.prepare(
        \\INSERT INTO "_events"
        \\  ("id","created","updated","name","payload","actor_collection","actor","account","occurred_at")
        \\ VALUES (?1,
        \\   strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'),
        \\   ?2, ?3, ?4, ?5, ?6,
        \\   strftime('%Y-%m-%dT%H:%M:%SZ','now'));
    );
    defer st.finalize();
    try st.bindText(1, &idbuf);
    try st.bindText(2, ev.name);
    try st.bindText(3, ev.payload_json);
    try st.bindText(4, ev.actor_collection);
    try st.bindText(5, ev.actor);
    try st.bindText(6, ev.account);
    _ = try st.step();
}

/// The `_kv` key holding a rollup's incremental watermark (the `occurred_at` boundary already
/// aggregated). Allocated on `alloc`.
pub fn watermarkKey(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "analytics:rollup:{s}:watermark", .{name});
}

/// The `_rollup_<name>` summary-table name, guarded through `schema.isValidIdentifier`. Returns
/// `error.InvalidIdentifier` for a name that is not a safe SQL identifier (defense in depth — the
/// comptime config already rejects these). Allocated (sentinel) on `alloc`.
pub fn summaryTable(alloc: std.mem.Allocator, name: []const u8) ![:0]u8 {
    if (!schema.isValidIdentifier(name)) return error.InvalidIdentifier;
    return std.fmt.allocPrintSentinel(alloc, "_rollup_{s}", .{name}, 0);
}

/// The SQL expression for a rollup's `bucket` value (a constant fragment, never user input).
fn bucketExpr(tb: TimeBucket) []const u8 {
    return switch (tb) {
        .none => "'all'",
        .day => "strftime('%Y-%m-%d',\"occurred_at\")",
        .hour => "strftime('%Y-%m-%dT%H:00:00Z',\"occurred_at\")",
    };
}

/// Provision the `_rollup_<name>` summary table (idempotent). Shape:
/// `(bucket, account, actor, value, computed_at)` with a UNIQUE(bucket,account,actor) key so the
/// incremental aggregation can UPSERT (`value = value + excluded.value`). Columns absent from the
/// grouping are stored as `''` so the key is uniform across all `group_by` shapes.
pub fn provisionSummary(conn: *db.Db, alloc: std.mem.Allocator, name: []const u8) !void {
    const table = try summaryTable(alloc, name);
    const create = try std.fmt.allocPrintSentinel(alloc,
        \\CREATE TABLE IF NOT EXISTS "{s}" (
        \\  "bucket" TEXT NOT NULL DEFAULT '',
        \\  "account" TEXT NOT NULL DEFAULT '',
        \\  "actor" TEXT NOT NULL DEFAULT '',
        \\  "value" INTEGER NOT NULL DEFAULT 0,
        \\  "computed_at" TEXT NOT NULL DEFAULT '',
        \\  PRIMARY KEY ("bucket","account","actor")
        \\);
    , .{table}, 0);
    try conn.exec(create);
}

/// Run one incremental aggregation pass for `spec` on the writer `conn`. Provisions the summary
/// table, reads the persisted watermark, aggregates `_events` rows with
/// `watermark < occurred_at <= now` into the summary (UPSERT, `count` metric), then advances the
/// watermark to `now`. Idempotent: a re-run with no new events is a no-op. `now` is captured from
/// SQLite (honoring `ZIGBASE_FAKE_NOW`) so a frozen-clock e2e test is deterministic.
pub fn runRollup(conn: *db.Db, alloc: std.mem.Allocator, spec: RollupSpec) !void {
    try provisionSummary(conn, alloc, spec.name);
    const table = try summaryTable(alloc, spec.name);

    // Snapshot "now" once (ISO-8601 UTC). Everything with occurred_at <= now is aggregated this
    // pass; the watermark advances to exactly this boundary so the next pass starts strictly after.
    const now_iso = try scalarNow(conn, alloc);

    const wkey = try watermarkKey(alloc, spec.name);
    const watermark = (try kvGet(conn, alloc, wkey)) orelse "";

    const account_expr: []const u8 = if (spec.group_account) "\"account\"" else "''";
    const actor_expr: []const u8 = if (spec.group_actor) "\"actor\"" else "''";

    const sql = try std.fmt.allocPrintSentinel(alloc,
        \\INSERT INTO "{s}" ("bucket","account","actor","value","computed_at")
        \\ SELECT {s} AS b, {s} AS a, {s} AS ac, COUNT(*) AS v, ?3
        \\ FROM "_events"
        \\ WHERE "name" = ?1 AND "occurred_at" > ?2 AND "occurred_at" <= ?3
        \\ GROUP BY b, a, ac
        \\ ON CONFLICT("bucket","account","actor")
        \\   DO UPDATE SET "value" = "value" + excluded."value", "computed_at" = excluded."computed_at";
    , .{ table, bucketExpr(spec.time_bucket), account_expr, actor_expr }, 0);

    var st = try conn.prepare(sql);
    defer st.finalize();
    try st.bindText(1, spec.event);
    try st.bindText(2, watermark);
    try st.bindText(3, now_iso);
    _ = try st.step();

    try kvSet(conn, alloc, wkey, now_iso);
}

/// Capture SQLite's current ISO-8601 UTC second (honors the dev-only frozen clock VFS).
fn scalarNow(conn: *db.Db, alloc: std.mem.Allocator) ![]const u8 {
    var st = try conn.prepare("SELECT strftime('%Y-%m-%dT%H:%M:%SZ','now');");
    defer st.finalize();
    _ = try st.step();
    return alloc.dupe(u8, st.columnText(0));
}

/// Minimal `_kv` read (the watermark store). Returns null when the key is absent.
fn kvGet(conn: *db.Db, alloc: std.mem.Allocator, key: []const u8) !?[]const u8 {
    var st = try conn.prepare("SELECT \"value\" FROM \"_kv\" WHERE \"key\" = ?1;");
    defer st.finalize();
    try st.bindText(1, key);
    if (!try st.step()) return null;
    return try alloc.dupe(u8, st.columnText(0));
}

/// Minimal `_kv` upsert (the watermark store). Preserves `created`, bumps `updated`.
fn kvSet(conn: *db.Db, alloc: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    _ = alloc;
    var st = try conn.prepare(
        \\INSERT INTO "_kv" ("key","value","created","updated")
        \\ VALUES (?1, ?2, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'))
        \\ ON CONFLICT("key") DO UPDATE SET "value" = excluded."value", "updated" = excluded."updated";
    );
    defer st.finalize();
    try st.bindText(1, key);
    try st.bindText(2, value);
    _ = try st.step();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const migrations = @import("../migrations.zig");

fn countEvents(d: *db.Db) !i64 {
    var st = try d.prepare("SELECT COUNT(*) FROM \"_events\";");
    defer st.finalize();
    _ = try st.step();
    return st.columnInt(0);
}

test "insertEvent appends an immutable row with server-stamped timestamps" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    try insertEvent(&d, std.testing.io, .{
        .name = "user.signup",
        .payload_json = "{\"plan\":\"pro\"}",
        .actor = "u1",
        .actor_collection = "users",
        .account = "acc1",
    });
    try std.testing.expectEqual(@as(i64, 1), try countEvents(&d));

    var st = try d.prepare("SELECT name, account, actor, payload, occurred_at FROM \"_events\";");
    defer st.finalize();
    _ = try st.step();
    try std.testing.expectEqualStrings("user.signup", st.columnText(0));
    try std.testing.expectEqualStrings("acc1", st.columnText(1));
    try std.testing.expectEqualStrings("u1", st.columnText(2));
    try std.testing.expectEqualStrings("{\"plan\":\"pro\"}", st.columnText(3));
    try std.testing.expect(st.columnText(4).len > 0); // occurred_at stamped
}

test "summaryTable gates the rollup name through isValidIdentifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("_rollup_signups", try summaryTable(a, "signups"));
    try std.testing.expectError(error.InvalidIdentifier, summaryTable(a, "bad-name"));
    try std.testing.expectError(error.InvalidIdentifier, summaryTable(a, "drop;table"));
}

test "runRollup aggregates incrementally and is idempotent" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);

    // Two signups for acc1, one for acc2 — all in the same day bucket.
    try d.exec("INSERT INTO \"_events\" (\"id\",\"created\",\"updated\",\"name\",\"payload\",\"account\",\"occurred_at\") VALUES " ++
        "('e1','t','t','user.signup','{}','acc1','2026-01-01T08:00:00Z')," ++
        "('e2','t','t','user.signup','{}','acc1','2026-01-01T09:00:00Z')," ++
        "('e3','t','t','user.signup','{}','acc2','2026-01-01T10:00:00Z')," ++
        "('e4','t','t','other.event','{}','acc1','2026-01-01T11:00:00Z');");

    const spec = RollupSpec{
        .name = "signups_daily",
        .event = "user.signup",
        .every = .{ .interval = .hourly },
        .group_account = true,
        .group_actor = false,
        .time_bucket = .day,
        .metric = .count,
    };
    try runRollup(&d, a, spec);

    // acc1 has 2 signups, acc2 has 1, the other.event is ignored.
    var st = try d.prepare("SELECT account, value FROM \"_rollup_signups_daily\" ORDER BY account;");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("acc1", st.columnText(0));
    try std.testing.expectEqual(@as(i64, 2), st.columnInt(1));
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("acc2", st.columnText(0));
    try std.testing.expectEqual(@as(i64, 1), st.columnInt(1));
    try std.testing.expect(!try st.step());

    // Re-run with NO new events: watermark guards a no-op (acc1 stays 2, not 4).
    try runRollup(&d, a, spec);
    var v = try d.prepare("SELECT value FROM \"_rollup_signups_daily\" WHERE account='acc1';");
    defer v.finalize();
    _ = try v.step();
    try std.testing.expectEqual(@as(i64, 2), v.columnInt(0));
}

test "registryFromApp round-trips the type-erased pointer; byName resolves" {
    const reg = Registry{ .rollups = &.{.{
        .name = "signups_daily",
        .event = "user.signup",
        .every = .{ .interval = .hourly },
        .group_account = true,
        .group_actor = false,
        .time_bucket = .day,
        .metric = .count,
    }} };
    var app: App = undefined;
    app.analytics = @ptrCast(&reg);
    const got = registryFromApp(&app).?;
    try std.testing.expect(got.byName("signups_daily") != null);
    try std.testing.expect(got.byName("nope") == null);
}
