//! Minimal, dependency-free date/datetime parsing for `date` field min/max
//! enforcement. Pure Zig, so it runs at BOTH comptime (validating schema-literal
//! bounds via @compileError) and runtime (validating record values). Parses to
//! UTC seconds since the Unix epoch for ordered comparison.

const std = @import("std");

pub const ParseError = error{ InvalidFormat, OutOfRange };

/// Parse an accepted date/datetime string to UTC seconds since 1970-01-01T00:00:00Z.
/// Accepted grammar:
///   YYYY-MM-DD
///   YYYY-MM-DD( |T)HH:MM[:SS][.fff...]
///   ...optionally followed by 'Z' or ±HH:MM
/// A missing zone is treated as UTC. Components are range-checked (leap years
/// included); trailing garbage is rejected.
pub fn parse(s: []const u8) ParseError!i64 {
    var i: usize = 0;
    const year = try readN(s, &i, 4);
    try lit(s, &i, '-');
    const month = try readN(s, &i, 2);
    try lit(s, &i, '-');
    const day = try readN(s, &i, 2);

    if (month < 1 or month > 12) return error.OutOfRange;
    if (day < 1 or day > daysInMonth(year, month)) return error.OutOfRange;

    var hour: i64 = 0;
    var min: i64 = 0;
    var sec: i64 = 0;
    var offset: i64 = 0; // seconds east of UTC

    if (i < s.len) {
        if (s[i] != 'T' and s[i] != ' ') return error.InvalidFormat;
        i += 1;
        hour = try readN(s, &i, 2);
        try lit(s, &i, ':');
        min = try readN(s, &i, 2);
        if (i < s.len and s[i] == ':') {
            i += 1;
            sec = try readN(s, &i, 2);
            if (i < s.len and s[i] == '.') {
                i += 1;
                var any = false;
                while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) any = true;
                if (!any) return error.InvalidFormat;
            }
        }
        if (hour > 23 or min > 59 or sec > 59) return error.OutOfRange;
        if (i < s.len) {
            if (s[i] == 'Z') {
                i += 1;
            } else if (s[i] == '+' or s[i] == '-') {
                const sign: i64 = if (s[i] == '-') -1 else 1;
                i += 1;
                const oh = try readN(s, &i, 2);
                try lit(s, &i, ':');
                const om = try readN(s, &i, 2);
                if (oh > 23 or om > 59) return error.OutOfRange;
                offset = sign * (oh * 3600 + om * 60);
            }
        }
    }

    if (i != s.len) return error.InvalidFormat; // trailing garbage

    const days = daysFromCivil(year, month, day);
    return days * 86400 + hour * 3600 + min * 60 + sec - offset;
}

/// Inverse of `daysFromCivil`: a count of days since 1970-01-01 back to a civil
/// (year, month, day). Howard Hinnant's `civil_from_days`. The era term uses TRUNCATING
/// division with the `z - 146096` adjustment (exactly as Hinnant writes it) so it is correct
/// for negative day counts (pre-epoch); `@divFloor` here would double-correct and give the
/// wrong era for `z < 0`. Returns month in [1,12], day in [1,31].
fn civilFromDays(z_in: i64) struct { y: i64, m: i64, d: i64 } {
    const z = z_in + 719468;
    const era = @divTrunc(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365); // [0, 399]
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365]
    const mp = @divFloor(5 * doy + 2, 153); // [0, 11]
    const d = doy - @divFloor(153 * mp + 2, 5) + 1; // [1, 31]
    const m = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

/// Format UTC seconds-since-epoch as the canonical SQLite UTC datetime
/// `YYYY-MM-DD HH:MM:SS` (no zone suffix; SQLite reads a bare datetime as UTC, matching
/// `'now'`). Returns a fixed 19-byte array. The inverse of the space-form `parse`, so
/// `parse(&formatUtc(t)) == t` for any second-granular instant in range.
pub fn formatUtc(unix: i64) [19]u8 {
    const days = @divFloor(unix, 86400);
    const secs_of_day = @mod(unix, 86400); // [0, 86399], correct for negative unix via floor/mod
    const civ = civilFromDays(days);
    const hh = @divTrunc(secs_of_day, 3600);
    const mm = @divTrunc(@mod(secs_of_day, 3600), 60);
    const ss = @mod(secs_of_day, 60);
    var buf: [19]u8 = undefined;
    // Year is clamped to 4 digits by the caller's contract (frozen instants are modern);
    // bufPrint can't fail into a 19-byte buffer for in-range values.
    _ = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u64, @intCast(civ.y)), @as(u64, @intCast(civ.m)), @as(u64, @intCast(civ.d)),
        @as(u64, @intCast(hh)),    @as(u64, @intCast(mm)),    @as(u64, @intCast(ss)),
    }) catch unreachable;
    return buf;
}

