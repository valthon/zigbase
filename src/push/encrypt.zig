// encrypt.zig — RFC 8291 Web Push Message Encryption (the `aes128gcm` content
// coding of RFC 8188).
//
// SECURITY-CRITICAL. The full derivation is pinned by the RFC 8291 Appendix A
// test vector at the bottom of this file — every intermediate (ecdh_secret,
// PRK_key, IKM, PRK, CEK, NONCE) and the final body are asserted byte-for-byte.
//
// Spec references:
//   RFC 8291 §3.4 (key/nonce derivation)   https://www.rfc-editor.org/rfc/rfc8291#section-3.4
//   RFC 8291 Appendix A (test vector)        https://www.rfc-editor.org/rfc/rfc8291#appendix-A
//   RFC 8188 §2 (aes128gcm header + records) https://www.rfc-editor.org/rfc/rfc8188#section-2
//
// The HKDF here uses two DIFFERENT "salts": the first Extract keys on the
// subscriber's `auth_secret` (RFC 8291 §3.4), the second on the per-message
// `salt` (the standard RFC 8188 content-coding). The `key_info` for the first
// Expand carries the unusual `"WebPush: info"\0 || ua_public || as_public`
// framing (§3.4), so we spell every HMAC step out by hand rather than lean on
// std's HkdfSha256 helper — it keeps the framing auditable against the RFC.

const std = @import("std");

const P256 = std.crypto.ecc.P256;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const Error = error{InvalidPublicKey} || std.mem.Allocator.Error;

/// RFC 8188 record size. Single-record messages only (push payloads are small),
/// so `rs` is fixed at 4096 and the padding delimiter is `0x02` (last record).
const RECORD_SIZE: u32 = 4096;

/// The intermediate secrets of the RFC 8291 §3.4 derivation. Exposed so the
/// Appendix A vector test can assert each value independently — a wrong ECDH X
/// extraction, info-string, or HMAC key/msg order shows up at the exact step.
pub const Keys = struct {
    /// ECDH shared secret = affine X of as_private · ua_public (32 bytes).
    ecdh_secret: [32]u8,
    /// HKDF-Extract(salt=auth_secret, ikm=ecdh_secret).
    prk_key: [32]u8,
    /// HKDF-Expand(prk_key, "WebPush: info"\0 || ua_public || as_public, 32).
    ikm: [32]u8,
    /// HKDF-Extract(salt=message salt, ikm=IKM).
    prk: [32]u8,
    /// HKDF-Expand(prk, "Content-Encoding: aes128gcm"\0, 16).
    cek: [16]u8,
    /// HKDF-Expand(prk, "Content-Encoding: nonce"\0, 12).
    nonce: [12]u8,
};

/// HKDF-Extract over SHA-256 = HMAC(key=salt, msg=ikm).
fn extract(salt: []const u8, ikm: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    HmacSha256.create(&out, ikm, salt);
    return out;
}

/// HKDF-Expand over SHA-256 for `L <= 32` (one block): first L bytes of
/// HMAC(prk, info || 0x01). Web Push never needs more than one block.
fn expand(comptime L: usize, prk: []const u8, info: []const u8, out: *[L]u8) void {
    comptime std.debug.assert(L <= 32);
    var ctx = HmacSha256.init(prk);
    ctx.update(info);
    ctx.update(&[_]u8{0x01}); // T(1) counter
    var t: [32]u8 = undefined;
    ctx.final(&t);
    @memcpy(out, t[0..L]);
}

