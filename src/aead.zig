const std = @import("std");

const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const b64 = std.base64.url_safe_no_pad;

// ---------------------------------------------------------------------------
// Shared authenticated-encryption envelope.
//
// One audited AEAD primitive backs every at-rest secret in ZigBase (OAuth client
// secrets in `oauth/secrets.zig`, encrypted record fields in `field_policy.zig`).
// Each caller derives its 32-byte key from its own secret via `deriveKey` with a
// DISTINCT domain string, so the two key spaces never collide even when the same
// underlying secret material is reused.
//
// Envelope format (versioned): "v1:" ++ base64url(nonce(12) ‖ ciphertext ‖ tag(16))
//   - AES-256-GCM, empty associated data.
//   - A fresh random 12-byte nonce per seal (supplied by `io.random`).
//   - Decryption is FAIL-CLOSED: any tamper / wrong key / malformed blob / missing
//     prefix returns `error.BadEnvelope` and never yields partial plaintext.
//
// Key rotation lives in the `v<N>:` prefix: the version selects the key
// generation. `seal` stamps the writing generation; `open` is given the key the
// caller resolved from `parseVersion`. The field-encryption key-ring
// (`field_policy.Cipher`) maps each generation to its own HKDF-derived key, so a
// deployment can write `v2:` while still reading `v1:` data, and `zigbase rewrap`
// re-encrypts old generations forward. The OAuth-secret caller stays
// single-generation via the `sealV1`/`openV1` wrappers.
// ---------------------------------------------------------------------------

pub const Error = error{BadEnvelope} || std.mem.Allocator.Error;

pub const PREFIX_V1 = "v1:";

/// Derive a 32-byte AES key from `secret`, domain-separated by `domain`.
/// Different `domain` strings yield independent keys from the same secret.
pub fn deriveKey(secret: []const u8, domain: []const u8) [32]u8 {
    const prk = HkdfSha256.extract("", secret);
    var key: [32]u8 = undefined;
    HkdfSha256.expand(&key, domain, prk);
    return key;
}

/// Parse the envelope version `N` from a `v<N>:` prefix. Returns null when the
/// blob is not a versioned envelope (no `v`, no digits, or no closing `:`) — i.e.
/// legacy plaintext. `N` is the key-generation selector (see field_policy.Cipher).
pub fn parseVersion(blob: []const u8) ?u16 {
    if (blob.len < 3 or blob[0] != 'v') return null;
    var i: usize = 1;
    var v: u32 = 0;
    var any = false;
    while (i < blob.len and blob[i] != ':') : (i += 1) {
        if (blob[i] < '0' or blob[i] > '9') return null;
        any = true;
        v = v * 10 + (blob[i] - '0');
        if (v > std.math.maxInt(u16)) return null;
    }
    if (!any or i >= blob.len or blob[i] != ':') return null;
    return @intCast(v);
}

/// True if `blob` carries a recognized `v<N>:` envelope version prefix.
pub fn isEnvelope(blob: []const u8) bool {
    return parseVersion(blob) != null;
}

/// Seal `plaintext` into a `v<version>:` envelope. `io` supplies the per-seal
/// random nonce. The version tags the key generation; decryption selects the key
/// by parsing it back out (see `field_policy.Cipher`).
pub fn seal(io: std.Io, alloc: std.mem.Allocator, key: [32]u8, version: u16, plaintext: []const u8) std.mem.Allocator.Error![]u8 {
    var nonce: [12]u8 = undefined;
    io.random(&nonce);
    const ct = try alloc.alloc(u8, plaintext.len);
    var tag: [16]u8 = undefined;
    Aes256Gcm.encrypt(ct, &tag, plaintext, "", nonce, key);

    const raw = try alloc.alloc(u8, 12 + ct.len + 16);
    @memcpy(raw[0..12], &nonce);
    @memcpy(raw[12 .. 12 + ct.len], ct);
    @memcpy(raw[12 + ct.len ..], &tag);

    const enc = try alloc.alloc(u8, b64.Encoder.calcSize(raw.len));
    _ = b64.Encoder.encode(enc, raw);
    return std.fmt.allocPrint(alloc, "v{d}:{s}", .{ version, enc });
}

/// Open a `v<N>:` envelope with `key`. The caller is responsible for selecting
/// the key that matches the version (see `field_policy.Cipher.open`); `open`
/// itself only strips the prefix and AEAD-decrypts the body. Any tamper / wrong
/// key / malformed or non-prefixed blob returns `error.BadEnvelope` (fail-closed).
/// Returned plaintext is owned by `alloc`.
pub fn open(alloc: std.mem.Allocator, key: [32]u8, blob: []const u8) Error![]u8 {
    if (parseVersion(blob) == null) return error.BadEnvelope;
    const colon = std.mem.indexOfScalar(u8, blob, ':') orelse return error.BadEnvelope;
    const enc = blob[colon + 1 ..];
    const raw_len = b64.Decoder.calcSizeForSlice(enc) catch return error.BadEnvelope;
    if (raw_len < 12 + 16) return error.BadEnvelope;
    const raw = try alloc.alloc(u8, raw_len);
    b64.Decoder.decode(raw, enc) catch return error.BadEnvelope;

    const ct_len = raw_len - 12 - 16;
    const nonce: [12]u8 = raw[0..12].*;
    const ct = raw[12 .. 12 + ct_len];
    const tag: [16]u8 = raw[12 + ct_len ..][0..16].*;

    const pt = try alloc.alloc(u8, ct_len);
    Aes256Gcm.decrypt(pt, ct, tag, "", nonce, key) catch return error.BadEnvelope;
    return pt;
}

