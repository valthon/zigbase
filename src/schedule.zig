const std = @import("std");

pub const Interval = union(enum) { weekly, daily, hourly, minutes: u64 };
/// A job's firing schedule. For `interval` schedules the next fire is measured from the
/// previous run's COMPLETION (via completeJob -> after + period), not a fixed wall-clock
/// cadence, so long-running jobs drift; runs never overlap (single-flight).
pub const Schedule = union(enum) { cron: []const u8, interval: Interval, reactive };
pub const Reactive = union(enum) { after: Interval, stop };

pub fn periodSeconds(iv: Interval) i64 {
    return switch (iv) {
        .weekly => 7 * 86400,
        .daily => 86400,
        .hourly => 3600,
        .minutes => |m| @as(i64, @intCast(m)) * 60,
    };
}

/// Case-insensitive 3-letter month (`JAN`..`DEC` = 1..12) and day-of-week
/// (`SUN`..`SAT` = 0..6) names, mirroring Vixie cron. The month and day name sets do
/// not overlap, so a single combined lookup is unambiguous. Returns null for anything else.
fn cronNameToNum(tok: []const u8) ?u32 {
    // Every alias is exactly 3 chars — reject anything else before the linear scan.
    if (tok.len != 3) return null;
    const names = [_]struct { name: []const u8, num: u32 }{
        .{ .name = "JAN", .num = 1 },  .{ .name = "FEB", .num = 2 },  .{ .name = "MAR", .num = 3 },
        .{ .name = "APR", .num = 4 },  .{ .name = "MAY", .num = 5 },  .{ .name = "JUN", .num = 6 },
        .{ .name = "JUL", .num = 7 },  .{ .name = "AUG", .num = 8 },  .{ .name = "SEP", .num = 9 },
        .{ .name = "OCT", .num = 10 }, .{ .name = "NOV", .num = 11 }, .{ .name = "DEC", .num = 12 },
        .{ .name = "SUN", .num = 0 },  .{ .name = "MON", .num = 1 },  .{ .name = "TUE", .num = 2 },
        .{ .name = "WED", .num = 3 },  .{ .name = "THU", .num = 4 },  .{ .name = "FRI", .num = 5 },
        .{ .name = "SAT", .num = 6 },
    };
    for (names) |entry| {
        if (std.ascii.eqlIgnoreCase(tok, entry.name)) return entry.num;
    }
    return null;
}

/// Parse a cron sub-token as either a decimal number or a 3-letter name alias; null if neither.
/// Numbers are tried first: they are by far the common case, and `nextFire` evaluates a field
/// up to ~532k times (minute-by-minute over ~370 days), so a numeric token must not pay for a
/// scan of the 19 name aliases.
fn parseCronNum(tok: []const u8) ?u32 {
    return (std.fmt.parseInt(u32, tok, 10) catch null) orelse cronNameToNum(tok);
}

/// Does a single cron field match `value`? Supports `*`, `a`, `a,b,c`, `a-b`, `*/n`, plus
/// case-insensitive 3-letter month (`JAN`..`DEC`) / day-of-week (`SUN`..`SAT`) names in the
/// bare and range forms (steps stay numeric). Evaluated in UTC. `min`/`max` are accepted for
/// signature symmetry. Parsing is best-effort: an unparseable sub-part is silently skipped
/// (catch continue) rather than rejecting the whole field, so a typo'd field may match
/// unexpectedly.
pub fn cronFieldMatches(field: []const u8, value: u32, min: u32, max: u32) bool {
    _ = min;
    _ = max;
    var it = std.mem.splitScalar(u8, field, ',');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "*")) return true;
        if (std.mem.startsWith(u8, part, "*/")) {
            const step = std.fmt.parseInt(u32, part[2..], 10) catch continue;
            if (step != 0 and value % step == 0) return true;
            continue;
        }
        if (std.mem.indexOfScalar(u8, part, '-')) |dash| {
            const lo = parseCronNum(part[0..dash]) orelse continue;
            const hi = parseCronNum(part[dash + 1 ..]) orelse continue;
            if (value >= lo and value <= hi) return true;
            continue;
        }
        const n = parseCronNum(part) orelse continue;
        if (n == value) return true;
    }
    return false;
}

