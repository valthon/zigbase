const std = @import("std");

/// Lowercase base36 — safe in URLs, table names, and JSON without escaping.
const alphabet = "0123456789abcdefghijklmnopqrstuvwxyz";

/// Fill `out` with random base36 characters. `io` supplies entropy.
pub fn generate(io: std.Io, out: []u8) void {
    io.random(out);
    for (out) |*b| b.* = alphabet[b.* % alphabet.len];
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
