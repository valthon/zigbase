//! Pure feature-flag + experiment resolution (0.8.0, #128/#129/#130).
//!
//! These functions take the declared definitions (from `features.zig`) plus the
//! relevant `_kv` overrides and return resolved values. They perform NO database
//! IO themselves — the ctx/data layer scans `_kv` and hands the entries in — so
//! they are trivially unit-testable and deterministic.
//!
//! `_kv` key conventions (distinct prefixes so a batched scan can group them and
//! they never collide with arbitrary settings):
//!   - `flag:<name>`         = `"true"` / `"false"` (a per-flag override)
//!   - `exp:<name>:weights`  = JSON array, e.g. `[90,10]` (a weight override)
//!
//! Experiments resolve by PURE deterministic hash by default. An experiment declared
//! `.sticky = true` instead PERSISTS its first assignment in `_experiment_assignments`
//! (keyed by `(experiment, subject)`) so the variant SURVIVES later weight changes
//! (#129) — `resolveExperiment` reads/writes that row when handed a writer connection.

const std = @import("std");
const features = @import("features.zig");
const db = @import("db.zig");

pub const FlagDef = features.FlagDef;
pub const ExperimentDef = features.ExperimentDef;
pub const Registry = features.Registry;

/// A minimal key/value pair (a projection of `data.KvEntry`) the resolver operates
/// on, so it need not import the DB layer.
pub const KvPair = struct { key: []const u8, value: []const u8 };

pub const ResolvedFlag = struct { name: []const u8, value: bool };
pub const ResolvedExperiment = struct { name: []const u8, variant: []const u8 };
pub const Resolved = struct {
    flags: []const ResolvedFlag = &.{},
    experiments: []const ResolvedExperiment = &.{},
};

fn isTruthy(v: []const u8) bool {
    return std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
}

/// Resolve a flag: if an override string is present, use its truthiness; otherwise
/// the declared default. (So a default-ON kill switch stays ON until an override
/// explicitly sets `"false"`.)
pub fn resolveFlag(override: ?[]const u8, def: FlagDef) bool {
    if (override) |v| return isTruthy(v);
    return def.default;
}

/// Deterministic bucketing: `FNV1a-64(name ++ 0x00 ++ subject) % 256`, then the
/// first variant whose cumulative weight threshold (scaled to 256) exceeds the
/// bucket. Stable for a given `(name, subject, weights)`. An empty subject always
/// maps to variant 0 (a stable "anonymous" assignment).
pub fn bucket(name: []const u8, subject: []const u8, weights: []const u16) usize {
    if (subject.len == 0) return 0;
    var total: u64 = 0;
    for (weights) |w| total += w;
    if (total == 0) return 0;

    var h = std.hash.Fnv1a_64.init();
    h.update(name);
    h.update("\x00");
    h.update(subject);
    const b: u64 = h.final() % 256;

    var cum: u64 = 0;
    for (weights, 0..) |w, i| {
        cum += w;
        const thr = (256 * cum) / total;
        if (b < thr) return i;
    }
    return weights.len - 1;
}

/// Parse a `[n,n,…]` weight-override JSON into `[]u16`, or null on any problem
/// (malformed JSON, wrong length, all-zero). Caller falls back to declared weights.
fn parseWeightOverride(alloc: std.mem.Allocator, json: []const u8, expect_len: usize) ?[]const u16 {
    const parsed = std.json.parseFromSlice([]u16, alloc, json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value.len != expect_len) return null;
    var total: u64 = 0;
    for (parsed.value) |w| total += w;
    if (total == 0) return null;
    return alloc.dupe(u16, parsed.value) catch null;
}

