//! Seeded entropy seam for deterministic ID/token generation in test/dev mode.
//!
//! ## What this solves
//! `src/id.zig` draws random bytes from `io.random` for every record/token/field ID.
//! In a test run those bytes are real CSPRNG output, so IDs differ on every run and
//! snapshot tests cannot assert stable values. Setting `ZIGBASE_FAKE_SEED` to a u64
//! integer plants a deterministic PRNG (Xoshiro256++) as the entropy source, making
//! ID/token generation reproducible across runs with the same seed.
//!
//! ## Dev-only override
//! When `ZIGBASE_FAKE_SEED` is set to a decimal u64 (e.g. `12345`), every call to
//! `entropy.fill` on a dev build draws from a seeded Xoshiro256++ rather than the OS
//! CSPRNG. Re-seeding to the same value resets the PRNG to its initial state, so two
//! runs with the same seed produce byte-for-byte identical IDs and tokens.
//!
//! ## Production gate (hard requirement)
//! The seeded PRNG is compiled in ONLY when `clock.enabled` is true (i.e. the `dev_clock`
//! build option is on — default in `Debug`, forced off by the release script in all
//! release/prod builds). On a prod build `enabled` is `comptime false`, every override
//! branch is dead code, and `entropy.fill` degrades to a straight `io.random(buf)` call.
//! A production binary never reads `ZIGBASE_FAKE_SEED` and the real OS CSPRNG is always
//! used — the seeded path is comptime-eliminated and cannot weaken production randomness.
//!
//! ## Scope
//! Routes through `id.generate` (called by `crypto.genToken` and every `id.collectionId`
//! / `id.fieldId`), covering all record/field/token/tokenKey IDs. Other randomness
//! (AEAD nonces, OTP digits, SMTP entropy, WebAuthn challenges) is NOT routed here —
//! those are security-critical at runtime and seeding them is an explicit non-goal.

const std = @import("std");
const builtin = @import("builtin");
const clock = @import("clock.zig");

/// Comptime gate. True only on a `dev_clock`-enabled build (Debug by default; never a
/// release/prod build). Reuses the same build option as the clock seam — a single
/// `-Ddev-clock` flag enables the full deterministic-test-mode surface (frozen time +
/// seeded entropy). When false, every seeded-PRNG branch below is comptime-dead.
pub const enabled = clock.enabled;

/// The name of the env var that seeds entropy (dev builds only).
pub const env_var = "ZIGBASE_FAKE_SEED";

/// Sentinel meaning "no seed installed" — stored in a cache atomic so no extra bool is needed.
const unset_sentinel: u64 = std.math.maxInt(u64);

/// Process-global seeded PRNG + spinlock (dev builds only). The PRNG is written once at
/// startup (or by setForTest) and then read by concurrent worker threads on every ID
/// generation, so a spinlock is required. The lock is always very briefly held — one
/// Xoshiro256++ step per output byte — so spinlock contention is negligible.
const Cache = struct {
    var mu: std.atomic.Mutex = .unlocked;
    var prng: std.Random.DefaultPrng = undefined; // valid iff seed_val != unset_sentinel
    var seed_val: std.atomic.Value(u64) = std.atomic.Value(u64).init(unset_sentinel);
};

/// Parse `ZIGBASE_FAKE_SEED` as a decimal u64. Returns null on a prod build (the
/// override is comptime-dead), on an unset/empty value, or if the value cannot be
/// parsed (logged + ignored, never a crash). Call this from config loading and pass the
/// result to `install`.
pub fn resolveFromEnv(raw: ?[]const u8) ?u64 {
    if (!enabled) return null;
    const s = raw orelse return null;
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(u64, trimmed, 10) catch {
        std.log.warn("{s}=\"{s}\" is not a valid u64 integer seed; ignoring (using real CSPRNG)", .{ env_var, trimmed });
        return null;
    };
}

/// Install the seeded PRNG from the resolved config. No-op on a prod build (the gate
/// forces null), so a production binary can never plant a seeded PRNG even if a
/// non-null value were somehow threaded in. Logged loudly when a seed is actually active.
pub fn install(seed: ?u64) void {
    if (!enabled) return;
    if (seed) |v| {
        while (!Cache.mu.tryLock()) std.atomic.spinLoopHint();
        Cache.prng = std.Random.DefaultPrng.init(v);
        Cache.seed_val.store(v, .release);
        Cache.mu.unlock();
        std.log.warn(
            "DEV ENTROPY SEEDED via {s} (seed={d}) — ID/token generation is deterministic. This must NEVER appear on a production build.",
            .{ env_var, v },
        );
    } else {
        Cache.seed_val.store(unset_sentinel, .release);
    }
}

