//! The single "now" seam. Every framework-controlled timestamp (token expiry, the
//! scheduler's tick clock, the auth-rate-limiter wall clock, challenge-store TTL math)
//! reads "now" through here instead of calling the OS / SQLite clock directly, so an
//! e2e suite can freeze time and exercise time-boundary scenarios deterministically.
//!
//! ## Dev-only override
//! When `ZIGBASE_FAKE_NOW` is set to an ISO-8601 UTC instant (e.g.
//! `2029-03-07T16:00:00Z`), every helper here returns that frozen instant instead of
//! wall-clock. The grammar is `datetime.parse`'s (a bare `YYYY-MM-DD`, a space- or
//! `T`-separated datetime, optional fractional seconds, optional `Z`/±HH:MM; a missing
//! zone is UTC).
//!
//! ## Production gate (hard requirement)
//! The override is compiled in ONLY when the `dev_clock` build option is true. That
//! option defaults to `optimize == .Debug` (see build.zig) and is forced false by the
//! release script's cross-compiles, so a production binary never even reads the env var:
//! `enabled` is `comptime false` there, the parse code is dead, and `frozenUnix()` folds
//! to `null` at compile time. It is impossible to freeze time on a prod build.
//!
//! ## Scope of what honors the override
//! - The framework clock: `scheduler.unixNow` (job scheduling cadence / next-fire math).
//! - The auth rate-limiter wall clock (`api/auth.wallNowUnix`).
//! - SQL `now` the framework issues for its OWN logic: token `iat`/`exp` (`api/auth`,
//!   `auth`), the auth-challenge TTL/expiry checks, the records keyset-cursor `now`.
//! NOT honored (documented in KNOWN_LIMITATIONS.md): a `datetime('now')`/`unixepoch('now')`
//! a *consumer* embeds in their own custom SQL, or SQLite column DEFAULTs — those still read
//! the OS clock. The override governs the framework's clock, not SQLite's global clock.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const datetime = @import("datetime.zig");
const db = @import("db.zig");

/// Comptime gate. True only on a `dev_clock`-enabled build (Debug by default; never a
/// release/prod build). When false, every override branch below is comptime-dead and
/// the env var is never consulted.
pub const enabled = build_options.dev_clock;

/// The name of the env var that freezes time (dev builds only).
pub const env_var = "ZIGBASE_FAKE_NOW";

/// Process-global frozen instant, installed once at startup (`install`) from the resolved
/// config. Read by every helper below. Guarded by a spinlock so the scheduler/worker threads
/// can read it concurrently with a (one-shot, startup-only) install. On a prod build `enabled`
/// is comptime-false, so `install` is a no-op and `value` is permanently null.
const Cache = struct {
    var mutex: std.atomic.Mutex = .unlocked;
    var value: ?i64 = null;

    fn lock() void {
        while (!mutex.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock() void {
        mutex.unlock();
    }
};

/// Parse a `ZIGBASE_FAKE_NOW` value to unix seconds, gated by the build. Returns null on a
/// prod build (the override is comptime-dead), on an unset/empty value, or on a value that
/// fails to parse as an accepted ISO-8601 instant (logged + ignored, never a crash). Call this
/// from config loading (which holds the env map) and pass the result to `install`.
pub fn resolveFromEnv(raw: ?[]const u8) ?i64 {
    if (!enabled) return null;
    const s = raw orelse return null;
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    if (trimmed.len == 0) return null;
    return datetime.parse(trimmed) catch {
        std.log.warn("{s}=\"{s}\" is not a valid ISO-8601 instant; ignoring (using wall-clock)", .{ env_var, trimmed });
        return null;
    };
}

/// Install the resolved override into the process-global cache. No-op on a prod build (the
/// gate forces null), so a production binary can never freeze time even if a non-null value
/// were somehow threaded in. Logged loudly when an override is actually active.
pub fn install(frozen: ?i64) void {
    if (!enabled) return;
    Cache.lock();
    defer Cache.unlock();
    Cache.value = frozen;
    if (frozen) |v| std.log.warn(
        "DEV CLOCK FROZEN via {s} ({d}) — framework time is overridden. This must NEVER appear on a production build.",
        .{ env_var, v },
    );
}

/// The installed frozen instant (unix seconds) on a dev build with an override set, else null.
/// On a prod build this is `comptime null`.
pub fn frozenUnix() ?i64 {
    if (!enabled) return null;
    Cache.lock();
    defer Cache.unlock();
    return Cache.value;
}

/// TEST-ONLY: force the cached override to `v` (or back to wall-clock with null) so a unit
/// test can exercise the frozen-clock branch deterministically and reset it afterward.
/// The prod gate still applies: on a non-dev build this can never install a frozen value.
pub fn setForTest(v: ?i64) void {
    if (!builtin.is_test) @compileError("clock.setForTest is test-only");
    install(v);
}

/// TEST-ONLY: drop the cached override (back to wall-clock).
pub fn resetForTest() void {
    if (!builtin.is_test) @compileError("clock.resetForTest is test-only");
    Cache.lock();
    defer Cache.unlock();
    Cache.value = null;
}

/// Wall-clock seconds, honoring the override. The framework clock (`scheduler.unixNow`)
/// and the auth rate-limiter route through here. On a prod build / no override it is
/// exactly `std.Io.Timestamp.now(io, .real)` truncated to seconds.
pub fn nowUnix(io: std.Io) i64 {
    if (frozenUnix()) |v| return v;
    const ts = std.Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s));
}

/// SQL `now` (unix seconds) for framework-issued timestamp logic: returns the frozen
/// instant when overridden, else `SELECT unixepoch('now')`. Replaces the per-file
/// `SELECT unixepoch('now')` helpers so they all agree with the wall clock above.
pub fn sqlNowUnix(conn: *db.Db) db.DbError!i64 {
    if (frozenUnix()) |v| return v;
    var st = try conn.prepare("SELECT unixepoch('now');");
    defer st.finalize();
    _ = try st.step();
    return st.columnInt(0);
}

test "resolveFromEnv parses, tolerates garbage, and is gated by the build" {
    if (enabled) {
        try std.testing.expectEqual(@as(?i64, 1867593600), resolveFromEnv("2029-03-07T16:00:00Z"));
        try std.testing.expectEqual(@as(?i64, null), resolveFromEnv("garbage")); // ignored, not a crash
        try std.testing.expectEqual(@as(?i64, null), resolveFromEnv("  ")); // empty/blank
        try std.testing.expectEqual(@as(?i64, null), resolveFromEnv(null)); // unset
    } else {
        // prod build: gate is comptime-off — even a valid value resolves to null.
        try std.testing.expectEqual(@as(?i64, null), resolveFromEnv("2029-03-07T16:00:00Z"));
    }
}
