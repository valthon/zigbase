const std = @import("std");
const id = @import("id.zig");

const argon2 = std.crypto.pwhash.argon2;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// Hash a password with argon2id, returning a PHC-format string allocated from `alloc`.
pub fn hashPassword(io: std.Io, alloc: std.mem.Allocator, password: []const u8) ![]u8 {
    var buf: [256]u8 = undefined;
    const phc = try argon2.strHash(password, .{
        .allocator = alloc,
        .params = argon2.Params.interactive_2id,
    }, &buf, io);
    return alloc.dupe(u8, phc);
}

/// Verify a password against a PHC hash. Constant-time; returns false on any mismatch/parse error.
pub fn verifyPassword(io: std.Io, alloc: std.mem.Allocator, phc: []const u8, password: []const u8) bool {
    argon2.strVerify(phc, password, .{ .allocator = alloc }, io) catch return false;
    return true;
}

/// Per-record JWT signing key = HMAC-SHA256(app_secret, token_key). Rotating token_key
/// (on password change) changes the key, invalidating all prior tokens for that record.
pub fn deriveKey(app_secret: []const u8, token_key: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    HmacSha256.create(&out, token_key, app_secret);
    return out;
}

/// A random base36 token string of `len` chars (used for tokenKey and the CSRF value).
pub fn genToken(io: std.Io, alloc: std.mem.Allocator, len: usize) ![]u8 {
    const buf = try alloc.alloc(u8, len);
    id.generate(io, buf);
    return buf;
}

test "password hash verifies the right password and rejects the wrong one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const phc = try hashPassword(std.testing.io, a, "correct horse");
    try std.testing.expect(std.mem.startsWith(u8, phc, "$argon2id$"));
    try std.testing.expect(verifyPassword(std.testing.io, a, phc, "correct horse"));
    try std.testing.expect(!verifyPassword(std.testing.io, a, phc, "wrong password"));
}

test "deriveKey is deterministic and changes with the token key" {
    const k1 = deriveKey("app-secret", "tokkey-1");
    const k1b = deriveKey("app-secret", "tokkey-1");
    const k2 = deriveKey("app-secret", "tokkey-2");
    try std.testing.expectEqualSlices(u8, &k1, &k1b);
    try std.testing.expect(!std.mem.eql(u8, &k1, &k2));
}

test "genToken produces a string of the requested length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try genToken(std.testing.io, arena.allocator(), 32);
    try std.testing.expectEqual(@as(usize, 32), t.len);
}
