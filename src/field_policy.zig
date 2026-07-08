const std = @import("std");
const aead = @import("aead.zig");
const schema = @import("schema.zig");
const dev = @import("dev.zig");

/// Field-crypto mode. `.real` = AES-GCM envelopes (production). `.fake` = a dev-only,
/// build-gated readable passthrough (`fake:<key>:<value>`) for debugging/testing.
pub const Mode = enum { real, fake };

/// Env var selecting the mode (dev builds only): `ZIGBASE_FIELD_CRYPTO=fake`.
pub const env_var = "ZIGBASE_FIELD_CRYPTO";

/// Resolve the mode from the env, gated by `dev.enabled`. On a prod build this is
/// comptime `.real` — the env var is never consulted, so fake crypto can't be selected.
pub fn resolveModeFromEnv(raw: ?[]const u8) Mode {
    if (!dev.enabled) return .real;
    const s = raw orelse return .real;
    const t = std.mem.trim(u8, s, " \t\r\n");
    return if (std.mem.eql(u8, t, "fake")) .fake else .real;
}

// ---------------------------------------------------------------------------
// Field policy pipeline.
//
// A value-transform seam applied at the records read/write choke point
// (`values.bindValue`/`values.readValue`). Its first (and currently only)
// behavior is transparent at-rest encryption for fields declared
// `.encrypted = true`. Handlers, the records API, and the HTTP layer always see
// plaintext; only the SQLite file holds the ciphertext envelope.
//
// The cipher is resolved once at startup from ZIGBASE_FIELD_KEY (+ optional older
// generations) and stamped onto pooled DB connections (db.zig), so it reaches
// `values.zig` via the prepared statement with no changes to the records function
// signatures. A null cipher (no key configured / direct test connections) leaves
// every value untouched.
//
// Key rotation: the cipher is a generation-indexed key-ring. Writes use the
// PRIMARY generation's key and stamp `v<primary>:`; reads parse the version `N`
// out of the envelope and decrypt with generation `N`'s key. An envelope whose
// generation has no configured key fails closed. See
// docs/superpowers/specs/2026-06-27-encryption-rotation-design.md.
// ---------------------------------------------------------------------------

/// Domain-separation prefix for the field-encryption key space. Each generation
/// derives an independent key with domain `FIELD_KEY_DOMAIN_PREFIX ++ "<gen>"`,
/// e.g. generation 1 -> "zigbase-field-encryption-v1" (the constant the
/// single-key build used, so existing v1: data decrypts unchanged).
pub const FIELD_KEY_DOMAIN_PREFIX = "zigbase-field-encryption-v";

/// Generation 1's domain, preserved as a named constant for clarity / back-compat.
pub const FIELD_KEY_DOMAIN = FIELD_KEY_DOMAIN_PREFIX ++ "1";

/// Highest supported key generation (== highest envelope version). A generation
/// outside 1..MAX_GENERATION is a config error; a stored envelope version above
/// it has no key and fails closed.
pub const MAX_GENERATION: u16 = 64;

/// Config-resolution errors for the multi-generation key-ring.
pub const ResolveError = error{
    /// `ZIGBASE_FIELD_KEY_GENERATION` was outside 1..MAX_GENERATION.
    BadGeneration,
    /// `ZIGBASE_FIELD_KEY_V<M>` was set for the primary generation, which already
    /// gets its key from `ZIGBASE_FIELD_KEY` (ambiguous — two sources).
    GenerationConflict,
};

/// Derive generation `gen`'s 32-byte key from the raw secret via HKDF. The raw
/// key material is never stored. `gen` must be in 1..MAX_GENERATION.
pub fn deriveGeneration(secret: []const u8, gen: u16) [32]u8 {
    var buf: [FIELD_KEY_DOMAIN_PREFIX.len + 8]u8 = undefined;
    const domain = std.fmt.bufPrint(&buf, "{s}{d}", .{ FIELD_KEY_DOMAIN_PREFIX, gen }) catch unreachable;
    return aead.deriveKey(secret, domain);
}

