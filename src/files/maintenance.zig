//! Cooperative local-storage quiescence. Never unlink this permanent lock file:
//! replacing its inode would let two owners hold independent locks.
const std = @import("std");
pub const lock_name = ".zigbase-maintenance.lock";

/// Caller owns the returned file and closes it to release the lease. The
/// opened directory identifies the actual storage root, including root aliases.
/// Descendant lock symlinks are refused, never followed or truncated.
pub fn acquire(io: std.Io, root: std.Io.Dir, exclusive: bool) !std.Io.File {
    // Existing leases need no directory write permission. Never recreate an
    // existing inode; only race the first creator when the name is absent.
    return openExisting(io, root, exclusive) catch |err| switch (err) {
        error.FileNotFound => create(io, root, exclusive),
        else => err,
    };
}

fn openExisting(io: std.Io, root: std.Io.Dir, exclusive: bool) !std.Io.File {
    return root.openFile(io, lock_name, .{
        // Shared flock needs only read access. Retain write access for apply:
        // exclusive flock emulated with fcntl (e.g. Linux NFS) requires it.
        .mode = if (exclusive) .read_write else .read_only,
        .follow_symlinks = false,
        .lock = if (exclusive) .exclusive else .shared,
        .lock_nonblocking = true,
    });
}

fn create(io: std.Io, root: std.Io.Dir, exclusive: bool) !std.Io.File {
    const options = .{ .lock = if (exclusive) std.Io.File.Lock.exclusive else .shared, .lock_nonblocking = true };
    return root.createFile(io, lock_name, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .lock = options.lock,
        .lock_nonblocking = options.lock_nonblocking,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => openExisting(io, root, exclusive),
        else => err,
    };
}

test "shared app leases exclude maintenance until every app exits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try acquire(std.testing.io, tmp.dir, false);
    const second = try acquire(std.testing.io, tmp.dir, false);
    try std.testing.expectError(error.WouldBlock, acquire(std.testing.io, tmp.dir, true));
    first.close(std.testing.io);
    try std.testing.expectError(error.WouldBlock, acquire(std.testing.io, tmp.dir, true));
    second.close(std.testing.io);
    const apply = try acquire(std.testing.io, tmp.dir, true);
    defer apply.close(std.testing.io);
    try std.testing.expectError(error.WouldBlock, acquire(std.testing.io, tmp.dir, false));
}

test "maintenance refuses a symlink lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target", .data = "keep" });
    try tmp.dir.symLink(std.testing.io, "target", lock_name, .{});
    try std.testing.expectError(error.SymLinkLoop, acquire(std.testing.io, tmp.dir, true));
}
