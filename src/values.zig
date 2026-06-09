const std = @import("std");

pub const ValueError = error{ TypeMismatch, TooPrecise, Overflow, BadNumber, BadSelect, NotObject } || std.mem.Allocator.Error;

pub fn decimalToScaledInt(s: []const u8, scale: u8) ValueError!i64 {
    if (s.len == 0) return error.BadNumber;
    var i: usize = 0;
    var neg = false;
    if (s[0] == '-') { neg = true; i = 1; } else if (s[0] == '+') { i = 1; }
    var int_part: i64 = 0;
    var seen = false;
    while (i < s.len and s[i] != '.') : (i += 1) {
        if (s[i] < '0' or s[i] > '9') return error.BadNumber;
        seen = true;
        int_part = std.math.mul(i64, int_part, 10) catch return error.Overflow;
        int_part = std.math.add(i64, int_part, s[i] - '0') catch return error.Overflow;
    }
    var frac: i64 = 0;
    var fdigits: u8 = 0;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len) : (i += 1) {
            if (s[i] < '0' or s[i] > '9') return error.BadNumber;
            seen = true;
            if (fdigits >= scale) return error.TooPrecise;
            frac = frac * 10 + (s[i] - '0');
            fdigits += 1;
        }
    }
    if (!seen) return error.BadNumber;
    var pow: i64 = 1;
    var k: u8 = 0;
    while (k < scale) : (k += 1) pow = std.math.mul(i64, pow, 10) catch return error.Overflow;
    while (fdigits < scale) : (fdigits += 1) frac *= 10;
    var result = std.math.mul(i64, int_part, pow) catch return error.Overflow;
    result = std.math.add(i64, result, frac) catch return error.Overflow;
    return if (neg) -result else result;
}

pub fn scaledIntToDecimal(alloc: std.mem.Allocator, v: i64, scale: u8) ![]u8 {
    if (scale == 0) return std.fmt.allocPrint(alloc, "{d}", .{v});
    // -minInt(i64) overflows; only reachable via direct DB tampering since
    // decimalToScaledInt is overflow-checked. Reject rather than panic.
    if (v == std.math.minInt(i64)) return error.Overflow;
    var pow: i64 = 1;
    var k: u8 = 0;
    while (k < scale) : (k += 1) pow *= 10;
    const neg = v < 0;
    const av: i64 = if (neg) -v else v;
    const int_part = @divTrunc(av, pow);
    const frac_part = @rem(av, pow);
    var fbuf: [24]u8 = undefined;
    const fs = try std.fmt.bufPrint(&fbuf, "{d}", .{frac_part});
    const pad = scale - @as(u8, @intCast(fs.len));
    var ibuf: [24]u8 = undefined;
    const is = try std.fmt.bufPrint(&ibuf, "{d}", .{int_part});
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    if (neg) try out.append(alloc, '-');
    try out.appendSlice(alloc, is);
    try out.append(alloc, '.');
    var p: u8 = 0;
    while (p < pad) : (p += 1) try out.append(alloc, '0');
    try out.appendSlice(alloc, fs);
    return out.toOwnedSlice(alloc);
}

test "decimalToScaledInt: scale 2" {
    try std.testing.expectEqual(@as(i64, 1050), try decimalToScaledInt("10.50", 2));
    try std.testing.expectEqual(@as(i64, 1050), try decimalToScaledInt("10.5", 2));
    try std.testing.expectEqual(@as(i64, 1000), try decimalToScaledInt("10", 2));
    try std.testing.expectEqual(@as(i64, -5), try decimalToScaledInt("-0.05", 2));
    try std.testing.expectEqual(@as(i64, 0), try decimalToScaledInt("0", 2));
    try std.testing.expectError(error.TooPrecise, decimalToScaledInt("10.123", 2));
    try std.testing.expectError(error.BadNumber, decimalToScaledInt("abc", 2));
    try std.testing.expectError(error.BadNumber, decimalToScaledInt("", 2));
}

test "decimalToScaledInt: scale 0 (int)" {
    try std.testing.expectEqual(@as(i64, 42), try decimalToScaledInt("42", 0));
    try std.testing.expectEqual(@as(i64, -7), try decimalToScaledInt("-7", 0));
    try std.testing.expectError(error.TooPrecise, decimalToScaledInt("4.2", 0));
    try std.testing.expectEqual(@as(i64, 9007199254740993), try decimalToScaledInt("9007199254740993", 0));
}

test "scaledIntToDecimal round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("10.50", try scaledIntToDecimal(a, 1050, 2));
    try std.testing.expectEqualStrings("-0.05", try scaledIntToDecimal(a, -5, 2));
    try std.testing.expectEqualStrings("0.00", try scaledIntToDecimal(a, 0, 2));
    try std.testing.expectEqualStrings("42", try scaledIntToDecimal(a, 42, 0));
    try std.testing.expectEqualStrings("9007199254740993", try scaledIntToDecimal(a, 9007199254740993, 0));
}
