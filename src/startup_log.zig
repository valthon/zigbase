const std = @import("std");

/// Expected startup rejection paths retain their diagnostic under the test
/// runner, whose error counter otherwise treats the expected refusal as failure.
pub fn refusal(comptime fmt: []const u8, args: anytype) void {
    if (@import("builtin").is_test) std.log.warn(fmt, args) else std.log.err(fmt, args);
}
