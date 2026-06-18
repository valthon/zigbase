const std = @import("std");
const zigbase = @import("zigbase");

/// The OFFICIAL distributed binary: the framework with the `typegen` subcommand
/// compiled in (comptime `enable_typegen = true`). The default `zigbase`
/// (src/main.zig) keeps it off so production server builds carry no codegen;
/// this target is what the @zigbase/server npm packages ship.
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{ .enable_typegen = true }).runCli(init);
}
