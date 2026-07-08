//! Tests for the dev-only injectable clock (`clock.zig`). They exercise the seam through
//! a real in-memory SQLite connection and through the JWT expiry path, and assert the
//! production gate's hard contract: when `dev_mode` is off, time can NOT be frozen.

const std = @import("std");
const builtin = @import("builtin");
const clock = @import("clock.zig");
const db = @import("db.zig");
const jwt = @import("jwt.zig");
const datetime = @import("datetime.zig");

const frozen_iso = "2029-03-07T16:00:00Z";
const frozen_unix: i64 = 1867593600; // = datetime.parse(frozen_iso)

test "frozen_unix constant matches datetime.parse" {
    try std.testing.expectEqual(frozen_unix, try datetime.parse(frozen_iso));
}

test "no override: sqlNowUnix tracks SQLite wall clock" {
    clock.resetForTest();
    defer clock.resetForTest();
    var d = try db.Db.openMemory();
    defer d.close();
    const a = try clock.sqlNowUnix(&d);
    // Sanity: SQLite's unixepoch('now') is a plausible recent wall-clock value (> 2020),
    // proving we did NOT silently return a frozen/zero value with no override set.
    try std.testing.expect(a > 1577836800); // 2020-01-01
}

test "frozen override drives sqlNowUnix and the wall clock to the same instant (dev build only)" {
    if (!clock.enabled) return error.SkipZigTest; // contract verified by the prod-gate test below
    clock.setForTest(frozen_unix);
    defer clock.resetForTest();
    var d = try db.Db.openMemory();
    defer d.close();
    try std.testing.expectEqual(frozen_unix, try clock.sqlNowUnix(&d));
    try std.testing.expectEqual(frozen_unix, clock.nowUnix(std.testing.io));
    try std.testing.expectEqual(@as(?i64, frozen_unix), clock.frozenUnix());
}

test "token expiry is deterministic against the frozen clock (dev build only)" {
    if (!clock.enabled) return error.SkipZigTest;
    clock.setForTest(frozen_unix);
    defer clock.resetForTest();
    // jwt.sign / jwt.verify allocate (claims borrow from the arena); use an arena like the
    // jwt.zig tests do, so nothing leaks.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const key = "test-signing-key-please-ignore";

    // Issue a token whose iat/exp derive from the seam's "now" (mirrors api/auth.issue).
    var d = try db.Db.openMemory();
    defer d.close();
    const now = try clock.sqlNowUnix(&d);
    try std.testing.expectEqual(frozen_unix, now); // the SQL seam returns the frozen instant
    const ttl: i64 = 3600;
    const claims = jwt.Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = now, .exp = now + ttl };
    const token = try jwt.sign(alloc, claims, key);

    // Valid 1s before exp; expired 1s after exp — both judged against the frozen clock.
    const ok = try jwt.verify(alloc, token, key, frozen_unix + ttl - 1);
    try std.testing.expectEqual(frozen_unix + ttl, ok.exp);
    try std.testing.expectError(error.Expired, jwt.verify(alloc, token, key, frozen_unix + ttl + 1));
}

test "PROD GATE: a non-dev build can never freeze time" {
    if (clock.enabled) return error.SkipZigTest; // only meaningful when compiled with -Ddev-mode=false
    // Even if a test tries to force an override, the gate refuses it and now stays wall-clock.
    clock.setForTest(frozen_unix);
    defer clock.resetForTest();
    try std.testing.expectEqual(@as(?i64, null), clock.frozenUnix());
    var d = try db.Db.openMemory();
    defer d.close();
    try std.testing.expect((try clock.sqlNowUnix(&d)) > 1577836800);
}

test "invalid ISO instant in env is ignored (no crash); valid one parses" {
    // The resolver tolerates garbage: parse must reject it, leaving wall-clock in place.
    try std.testing.expectError(error.InvalidFormat, datetime.parse("not-a-date"));
    try std.testing.expectEqual(frozen_unix, try datetime.parse(frozen_iso));
}
