const std = @import("std");
const builtin = @import("builtin");
const id = @import("id.zig");
const entropy = @import("entropy.zig");

const argon2 = std.crypto.pwhash.argon2;
const bcrypt = std.crypto.pwhash.bcrypt;
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

// ---------------------------------------------------------------------------
// Legacy (imported) password hashes.
//
// A credential migrated from another backend is stored in the ordinary `passwordHash`
// column, tagged: `$zblegacy$<alg>$<original-hash>`. The tag — not the hash's own prefix —
// selects the verifier, so an untagged foreign hash matches nothing and fails CLOSED.
// The ONLY writer of a tagged value is the offline `zigbase import --legacy-hashes` seam;
// the login path replaces it with argon2id on the first successful verification and never
// writes one back. See docs/migration-tools.md.
// ---------------------------------------------------------------------------

/// Marker for an imported, not-yet-upgraded credential: `$zblegacy$<alg>$<original-hash>`.
/// Stored in the ordinary `passwordHash` column. An UNTAGGED foreign hash is never
/// accepted — no verifier matches it, so it fails closed.
pub const legacy_prefix = "$zblegacy$";

/// The complete algorithm allowlist. Append-only, and only after a security review.
pub const legacy_algorithms = [_][]const u8{"bcrypt"};

pub const LegacyError = error{ UnsupportedAlgorithm, MalformedLegacyHash };

pub const LegacyHash = struct { algorithm: []const u8, hash: []const u8 };

pub fn isLegacyHash(stored: []const u8) bool {
    return std.mem.startsWith(u8, stored, legacy_prefix);
}

fn isAllowedAlgorithm(alg: []const u8) bool {
    for (legacy_algorithms) |a| if (std.mem.eql(u8, a, alg)) return true;
    return false;
}

/// A bcrypt crypt-format hash: exactly 60 bytes, `$2<v>$<cc>$<22-char salt><31-char hash>`.
/// `$2x$` is REFUSED: it marks the deliberately-preserved crypt_blowfish 8-bit bug, which
/// this implementation does not reproduce, so accepting it would silently fail to verify
/// any password containing a high-bit byte.
fn isBcryptHash(h: []const u8) bool {
    if (h.len != bcrypt.hash_length) return false; // 60
    if (h[0] != '$' or h[1] != '2' or h[3] != '$' or h[6] != '$') return false;
    switch (h[2]) {
        'a', 'b', 'y' => {},
        else => return false,
    }
    if (!std.ascii.isDigit(h[4]) or !std.ascii.isDigit(h[5])) return false;
    return true;
}

/// Split a tagged value. Borrows from `stored`.
pub fn parseLegacy(stored: []const u8) LegacyError!LegacyHash {
    if (!isLegacyHash(stored)) return LegacyError.MalformedLegacyHash;
    const rest = stored[legacy_prefix.len..];
    const sep = std.mem.indexOfScalar(u8, rest, '$') orelse return LegacyError.MalformedLegacyHash;
    const alg = rest[0..sep];
    const hash = rest[sep + 1 ..];
    if (!isAllowedAlgorithm(alg)) return LegacyError.UnsupportedAlgorithm;
    if (hash.len == 0) return LegacyError.MalformedLegacyHash;
    return .{ .algorithm = alg, .hash = hash };
}

/// Validate `algorithm` against the allowlist AND `hash` against that algorithm's format,
/// then build the tagged value. Owned result on `alloc`.
pub fn wrapLegacy(alloc: std.mem.Allocator, algorithm: []const u8, hash: []const u8) (LegacyError || std.mem.Allocator.Error)![]u8 {
    if (!isAllowedAlgorithm(algorithm)) return LegacyError.UnsupportedAlgorithm;
    // Validate the hash against the algorithm at IMPORT time, so a malformed credential is
    // rejected while an operator is watching rather than at some user's next login.
    if (std.mem.eql(u8, algorithm, "bcrypt") and !isBcryptHash(hash)) return LegacyError.MalformedLegacyHash;
    return std.fmt.allocPrint(alloc, "{s}{s}${s}", .{ legacy_prefix, algorithm, hash });
}

/// Verify a password against a TAGGED legacy hash. Returns false — never an error — on any
/// mismatch, unknown algorithm or malformed hash, matching `verifyPassword`'s contract so
/// no caller can accidentally treat "broken hash" as "authenticated".
pub fn verifyLegacy(stored: []const u8, password: []const u8) bool {
    const parsed = parseLegacy(stored) catch return false;
    if (!std.mem.eql(u8, parsed.algorithm, "bcrypt")) return false;
    if (!isBcryptHash(parsed.hash)) return false;

    // `bcrypt.strVerify` recomputes the whole 60-byte string with a hardcoded `b` version
    // byte and compares it in full, so a stored `$2a$`/`$2y$` mismatches at byte 2 even for
    // the RIGHT password. `$2a`/`$2b`/`$2y` denote the same KDF here, so normalize to `b`.
    var buf: [bcrypt.hash_length]u8 = undefined;
    @memcpy(&buf, parsed.hash);
    buf[2] = 'b';

    // `silently_truncate_password = true` matches every mainstream implementation (PHP, Go,
    // Node, Python), which ignore bytes past 72. The Zig default pre-hashes instead, which
    // would lock out every user with a password longer than that.
    bcrypt.strVerify(&buf, password, .{ .silently_truncate_password = true }) catch return false;
    return true;
}

