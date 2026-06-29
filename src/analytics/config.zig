//! Comptime lowering + validation of the `.analytics = .{ .rollups = .{ … } }` config (#158).
//!
//! Each `.rollups.<name>` entry becomes a `RollupSpec`; `framework.zig` registers one scheduled
//! job per spec. Misconfiguration fails LOUDLY at compile time (unknown key, unknown `.metric` /
//! `.group_by`, a missing/empty `.event`, a non-identifier rollup name, a bad shape) — never a
//! silent runtime no-op.
//!
//! Config shape:
//! ```zig
//! .analytics = .{
//!     .rollups = .{
//!         .signups_daily = .{
//!             .event = "user.signup",
//!             .every = .{ .interval = .hourly },          // a schedule.Schedule
//!             .group_by = .{ .account = true, .time_bucket = .day },
//!             .metric = .count,                            // optional, default .count
//!         },
//!     },
//! }
//! ```

const std = @import("std");
const schema = @import("../schema.zig");
const schedule = @import("../schedule.zig");
const analytics = @import("analytics.zig");

const RollupSpec = analytics.RollupSpec;

/// Validate `.analytics` and lower its `.rollups` into a static `[]const RollupSpec`. Empty slice
/// when `.analytics` is absent or declares no rollups.
pub fn rollupSpecs(comptime acfg: anytype) []const RollupSpec {
    const ACT = @TypeOf(acfg);
    if (@typeInfo(ACT) != .@"struct")
        @compileError(".analytics must be a struct, e.g. '.{ .rollups = .{ … } }'");
    for (std.meta.fields(ACT)) |f| {
        if (!std.mem.eql(u8, f.name, "rollups"))
            @compileError(".analytics: unknown key '." ++ f.name ++ "' (recognized: .rollups)");
    }
    if (!@hasField(ACT, "rollups")) return &.{};

    const rcfg = acfg.rollups;
    const RT = @TypeOf(rcfg);
    if (@typeInfo(RT) != .@"struct")
        @compileError(".analytics.rollups must be a struct of named rollups, e.g. '.{ .signups_daily = .{ … } }'");

    const fields = std.meta.fields(RT);
    const Holder = struct {
        const table: [fields.len]RollupSpec = blk: {
            var t: [fields.len]RollupSpec = undefined;
            for (fields, 0..) |f, i| t[i] = lowerOne(f.name, @field(rcfg, f.name));
            break :blk t;
        };
    };
    return &Holder.table;
}

/// Lower a single `.rollups.<name> = .{ … }` entry into a `RollupSpec`, validating every key.
fn lowerOne(comptime name: []const u8, comptime entry: anytype) RollupSpec {
    if (!schema.isValidIdentifier(name))
        @compileError(".analytics.rollups: rollup name '" ++ name ++ "' is not a valid identifier " ++
            "(it names the _rollup_<name> summary table; use letters/digits/underscore, letter-first)");

    const ET = @TypeOf(entry);
    if (@typeInfo(ET) != .@"struct")
        @compileError(".analytics.rollups." ++ name ++ " must be a struct '.{ .event = \"…\", .every = …, … }'");

    // Reject unknown keys.
    for (std.meta.fields(ET)) |f| {
        const ok = std.mem.eql(u8, f.name, "event") or std.mem.eql(u8, f.name, "every") or
            std.mem.eql(u8, f.name, "group_by") or std.mem.eql(u8, f.name, "metric");
        if (!ok)
            @compileError(".analytics.rollups." ++ name ++ ": unknown key '." ++ f.name ++
                "' (recognized: .event, .every, .group_by, .metric)");
    }

    if (!@hasField(ET, "event"))
        @compileError(".analytics.rollups." ++ name ++ " is missing required key '.event' (the _events.name to aggregate)");
    const event: []const u8 = entry.event;
    if (event.len == 0)
        @compileError(".analytics.rollups." ++ name ++ ": '.event' is empty — a rollup must reference an event name");

    if (!@hasField(ET, "every"))
        @compileError(".analytics.rollups." ++ name ++ " is missing required key '.every' (a cron/interval Schedule, e.g. '.{ .interval = .hourly }')");
    const every: schedule.Schedule = lowerEvery(name, entry.every);

    var spec = RollupSpec{
        .name = name,
        .event = event,
        .every = every,
        .group_account = false,
        .group_actor = false,
        .time_bucket = .none,
        .metric = .count,
    };

    if (@hasField(ET, "group_by")) lowerGroupBy(name, entry.group_by, &spec);
    if (@hasField(ET, "metric")) spec.metric = lowerMetric(name, entry.metric);

    return spec;
}

