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

test "runs at comptime" {
    const v = comptime parse("2026-01-01") catch unreachable;
    try std.testing.expectEqual(v, try parse("2026-01-01"));
}
