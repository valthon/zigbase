//! Dev-only: make a *consumer's* raw SQL `datetime('now')` / `unixepoch('now')` /
//! `strftime(fmt, 'now', …)` (and `date`/`time`/`julianday`) honor the frozen test clock
//! (`clock.frozenUnix()`), closing issue #84. Without this, only the framework's OWN
//! timestamps freeze under `ZIGBASE_FAKE_NOW`; a route doing raw SQL still read the OS
//! clock, so its output could never be snapshot-tested deterministically.
//!
//! ## How
//! At connection-open time we register application-defined SQL functions under the SAME
//! names as SQLite's date/time builtins. An app function shadows the builtin on that
//! connection. Our override does exactly one thing differently: when a freeze is active it
//! substitutes the `'now'` time-value with the frozen instant; otherwise it is a faithful
//! pass-through. The actual date math is NOT re-implemented — each call is delegated to a
//! process-global helper SQLite connection that has no overrides registered (so its date
//! functions are the genuine builtins). No recursion; full SQLite semantics preserved.
//!
//! ## Production gate (hard requirement)
//! `register` begins with `if (comptime !clock.enabled) return;`. `clock.enabled` is the
//! comptime `dev_mode` build option (off in every release build), so on a prod build the
//! entire body — every `sqlite3_create_function` call, the callback, the helper connection
//! — is comptime-dead and eliminated. A production connection is byte-for-byte unchanged
//! and `ZIGBASE_FAKE_NOW` is never consulted.

const std = @import("std");
const c = @import("c.zig").c;
const clock = @import("clock.zig");
const datetime = @import("datetime.zig");

/// The date/time builtins we shadow. `'now'` (and the zero-argument implicit-`'now'` form)
/// in any of these resolves to the frozen instant when a freeze is active.
const fn_names = [_][:0]const u8{ "date", "time", "datetime", "julianday", "unixepoch", "strftime" };

/// SQLITE_TRANSIENT as an opaque pointer (see db.zig for the aarch64 fn-ptr-alignment
/// rationale): tells SQLite to copy bound/returned text immediately.
const SQLITE_TRANSIENT: ?*const anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

// Re-declared with an opaque-pointer destructor (vs translate-c's fn-pointer type) so
// SQLITE_TRANSIENT passes without a fn-ptr alignment cast. Same C symbols; ABI-identical.
extern fn sqlite3_bind_text(stmt: ?*c.sqlite3_stmt, idx: c_int, text: [*c]const u8, n: c_int, destructor: ?*const anyopaque) callconv(.c) c_int;
extern fn sqlite3_bind_blob(stmt: ?*c.sqlite3_stmt, idx: c_int, data: ?*const anyopaque, n: c_int, destructor: ?*const anyopaque) callconv(.c) c_int;
extern fn sqlite3_result_text(ctx: ?*c.sqlite3_context, text: [*c]const u8, n: c_int, destructor: ?*const anyopaque) callconv(.c) void;

/// Process-global helper connection used to evaluate the genuine builtins. Opened lazily,
/// guarded by a spin-mutex (matching db.zig's `std.atomic.Mutex` usage), shared across all
/// reader/writer threads (FULLMUTEX serializes internally). Dev-only; lives for the process
/// lifetime, so there is no per-connection cleanup to track.
const Helper = struct {
    var mutex: std.atomic.Mutex = .unlocked;
    var conn: ?*c.sqlite3 = null;

    /// Returns the helper connection, opening it on first use. Caller must hold `mutex`.
    fn get() ?*c.sqlite3 {
        if (conn) |h| return h;
        var handle: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        if (c.sqlite3_open_v2(":memory:", &handle, flags, null) != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return null;
        }
        conn = handle;
        return handle;
    }
};

/// Register the date/time overrides on `handle`. No-op (comptime-eliminated) on a prod
/// build. Called from `db.zig` at connection open for the writer and every reader.
pub fn register(handle: *c.sqlite3) void {
    if (comptime !clock.enabled) return;
    inline for (fn_names) |name| {
        // nArg = -1: accept any argument count (date fns are variadic via modifiers).
        // pApp carries the builtin name so the shared callback knows what to delegate to.
        _ = c.sqlite3_create_function(
            handle,
            name.ptr,
            -1,
            c.SQLITE_UTF8,
            @ptrCast(@constCast(name.ptr)),
            xFunc,
            null,
            null,
        );
    }
}

/// Is `argv[i]` a text value that means `'now'` (trimmed, case-insensitive)?
fn argIsNow(val: *c.sqlite3_value) bool {
    if (c.sqlite3_value_type(val) != c.SQLITE3_TEXT) return false;
    const ptr = c.sqlite3_value_text(val);
    if (ptr == null) return false;
    const len: usize = @intCast(c.sqlite3_value_bytes(val));
    const s = std.mem.trim(u8, ptr[0..len], " \t\r\n");
    return std.ascii.eqlIgnoreCase(s, "now");
}