/// Lower `.every` into a `schedule.Schedule`. Accepts either an explicit `schedule.Schedule` value
/// or the ergonomic anonymous form (`.{ .cron = "…" }`, `.{ .interval = … }`, `.reactive`) — an
/// anonymous struct does not auto-coerce to the union once stored as a field, so reflect on it.
fn lowerEvery(comptime name: []const u8, comptime e: anytype) schedule.Schedule {
    const ET = @TypeOf(e);
    if (ET == schedule.Schedule) return e;
    if (@typeInfo(ET) == .enum_literal) {
        if (std.mem.eql(u8, @tagName(e), "reactive"))
            @compileError(".analytics.rollups." ++ name ++ ".every must be a cron/interval Schedule, not .reactive");
        @compileError(".analytics.rollups." ++ name ++ ".every: unexpected '." ++ @tagName(e) ++ "' (use '.{ .interval = .hourly }' or '.{ .cron = \"…\" }')");
    }
    if (@typeInfo(ET) != .@"struct")
        @compileError(".analytics.rollups." ++ name ++ ".every must be a Schedule, e.g. '.{ .interval = .hourly }' or '.{ .cron = \"0 * * * *\" }'");
    if (@hasField(ET, "cron")) return .{ .cron = e.cron };
    if (@hasField(ET, "interval")) return .{ .interval = lowerInterval(name, e.interval) };
    @compileError(".analytics.rollups." ++ name ++ ".every: expected '.cron' or '.interval', e.g. '.{ .interval = .hourly }'");
}

/// Lower an `.interval` value into `schedule.Interval`. Accepts the enum literals
/// (`.weekly`/`.daily`/`.hourly`), the anonymous `.{ .minutes = N }` form, or an explicit
/// `schedule.Interval` (anonymous literals do not auto-coerce once stored as a field).
fn lowerInterval(comptime name: []const u8, comptime iv: anytype) schedule.Interval {
    const IT = @TypeOf(iv);
    if (IT == schedule.Interval) return iv;
    if (@typeInfo(IT) == .enum_literal) {
        const t = @tagName(iv);
        if (std.mem.eql(u8, t, "weekly")) return .weekly;
        if (std.mem.eql(u8, t, "daily")) return .daily;
        if (std.mem.eql(u8, t, "hourly")) return .hourly;
        @compileError(".analytics.rollups." ++ name ++ ".every.interval: unknown '." ++ t ++ "' (recognized: .weekly, .daily, .hourly, .{ .minutes = N })");
    }
    if (@typeInfo(IT) == .@"struct" and @hasField(IT, "minutes")) return .{ .minutes = iv.minutes };
    @compileError(".analytics.rollups." ++ name ++ ".every.interval must be .weekly/.daily/.hourly or '.{ .minutes = N }'");
}