// Timing note: `bcrypt.strVerify`'s final comparison is `mem.eql`, which is exactly what the
// argon2 path already in production uses (`std/crypto/argon2.zig`). This introduces no new
// timing property. The one accepted residual is that bcrypt and argon2id have different
// verify costs, so response timing can distinguish a not-yet-migrated account from a
// migrated one; it cannot distinguish an existing account from a non-existent one, because
// `dummyVerify` still covers the unknown-identity path.

/// Constant-time byte-slice equality. Returns true only if both slices have the same
/// length AND every byte is identical.
///
/// The length check short-circuits (a length mismatch is not secret — a presented secret
/// is compared against a server-side value of known, fixed length). Once the lengths match,
/// the comparison XOR-accumulates every byte difference into a single value and NEVER
/// early-exits, so no timing signal leaks the position of the first differing byte. Use this
/// whenever comparing a secret (auth code, shared path secret, HMAC tag) against
/// attacker-supplied input — a plain `std.mem.eql` returns early on the first mismatch and so
/// leaks a byte-position timing oracle. `std.crypto.timing_safe.eql` only takes fixed-size
/// arrays; this is the slice-shaped counterpart used across the codebase.
pub fn timingSafeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
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

test "timingSafeEql is correct (ported from otp.zig)" {
    try std.testing.expect(timingSafeEql("123456", "123456"));
    try std.testing.expect(!timingSafeEql("123456", "123457")); // last char differs
    try std.testing.expect(!timingSafeEql("123456", "000000")); // all chars differ
    try std.testing.expect(!timingSafeEql("12345", "123456")); // length mismatch
    try std.testing.expect(!timingSafeEql("123456", "12345")); // length mismatch
    try std.testing.expect(timingSafeEql("", "")); // empty slices equal
    // A longer, mixed-byte secret round-trips and rejects a single-byte flip anywhere.
    const secret = "s3cr3t-deploy-key-9f2a";
    try std.testing.expect(timingSafeEql(secret, "s3cr3t-deploy-key-9f2a"));
    try std.testing.expect(!timingSafeEql(secret, "S3cr3t-deploy-key-9f2a")); // first byte
    try std.testing.expect(!timingSafeEql(secret, "s3cr3t-deploy-key-9f2b")); // last byte
}

test "password hash verifies the right password and rejects the wrong one" {
    const a = std.testing.allocator;
    const phc = try hashPassword(std.testing.io, a, "correct horse");
    defer a.free(phc);
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
    const a = std.testing.allocator;
    const t = try genToken(std.testing.io, a, 32);
    defer a.free(t);
    try std.testing.expectEqual(@as(usize, 32), t.len);
}