/// Resolve an experiment to a variant. `override_weights_json` (the `exp:<name>:weights`
/// value, or null) replaces the declared weights when valid. The returned slice is one
/// of `def.variants` (static), so it outlives `alloc`.
///
/// Resolution is a pure deterministic hash bucket UNLESS the experiment is `.sticky` and
/// a non-empty `subject` and a (writer) `conn` are supplied — then the first assignment
/// is persisted in `_experiment_assignments` and re-read on subsequent resolves, so the
/// variant SURVIVES a later weight change (#129). Passing `conn == null` (or an empty
/// subject) always takes the pure path; an empty subject is never persisted.
pub fn resolveExperiment(
    alloc: std.mem.Allocator,
    conn: ?*db.Db,
    override_weights_json: ?[]const u8,
    def: ExperimentDef,
    subject: []const u8,
) ![]const u8 {
    // An override parse dupes its own []u16 onto `alloc`; the declared weights are
    // static. Track + free the duped copy so the function is leak-free under a
    // general-purpose allocator (and a no-op under the arena it gets on the ctx path).
    var owned_weights: ?[]const u16 = null;
    defer if (owned_weights) |w| alloc.free(w);
    const weights: []const u16 = blk: {
        if (override_weights_json) |j| {
            if (parseWeightOverride(alloc, j, def.variants.len)) |w| {
                owned_weights = w;
                break :blk w;
            }
        }
        break :blk def.weights;
    };

    // Sticky: a previously-stored assignment wins over a fresh bucket, so the variant
    // is stable across weight changes. Needs a writer (the miss path INSERTs). An empty
    // subject always maps to variant 0 and is never persisted.
    if (def.sticky and subject.len > 0) {
        if (conn) |c| return stickyVariant(c, def, subject, weights);
    }

    const idx = bucket(def.name, subject, weights);
    return def.variants[idx];
}

/// Sticky resolution against `_experiment_assignments`. On a hit, return the STORED
/// variant (mapped back to the static `def.variants` slice so it outlives the row
/// buffer). On a miss, `bucket` + `INSERT OR IGNORE` the assignment, then return the
/// freshly-computed variant. Requires the WRITER connection (the single-writer model
/// means the read+insert pair is exclusive, so the computed variant is what is stored).
/// SQLITE_TRANSIENT copies the bound subject/variant text at bind time. A stored variant
/// that is no longer declared (the variant set changed) is ignored and recomputed.
fn stickyVariant(conn: *db.Db, def: ExperimentDef, subject: []const u8, weights: []const u16) ![]const u8 {
    {
        var st = try conn.prepare(
            \\SELECT "variant" FROM "_experiment_assignments"
            \\ WHERE "experiment" = ?1 AND "subject" = ?2;
        );
        defer st.finalize();
        try st.bindText(1, def.name);
        try st.bindText(2, subject);
        if (try st.step()) {
            const stored = st.columnText(0);
            for (def.variants) |v| {
                if (std.mem.eql(u8, v, stored)) return v;
            }
            // Stored variant no longer declared → fall through and recompute.
        }
    }

    const idx = bucket(def.name, subject, weights);
    const variant = def.variants[idx];
    var ins = try conn.prepare(
        \\INSERT OR IGNORE INTO "_experiment_assignments" ("experiment","subject","variant","created")
        \\ VALUES (?1, ?2, ?3, strftime('%Y-%m-%dT%H:%M:%SZ','now'));
    );
    defer ins.finalize();
    try ins.bindText(1, def.name);
    try ins.bindText(2, subject);
    try ins.bindText(3, variant);
    _ = try ins.step();
    return variant;
}

/// Batch size for the sticky-assignment GC sweep: bound each DELETE so a large backlog
/// never holds the single writer for one long statement (mirrors `session_gc_batch`).
pub const assignment_gc_batch: usize = 1000;