/// Lower `.group_by = .{ .account = bool, .actor = bool, .time_bucket = .day|.hour }` onto `spec`.
fn lowerGroupBy(comptime name: []const u8, comptime gcfg: anytype, comptime spec: *RollupSpec) void {
    const GT = @TypeOf(gcfg);
    if (@typeInfo(GT) != .@"struct")
        @compileError(".analytics.rollups." ++ name ++ ".group_by must be a struct, e.g. '.{ .account = true, .time_bucket = .day }'");
    for (std.meta.fields(GT)) |f| {
        const ok = std.mem.eql(u8, f.name, "account") or std.mem.eql(u8, f.name, "actor") or
            std.mem.eql(u8, f.name, "time_bucket");
        if (!ok)
            @compileError(".analytics.rollups." ++ name ++ ".group_by: unknown key '." ++ f.name ++
                "' (recognized: .account, .actor, .time_bucket)");
    }
    if (@hasField(GT, "account")) spec.group_account = gcfg.account;
    if (@hasField(GT, "actor")) spec.group_actor = gcfg.actor;
    if (@hasField(GT, "time_bucket")) spec.time_bucket = lowerTimeBucket(name, gcfg.time_bucket);
}

fn lowerTimeBucket(comptime name: []const u8, comptime tb: anytype) analytics.TimeBucket {
    if (@typeInfo(@TypeOf(tb)) != .enum_literal)
        @compileError(".analytics.rollups." ++ name ++ ".group_by.time_bucket must be .none, .day, or .hour");
    const t = @tagName(tb);
    if (std.mem.eql(u8, t, "none")) return .none;
    if (std.mem.eql(u8, t, "day")) return .day;
    if (std.mem.eql(u8, t, "hour")) return .hour;
    @compileError(".analytics.rollups." ++ name ++ ".group_by.time_bucket: unknown value '." ++ t ++ "' (recognized: .none, .day, .hour)");
}

fn lowerMetric(comptime name: []const u8, comptime m: anytype) analytics.Metric {
    if (@typeInfo(@TypeOf(m)) != .enum_literal)
        @compileError(".analytics.rollups." ++ name ++ ".metric must be .count");
    const t = @tagName(m);
    if (std.mem.eql(u8, t, "count")) return .count;
    @compileError(".analytics.rollups." ++ name ++ ".metric: unknown value '." ++ t ++ "' (recognized: .count)");
}

// ---------------------------------------------------------------------------
// Tests (comptime lowering)
// ---------------------------------------------------------------------------

test "rollupSpecs lowers a full rollup config" {
    const specs = comptime rollupSpecs(.{ .rollups = .{
        .signups_daily = .{
            .event = "user.signup",
            .every = .{ .interval = .hourly },
            .group_by = .{ .account = true, .time_bucket = .day },
            .metric = .count,
        },
        .clicks_hourly = .{
            .event = "link.click",
            .every = .{ .cron = "0 * * * *" },
            .group_by = .{ .account = true, .actor = true, .time_bucket = .hour },
        },
    } });
    try std.testing.expectEqual(@as(usize, 2), specs.len);

    try std.testing.expectEqualStrings("signups_daily", specs[0].name);
    try std.testing.expectEqualStrings("user.signup", specs[0].event);
    try std.testing.expect(specs[0].group_account and !specs[0].group_actor);
    try std.testing.expect(specs[0].time_bucket == .day);
    try std.testing.expect(specs[0].metric == .count);
    try std.testing.expect(specs[0].every == .interval);

    try std.testing.expectEqualStrings("clicks_hourly", specs[1].name);
    try std.testing.expect(specs[1].group_account and specs[1].group_actor);
    try std.testing.expect(specs[1].time_bucket == .hour);
    try std.testing.expect(specs[1].every == .cron);
}

test "rollupSpecs: absent .rollups yields empty" {
    const specs = comptime rollupSpecs(.{});
    try std.testing.expectEqual(@as(usize, 0), specs.len);
}

test "rollupSpecs: defaults (no group_by, no metric) -> ungrouped count" {
    const specs = comptime rollupSpecs(.{ .rollups = .{
        .total = .{ .event = "page.view", .every = .{ .interval = .{ .minutes = 5 } } },
    } });
    try std.testing.expectEqual(@as(usize, 1), specs.len);
    try std.testing.expect(!specs[0].group_account and !specs[0].group_actor);
    try std.testing.expect(specs[0].time_bucket == .none);
    try std.testing.expect(specs[0].metric == .count);
}
