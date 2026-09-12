//! Cooperative permanent sidecar locks. Never unlink or replace the lock inode.
const std = @import("std");

/// Caller owns the returned file and closes it to release the lease. The opened
/// directory identifies the root; name is a caller-selected sidecar filename.
/// Existing files are never truncated, and lock-file symlinks are refused.
pub fn acquirePermanent(io: std.Io, dir: std.Io.Dir, name: []const u8, exclusive: bool) !std.Io.File {
    return openExisting(io, dir, name, exclusive) catch |err| switch (err) {
        error.FileNotFound => create(io, dir, name, exclusive),
        else => err,
    };
}

fn openExisting(io: std.Io, dir: std.Io.Dir, name: []const u8, exclusive: bool) !std.Io.File {
    return dir.openFile(io, name, .{
        // Shared flock needs only read access. Exclusive flock emulated with
        // fcntl (e.g. Linux NFS) requires write access.
        .mode = if (exclusive) .read_write else .read_only,
        .follow_symlinks = false,
        .lock = if (exclusive) .exclusive else .shared,
        .lock_nonblocking = true,
    });
}

fn create(io: std.Io, dir: std.Io.Dir, name: []const u8, exclusive: bool) !std.Io.File {
    // Only race the first creator when the name is absent. If another creator
    // wins, reopen its permanent inode rather than replacing it.
    return dir.createFile(io, name, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .lock = if (exclusive) .exclusive else .shared,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => openExisting(io, dir, name, exclusive),
        else => err,
    };
}

test "shared leases exclude an exclusive lease until every holder exits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try acquirePermanent(std.testing.io, tmp.dir, "test.lock", false);
    const second = try acquirePermanent(std.testing.io, tmp.dir, "test.lock", false);
    try std.testing.expectError(error.WouldBlock, acquirePermanent(std.testing.io, tmp.dir, "test.lock", true));
    first.close(std.testing.io);
    try std.testing.expectError(error.WouldBlock, acquirePermanent(std.testing.io, tmp.dir, "test.lock", true));
    second.close(std.testing.io);
    const apply = try acquirePermanent(std.testing.io, tmp.dir, "test.lock", true);
    defer apply.close(std.testing.io);
    try std.testing.expectError(error.WouldBlock, acquirePermanent(std.testing.io, tmp.dir, "test.lock", false));
}

test "permanent sidecar refuses a symlink lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target", .data = "keep" });
    try tmp.dir.symLink(std.testing.io, "target", "test.lock", .{});
    try std.testing.expectError(error.SymLinkLoop, acquirePermanent(std.testing.io, tmp.dir, "test.lock", true));
}