/// Garbage-collect `_experiment_assignments` rows older than `ttl_days`, in bounded
/// batches (mirrors `gcExpiredSessions`). Each batch is its own autocommit
/// `DELETE … RETURNING`, so the writer is never held across the whole sweep. The cutoff
/// is `strftime(…, 'now', '-<ttl_days> days')`; both sides are normalized via strftime so
/// a non-canonical `created` compares correctly and an unparseable one (strftime → NULL)
/// is kept (fail-safe). Returns the total rows deleted. Writer required.
pub fn gcExpiredAssignments(conn: *db.Db, ttl_days: u32) !usize {
    var buf: [32]u8 = undefined;
    // "-<u32> days" is at most "-4294967295 days" (16 chars) — never overflows buf.
    const modifier = std.fmt.bufPrint(&buf, "-{d} days", .{ttl_days}) catch unreachable;
    var total: usize = 0;
    while (true) {
        var st = try conn.prepare(comptime std.fmt.comptimePrint(
            \\DELETE FROM "_experiment_assignments"
            \\ WHERE rowid IN (
            \\   SELECT rowid FROM "_experiment_assignments"
            \\    WHERE strftime('%Y-%m-%dT%H:%M:%SZ', "created") IS NOT NULL
            \\      AND strftime('%Y-%m-%dT%H:%M:%SZ', "created") <= strftime('%Y-%m-%dT%H:%M:%SZ','now',?1)
            \\    LIMIT {d}
            \\ )
            \\ RETURNING "experiment";
        , .{assignment_gc_batch}));
        defer st.finalize();
        try st.bindText(1, modifier);
        var batch: usize = 0;
        while (try st.step()) batch += 1;
        total += batch;
        if (batch < assignment_gc_batch) break; // partial (or zero) batch → done
    }
    return total;
}

/// Resolve every declared flag and experiment for `subject` from a single batched
/// `_kv` scan (the entries matching `flag:*` / `exp:*`). Results are allocated on
/// `alloc`.
pub fn resolveAll(
    alloc: std.mem.Allocator,
    reg: Registry,
    entries: []const KvPair,
    subject: []const u8,
) !Resolved {
    const flags_out = try alloc.alloc(ResolvedFlag, reg.flags.len);
    for (reg.flags, 0..) |def, i| {
        const key = try std.fmt.allocPrint(alloc, "flag:{s}", .{def.name});
        defer alloc.free(key);
        var ov: ?[]const u8 = null;
        for (entries) |e| {
            if (std.mem.eql(u8, e.key, key)) {
                ov = e.value;
                break;
            }
        }
        flags_out[i] = .{ .name = def.name, .value = resolveFlag(ov, def) };
    }

    const exps_out = try alloc.alloc(ResolvedExperiment, reg.experiments.len);
    for (reg.experiments, 0..) |def, i| {
        const key = try std.fmt.allocPrint(alloc, "exp:{s}:weights", .{def.name});
        defer alloc.free(key);
        var ov: ?[]const u8 = null;
        for (entries) |e| {
            if (std.mem.eql(u8, e.key, key)) {
                ov = e.value;
                break;
            }
        }
        // The batch projection resolves by pure hash (conn == null). The sticky read/
        // write path runs only through the single-experiment `App.experiment` accessor,
        // which hands a writer connection; the public `/api/state` projection threads
        // its own connection in a later PR.
        exps_out[i] = .{ .name = def.name, .variant = try resolveExperiment(alloc, null, ov, def, subject) };
    }

    return .{ .flags = flags_out, .experiments = exps_out };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "resolveFlag returns declared default when unset; override wins" {
    const off = FlagDef{ .name = "f", .default = false };
    const on = FlagDef{ .name = "f", .default = true };

    // Unset → default.
    try std.testing.expect(!resolveFlag(null, off));
    try std.testing.expect(resolveFlag(null, on));

    // Override wins either way.
    try std.testing.expect(resolveFlag("true", off));
    try std.testing.expect(resolveFlag("1", off));
    try std.testing.expect(!resolveFlag("false", on));
    try std.testing.expect(!resolveFlag("0", on)); // non-truthy → false
}

test "default-ON flag stays on when unset (#128 kill-switch)" {
    const killswitch = FlagDef{ .name = "checkout_enabled", .default = true };
    // No operator action → still on.
    try std.testing.expect(resolveFlag(null, killswitch));
    // Operator flips it off.
    try std.testing.expect(!resolveFlag("false", killswitch));
}

test "bucket is deterministic and respects empty subject" {
    const weights = [_]u16{ 50, 50 };
    // Same (name, subject) → same bucket every time.
    const a = bucket("exp", "user-123", &weights);
    const b = bucket("exp", "user-123", &weights);
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a < 2);
    // Empty subject → variant 0.
    try std.testing.expectEqual(@as(usize, 0), bucket("exp", "", &weights));
}