/// Resolved field cipher: a generation-indexed key-ring plus the io used to
/// source a fresh nonce per write. Constructed once at startup; pointed at by
/// db.Db (type-erased). `values.zig` holds a `*const Cipher` (no per-value copy).
pub const Cipher = struct {
    /// keys[g] = derived key for generation g (1..MAX_GENERATION), null if that
    /// generation is not configured. Index 0 is unused.
    keys: [MAX_GENERATION + 1]?[32]u8 = @splat(null),
    /// The generation used for all writes; `keys[primary_gen]` is always set.
    primary_gen: u16 = 1,
    io: std.Io,
    /// Field-crypto mode. `.real` uses the key-ring below; `.fake` uses `fake_key`.
    mode: Mode = .real,
    /// Fake-mode label: embedded in the readable envelope and required on open.
    fake_key: []const u8 = "",

    /// Single-generation cipher (generation 1) from the raw `ZIGBASE_FIELD_KEY`.
    /// Backward-compatible shorthand used by tests and the single-key path.
    pub fn fromEnv(io: std.Io, field_key: []const u8) Cipher {
        var c = Cipher{ .io = io, .primary_gen = 1 };
        c.keys[1] = deriveGeneration(field_key, 1);
        return c;
    }

    /// Dev-only fake cipher: `seal` writes readable `fake:<key>:<value>`. Callers must
    /// gate construction on `dev.enabled` (the boot path does). `key` is the label.
    pub fn fake(io: std.Io, key: []const u8) Cipher {
        return .{ .io = io, .mode = .fake, .fake_key = key };
    }

    /// Resolve the full key-ring from config: the primary key (`field_key`) at
    /// `primary_gen`, plus any older read-only generations supplied via
    /// `ZIGBASE_FIELD_KEY_V<M>` (read through `getter`, which has a
    /// `get(key) ?[]const u8` method). Fail-closed config validation:
    ///   - `primary_gen` must be in 1..MAX_GENERATION (else `BadGeneration`).
    ///   - `ZIGBASE_FIELD_KEY_V<primary_gen>` set -> `GenerationConflict`.
    /// An out-of-range `ZIGBASE_FIELD_KEY_V<M>` (M == 0 or M > MAX_GENERATION) is
    /// ignored (no such generation exists), but a startup WARNING names it so a
    /// typo like `V65` is not silently unused.
    pub fn resolve(io: std.Io, getter: anytype, field_key: []const u8, primary_gen: u16) ResolveError!Cipher {
        if (primary_gen < 1 or primary_gen > MAX_GENERATION) return error.BadGeneration;
        var c = Cipher{ .io = io, .primary_gen = primary_gen };
        c.keys[primary_gen] = deriveGeneration(field_key, primary_gen);
        var g: u16 = 1;
        while (g <= MAX_GENERATION) : (g += 1) {
            var namebuf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&namebuf, "ZIGBASE_FIELD_KEY_V{d}", .{g}) catch unreachable;
            const val = getter.get(name) orelse continue;
            if (val.len == 0) continue;
            if (g == primary_gen) return error.GenerationConflict;
            c.keys[g] = deriveGeneration(val, g);
        }
        // Warn (don't fail) on a set-but-out-of-range generation env var so an
        // operator typo isn't silently ignored. Probe V0 and a window just above
        // MAX_GENERATION (covers the common 2-digit fat-finger like V65).
        warnOutOfRange(getter, 0);
        var bad: u16 = MAX_GENERATION + 1;
        while (bad <= MAX_GENERATION + 36) : (bad += 1) warnOutOfRange(getter, bad);
        return c;
    }

    /// Emit a startup warning if `ZIGBASE_FIELD_KEY_V<gen>` is set for an
    /// out-of-range generation (it will be ignored).
    fn warnOutOfRange(getter: anytype, gen: u16) void {
        var namebuf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&namebuf, "ZIGBASE_FIELD_KEY_V{d}", .{gen}) catch unreachable;
        const val = getter.get(name) orelse return;
        if (val.len == 0) return;
        std.log.warn("{s} is set but generation {d} is out of range (valid generations are 1..{d}); it is IGNORED — check for a typo", .{ name, gen, MAX_GENERATION });
    }

    /// Seal a storage string into a `v<primary>:` envelope under the primary key.
    pub fn seal(self: *const Cipher, alloc: std.mem.Allocator, plaintext: []const u8) std.mem.Allocator.Error![]u8 {
        switch (self.mode) {
            .real => {
                const key = self.keys[self.primary_gen].?;
                return aead.seal(self.io, alloc, key, self.primary_gen, plaintext);
            },
            // Readable, self-labeling, deterministic. Dev-only (construction is gated).
            .fake => return std.fmt.allocPrint(alloc, "fake:{s}:{s}", .{ self.fake_key, plaintext }),
        }
    }

    /// Open a stored value back to its plaintext storage string. STRICT /
    /// fail-closed: the stored value MUST be a valid `v<N>:` envelope whose
    /// generation `N` has a configured key. A non-envelope (legacy plaintext), an
    /// unknown/unconfigured generation, a wrong key, or tamper all return
    /// `error.BadEnvelope`. Enabling `.encrypted` on a column that already holds
    /// plaintext therefore requires an explicit `zigbase rewrap` first; there is
    /// no silent plaintext passthrough.
    pub fn open(self: *const Cipher, alloc: std.mem.Allocator, stored: []const u8) aead.Error![]u8 {
        switch (self.mode) {
            .real => {
                const ver = aead.parseVersion(stored) orelse return error.BadEnvelope;
                if (ver < 1 or ver > MAX_GENERATION) return error.BadEnvelope;
                const key = self.keys[ver] orelse return error.BadEnvelope;
                return aead.open(alloc, key, stored);
            },
            .fake => {
                // Require the exact `fake:<fake_key>:` prefix (prefix-walk tolerates a ':'
                // inside the key). A different label, or a real `v<N>:` envelope, fails closed.
                if (!std.mem.startsWith(u8, stored, "fake:")) return error.BadEnvelope;
                const rest = stored["fake:".len..];
                if (!std.mem.startsWith(u8, rest, self.fake_key)) return error.BadEnvelope;
                const after = rest[self.fake_key.len..];
                if (after.len == 0 or after[0] != ':') return error.BadEnvelope;
                return alloc.dupe(u8, after[1..]);
            },
        }
    }
};

