//! RFC 6238 authenticator-app codes: SHA-1, six digits, 30-second steps.
//! The caller persists the returned step atomically with successful authentication.
const std = @import("std");

pub const secret_length = 20;
pub const step_seconds = 30;

fn hotp(secret: []const u8, step: u64) u32 {
    var counter: [8]u8 = undefined;
    std.mem.writeInt(u64, &counter, step, .big);
    var digest: [20]u8 = undefined;
    std.crypto.auth.hmac.HmacSha1.create(&digest, &counter, secret);
    const offset: usize = digest[19] & 15;
    return std.mem.readInt(u32, digest[offset..][0..4], .big) & 0x7fffffff;
}

pub fn code(secret: []const u8, step: u64) [6]u8 {
    var result: [6]u8 = undefined;
    var value = hotp(secret, step) % 1_000_000;
    var i: usize = result.len;
    while (i > 0) {
        i -= 1;
        result[i] = @as(u8, @intCast(value % 10)) + '0';
        value /= 10;
    }
    return result;
}

/// Accept at most one step of clock skew in either direction. Reject steps at
/// or before last_step, including reuse through a different pending login.
pub fn verify(secret: []const u8, submitted: []const u8, unix_seconds: i64, last_step: i64) ?i64 {
    if (submitted.len != 6 or unix_seconds < 0) return null;
    for (submitted) |ch| if (ch < '0' or ch > '9') return null;
    const current = @divFloor(unix_seconds, step_seconds);
    var matched: ?i64 = null;
    for ([_]i64{ -1, 0, 1 }) |delta| {
        const candidate = current + delta;
        if (candidate < 0 or candidate <= last_step) continue;
        const expected = code(secret, @intCast(candidate));
        if (std.crypto.timing_safe.eql([6]u8, expected, submitted[0..6].*)) matched = candidate;
    }
    return matched;
}

/// Unpadded RFC 4648 Base32 for a randomly generated 160-bit enrollment secret.
pub fn encodeSecret(secret: [secret_length]u8) [32]u8 {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    var out: [32]u8 = undefined;
    for (0..4) |group| {
        var bits: u40 = 0;
        for (secret[group * 5 ..][0..5]) |byte| bits = (bits << 8) | byte;
        for (0..8) |i| out[group * 8 + i] = alphabet[@as(u5, @truncate(bits >> @as(u6, @intCast(35 - i * 5))))];
    }
    return out;
}

test "RFC 6238 SHA-1 vectors including timestamps beyond 2038" {
    const secret = "12345678901234567890";
    const times = [_]u64{ 59, 1111111109, 1111111111, 1234567890, 2000000000, 20000000000 };
    const expected = [_]u32{ 94287082, 7081804, 14050471, 89005924, 69279037, 65353130 };
    for (times, expected) |timestamp, value| {
        try std.testing.expectEqual(value, hotp(secret, timestamp / step_seconds) % 100_000_000);
    }
}

test "TOTP verification bounds skew, rejects malformed codes and replay" {
    const secret = "12345678901234567890";
    const previous = code(secret, 99);
    const current = code(secret, 100);
    const next = code(secret, 101);
    const distant = code(secret, 102);
    try std.testing.expectEqual(@as(?i64, 99), verify(secret, &previous, 3000, -1));
    try std.testing.expectEqual(@as(?i64, 100), verify(secret, &current, 3000, -1));
    try std.testing.expectEqual(@as(?i64, 101), verify(secret, &next, 3000, -1));
    try std.testing.expectEqual(null, verify(secret, &distant, 3000, -1));
    try std.testing.expectEqual(null, verify(secret, &current, 3000, 100));
    try std.testing.expectEqual(null, verify(secret, &previous, 3000, 100));
    try std.testing.expectEqual(null, verify(secret, "12345", 3000, -1));
    try std.testing.expectEqual(null, verify(secret, "12a456", 3000, -1));
    try std.testing.expectEqual(null, verify(secret, &current, -1, -1));
    const first = code(secret, 0);
    try std.testing.expectEqual(@as(?i64, 0), verify(secret, &first, 0, -1));
}

test "enrollment secret Base32 matches RFC encoding" {
    const encoded = encodeSecret("12345678901234567890".*);
    try std.testing.expectEqualStrings("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", &encoded);
}
