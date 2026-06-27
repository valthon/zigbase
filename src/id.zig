const std = @import("std");
const entropy = @import("entropy.zig");

/// Lowercase base36 — safe in URLs, table names, and JSON without escaping.
const alphabet = "0123456789abcdefghijklmnopqrstuvwxyz";

/// Fill `out` with random base36 characters. Entropy is sourced via `entropy.fill`,
/// which uses the seeded deterministic PRNG when `ZIGBASE_FAKE_SEED` is set on a dev
/// build, otherwise falls back to `io.random` (the OS CSPRNG). On a production build
/// the seeded path is comptime-dead and this is exactly `io.random`.
///
/// Uses rejection sampling so each character is uniformly distributed (no modulo bias):
/// random bytes >= the largest multiple of alphabet.len that fits in a byte are discarded
/// and redrawn (256 % 36 = 4 -> reject bytes >= 252).
pub fn generate(io: std.Io, out: []u8) void {
    const limit: u8 = @intCast(256 - (256 % alphabet.len)); // 252 for len 36
    var i: usize = 0;
    var b: [1]u8 = undefined;
    while (i < out.len) {
        entropy.fill(io, &b);
        if (b[0] >= limit) continue; // reject to keep the mapping uniform
        out[i] = alphabet[b[0] % alphabet.len];
        i += 1;
    }
}

/// 15-char id for collections and records.
pub fn collectionId(io: std.Io) [15]u8 {
    var buf: [15]u8 = undefined;
    generate(io, &buf);
    return buf;
}

/// 8-char id for fields.
pub fn fieldId(io: std.Io) [8]u8 {
    var buf: [8]u8 = undefined;
    generate(io, &buf);
    return buf;
}

test "generate fills exact length with base36 chars" {
    var buf: [15]u8 = undefined;
    generate(std.testing.io, &buf);
    for (buf) |c| try std.testing.expect(std.mem.indexOfScalar(u8, alphabet, c) != null);
}

test "ids vary between calls" {
    const a = collectionId(std.testing.io);
    const b = collectionId(std.testing.io);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    try std.testing.expectEqual(@as(usize, 8), fieldId(std.testing.io).len);
}

test "with a seed: generate is deterministic (dev builds only)" {
    if (!entropy.enabled) return error.SkipZigTest;
    entropy.setForTest(999);
    defer entropy.resetForTest();

    var a: [15]u8 = undefined;
    generate(std.testing.io, &a);

    // Re-seed identically — must produce the same ID.
    entropy.setForTest(999);
    var b: [15]u8 = undefined;
    generate(std.testing.io, &b);

    try std.testing.expectEqualSlices(u8, &a, &b);
    // And the output must be all valid base36 chars.
    for (a) |c| try std.testing.expect(std.mem.indexOfScalar(u8, alphabet, c) != null);
}

test "with a seed: collectionId and fieldId are deterministic (dev builds only)" {
    if (!entropy.enabled) return error.SkipZigTest;
    entropy.setForTest(777);
    defer entropy.resetForTest();
    const cid1 = collectionId(std.testing.io);

    entropy.setForTest(777);
    const cid2 = collectionId(std.testing.io);
    try std.testing.expectEqualSlices(u8, &cid1, &cid2);

    entropy.setForTest(777);
    const fid1 = fieldId(std.testing.io);
    entropy.setForTest(777);
    const fid2 = fieldId(std.testing.io);
    try std.testing.expectEqualSlices(u8, &fid1, &fid2);
}

test "generate is unbiased across the alphabet (rejection sampling)" {
    var counts = [_]usize{0} ** alphabet.len;
    var buf: [4000]u8 = undefined;
    generate(std.testing.io, &buf);
    for (buf) |c| {
        const idx = std.mem.indexOfScalar(u8, alphabet, c).?;
        counts[idx] += 1;
    }
    // With a biased modulo map, digits 0-3 would appear ~9% more often. Assert every
    // symbol shows up and no symbol is wildly over-represented (expected ~111 each).
    for (counts) |n| try std.testing.expect(n > 40 and n < 200);
}