/// Field types that may carry an encryption envelope (text/editor/json). Single
/// source of truth lives in schema.zig so the comptime guards, the runtime
/// validator, and this value layer never drift.
pub const isEncryptableType = schema.isEncryptableType;

/// Test getter with a `get(key) ?[]const u8` method backed by a fixed list.
const MapGetter = struct {
    pairs: []const [2][]const u8,
    fn get(self: MapGetter, key: []const u8) ?[]const u8 {
        for (self.pairs) |p| if (std.mem.eql(u8, p[0], key)) return p[1];
        return null;
    }
};

test "seal/open round-trips a storage string and ciphertext-at-rest holds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cph = Cipher.fromEnv(std.testing.io, "operator-field-key");
    const blob = try cph.seal(a, "sensitive-value");
    try std.testing.expect(aead.isEnvelope(blob));
    try std.testing.expect(std.mem.startsWith(u8, blob, "v1:"));
    try std.testing.expect(std.mem.indexOf(u8, blob, "sensitive-value") == null);
    try std.testing.expectEqualStrings("sensitive-value", try cph.open(a, blob));
}

test "open is strict: legacy plaintext fails closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cph = Cipher.fromEnv(std.testing.io, "k");
    try std.testing.expectError(error.BadEnvelope, cph.open(a, "legacy-plaintext"));
}

test "multi-gen: writes use primary version; old generations still decrypt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Old single-key deployment: write v1: with "oldkey".
    const old = Cipher.fromEnv(std.testing.io, "oldkey");
    const v1_blob = try old.seal(a, "secret-payload");
    try std.testing.expect(std.mem.startsWith(u8, v1_blob, "v1:"));

    // Rotate: primary = generation 2 ("newkey"), generation 1 = "oldkey" (read-only).
    const getter = MapGetter{ .pairs = &.{.{ "ZIGBASE_FIELD_KEY_V1", "oldkey" }} };
    const ring = try Cipher.resolve(std.testing.io, getter, "newkey", 2);

    // Writes now stamp v2:.
    const v2_blob = try ring.seal(a, "secret-payload");
    try std.testing.expect(std.mem.startsWith(u8, v2_blob, "v2:"));
    // Both the legacy v1 blob and the new v2 blob decrypt under the ring.
    try std.testing.expectEqualStrings("secret-payload", try ring.open(a, v1_blob));
    try std.testing.expectEqualStrings("secret-payload", try ring.open(a, v2_blob));
}

