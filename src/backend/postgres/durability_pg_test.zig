//! Live commit-durability tests (#490). Every connection zigbase opens raises a session whose
//! effective `synchronous_commit` is `off` to `local`, and leaves every stronger level alone.
//! The server-side default is set per throwaway ROLE (`ALTER ROLE … SET synchronous_commit`), so
//! the suite role needs CREATEROLE (CI's is a superuser); skips when no PG is reachable or the
//! role lacks the privilege, like `scram_pg_test.zig`. Role names carry this process's pid so
//! concurrent runs against one shared cluster (roles are cluster-global) do not collide.

const std = @import("std");
const pg = @import("postgres.zig");
const pgtests = @import("tests.zig");
const conn = @import("conn.zig");

const role_password = "zb_sync_pw";

fn adminOrSkip(a: std.mem.Allocator, io: std.Io) !?pg.Db {
    var db = pg.Db.open(a, io, pgtests.testUrl()) catch |e| switch (e) {
        error.OpenFailed => return null,
        else => return e,
    };
    // CREATEROLE probe: a no-op when permitted, "permission denied" otherwise.
    db.exec("DROP ROLE IF EXISTS zb_sync_privilege_probe;") catch {
        db.close();
        return null;
    };
    return db;
}

/// The suite URL with the userinfo swapped for `user:role_password` (verbatim splice; the
/// fixture credentials are URL-safe).
fn urlAs(a: std.mem.Allocator, user: []const u8) ![]const u8 {
    const base = pgtests.testUrl();
    const scheme_end = (std.mem.indexOf(u8, base, "://") orelse return error.TestUnexpectedResult) + 3;
    const at = std.mem.indexOfScalarPos(u8, base, scheme_end, '@') orelse return error.TestUnexpectedResult;
    return a.print("{s}{s}:{s}@{s}", .{ base[0..scheme_end], user, role_password, base[at + 1 ..] });
}

/// (Re)create login role `name` whose server-side default is `synchronous_commit = level`.
fn createRole(a: std.mem.Allocator, admin: *pg.Db, name: []const u8, level: []const u8) !void {
    const drop = try a.printSentinel("DROP ROLE IF EXISTS {s};", .{name}, 0);
    defer a.free(drop);
    try admin.exec(drop);
    const create = try a.printSentinel("CREATE ROLE {s} LOGIN PASSWORD '{s}';", .{ name, role_password }, 0);
    defer a.free(create);
    try admin.exec(create);
    const alter = try a.printSentinel("ALTER ROLE {s} SET synchronous_commit = '{s}';", .{ name, level }, 0);
    defer a.free(alter);
    try admin.exec(alter);
}

fn dropRole(a: std.mem.Allocator, admin: *pg.Db, name: []const u8) void {
    const drop = a.printSentinel("DROP ROLE IF EXISTS {s};", .{name}, 0) catch return;
    defer a.free(drop);
    admin.exec(drop) catch {};
}

fn expectSyncCommit(db: *pg.Db, expected: []const u8) !void {
    var st = try db.prepare("SHOW synchronous_commit;");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings(expected, st.columnText(0));
}

/// `<base>_<pid>`: a per-run role name (caller frees).
fn roleName(a: std.mem.Allocator, base: []const u8) ![]u8 {
    return a.print("{s}_{d}", .{ base, std.c.getpid() });
}

test "pg durability: a role defaulting to synchronous_commit=off is raised to local on connect" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var admin = (try adminOrSkip(a, io)) orelse return error.SkipZigTest;
    defer admin.close();
    const role = try roleName(a, "zb_sync_off");
    defer a.free(role);
    try createRole(a, &admin, role, "off");
    defer dropRole(a, &admin, role);

    const url = try urlAs(a, role);
    defer a.free(url);
    var db = try pg.Db.open(a, io, url);
    defer db.close();
    try expectSyncCommit(&db, "local");
}

test "pg durability: the pool's writer and every reader run at local under a synchronous_commit=off default" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var admin = (try adminOrSkip(a, io)) orelse return error.SkipZigTest;
    defer admin.close();
    const role = try roleName(a, "zb_sync_off_pool");
    defer a.free(role);
    try createRole(a, &admin, role, "off");
    defer dropRole(a, &admin, role);

    const url = try urlAs(a, role);
    defer a.free(url);
    var pool = try pg.Pool.init(a, io, url);
    defer pool.deinit();
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try expectSyncCommit(w, "local");
    }
    var r1 = try pool.acquireReader();
    defer pool.releaseReader(&r1);
    var r2 = try pool.acquireReader(); // a second, concurrently held reader is a fresh connect
    defer pool.releaseReader(&r2);
    try expectSyncCommit(&r1, "local");
    try expectSyncCommit(&r2, "local");
}

test "pg durability: stronger synchronous_commit levels are never changed and never warn" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var admin = (try adminOrSkip(a, io)) orelse return error.SkipZigTest;
    defer admin.close();
    const role = try roleName(a, "zb_sync_strong");
    defer a.free(role);
    conn.sync_commit_warning_for_test.reset();
    for ([_][]const u8{ "local", "on", "remote_write", "remote_apply" }) |level| {
        try createRole(a, &admin, role, level);
        defer dropRole(a, &admin, role);
        const url = try urlAs(a, role);
        defer a.free(url);
        var db = try pg.Db.open(a, io, url);
        defer db.close();
        try expectSyncCommit(&db, level);
    }
    try std.testing.expectEqual(@as(u32, 0), conn.sync_commit_warning_for_test.count());
}

test "pg durability: the override warning is logged once per process, not once per connect" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var admin = (try adminOrSkip(a, io)) orelse return error.SkipZigTest;
    defer admin.close();
    const role = try roleName(a, "zb_sync_off_warn");
    defer a.free(role);
    try createRole(a, &admin, role, "off");
    defer dropRole(a, &admin, role);
    const url = try urlAs(a, role);
    defer a.free(url);

    conn.sync_commit_warning_for_test.reset();
    // Five standalone connects, then a pool (writer + two concurrently held readers): eight
    // overridden sessions in all.
    for (0..5) |_| {
        var db = try pg.Db.open(a, io, url);
        defer db.close();
        try expectSyncCommit(&db, "local");
    }
    var pool = try pg.Pool.init(a, io, url);
    defer pool.deinit();
    var r1 = try pool.acquireReader();
    defer pool.releaseReader(&r1);
    var r2 = try pool.acquireReader();
    defer pool.releaseReader(&r2);
    try expectSyncCommit(&r2, "local");
    try std.testing.expectEqual(@as(u32, 1), conn.sync_commit_warning_for_test.count());
}