/// Derive the CEK/NONCE (and every intermediate) per RFC 8291 §3.4.
pub fn deriveKeys(
    ua_public: [65]u8,
    auth_secret: [16]u8,
    as_public: [65]u8,
    as_private: [32]u8,
    salt: [16]u8,
) Error!Keys {
    // (1) ECDH: decode the UA's uncompressed SEC1 point, multiply by our private
    // scalar (constant-time `mul` — the scalar is secret), take the affine X.
    const ua_point = P256.fromSec1(&ua_public) catch return error.InvalidPublicKey;
    const shared = ua_point.mul(as_private, .big) catch return error.InvalidPublicKey;
    const ecdh_secret = shared.affineCoordinates().x.toBytes(.big);

    // (2) PRK_key = HKDF-Extract(salt=auth_secret, ikm=ecdh_secret).
    const prk_key = extract(&auth_secret, &ecdh_secret);

    // (3) key_info = "WebPush: info"\0 || ua_public(65) || as_public(65).
    var key_info: [13 + 1 + 65 + 65]u8 = undefined;
    @memcpy(key_info[0..13], "WebPush: info");
    key_info[13] = 0x00;
    @memcpy(key_info[14..79], &ua_public);
    @memcpy(key_info[79..144], &as_public);

    // (4) IKM = HKDF-Expand(PRK_key, key_info, 32).
    var ikm: [32]u8 = undefined;
    expand(32, &prk_key, &key_info, &ikm);

    // (5) PRK = HKDF-Extract(salt=message salt, ikm=IKM).
    const prk = extract(&salt, &ikm);

    // (6) CEK = HKDF-Expand(PRK, "Content-Encoding: aes128gcm"\0, 16).
    var cek: [16]u8 = undefined;
    expand(16, &prk, "Content-Encoding: aes128gcm\x00", &cek);

    // (7) NONCE = HKDF-Expand(PRK, "Content-Encoding: nonce"\0, 12).
    var nonce: [12]u8 = undefined;
    expand(12, &prk, "Content-Encoding: nonce\x00", &nonce);

    return .{
        .ecdh_secret = ecdh_secret,
        .prk_key = prk_key,
        .ikm = ikm,
        .prk = prk,
        .cek = cek,
        .nonce = nonce,
    };
}