const Civil = struct { minute: u32, hour: u32, dom: u32, month: u32, dow: u32 };

/// Decompose a unix timestamp into UTC civil fields (Howard Hinnant's algorithm).
fn civilFromUnix(t: i64) Civil {
    const days = @divFloor(t, 86400);
    const secs_of_day: u32 = @intCast(t - days * 86400);
    const minute = (secs_of_day / 60) % 60;
    const hour = secs_of_day / 3600;
    const dow: u32 = @intCast(@mod(days + 4, 7)); // 1970-01-01 = Thursday(4); 0=Sun..6=Sat
    const z = days + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d = doy - (153 * mp + 2) / 5 + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .minute = minute, .hour = hour, .dom = @intCast(d), .month = @intCast(m), .dow = dow };
}

/// Matches a 5-field cron expression against UTC time `t`. Day-of-month and day-of-week
/// are ANDed (both must match); this differs from Vixie cron, which ORs them when one is `*`.
fn cronMatchesAt(expr: []const u8, t: i64) bool {
    var it = std.mem.splitScalar(u8, expr, ' ');
    const f_min = it.next() orelse return false;
    const f_hour = it.next() orelse return false;
    const f_dom = it.next() orelse return false;
    const f_mon = it.next() orelse return false;
    const f_dow = it.next() orelse return false;
    if (it.next() != null) return false; // exactly 5 fields
    const c = civilFromUnix(t);
    return cronFieldMatches(f_min, c.minute, 0, 59) and
        cronFieldMatches(f_hour, c.hour, 0, 23) and
        cronFieldMatches(f_dom, c.dom, 1, 31) and
        cronFieldMatches(f_mon, c.month, 1, 12) and
        cronFieldMatches(f_dow, c.dow, 0, 6);
}

/// Next fire strictly after `after_unix` (all times are UTC):
/// - interval: after + periodSeconds
/// - reactive: null (handler return drives the next fire)
/// - cron: next whole UTC minute matching the expression (searched up to ~370 days); null if none/invalid.
///
/// Cron expressions accept case-insensitive 3-letter month (`JAN`..`DEC`) and day-of-week
/// (`SUN`..`SAT`) names as well as numbers, and are evaluated in UTC. Day-of-month
/// and day-of-week are ANDed (both must match); this differs from Vixie cron, which ORs them
/// when one is `*`.
pub fn nextFire(sched: Schedule, after_unix: i64) ?i64 {
    switch (sched) {
        .interval => |iv| return after_unix + periodSeconds(iv),
        .reactive => return null,
        .cron => |expr| {
            var t = (@divFloor(after_unix, 60) + 1) * 60;
            const limit = t + 370 * 86400;
            while (t <= limit) : (t += 60) {
                if (cronMatchesAt(expr, t)) return t;
            }
            return null;
        },
    }
}

test "periodSeconds maps interval presets and minutes" {
    try std.testing.expectEqual(@as(i64, 3600), periodSeconds(.hourly));
    try std.testing.expectEqual(@as(i64, 86400), periodSeconds(.daily));
    try std.testing.expectEqual(@as(i64, 7 * 86400), periodSeconds(.weekly));
    try std.testing.expectEqual(@as(i64, 15 * 60), periodSeconds(.{ .minutes = 15 }));
}

test "nextFire interval = after + period" {
    try std.testing.expectEqual(@as(?i64, 1000 + 3600), nextFire(.{ .interval = .hourly }, 1000));
    try std.testing.expectEqual(@as(?i64, 1000 + 900), nextFire(.{ .interval = .{ .minutes = 15 } }, 1000));
}