test "bucket distribution roughly follows weights" {
    const weights = [_]u16{ 90, 10 };
    var counts = [_]usize{ 0, 0 };
    var i: usize = 0;
    var buf: [32]u8 = undefined;
    while (i < 2000) : (i += 1) {
        const subj = std.fmt.bufPrint(&buf, "subject-{d}", .{i}) catch unreachable;
        counts[bucket("layout", subj, &weights)] += 1;
    }
    // Variant 0 should dominate (~90%). Loose bounds to avoid flakiness.
    try std.testing.expect(counts[0] > counts[1]);
    try std.testing.expect(counts[0] > 1500); // >75%
    try std.testing.expect(counts[1] > 50); // variant 1 not starved
}

test "weight override changes the split" {
    const def = ExperimentDef{
        .name = "layout",
        .variants = &.{ "control", "compact" },
        .weights = &.{ 50, 50 },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Count variants under declared 50/50 vs an override pinning everything to control.
    var control_default: usize = 0;
    var control_override: usize = 0;
    var i: usize = 0;
    var buf: [32]u8 = undefined;
    while (i < 1000) : (i += 1) {
        const subj = std.fmt.bufPrint(&buf, "u{d}", .{i}) catch unreachable;
        if (std.mem.eql(u8, try resolveExperiment(a, null, null, def, subj), "control")) control_default += 1;
        if (std.mem.eql(u8, try resolveExperiment(a, null, "[100,0]", def, subj), "control")) control_override += 1;
    }
    // 50/50 ≈ half control; the [100,0] override forces ALL to control.
    try std.testing.expect(control_default < 1000);
    try std.testing.expectEqual(@as(usize, 1000), control_override);
}

test "resolveExperiment falls back to declared weights on a bad override" {
    const def = ExperimentDef{
        .name = "layout",
        .variants = &.{ "control", "compact" },
        .weights = &.{ 100, 0 }, // declared: always control
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Malformed / wrong-length / all-zero overrides all fall back to declared.
    try std.testing.expectEqualStrings("control", try resolveExperiment(a, null, "not json", def, "x"));
    try std.testing.expectEqualStrings("control", try resolveExperiment(a, null, "[1,2,3]", def, "x"));
    try std.testing.expectEqualStrings("control", try resolveExperiment(a, null, "[0,0]", def, "x"));
}

test "resolveAll returns every declared flag + experiment via the batched scan" {
    const reg = Registry{
        .flags = &.{
            .{ .name = "checkout_enabled", .default = true },
            .{ .name = "new_dashboard", .default = false },
        },
        .experiments = &.{
            .{ .name = "layout", .variants = &.{ "control", "compact" }, .weights = &.{ 50, 50 } },
        },
    };
    // Simulated batched _kv scan: one flag override + one weight override.
    const entries = [_]KvPair{
        .{ .key = "flag:new_dashboard", .value = "true" },
        .{ .key = "exp:layout:weights", .value = "[0,100]" },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const resolved = try resolveAll(a, reg, &entries, "user-7");
    try std.testing.expectEqual(@as(usize, 2), resolved.flags.len);
    // checkout_enabled has no override → declared default true.
    try std.testing.expectEqualStrings("checkout_enabled", resolved.flags[0].name);
    try std.testing.expect(resolved.flags[0].value);
    // new_dashboard override → true (was default false).
    try std.testing.expectEqualStrings("new_dashboard", resolved.flags[1].name);
    try std.testing.expect(resolved.flags[1].value);
    // layout weight override [0,100] forces "compact".
    try std.testing.expectEqual(@as(usize, 1), resolved.experiments.len);
    try std.testing.expectEqualStrings("layout", resolved.experiments[0].name);
    try std.testing.expectEqualStrings("compact", resolved.experiments[0].variant);
}

// ---------------------------------------------------------------------------
// Sticky-assignment tests (#129) — exercise the real `_experiment_assignments`
// table on an in-memory db.
// ---------------------------------------------------------------------------

const assignments_ddl =
    \\CREATE TABLE "_experiment_assignments" (
    \\  "experiment" TEXT NOT NULL,
    \\  "subject" TEXT NOT NULL,
    \\  "variant" TEXT NOT NULL,
    \\  "created" TEXT NOT NULL,
    \\  PRIMARY KEY ("experiment","subject")
    \\);
;

test "sticky experiment SURVIVES a weight change (#129)" {
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec(assignments_ddl);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const def = ExperimentDef{
        .name = "checkout_layout",
        .variants = &.{ "control", "compact" },
        .weights = &.{ 50, 50 },
        .sticky = true,
    };

    // First resolve under the declared 50/50 weights persists an assignment.
    const first = try resolveExperiment(a, &d, null, def, "user-42");

    // A later weight override that would otherwise force EVERYONE to the other
    // variant must NOT move an already-assigned subject.
    const opposite = if (std.mem.eql(u8, first, "control")) "[0,100]" else "[100,0]";
    const after = try resolveExperiment(a, &d, opposite, def, "user-42");
    try std.testing.expectEqualStrings(first, after);

    // And a brand-new subject under the override DOES follow the new weights.
    const newcomer = try resolveExperiment(a, &d, opposite, def, "newcomer-1");
    const forced = if (std.mem.eql(u8, first, "control")) "compact" else "control";
    try std.testing.expectEqualStrings(forced, newcomer);

    // Exactly one row for the sticky subject was persisted.
    var st = try d.prepare("SELECT COUNT(*) FROM \"_experiment_assignments\" WHERE \"subject\" = ?1;");
    defer st.finalize();
    try st.bindText(1, "user-42");
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 1), st.columnInt(0));
}

test "non-sticky experiment FOLLOWS the new weights (no persistence)" {
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec(assignments_ddl);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const def = ExperimentDef{
        .name = "layout",
        .variants = &.{ "control", "compact" },
        .weights = &.{ 50, 50 },
        .sticky = false,
    };

    // Even with a writer connection, a non-sticky experiment ignores the table and
    // honors the override on every resolve.
    try std.testing.expectEqualStrings("control", try resolveExperiment(a, &d, "[100,0]", def, "user-42"));
    try std.testing.expectEqualStrings("compact", try resolveExperiment(a, &d, "[0,100]", def, "user-42"));

    // Nothing was persisted.
    var st = try d.prepare("SELECT COUNT(*) FROM \"_experiment_assignments\";");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 0), st.columnInt(0));
}

