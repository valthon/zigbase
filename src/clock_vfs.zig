//! Dev-only: make SQLite's `CURRENT_TIMESTAMP` / `CURRENT_TIME` / `CURRENT_DATE` keywords
//! and column `DEFAULT CURRENT_TIMESTAMP` honor the frozen test clock (`clock.frozenUnix()`),
//! closing issue #97. Those keywords do NOT go through the SQL date/time *function* layer
//! that `clock_sql.zig` shadows for #84 — they read the clock through the VFS method
//! `xCurrentTimeInt64` (falling back to `xCurrentTime`). So freezing them needs a VFS, not
//! an app function.
//!
//! ## How
//! At connection-open time we open against a custom VFS named `zigbase_frozen` that is a
//! byte-for-byte COPY of the default VFS struct, with exactly three fields changed: `zName`,
//! `xCurrentTimeInt64`, and `xCurrentTime`. Every other field — `pAppData`, `szOsFile`,
//! `mxPathname`, `iVersion`, and ALL the I/O method pointers (`xOpen`, `xDelete`, …) — is
//! the genuine default-VFS value, so the real (unix) file methods run unchanged: no file
//! I/O is re-implemented. The two time hooks substitute the frozen instant when a freeze is
//! active and otherwise delegate to the real default VFS. The wrapper is registered
//! NON-default; connections opt in via the `zVfs` arg of `sqlite3_open_v2`, so anything that
//! opens without a name (the `clock_sql` helper connection, etc.) is untouched.
//!
//! ## Production gate (hard requirement)
//! `vfsName()` begins with `if (comptime !clock.enabled) return null;`. `clock.enabled` is
//! the comptime `dev_mode` build option (off in every release build), so on a prod build
//! `vfsName()` folds to `null` and `sqlite3_open_v2` is called with `zVfs = null` — the OS
//! default VFS, byte-for-byte unchanged. The wrapper struct, `ensureInstalled`, and both
//! callbacks are comptime-dead and eliminated; no custom VFS is ever registered.

const std = @import("std");
const c = @import("c.zig").c;
const clock = @import("clock.zig");

/// Name connections pass as the `zVfs` arg to select the freezing wrapper.
pub const vfs_name: [:0]const u8 = "zigbase_frozen";

/// The unix epoch (1970-01-01T00:00:00Z) expressed in `xCurrentTimeInt64` units:
/// Julian-day milliseconds. The unix epoch is Julian Day 2440587.5; ×86_400_000 ms/day.
const unix_epoch_jd_ms: i64 = 210866760000000;

/// Julian Day number of the unix epoch (for the floating-point `xCurrentTime`).
const unix_epoch_jd: f64 = 2440587.5;

const ms_per_s: i64 = 1000;
const secs_per_day: f64 = 86400.0;

/// Process-global wrapper state. The wrapper struct lives for the process lifetime once
/// registered (SQLite keeps the pointer in its VFS list), so it must be a global, not a
/// stack value. `real` is the genuine default VFS we delegate the non-frozen time reads to.
/// Guarded by a spin-mutex during install only (matching `clock_sql`'s helper); after
/// `installed` is set the callbacks read `real`/the struct without locking.
const State = struct {
    var mutex: std.atomic.Mutex = .unlocked;
    var installed: bool = false;
    var wrapper: c.sqlite3_vfs = undefined;
    var real: [*c]c.sqlite3_vfs = null;
};

/// Lazily register the freezing wrapper (idempotent) and return its name for the `zVfs`
/// arg of `sqlite3_open_v2`. Returns `null` (so the caller uses the default VFS) on a prod
/// build — the whole body is comptime-eliminated there — or if the default VFS can't be
/// found / registration fails (degrades to the unfrozen default rather than failing the open).
pub fn vfsName() ?[*:0]const u8 {
    if (comptime !clock.enabled) return null;
    ensureInstalled();
    if (!State.installed) return null;
    return vfs_name.ptr;
}

/// Copy the default VFS struct, override only `zName` + the two time hooks, and register the
/// copy non-default. comptime-dead on a prod build (only reachable via `vfsName`, which
/// returns before calling this when `!clock.enabled`).
fn ensureInstalled() void {
    while (!State.mutex.tryLock()) std.atomic.spinLoopHint();
    defer State.mutex.unlock();
    if (State.installed) return;

    const def = c.sqlite3_vfs_find(null);
    if (def == null) return; // no default VFS: caller falls back to null (unfrozen).
    State.real = def;
    State.wrapper = def.*; // byte-for-byte copy: preserves pAppData/szOsFile/mxPathname/I-O.
    State.wrapper.zName = vfs_name.ptr;
    State.wrapper.pNext = null; // sqlite3_vfs_register manages the linked list.
    State.wrapper.xCurrentTimeInt64 = xCurrentTimeInt64;
    // Only override xCurrentTime if the real VFS provides one; otherwise leave it null so
    // SQLite uses xCurrentTimeInt64 exclusively and the delegation in xCurrentTime() is safe.
    if (def.*.xCurrentTime != null) State.wrapper.xCurrentTime = xCurrentTime;
    if (c.sqlite3_vfs_register(&State.wrapper, 0) == c.SQLITE_OK) State.installed = true;
}