/// Format UTC seconds-since-epoch as the canonical API timestamp
/// `YYYY-MM-DDTHH:MM:SSZ`. This shape sorts lexically across native and imported rows.
pub fn formatIsoUtc(unix: i64) [20]u8 {
    const stored = formatUtc(unix);
    var out: [20]u8 = undefined;
    @memcpy(out[0..19], &stored);
    out[10] = 'T';
    out[19] = 'Z';
    return out;
}

fn readN(s: []const u8, i: *usize, n: usize) ParseError!i64 {
    if (i.* + n > s.len) return error.InvalidFormat;
    var v: i64 = 0;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const c = s[i.* + k];
        if (c < '0' or c > '9') return error.InvalidFormat;
        v = v * 10 + @as(i64, c - '0');
    }
    i.* += n;
    return v;
}

fn lit(s: []const u8, i: *usize, c: u8) ParseError!void {
    if (i.* >= s.len or s[i.*] != c) return error.InvalidFormat;
    i.* += 1;
}

fn isLeap(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

fn daysInMonth(y: i64, m: i64) i64 {
    const tbl = [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (m == 2 and isLeap(y)) return 29;
    return tbl[@intCast(m - 1)];
}

/// Howard Hinnant's days_from_civil: days since 1970-01-01 (negative before).
/// Uses floor division so it is correct for negative years too.
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const mp = if (m > 2) m - 3 else m + 9; // Mar=0..Feb=11
    const doy = @divFloor(153 * mp + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

test "parses date-only" {
    try std.testing.expectEqual(@as(i64, 0), try parse("1970-01-01"));
    try std.testing.expectEqual(@as(i64, 86400), try parse("1970-01-02"));
}

test "parses canonical stored form (T...Z)" {
    const a = try parse("2026-06-10T08:00:00Z");
    const b = try parse("2026-06-10 08:00:00"); // space form, no zone == UTC
    try std.testing.expectEqual(a, b);
}

test "fractional seconds accepted, truncated" {
    const a = try parse("2026-06-10T08:00:00.123Z");
    const b = try parse("2026-06-10T08:00:00Z");
    try std.testing.expectEqual(a, b);
}

test "numeric offset folds to UTC" {
    // 10:00+02:00 == 08:00Z
    try std.testing.expectEqual(try parse("2026-06-10T08:00:00Z"), try parse("2026-06-10T10:00:00+02:00"));
}

test "rejects garbage time components" {
    try std.testing.expectError(error.OutOfRange, parse("2026-06-10 25:99:99"));
    try std.testing.expectError(error.OutOfRange, parse("2026-13-01"));
    try std.testing.expectError(error.OutOfRange, parse("2026-02-29")); // 2026 not leap
    _ = try parse("2024-02-29"); // 2024 is leap -> ok
}

test "rejects malformed shapes and trailing garbage" {
    try std.testing.expectError(error.InvalidFormat, parse("2026/06/10"));
    try std.testing.expectError(error.InvalidFormat, parse("2026-6-10"));
    try std.testing.expectError(error.InvalidFormat, parse("2026-06-10T08:00:00Zextra"));
    try std.testing.expectError(error.InvalidFormat, parse(""));
}

test "ordering is correct across mixed formats" {
    try std.testing.expect((try parse("2025-12-31 23:59:59")) < (try parse("2026-01-01")));
    try std.testing.expect((try parse("2026-12-31 23:59:59")) < (try parse("2027-01-01 00:00:00")));
}

test "formatUtc renders canonical UTC datetime and round-trips through parse" {
    try std.testing.expectEqualStrings("1970-01-01 00:00:00", &formatUtc(0));
    try std.testing.expectEqualStrings("1970-01-02 00:00:00", &formatUtc(86400));
    try std.testing.expectEqualStrings("2029-03-07 16:00:00", &formatUtc(1867593600));
    // round-trips: parse(formatUtc(t)) == t for a spread of instants, including pre-epoch.
    for ([_]i64{ 0, 86400, 1867593600, 1577836800, -86400, -1, 1718000000 }) |t| {
        try std.testing.expectEqual(t, try parse(&formatUtc(t)));
    }
    // Deep pre-epoch: before 0000-03-01 the internal day count goes negative (z < 0 in
    // civilFromDays), which is the regime where the era term must use TRUNCATING division.
    // @divFloor here would mis-compute the era and corrupt these; @divTrunc gets them right.
    try std.testing.expectEqualStrings("0001-01-01 00:00:00", &formatUtc(try parse("0001-01-01")));
    try std.testing.expectEqualStrings("0000-01-01 00:00:00", &formatUtc(try parse("0000-01-01")));
    try std.testing.expectEqual(try parse("0000-01-01"), try parse(&formatUtc(try parse("0000-01-01"))));
}

test "formatIsoUtc renders canonical API timestamps" {
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", &formatIsoUtc(0));
    try std.testing.expectEqual(
        try parse("2029-03-07T16:00:00Z"),
        try parse(&formatIsoUtc(1867593600)),
    );
}

test "runs at comptime" {
    const v = comptime parse("2026-01-01") catch unreachable;
    try std.testing.expectEqual(v, try parse("2026-01-01"));
}
