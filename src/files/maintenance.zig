//! Cooperative local-storage quiescence. Never unlink this permanent lock file:
//! replacing its inode would let two owners hold independent locks.
const std = @import("std");
pub const lock_name = ".zigbase-maintenance.lock";

/// Caller owns the returned file and closes it to release the lease. The
/// opened directory identifies the actual storage root, including root aliases.
/// Descendant lock symlinks are refused, never followed or truncated.
pub fn acquire(io: std.Io, root: std.Io.Dir, exclusive: bool) !std.Io.File {
    return @import("../fslock.zig").acquirePermanent(io, root, lock_name, exclusive);
}