test "genHex produces a lowercase-hex string of the requested length" {
    const a = std.testing.allocator;
    inline for (.{ 0, 1, 7, 32 }) |n| {
        const h = try genHex(std.testing.io, a, n);
        defer a.free(h);
        try std.testing.expectEqual(@as(usize, n), h.len);
        for (h) |c| try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "dummy login-timing hash is a well-formed argon2id PHC string" {
    const a = std.testing.allocator;
    try std.testing.expect(std.mem.startsWith(u8, dummy_password_hash, "$argon2id$"));
    // It verifies its own plaintext (proves the constant parses + is real work) ...
    try std.testing.expect(verifyPassword(std.testing.io, a, dummy_password_hash, "zigbase-login-timing-dummy"));
    // ... and dummyVerify (which uses a deliberately-mismatched plaintext) just runs the work.
    dummyVerify(std.testing.io, a);
}

/// Produce a cost-4 bcrypt hash in the 60-char crypt format — test scaffolding only, so the
/// truncation test does not depend on a hardcoded vector.
fn bcryptHashForTest(alloc: std.mem.Allocator, password: []const u8) ![]u8 {
    var buf: [bcrypt.hash_length]u8 = undefined;
    const s = try bcrypt.strHash(password, .{
        .params = .{ .rounds_log = 4, .silently_truncate_password = true },
        .encoding = .crypt,
    }, &buf, std.testing.io);
    return alloc.dupe(u8, s);
}

test "legacy tag round-trips and rejects everything outside the allowlist" {
    const a = std.testing.allocator;
    const bc = "$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy";

    const tagged = try wrapLegacy(a, "bcrypt", bc);
    defer a.free(tagged);
    try std.testing.expectEqualStrings("$zblegacy$bcrypt$" ++ bc, tagged);
    try std.testing.expect(isLegacyHash(tagged));
    try std.testing.expect(!isLegacyHash(dummy_password_hash)); // an argon2 PHC is not legacy

    const parsed = try parseLegacy(tagged);
    try std.testing.expectEqualStrings("bcrypt", parsed.algorithm);
    try std.testing.expectEqualStrings(bc, parsed.hash);

    // Allowlist: only what is on it, by TAG, never inferred from the hash itself.
    try std.testing.expectError(LegacyError.UnsupportedAlgorithm, wrapLegacy(a, "md5", bc));
    try std.testing.expectError(LegacyError.UnsupportedAlgorithm, wrapLegacy(a, "scrypt", bc));
    try std.testing.expectError(LegacyError.UnsupportedAlgorithm, wrapLegacy(a, "", bc));
    // Format: wrong length, wrong framing, single-digit cost, and the buggy $2x variant.
    try std.testing.expectError(LegacyError.MalformedLegacyHash, wrapLegacy(a, "bcrypt", "$2a$10$short"));
    try std.testing.expectError(LegacyError.MalformedLegacyHash, wrapLegacy(a, "bcrypt", bc[0..59]));
    try std.testing.expectError(LegacyError.MalformedLegacyHash, wrapLegacy(a, "bcrypt", "$2x$" ++ bc[4..]));
    try std.testing.expectError(LegacyError.MalformedLegacyHash, wrapLegacy(a, "bcrypt", "$argon2id$v=19$m=8,t=1,p=1$aaaa$bbbb"));
    try std.testing.expectError(LegacyError.MalformedLegacyHash, parseLegacy("$zblegacy$bcrypt"));
    try std.testing.expectError(LegacyError.UnsupportedAlgorithm, parseLegacy("$zblegacy$md5$x"));
}

test "verifyLegacy accepts $2a/$2b/$2y bcrypt hashes of the same password" {
    // "abc" hashed at cost 4 by a reference implementation, presented under each version
    // byte. All three denote the same KDF; Zig's strVerify only accepts `b`, so the
    // implementation must normalize. Regenerate with:
    //   python3 -c 'import bcrypt;print(bcrypt.hashpw(b"abc",bcrypt.gensalt(4)).decode())'
    const b2b = "$2b$04$gKLlzqBYq6vyAUzUTYq/f.2na5B02QSMuFv75B374EKmX3m3Kt1UG";
    const a = std.testing.allocator;
    inline for (.{ "a", "b", "y" }) |ver| {
        var buf: [60]u8 = undefined;
        @memcpy(&buf, b2b);
        buf[2] = ver[0];
        const tagged = try wrapLegacy(a, "bcrypt", &buf);
        defer a.free(tagged);
        try std.testing.expect(verifyLegacy(tagged, "abc"));
        try std.testing.expect(!verifyLegacy(tagged, "abd"));
        try std.testing.expect(!verifyLegacy(tagged, ""));
    }
}

test "verifyLegacy truncates at 72 bytes the way every other bcrypt does" {
    // Reference implementations ignore bytes past 72. Zig's default instead HMAC-pre-hashes
    // a long password, which would lock out any user whose password exceeds 72 bytes.
    const a = std.testing.allocator;
    const base = "x" ** 72;
    const long = base ++ "IGNORED-BY-EVERY-OTHER-BCRYPT";
    const h = try bcryptHashForTest(a, base); // helper below
    defer a.free(h);
    const tagged = try wrapLegacy(a, "bcrypt", h);
    defer a.free(tagged);
    try std.testing.expect(verifyLegacy(tagged, base));
    try std.testing.expect(verifyLegacy(tagged, long));
}

test "verifyLegacy fails closed on garbage, and verifyPassword never accepts a legacy value" {
    const a = std.testing.allocator;
    try std.testing.expect(!verifyLegacy("$zblegacy$bcrypt$not-a-hash", "abc"));
    try std.testing.expect(!verifyLegacy("$zblegacy$md5$whatever", "abc"));
    try std.testing.expect(!verifyLegacy("not tagged at all", "abc"));
    // The argon2 verifier must never authenticate a tagged legacy value, so a caller that
    // forgets to branch fails CLOSED rather than open.
    const bc = "$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy";
    const tagged = try wrapLegacy(a, "bcrypt", bc);
    defer a.free(tagged);
    try std.testing.expect(!verifyPassword(std.testing.io, a, tagged, "abc"));
    try std.testing.expect(!verifyPassword(std.testing.io, a, bc, "abc"));
}