/// Encrypt `plaintext` into an RFC 8291 `aes128gcm` message body.
///
/// `ua_public`   — the subscriber's `p256dh` key (uncompressed SEC1, 65 bytes).
/// `auth_secret` — the subscriber's `auth` secret (16 bytes).
/// `as_public`/`as_private`/`salt` — the application-server ephemeral keypair and
///   per-message salt. In production these are freshly random per message; they
///   are parameters so the Appendix A vector can pin them. `io` is accepted for
///   signature parity with the Pass-2 caller (which will generate them); the
///   derivation itself is deterministic in these inputs.
///
/// Returns the full message body (owned by `alloc`):
///   salt(16) || rs(4, BE) || idlen(1) || keyid(=as_public, 65) || ciphertext+tag
pub fn encrypt(
    alloc: std.mem.Allocator,
    io: std.Io,
    plaintext: []const u8,
    ua_public: [65]u8,
    auth_secret: [16]u8,
    as_public: [65]u8,
    as_private: [32]u8,
    salt: [16]u8,
) Error![]u8 {
    _ = io; // derivation is deterministic in the supplied salt/keys.

    const keys = try deriveKeys(ua_public, auth_secret, as_public, as_private, salt);

    // (8) content = plaintext || 0x02 (single-record padding delimiter, RFC 8188).
    const content = try alloc.alloc(u8, plaintext.len + 1);
    defer alloc.free(content);
    @memcpy(content[0..plaintext.len], plaintext);
    content[plaintext.len] = 0x02;

    // (9) ciphertext = AES-128-GCM(CEK, NONCE, aad="", content) with tag appended.
    // Body layout: 16 (salt) + 4 (rs) + 1 (idlen) + 65 (keyid) + content + 16 (tag).
    const header_len = 16 + 4 + 1 + 65;
    const body = try alloc.alloc(u8, header_len + content.len + 16);
    errdefer alloc.free(body);

    @memcpy(body[0..16], &salt);
    std.mem.writeInt(u32, body[16..20], RECORD_SIZE, .big);
    body[20] = 65; // idlen — the keyid is the 65-byte as_public.
    @memcpy(body[21..86], &as_public);

    const ct = body[header_len .. header_len + content.len];
    var tag: [16]u8 = undefined;
    Aes128Gcm.encrypt(ct, &tag, content, "", keys.nonce, keys.cek);
    @memcpy(body[header_len + content.len ..], &tag);

    return body;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const b64 = std.base64.url_safe_no_pad;

fn b64dec(comptime N: usize, s: []const u8) [N]u8 {
    var out: [N]u8 = undefined;
    std.debug.assert(b64.Decoder.calcSizeForSlice(s) catch unreachable == N);
    b64.Decoder.decode(&out, s) catch unreachable;
    return out;
}

test "RFC 8291 Appendix A: intermediates + final body match the published vector" {
    const a = std.testing.allocator;

    // Appendix A inputs (base64url, no padding).
    const plaintext = "When I grow up, I want to be a watermelon";
    const auth_secret = b64dec(16, "BTBZMqHH6r4Tts7J_aSIgg");
    const ua_public = b64dec(65, "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4");
    const as_public = b64dec(65, "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8");
    const as_private = b64dec(32, "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw");
    const salt = b64dec(16, "DGv6ra1nlYgDCS1FRnbzlw");

    // Sanity: the b64url of the plaintext matches the RFC's stated value.
    var pt_b64: [b64.Encoder.calcSize(plaintext.len)]u8 = undefined;
    _ = b64.Encoder.encode(&pt_b64, plaintext);
    try std.testing.expectEqualStrings("V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24", &pt_b64);

    const keys = try deriveKeys(ua_public, auth_secret, as_public, as_private, salt);

    try std.testing.expectEqual(b64dec(32, "kyrL1jIIOHEzg3sM2ZWRHDRB62YACZhhSlknJ672kSs"), keys.ecdh_secret);
    try std.testing.expectEqual(b64dec(32, "Snr3JMxaHVDXHWJn5wdC52WjpCtd2EIEGBykDcZW32k"), keys.prk_key);
    try std.testing.expectEqual(b64dec(32, "S4lYMb_L0FxCeq0WhDx813KgSYqU26kOyzWUdsXYyrg"), keys.ikm);
    try std.testing.expectEqual(b64dec(32, "09_eUZGrsvxChDCGRCdkLiDXrReGOEVeSCdCcPBSJSc"), keys.prk);
    try std.testing.expectEqual(b64dec(16, "oIhVW04MRdy2XN9CiKLxTg"), keys.cek);
    try std.testing.expectEqual(b64dec(12, "4h_95klXJ5E_qnoN"), keys.nonce);

    const body = try encrypt(a, std.testing.io, plaintext, ua_public, auth_secret, as_public, as_private, salt);
    defer a.free(body);

    // Reconstruct the expected 144-byte body from the RFC's PUBLISHED pieces:
    //   header = salt(16) || rs(4, BE=4096) || idlen(1=65) || keyid(=as_public, 65)
    //   ciphertext = the exact base64url the RFC publishes for the encrypted record.
    //
    // We assemble the RAW bytes rather than compare a single base64url of the whole
    // body on purpose: the header is 86 bytes (not a multiple of 3), so
    // `base64url(header) ++ base64url(ciphertext)` is NOT equal to
    // `base64url(header || ciphertext)` — the field boundary falls mid-b64-group.
    // (Publications that print the fields separately, then splice their base64url,
    // produce a string that mis-decodes at the seam.) Pinning each raw field keeps
    // the assertion independent of our own body-assembly b64.
    const rfc_ciphertext = b64dec(58, "8pfeW0KbunFT06SuDKoJH9Ql87S1QUrdirN6GcG7sFz1y1sqLgVi1VhjVkHsUoEsbI_0LpXMuGvnzQ");
    var expected: [144]u8 = undefined;
    @memcpy(expected[0..16], &salt);
    std.mem.writeInt(u32, expected[16..20], 4096, .big);
    expected[20] = 65;
    @memcpy(expected[21..86], &as_public);
    @memcpy(expected[86..144], &rfc_ciphertext);
    try std.testing.expectEqualSlices(u8, &expected, body);
}

test "encrypt: body header framing (salt, rs, idlen, keyid) is well-formed" {
    const a = std.testing.allocator;

    const auth_secret = [_]u8{0x11} ** 16;
    const ua_public = b64dec(65, "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4");
    const as_public = b64dec(65, "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8");
    const as_private = b64dec(32, "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw");
    const salt = [_]u8{0x22} ** 16;

    const body = try encrypt(a, std.testing.io, "hello", ua_public, auth_secret, as_public, as_private, salt);
    defer a.free(body);

    try std.testing.expectEqualSlices(u8, &salt, body[0..16]);
    try std.testing.expectEqual(@as(u32, 4096), std.mem.readInt(u32, body[16..20], .big));
    try std.testing.expectEqual(@as(u8, 65), body[20]);
    try std.testing.expectEqualSlices(u8, &as_public, body[21..86]);
    // 5-byte plaintext + 1 delimiter + 16 tag past the 86-byte header.
    try std.testing.expectEqual(@as(usize, 86 + 5 + 1 + 16), body.len);
}

test "encrypt: a bad UA public key fails closed" {
    const a = std.testing.allocator;
    const bad_ua = [_]u8{0x00} ** 65; // not a valid SEC1 point.
    try std.testing.expectError(error.InvalidPublicKey, encrypt(
        a,
        std.testing.io,
        "x",
        bad_ua,
        [_]u8{0} ** 16,
        [_]u8{0x04} ** 65,
        [_]u8{1} ** 32,
        [_]u8{0} ** 16,
    ));
}