/// Julian-day-milliseconds clock. Returns the frozen instant when a freeze is active, else
/// delegates to the real default VFS (passing the REAL vfs pointer, not our wrapper).
fn xCurrentTimeInt64(_: [*c]c.sqlite3_vfs, out: [*c]c.sqlite3_int64) callconv(.c) c_int {
    if (clock.frozenUnix()) |f| {
        out.* = unix_epoch_jd_ms + f * ms_per_s;
        return c.SQLITE_OK;
    }
    const real = State.real;
    if (real.*.xCurrentTimeInt64) |f| return f(real, out);
    // Defensive: an iVersion-1 base VFS has no xCurrentTimeInt64; derive it from xCurrentTime.
    var r: f64 = 0;
    const rc = real.*.xCurrentTime.?(real, &r);
    if (rc == c.SQLITE_OK) out.* = @intFromFloat(r * 86400000.0);
    return rc;
}

/// Julian-day (floating) clock. Frozen instant when active, else delegates to the real VFS.
fn xCurrentTime(_: [*c]c.sqlite3_vfs, out: [*c]f64) callconv(.c) c_int {
    if (clock.frozenUnix()) |f| {
        out.* = unix_epoch_jd + @as(f64, @floatFromInt(f)) / secs_per_day;
        return c.SQLITE_OK;
    }
    const real = State.real;
    return real.*.xCurrentTime.?(real, out);
}

// ---------------------------------------------------------------------------
// Tests — prove #97: `CURRENT_TIMESTAMP` and column DEFAULTs honor the frozen clock when a
// freeze is active, track the wall clock otherwise, and stay on the OS clock (no wrapper
// installed) on a prod build. File-backed + WAL I/O through the wrapper is covered by the
// existing Pool tests in db.zig (they open via Db.open/openReader, which now route through
// vfsName() on a dev/test build).
// ---------------------------------------------------------------------------
const db = @import("db.zig");
const datetime = @import("datetime.zig");

const frozen_iso = "2029-03-07T16:00:00Z";
const frozen_unix: i64 = 1867593600; // = datetime.parse(frozen_iso)

fn scalarText(d: *db.Db, alloc: std.mem.Allocator, sql: [:0]const u8) ![]u8 {
    var stmt = try d.prepare(sql);
    defer stmt.finalize();
    try std.testing.expect(try stmt.step());
    return alloc.dupe(u8, stmt.columnText(0));
}

test "frozen: CURRENT_TIMESTAMP / CURRENT_DATE / CURRENT_TIME honor the freeze (dev build only)" {
    if (!clock.enabled) return error.SkipZigTest;
    clock.setForTest(frozen_unix);
    defer clock.resetForTest();
    var d = try db.Db.openMemory(); // routes through vfsName() -> the frozen wrapper
    defer d.close();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const want_ts = datetime.formatUtc(frozen_unix); // "2029-03-07 16:00:00"
    try std.testing.expectEqualStrings(&want_ts, try scalarText(&d, a, "SELECT CURRENT_TIMESTAMP"));
    try std.testing.expectEqualStrings("2029-03-07", try scalarText(&d, a, "SELECT CURRENT_DATE"));
    try std.testing.expectEqualStrings("16:00:00", try scalarText(&d, a, "SELECT CURRENT_TIME"));
}

test "frozen: a column DEFAULT CURRENT_TIMESTAMP inserts the frozen instant (dev build only)" {
    if (!clock.enabled) return error.SkipZigTest;
    clock.setForTest(frozen_unix);
    defer clock.resetForTest();
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, created TEXT DEFAULT CURRENT_TIMESTAMP);");
    try d.exec("INSERT INTO t (id) VALUES (1);");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const want = datetime.formatUtc(frozen_unix);
    try std.testing.expectEqualStrings(&want, try scalarText(&d, arena.allocator(), "SELECT created FROM t WHERE id = 1"));
}

test "no freeze: CURRENT_TIMESTAMP tracks the real wall clock (delegation, dev build)" {
    if (!clock.enabled) return error.SkipZigTest;
    clock.resetForTest();
    defer clock.resetForTest();
    var d = try db.Db.openMemory();
    defer d.close();
    // strftime('%s', CURRENT_TIMESTAMP) is a plausible recent wall-clock value, not frozen/zero.
    var stmt = try d.prepare("SELECT CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)");
    defer stmt.finalize();
    try std.testing.expect(try stmt.step());
    try std.testing.expect(stmt.columnInt(0) > 1577836800); // 2020-01-01
}

test "PROD GATE: no wrapper VFS installed and CURRENT_TIMESTAMP stays on the wall clock" {
    if (clock.enabled) return error.SkipZigTest; // only meaningful with -Ddev-mode=false
    clock.setForTest(frozen_unix); // gate refuses the freeze
    defer clock.resetForTest();
    // vfsName() comptime-folds to null; the wrapper is never registered.
    try std.testing.expectEqual(@as(?[*:0]const u8, null), vfsName());
    try std.testing.expectEqual(@as([*c]c.sqlite3_vfs, null), c.sqlite3_vfs_find(vfs_name.ptr));

    var d = try db.Db.openMemory();
    defer d.close();
    var stmt = try d.prepare("SELECT CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)");
    defer stmt.finalize();
    try std.testing.expect(try stmt.step());
    try std.testing.expect(stmt.columnInt(0) > 1577836800); // real clock, not the frozen 2029 value's behavior
}
