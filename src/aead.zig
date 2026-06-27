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
// Key rotation is designed into the `v<N>:` prefix: the version selects the key
// generation. v1 is the only generation shipped today; a future v2 adds a second
// derived key and reads dispatch on the prefix (writes always use the primary).
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

/// True if `blob` carries a recognized envelope version prefix.
pub fn isEnvelope(blob: []const u8) bool {
    return std.mem.startsWith(u8, blob, PREFIX_V1);
}

/// Seal `plaintext` into a v1 envelope. `io` supplies the per-seal random nonce.
pub fn sealV1(io: std.Io, alloc: std.mem.Allocator, key: [32]u8, plaintext: []const u8) std.mem.Allocator.Error![]u8 {
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
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ PREFIX_V1, enc });
}

/// Open a v1 envelope. Any tamper / wrong key / malformed or non-prefixed blob
/// returns `error.BadEnvelope` (fail-closed). Returned plaintext is owned by `alloc`.
pub fn openV1(alloc: std.mem.Allocator, key: [32]u8, blob: []const u8) Error![]u8 {
    if (!isEnvelope(blob)) return error.BadEnvelope;
    const enc = blob[PREFIX_V1.len..];
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
