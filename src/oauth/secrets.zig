const std = @import("std");
const aead = @import("../aead.zig");

pub const SecretError = error{BadSecret} || std.mem.Allocator.Error;

/// Domain separator for the OAuth-secret key space. Distinct from the
/// field-encryption domain (see `field_policy.zig`) so the two key spaces never
/// collide even for the same underlying app secret.
const OAUTH_SECRET_DOMAIN = "zigbase-oauth-secret-v1";

/// True if `blob` is an encrypted secret (has the version prefix).
pub fn isEncrypted(blob: []const u8) bool {
    return aead.isEnvelope(blob);
}

/// Encrypt `plaintext` -> "v1:" ++ base64url(nonce ‖ ciphertext ‖ tag). `io` supplies the nonce.
pub fn encryptSecret(io: std.Io, alloc: std.mem.Allocator, app_secret: []const u8, plaintext: []const u8) ![]u8 {
    const key = aead.deriveKey(app_secret, OAUTH_SECRET_DOMAIN);
    return aead.sealV1(io, alloc, key, plaintext);
}

/// Decrypt a "v1:"-prefixed blob. Any tamper / wrong key / non-blob -> error.BadSecret.
pub fn decryptSecret(alloc: std.mem.Allocator, app_secret: []const u8, blob: []const u8) SecretError![]u8 {
    const key = aead.deriveKey(app_secret, OAUTH_SECRET_DOMAIN);
    return aead.openV1(alloc, key, blob) catch |e| switch (e) {
        error.BadEnvelope => error.BadSecret,
        error.OutOfMemory => error.OutOfMemory,
    };
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
