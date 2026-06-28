const std = @import("std");
const builtin = @import("builtin");
const id = @import("id.zig");
const entropy = @import("entropy.zig");

const argon2 = std.crypto.pwhash.argon2;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// Argon2id cost parameters. Production uses `interactive_2id` (64 MiB, t=2) for real
/// resistance. **Test builds** drop to deliberately weak params: the unit suite hashes
/// and verifies passwords across ~700 tests, and at production cost that KDF work alone
/// is ~25 s of every `zig build test`. The switch is keyed on `builtin.is_test`, so it
/// affects ONLY the test binary — the shipped server binary, and the Playwright browser
/// suite (which drives that real binary), always run full-strength params.
const hash_params: argon2.Params = if (builtin.is_test)
    .{ .t = 1, .m = 8, .p = 1 }
else
    argon2.Params.interactive_2id;

/// Hash a password with argon2id, returning a PHC-format string allocated from `alloc`.
pub fn hashPassword(io: std.Io, alloc: std.mem.Allocator, password: []const u8) ![]u8 {
    var buf: [256]u8 = undefined;
    const phc = try argon2.strHash(password, .{
        .allocator = alloc,
        .params = hash_params,
    }, &buf, io);
    return alloc.dupe(u8, phc);
}

/// Verify a password against a PHC hash. Constant-time; returns false on any mismatch/parse error.
pub fn verifyPassword(io: std.Io, alloc: std.mem.Allocator, phc: []const u8, password: []const u8) bool {
    argon2.strVerify(phc, password, .{ .allocator = alloc }, io) catch return false;
    return true;
}

/// A fixed, valid argon2id PHC hash with the same params `hashPassword` uses. Used to
/// perform identity-independent argon2 work on a login miss so the response time of an
/// unknown identity matches that of a known one (defeats account enumeration via a timing
/// oracle). Both variants hash the plaintext "zigbase-login-timing-dummy"; the test build
/// uses weak params (matching `hash_params`) so the timing-defense work stays cheap under
/// the unit suite, while production keeps the real 64 MiB / t=2 cost.
pub const dummy_password_hash = if (builtin.is_test)
    "$argon2id$v=19$m=8,t=1,p=1$Nogl5w29zufCdU9yMIexgeEuZY1gLIIvqHdjpw3tA7c$8kCzMNdJBFhiyspDpZQLe0e2jmHnCXAQhNbrhC8SmoE"
else
    "$argon2id$v=19$m=65536,t=2,p=1$X6nNL1XIBemv6GtMawOzIiupjeI6RhVcq4OM6oHc2Ds$7q5akLEU/XJR2q91NLbc9ARqZfPFtOSdtSIQZBP4I2o";

/// Run an argon2 verify against the fixed dummy hash, discarding the result. Call this on a
/// login miss (unknown identity / missing hash) to keep the work identity-independent.
pub fn dummyVerify(io: std.Io, alloc: std.mem.Allocator) void {
    _ = verifyPassword(io, alloc, dummy_password_hash, "zigbase-login-timing-dummy-mismatch");
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

/// A random lowercase-hex string of `len` chars. Draws ceil(len/2) random bytes from the
/// same entropy seam `genToken` uses and hex-encodes them, truncating to `len`. Useful
/// where a strictly `[0-9a-f]` alphabet is wanted (e.g. opaque ids in URLs/headers).
pub fn genHex(io: std.Io, alloc: std.mem.Allocator, len: usize) ![]u8 {
    const out = try alloc.alloc(u8, len);
    errdefer alloc.free(out); // only fires on an error path below; the success `return out` leaves it owned by the caller
    if (len == 0) return out;
    const nbytes = (len + 1) / 2;
    const raw = try alloc.alloc(u8, nbytes);
    defer alloc.free(raw);
    entropy.fill(io, raw);
    const hexchars = "0123456789abcdef";
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const byte = raw[i / 2];
        const nib: u4 = @intCast(if (i % 2 == 0) byte >> 4 else byte & 0x0f);
        out[i] = hexchars[nib];
    }
    return out;
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
    const k3 = deriveKey("other-secret", "tokkey-1");
    try std.testing.expectEqualSlices(u8, &k1, &k1b);
    try std.testing.expect(!std.mem.eql(u8, &k1, &k2)); // token_key changes the key
    try std.testing.expect(!std.mem.eql(u8, &k1, &k3)); // app_secret changes the key
}

test "genToken produces a string of the requested length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try genToken(std.testing.io, arena.allocator(), 32);
    try std.testing.expectEqual(@as(usize, 32), t.len);
}

test "genHex produces a lowercase-hex string of the requested length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ 0, 1, 7, 32 }) |n| {
        const h = try genHex(std.testing.io, a, n);
        try std.testing.expectEqual(@as(usize, n), h.len);
        for (h) |c| try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "dummy login-timing hash is a well-formed argon2id PHC string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(std.mem.startsWith(u8, dummy_password_hash, "$argon2id$"));
    // It verifies its own plaintext (proves the constant parses + is real work) ...
    try std.testing.expect(verifyPassword(std.testing.io, a, dummy_password_hash, "zigbase-login-timing-dummy"));
    // ... and dummyVerify (which uses a deliberately-mismatched plaintext) just runs the work.
    dummyVerify(std.testing.io, a);
}