test "sticky never persists an empty-subject assignment" {
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec(assignments_ddl);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const def = ExperimentDef{
        .name = "layout",
        .variants = &.{ "control", "compact" },
        .weights = &.{ 50, 50 },
        .sticky = true,
    };

    // Empty subject → variant 0, and NO row is written.
    try std.testing.expectEqualStrings("control", try resolveExperiment(a, &d, null, def, ""));
    var st = try d.prepare("SELECT COUNT(*) FROM \"_experiment_assignments\";");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 0), st.columnInt(0));
}

test "gcExpiredAssignments reaps rows older than the TTL and keeps newer ones" {
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec(assignments_ddl);

    // One ancient row (well past any TTL) and one fresh row (created now).
    try d.exec(
        \\INSERT INTO "_experiment_assignments" ("experiment","subject","variant","created")
        \\ VALUES ('layout','old','control','2000-01-01T00:00:00Z');
    );
    try d.exec(
        \\INSERT INTO "_experiment_assignments" ("experiment","subject","variant","created")
        \\ VALUES ('layout','new','compact', strftime('%Y-%m-%dT%H:%M:%SZ','now'));
    );

    // TTL 90 days → the 2000 row is reaped, the fresh one survives.
    const reaped = try gcExpiredAssignments(&d, 90);
    try std.testing.expectEqual(@as(usize, 1), reaped);

    var st = try d.prepare("SELECT \"subject\" FROM \"_experiment_assignments\";");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("new", st.columnText(0));
    try std.testing.expect(!try st.step()); // exactly one row left
}
