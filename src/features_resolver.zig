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
//! PR1 resolves experiments by PURE deterministic hash only. Sticky persistence
//! (the `.sticky` flag → `_experiment_assignments`) arrives in PR2.

const std = @import("std");
const features = @import("features.zig");

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
/// value, or null) replaces the declared weights when valid. Resolution is a pure hash
/// bucket (PR1 — no sticky storage). The returned slice is one of `def.variants`
/// (static), so it outlives `alloc`.
pub fn resolveExperiment(
    alloc: std.mem.Allocator,
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
    const idx = bucket(def.name, subject, weights);
    return def.variants[idx];
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
        exps_out[i] = .{ .name = def.name, .variant = try resolveExperiment(alloc, ov, def, subject) };
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
        if (std.mem.eql(u8, try resolveExperiment(a, null, def, subj), "control")) control_default += 1;
        if (std.mem.eql(u8, try resolveExperiment(a, "[100,0]", def, subj), "control")) control_override += 1;
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
    try std.testing.expectEqualStrings("control", try resolveExperiment(a, "not json", def, "x"));
    try std.testing.expectEqualStrings("control", try resolveExperiment(a, "[1,2,3]", def, "x"));
    try std.testing.expectEqualStrings("control", try resolveExperiment(a, "[0,0]", def, "x"));
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
