const std = @import("std");

const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const b64 = std.base64.url_safe_no_pad;

pub const SecretError = error{BadSecret} || std.mem.Allocator.Error;

const PREFIX = "v1:";

/// Derive the 32-byte AES key from the app secret (domain-separated).
fn deriveKey(app_secret: []const u8) [32]u8 {
    const prk = HkdfSha256.extract("", app_secret);
    var key: [32]u8 = undefined;
    HkdfSha256.expand(&key, "zigbase-oauth-secret-v1", prk);
    return key;
}

/// True if `blob` is an encrypted secret (has the version prefix).
pub fn isEncrypted(blob: []const u8) bool {
    return std.mem.startsWith(u8, blob, PREFIX);
}

/// Encrypt `plaintext` -> "v1:" ++ base64url(nonce ‖ ciphertext ‖ tag). `io` supplies the nonce.
pub fn encryptSecret(io: std.Io, alloc: std.mem.Allocator, app_secret: []const u8, plaintext: []const u8) ![]u8 {
    const key = deriveKey(app_secret);
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
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ PREFIX, enc });
}

/// Decrypt a "v1:"-prefixed blob. Any tamper / wrong key / non-blob -> error.BadSecret.
pub fn decryptSecret(alloc: std.mem.Allocator, app_secret: []const u8, blob: []const u8) SecretError![]u8 {
    if (!isEncrypted(blob)) return error.BadSecret;
    const enc = blob[PREFIX.len..];
    const raw_len = b64.Decoder.calcSizeForSlice(enc) catch return error.BadSecret;
    if (raw_len < 12 + 16) return error.BadSecret;
    const raw = try alloc.alloc(u8, raw_len);
    b64.Decoder.decode(raw, enc) catch return error.BadSecret;

    const ct_len = raw_len - 12 - 16;
    const nonce: [12]u8 = raw[0..12].*;
    const ct = raw[12 .. 12 + ct_len];
    const tag: [16]u8 = raw[12 + ct_len ..][0..16].*;
    const key = deriveKey(app_secret);

    const pt = try alloc.alloc(u8, ct_len);
    Aes256Gcm.decrypt(pt, ct, tag, "", nonce, key) catch return error.BadSecret;
    return pt;
}

test "encrypt then decrypt round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blob = try encryptSecret(std.testing.io, a, "app-secret", "my-client-secret");
    try std.testing.expect(std.mem.startsWith(u8, blob, "v1:"));
    try std.testing.expect(isEncrypted(blob));
    const pt = try decryptSecret(a, "app-secret", blob);
    try std.testing.expectEqualStrings("my-client-secret", pt);
}

test "wrong app secret fails authentication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blob = try encryptSecret(std.testing.io, a, "app-secret", "s3cr3t");
    try std.testing.expectError(error.BadSecret, decryptSecret(a, "other-secret", blob));
}

test "tampered blob fails authentication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blob = try encryptSecret(std.testing.io, a, "app-secret", "s3cr3t");
    const buf = try a.dupe(u8, blob);
    buf[buf.len - 1] = if (buf[buf.len - 1] == 'A') 'B' else 'A';
    try std.testing.expectError(error.BadSecret, decryptSecret(a, "app-secret", buf));
}

test "isEncrypted distinguishes plaintext from blobs; decrypt rejects non-blob" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(!isEncrypted("plaintext-secret"));
    try std.testing.expectError(error.BadSecret, decryptSecret(a, "app-secret", "plaintext-secret"));
}

test "empty plaintext round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blob = try encryptSecret(std.testing.io, a, "app-secret", "");
    try std.testing.expectEqualStrings("", try decryptSecret(a, "app-secret", blob));
}
