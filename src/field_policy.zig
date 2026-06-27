const std = @import("std");
const aead = @import("aead.zig");
const schema = @import("schema.zig");

// ---------------------------------------------------------------------------
// Field policy pipeline.
//
// A value-transform seam applied at the records read/write choke point
// (`values.bindValue`/`values.readValue`). Its first (and currently only)
// behavior is transparent at-rest encryption for fields declared
// `.encrypted = true`. Handlers, the records API, and the HTTP layer always see
// plaintext; only the SQLite file holds the ciphertext envelope.
//
// The cipher is resolved once at startup from ZIGBASE_FIELD_KEY and stamped onto
// pooled DB connections (db.zig), so it reaches `values.zig` via the prepared
// statement with no changes to the records function signatures. A null cipher
// (no key configured / direct test connections) leaves every value untouched.
// ---------------------------------------------------------------------------

/// Domain separator for the field-encryption key space (distinct from the
/// OAuth-secret domain so the key spaces never collide).
pub const FIELD_KEY_DOMAIN = "zigbase-field-encryption-v1";

/// Resolved field cipher: a derived AES-256 key plus the io used to source a
/// fresh nonce per write. Constructed once at startup; pointed at by db.Db.
pub const Cipher = struct {
    key: [32]u8,
    io: std.Io,

    /// Derive the cipher from the raw `ZIGBASE_FIELD_KEY` value via HKDF (so the
    /// env value may be any length/format). The raw key is never stored.
    pub fn fromEnv(io: std.Io, field_key: []const u8) Cipher {
        return .{ .key = aead.deriveKey(field_key, FIELD_KEY_DOMAIN), .io = io };
    }
};

/// Field types that may carry an encryption envelope (text/editor/json). Single
/// source of truth lives in schema.zig so the comptime guards, the runtime
/// validator, and this value layer never drift.
pub const isEncryptableType = schema.isEncryptableType;

/// Seal a storage string (the text, or the stringified json) into a v1 envelope.
pub fn seal(cipher: Cipher, alloc: std.mem.Allocator, plaintext: []const u8) std.mem.Allocator.Error![]u8 {
    return aead.sealV1(cipher.io, alloc, cipher.key, plaintext);
}

/// Open a stored value back to its plaintext storage string. STRICT / fail-closed:
/// the stored value MUST be a valid v1 envelope — a non-envelope (e.g. legacy
/// plaintext) or an undecryptable blob returns `error.BadEnvelope`. Enabling
/// `.encrypted` on a column that already holds plaintext therefore requires an
/// explicit rewrap migration first; there is no silent plaintext passthrough.
pub fn open(cipher: Cipher, alloc: std.mem.Allocator, stored: []const u8) aead.Error![]u8 {
    return aead.openV1(alloc, cipher.key, stored);
}

test "seal/open round-trips a storage string and ciphertext-at-rest holds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cph = Cipher.fromEnv(std.testing.io, "operator-field-key");
    const blob = try seal(cph, a, "sensitive-value");
    try std.testing.expect(aead.isEnvelope(blob));
    try std.testing.expect(std.mem.indexOf(u8, blob, "sensitive-value") == null);
    try std.testing.expectEqualStrings("sensitive-value", try open(cph, a, blob));
}

test "open is strict: legacy plaintext fails closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cph = Cipher.fromEnv(std.testing.io, "k");
    try std.testing.expectError(error.BadEnvelope, open(cph, a, "legacy-plaintext"));
}

test "isEncryptableType allows only text/editor/json" {
    try std.testing.expect(isEncryptableType(.text));
    try std.testing.expect(isEncryptableType(.editor));
    try std.testing.expect(isEncryptableType(.json));
    try std.testing.expect(!isEncryptableType(.email));
    try std.testing.expect(!isEncryptableType(.url));
    try std.testing.expect(!isEncryptableType(.number));
    try std.testing.expect(!isEncryptableType(.relation));
    try std.testing.expect(!isEncryptableType(.@"bool"));
}