/// True when a seed is installed (dev build + ZIGBASE_FAKE_SEED set).
/// Lock-free atomic load; on a prod build this is `comptime false`.
pub fn isActive() bool {
    if (!enabled) return false;
    return Cache.seed_val.load(.acquire) != unset_sentinel;
}

/// Fill `buf` with entropy.
///
/// When a seed is installed (dev builds only): uses the seeded Xoshiro256++ under a
/// spinlock — every call with the same prior PRNG state produces identical bytes, making
/// ID/token generation reproducible for snapshot tests.
///
/// When no seed is installed: delegates to `io.random` (the OS CSPRNG).
///
/// On a prod build `enabled` is `comptime false`, so the seeded branch is dead code and
/// this reduces to a plain `io.random(buf)` call with zero overhead.
pub fn fill(io: std.Io, buf: []u8) void {
    if (enabled and isActive()) {
        while (!Cache.mu.tryLock()) std.atomic.spinLoopHint();
        defer Cache.mu.unlock();
        Cache.prng.random().bytes(buf);
        return;
    }
    io.random(buf);
}

/// TEST-ONLY: force the seeded PRNG to `seed` (or back to real CSPRNG with null) so a
/// unit test can exercise the deterministic branch and reset it afterward.
/// The prod gate still applies: on a non-dev build install() is a no-op.
pub fn setForTest(seed: ?u64) void {
    if (!builtin.is_test) @compileError("entropy.setForTest is test-only");
    install(seed);
}

/// TEST-ONLY: drop the seeded override (back to real CSPRNG).
pub fn resetForTest() void {
    if (!builtin.is_test) @compileError("entropy.resetForTest is test-only");
    Cache.seed_val.store(unset_sentinel, .release);
}

test "resolveFromEnv parses valid seeds and is gated by the build" {
    if (enabled) {
        try std.testing.expectEqual(@as(?u64, 42), resolveFromEnv("42"));
        try std.testing.expectEqual(@as(?u64, 0), resolveFromEnv("0"));
        try std.testing.expectEqual(@as(?u64, 18446744073709551614), resolveFromEnv("18446744073709551614"));
        try std.testing.expectEqual(@as(?u64, null), resolveFromEnv("not-a-number")); // invalid, ignored
        try std.testing.expectEqual(@as(?u64, null), resolveFromEnv("  ")); // blank
        try std.testing.expectEqual(@as(?u64, null), resolveFromEnv(null)); // unset
        try std.testing.expectEqual(@as(?u64, null), resolveFromEnv("-1")); // out of range for u64
    } else {
        // prod build: gate is comptime-off — even a valid value resolves to null.
        try std.testing.expectEqual(@as(?u64, null), resolveFromEnv("42"));
    }
}

test "with a seed: fill is deterministic across two identical seeds" {
    if (!enabled) return error.SkipZigTest;
    setForTest(12345);
    defer resetForTest();

    var a: [32]u8 = undefined;
    fill(std.testing.io, &a);

    // Re-seed to the same value — resets the PRNG state to the initial position.
    setForTest(12345);
    var b: [32]u8 = undefined;
    fill(std.testing.io, &b);

    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "different seeds produce different output" {
    if (!enabled) return error.SkipZigTest;

    setForTest(1);
    defer resetForTest();
    var a: [16]u8 = undefined;
    fill(std.testing.io, &a);

    setForTest(2);
    var b: [16]u8 = undefined;
    fill(std.testing.io, &b);

    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "without a seed: fill produces real (non-seeded) entropy" {
    if (!enabled) return error.SkipZigTest;
    resetForTest();
    try std.testing.expect(!isActive());
    // Two separate calls to the real CSPRNG must not produce the same bytes
    // (astronomically unlikely for 16 bytes).
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    fill(std.testing.io, &a);
    fill(std.testing.io, &b);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "PROD GATE: a non-dev build never activates the seeded PRNG" {
    if (enabled) return error.SkipZigTest; // only meaningful when compiled with -Ddev-clock=false
    // install() is a no-op on prod; setForTest calls install() internally.
    install(42);
    try std.testing.expect(!isActive()); // gate refuses it
    // fill always delegates to io.random on prod (the seeded branch is comptime-dead).
    var buf: [8]u8 = undefined;
    fill(std.testing.io, &buf); // must not crash
}