test "nextFire reactive returns null (driven by the handler's return)" {
    try std.testing.expectEqual(@as(?i64, null), nextFire(.reactive, 1000));
}

test "nextFire cron: every minute" {
    try std.testing.expectEqual(@as(?i64, 1020), nextFire(.{ .cron = "* * * * *" }, 1000));
}

test "cron field matching: lists, ranges, steps, wildcard" {
    try std.testing.expect(cronFieldMatches("*", 5, 0, 59));
    try std.testing.expect(cronFieldMatches("5", 5, 0, 59));
    try std.testing.expect(!cronFieldMatches("5", 6, 0, 59));
    try std.testing.expect(cronFieldMatches("1,5,9", 5, 0, 59));
    try std.testing.expect(cronFieldMatches("10-20", 15, 0, 59));
    try std.testing.expect(!cronFieldMatches("10-20", 21, 0, 59));
    try std.testing.expect(cronFieldMatches("*/15", 30, 0, 59));
    try std.testing.expect(!cronFieldMatches("*/15", 31, 0, 59));
}

test "nextFire cron: daily at 03:00 UTC" {
    // 2021-01-01 02:59:00 UTC = 1609469940 ; next "0 3 * * *" = 2021-01-01 03:00:00 = 1609470000.
    try std.testing.expectEqual(@as(?i64, 1609470000), nextFire(.{ .cron = "0 3 * * *" }, 1609469940));
}

test "nextFire cron: weekly on a specific weekday (Mon 00:00 UTC)" {
    // 2021-01-04 is a Monday (dow=1). 2021-01-03 23:59:00 UTC = 1609718340 ; next "0 0 * * 1" = 1609718400.
    try std.testing.expectEqual(@as(?i64, 1609718400), nextFire(.{ .cron = "0 0 * * 1" }, 1609718340));
}

test "cron month name aliases" {
    try std.testing.expect(cronFieldMatches("JAN", 1, 1, 12));
    try std.testing.expect(cronFieldMatches("DEC", 12, 1, 12));
    try std.testing.expect(!cronFieldMatches("JAN", 2, 1, 12));
    // case-insensitive
    try std.testing.expect(cronFieldMatches("jan", 1, 1, 12));
    try std.testing.expect(cronFieldMatches("Feb", 2, 1, 12));
}

test "cron day-of-week name aliases" {
    try std.testing.expect(cronFieldMatches("SUN", 0, 0, 6));
    try std.testing.expect(cronFieldMatches("MON", 1, 0, 6));
    try std.testing.expect(cronFieldMatches("SAT", 6, 0, 6));
}

test "cron name ranges and lists" {
    // MON-FRI matches 1..5, not 0 or 6.
    var v: u32 = 0;
    while (v <= 6) : (v += 1) {
        const expect_match = v >= 1 and v <= 5;
        try std.testing.expectEqual(expect_match, cronFieldMatches("MON-FRI", v, 0, 6));
    }
    try std.testing.expect(cronFieldMatches("JAN,JUL", 7, 1, 12));
}

test "cron steps stay numeric and unknown tokens are skipped" {
    try std.testing.expect(cronFieldMatches("*/2", 4, 0, 59));
    try std.testing.expect(!cronFieldMatches("FOO", 3, 0, 59));
}

test "nextFire cron: name-based month equals numeric equivalent" {
    // "0 0 1 JAN *" must fire on the same instant as "0 0 1 1 *".
    const after: i64 = 1609459200; // 2021-01-01 00:00:00 UTC
    try std.testing.expectEqual(
        nextFire(.{ .cron = "0 0 1 1 *" }, after),
        nextFire(.{ .cron = "0 0 1 JAN *" }, after),
    );
    // And a name-based dow expr matches its numeric equivalent.
    try std.testing.expectEqual(
        nextFire(.{ .cron = "0 0 * * 1" }, 1609718340),
        nextFire(.{ .cron = "0 0 * * MON" }, 1609718340),
    );
}