test "multi-gen open fails closed on an unconfigured generation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A v1 blob, but the ring only knows generation 2 (no V1 supplied).
    const old = Cipher.fromEnv(std.testing.io, "oldkey");
    const v1_blob = try old.seal(a, "x");
    const getter = MapGetter{ .pairs = &.{} };
    const ring = try Cipher.resolve(std.testing.io, getter, "newkey", 2);
    try std.testing.expectError(error.BadEnvelope, ring.open(a, v1_blob));
}

test "resolve: bad generation and primary conflict are rejected" {
    const empty = MapGetter{ .pairs = &.{} };
    try std.testing.expectError(error.BadGeneration, Cipher.resolve(std.testing.io, empty, "k", 0));
    try std.testing.expectError(error.BadGeneration, Cipher.resolve(std.testing.io, empty, "k", MAX_GENERATION + 1));
    // Setting V<primary> alongside ZIGBASE_FIELD_KEY is ambiguous.
    const conflict = MapGetter{ .pairs = &.{.{ "ZIGBASE_FIELD_KEY_V2", "dup" }} };
    try std.testing.expectError(error.GenerationConflict, Cipher.resolve(std.testing.io, conflict, "k", 2));
}

test "generation 1 domain matches the legacy single-key domain (back-compat)" {
    // A v1 blob written by the pre-rotation build must decrypt when generation 1
    // is configured with the same raw key.
    const legacy_key = aead.deriveKey("rawkey", FIELD_KEY_DOMAIN);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blob = try aead.sealV1(std.testing.io, a, legacy_key, "legacy");
    const cph = Cipher.fromEnv(std.testing.io, "rawkey");
    try std.testing.expectEqualStrings("legacy", try cph.open(a, blob));
}

test "isEncryptableType allows only text/editor/json" {
    try std.testing.expect(isEncryptableType(.text));
    try std.testing.expect(isEncryptableType(.editor));
    try std.testing.expect(isEncryptableType(.json));
    try std.testing.expect(!isEncryptableType(.email));
    try std.testing.expect(!isEncryptableType(.url));
    try std.testing.expect(!isEncryptableType(.number));
    try std.testing.expect(!isEncryptableType(.relation));
    try std.testing.expect(!isEncryptableType(.bool));
}

test "fake mode: seal is readable and self-labeling; open round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cph = Cipher.fake(std.testing.io, "@test@");
    const blob = try cph.seal(a, "John Doe loves cheese");
    try std.testing.expectEqualStrings("fake:@test@:John Doe loves cheese", blob);
    try std.testing.expect(!aead.isEnvelope(blob)); // not a v<N>: envelope
    try std.testing.expectEqualStrings("John Doe loves cheese", try cph.open(a, blob));
}

test "fake mode: a different label fails closed (verifies which key)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blob = try Cipher.fake(std.testing.io, "k1").seal(a, "x");
    try std.testing.expectError(error.BadEnvelope, Cipher.fake(std.testing.io, "k2").open(a, blob));
}

test "fake and real envelopes are mutually unreadable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const real = Cipher.fromEnv(std.testing.io, "operator-key");
    const fake_c = Cipher.fake(std.testing.io, "@test@");
    const real_blob = try real.seal(a, "s");
    const fake_blob = try fake_c.seal(a, "s");
    try std.testing.expectError(error.BadEnvelope, real.open(a, fake_blob)); // prod can't read fake
    try std.testing.expectError(error.BadEnvelope, fake_c.open(a, real_blob)); // fake can't read real
}

test "resolveModeFromEnv is gated by the dev build" {
    if (dev.enabled) {
        try std.testing.expectEqual(Mode.fake, resolveModeFromEnv("fake"));
        try std.testing.expectEqual(Mode.real, resolveModeFromEnv("real"));
        try std.testing.expectEqual(Mode.real, resolveModeFromEnv(null));
    } else {
        try std.testing.expectEqual(Mode.real, resolveModeFromEnv("fake")); // comptime-off on prod
    }
}