/// Shared callback for every shadowed builtin. Substitutes the frozen instant for `'now'`
/// (when a freeze is active), then delegates to the helper connection's genuine builtin and
/// forwards the result. comptime-unreachable on a prod build (`register` never installs it).
fn xFunc(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    const name_z: [*:0]const u8 = @ptrCast(c.sqlite3_user_data(ctx));
    const name = std.mem.span(name_z);
    const frozen = clock.frozenUnix();

    var iso_buf: [19]u8 = undefined; // frozen instant formatted as "YYYY-MM-DD HH:MM:SS"
    var iso: []const u8 = "";
    if (frozen) |f| {
        iso_buf = datetime.formatUtc(f);
        iso = &iso_buf;
    }

    const n: usize = @intCast(argc);
    // The implicit-now form: `datetime()` == `datetime('now')`. When frozen, inject the
    // frozen instant as a single argument; otherwise let the builtin resolve real `now`.
    const inject_zero = (n == 0 and frozen != null);
    const nph: usize = if (inject_zero) 1 else n;

    if (nph > max_args) {
        c.sqlite3_result_error(ctx, "clock_sql: too many arguments", -1);
        return;
    }

    // Build `SELECT <name>(?1, ?2, …)` (null-terminated) for delegation.
    var sql_buf: [256]u8 = undefined;
    var len: usize = 0;
    len += (std.fmt.bufPrint(sql_buf[len..], "SELECT {s}(", .{name}) catch {
        c.sqlite3_result_error(ctx, "clock_sql: sql build failed", -1);
        return;
    }).len;
    var k: usize = 0;
    while (k < nph) : (k += 1) {
        const piece = std.fmt.bufPrint(sql_buf[len..], "{s}?{d}", .{ if (k == 0) "" else ",", k + 1 }) catch {
            c.sqlite3_result_error(ctx, "clock_sql: sql build failed", -1);
            return;
        };
        len += piece.len;
    }
    if (len + 2 > sql_buf.len) {
        c.sqlite3_result_error(ctx, "clock_sql: sql build failed", -1);
        return;
    }
    sql_buf[len] = ')';
    sql_buf[len + 1] = 0; // null terminator for prepare_v2 (nByte = -1)
    len += 1;

    while (!Helper.mutex.tryLock()) std.atomic.spinLoopHint();
    defer Helper.mutex.unlock();
    const helper = Helper.get() orelse {
        c.sqlite3_result_error(ctx, "clock_sql: helper connection unavailable", -1);
        return;
    };

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(helper, @ptrCast(&sql_buf), -1, &stmt, null) != c.SQLITE_OK or stmt == null) {
        c.sqlite3_result_error(ctx, "clock_sql: delegate prepare failed", -1);
        return;
    }
    defer _ = c.sqlite3_finalize(stmt);

    if (inject_zero) {
        // Single injected arg = frozen instant.
        _ = sqlite3_bind_text(stmt, 1, iso.ptr, @intCast(iso.len), SQLITE_TRANSIENT);
    } else {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const val = argv[i].?;
            const idx: c_int = @intCast(i + 1);
            if (frozen != null and argIsNow(val)) {
                _ = sqlite3_bind_text(stmt, idx, iso.ptr, @intCast(iso.len), SQLITE_TRANSIENT);
                continue;
            }
            switch (c.sqlite3_value_type(val)) {
                c.SQLITE_INTEGER => _ = c.sqlite3_bind_int64(stmt, idx, c.sqlite3_value_int64(val)),
                c.SQLITE_FLOAT => _ = c.sqlite3_bind_double(stmt, idx, c.sqlite3_value_double(val)),
                c.SQLITE3_TEXT => {
                    const tb: usize = @intCast(c.sqlite3_value_bytes(val));
                    _ = sqlite3_bind_text(stmt, idx, c.sqlite3_value_text(val), @intCast(tb), SQLITE_TRANSIENT);
                },
                c.SQLITE_BLOB => {
                    const bb: usize = @intCast(c.sqlite3_value_bytes(val));
                    _ = sqlite3_bind_blob(stmt, idx, c.sqlite3_value_blob(val), @intCast(bb), SQLITE_TRANSIENT);
                },
                else => _ = c.sqlite3_bind_null(stmt, idx),
            }
        }
    }

    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) {
        // No row / error: the builtin would have produced NULL for malformed input too.
        c.sqlite3_result_null(ctx);
        return;
    }
    switch (c.sqlite3_column_type(stmt, 0)) {
        c.SQLITE_INTEGER => c.sqlite3_result_int64(ctx, c.sqlite3_column_int64(stmt, 0)),
        c.SQLITE_FLOAT => c.sqlite3_result_double(ctx, c.sqlite3_column_double(stmt, 0)),
        c.SQLITE3_TEXT => {
            const rb: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
            sqlite3_result_text(ctx, c.sqlite3_column_text(stmt, 0), @intCast(rb), SQLITE_TRANSIENT);
        },
        else => c.sqlite3_result_null(ctx),
    }
}

