const std = @import("std");
const zigbase = @import("zigbase");

/// The shipped binary: the framework with the `typegen` subcommand compiled in.
/// One binary serves both the GitHub release tarballs and the @zigbase/server
/// npm packages. `enable_typegen` stays a framework option for embedders who
/// want it off. Demo flags/experiments live in fixtures/features (test-only).
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{ .enable_typegen = true }).runCli(init);
}