/// Seal into a v1 envelope (generation 1). Thin wrapper over `seal`; retained for
/// the OAuth-secret caller (`oauth/secrets.zig`), which is single-generation.
pub fn sealV1(io: std.Io, alloc: std.mem.Allocator, key: [32]u8, plaintext: []const u8) std.mem.Allocator.Error![]u8 {
    return seal(io, alloc, key, 1, plaintext);
}

/// Open a v1 envelope. Thin wrapper over `open` for single-generation callers.
pub fn openV1(alloc: std.mem.Allocator, key: [32]u8, blob: []const u8) Error![]u8 {
    return open(alloc, key, blob);
}

test "sealV1 then openV1 round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = deriveKey("master-secret", "test-domain-v1");
    const blob = try sealV1(std.testing.io, a, key, "the-plaintext");
    try std.testing.expect(std.mem.startsWith(u8, blob, "v1:"));
    try std.testing.expect(isEnvelope(blob));
    // Ciphertext-at-rest: the blob must not contain the plaintext.
    try std.testing.expect(std.mem.indexOf(u8, blob, "the-plaintext") == null);
    const pt = try openV1(a, key, blob);
    try std.testing.expectEqualStrings("the-plaintext", pt);
}

test "openV1 fails closed on wrong key, tamper, and non-envelope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = deriveKey("master", "dom-v1");
    const blob = try sealV1(std.testing.io, a, key, "s3cr3t");

    // Wrong key.
    const other = deriveKey("master", "different-domain-v1");
    try std.testing.expectError(error.BadEnvelope, openV1(a, other, blob));
    // Tamper the last byte.
    const buf = try a.dupe(u8, blob);
    buf[buf.len - 1] = if (buf[buf.len - 1] == 'A') 'B' else 'A';
    try std.testing.expectError(error.BadEnvelope, openV1(a, key, buf));
    // Non-envelope (no prefix).
    try std.testing.expectError(error.BadEnvelope, openV1(a, key, "plaintext-not-an-envelope"));
}

test "deriveKey is domain-separated: same secret, different domains -> different keys" {
    const k1 = deriveKey("same-secret", "domain-a");
    const k2 = deriveKey("same-secret", "domain-b");
    try std.testing.expect(!std.mem.eql(u8, &k1, &k2));
}

test "empty plaintext round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = deriveKey("k", "d-v1");
    const blob = try sealV1(std.testing.io, a, key, "");
    try std.testing.expectEqualStrings("", try openV1(a, key, blob));
}

test "parseVersion: digits between v and colon, else null" {
    try std.testing.expectEqual(@as(?u16, 1), parseVersion("v1:abc"));
    try std.testing.expectEqual(@as(?u16, 2), parseVersion("v2:abc"));
    try std.testing.expectEqual(@as(?u16, 42), parseVersion("v42:abc"));
    // Not envelopes.
    try std.testing.expectEqual(@as(?u16, null), parseVersion("legacy-plaintext"));
    try std.testing.expectEqual(@as(?u16, null), parseVersion("v:abc")); // no digits
    try std.testing.expectEqual(@as(?u16, null), parseVersion("vx:abc")); // non-digit
    try std.testing.expectEqual(@as(?u16, null), parseVersion("v1abc")); // no colon
    try std.testing.expectEqual(@as(?u16, null), parseVersion("1:abc")); // no leading v
    try std.testing.expectEqual(@as(?u16, null), parseVersion("v99999:abc")); // overflows u16
}

test "seal stamps the version; open decrypts regardless of version value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = deriveKey("master", "dom-v2");
    const blob = try seal(std.testing.io, a, key, 2, "payload");
    try std.testing.expect(std.mem.startsWith(u8, blob, "v2:"));
    try std.testing.expectEqual(@as(?u16, 2), parseVersion(blob));
    try std.testing.expectEqualStrings("payload", try open(a, key, blob));
}

test "rotation: a v2 blob does not decrypt under a v1-generation key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const k1 = deriveKey("secret", "zigbase-field-encryption-v1");
    const k2 = deriveKey("secret", "zigbase-field-encryption-v2");
    const blob_v2 = try seal(std.testing.io, a, k2, 2, "data");
    // Wrong generation key fails closed; correct one decrypts.
    try std.testing.expectError(error.BadEnvelope, open(a, k1, blob_v2));
    try std.testing.expectEqualStrings("data", try open(a, k2, blob_v2));
}