/// Upper bound on delegated arguments (keeps the SQL builder buffer bounded). Date/time
/// builtins in practice take a handful of modifiers; this is a generous ceiling.
const max_args: usize = 32;

// ---------------------------------------------------------------------------
// Tests — exercise the override through a real in-memory connection. They prove #84:
// a consumer's raw `datetime('now')` etc. resolve to the frozen instant when a freeze is
// active, behave like the builtins otherwise, and stay wall-clock on a prod build.
// ---------------------------------------------------------------------------
const db = @import("db.zig");

const frozen_iso = "2029-03-07T16:00:00Z";
const frozen_unix: i64 = 1867593600; // = datetime.parse(frozen_iso)

fn scalarText(d: *db.Db, alloc: std.mem.Allocator, sql: [:0]const u8) ![]u8 {
    var stmt = try d.prepare(sql);
    defer stmt.finalize();
    try std.testing.expect(try stmt.step());
    return alloc.dupe(u8, stmt.columnText(0));
}

fn scalarInt(d: *db.Db, sql: [:0]const u8) !i64 {
    var stmt = try d.prepare(sql);
    defer stmt.finalize();
    try std.testing.expect(try stmt.step());
    return stmt.columnInt(0);
}

test "no freeze: overridden builtins pass through to real SQLite" {
    clock.resetForTest();
    defer clock.resetForTest();
    var d = try db.Db.openMemory();
    defer d.close();
    register(db.sqliteHandle(&d));

    // unixepoch('now') is a plausible recent wall-clock value (not frozen/zero).
    try std.testing.expect((try scalarInt(&d, "SELECT unixepoch('now')")) > 1577836800);

    // An explicit (non-'now') datetime is returned verbatim — pure pass-through.
    const got = try scalarText(&d, std.testing.allocator, "SELECT datetime('2020-01-02 03:04:05')");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("2020-01-02 03:04:05", got);
}

test "frozen: consumer SQL 'now' resolves to the frozen instant (dev build only)" {
    if (!clock.enabled) return error.SkipZigTest;
    clock.setForTest(frozen_unix);
    defer clock.resetForTest();
    var d = try db.Db.openMemory();
    defer d.close();
    register(db.sqliteHandle(&d));

    const a = std.testing.allocator;

    try std.testing.expectEqual(frozen_unix, try scalarInt(&d, "SELECT unixepoch('now')"));
    const got1 = try scalarText(&d, a, "SELECT datetime('now')");
    defer a.free(got1);
    try std.testing.expectEqualStrings("2029-03-07 16:00:00", got1);
    const got2 = try scalarText(&d, a, "SELECT date('now')");
    defer a.free(got2);
    try std.testing.expectEqualStrings("2029-03-07", got2);
    const got3 = try scalarText(&d, a, "SELECT time('now')");
    defer a.free(got3);
    try std.testing.expectEqualStrings("16:00:00", got3);
    const got4 = try scalarText(&d, a, "SELECT strftime('%Y', 'now')");
    defer a.free(got4);
    try std.testing.expectEqualStrings("2029", got4);
    // Modifiers still work: 'now' is replaced, the rest of the math is genuine SQLite.
    const got5 = try scalarText(&d, a, "SELECT datetime('now','+1 day')");
    defer a.free(got5);
    try std.testing.expectEqualStrings("2029-03-08 16:00:00", got5);
    // Implicit-'now' (zero-arg) form is frozen too.
    const got6 = try scalarText(&d, a, "SELECT datetime()");
    defer a.free(got6);
    try std.testing.expectEqualStrings("2029-03-07 16:00:00", got6);
    // Case/whitespace-insensitive 'now'.
    try std.testing.expectEqual(frozen_unix, try scalarInt(&d, "SELECT unixepoch(' NOW ')"));
    // Explicit (non-'now') values are NOT touched even under a freeze.
    try std.testing.expectEqual(@as(i64, 1577836800), try scalarInt(&d, "SELECT unixepoch('2020-01-01 00:00:00')"));
}

test "PROD GATE: a non-dev build leaves consumer SQL on the wall clock" {
    if (clock.enabled) return error.SkipZigTest; // only meaningful with -Ddev-mode=false
    clock.setForTest(frozen_unix); // gate refuses the freeze
    defer clock.resetForTest();
    var d = try db.Db.openMemory();
    defer d.close();
    register(db.sqliteHandle(&d)); // comptime no-op
    try std.testing.expect((try scalarInt(&d, "SELECT unixepoch('now')")) > 1577836800);
}
