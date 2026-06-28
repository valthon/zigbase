const std = @import("std");
const zigbase = @import("zigbase");

/// The shipped binary: the framework with the `typegen` subcommand compiled in.
/// One binary serves both the GitHub release tarballs and the @zigbase/server
/// npm packages. `enable_typegen` stays a framework option for embedders who
/// want it off.
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .enable_typegen = true,
        // Sample declared flags + experiments shipped with the standalone binary.
        // They demonstrate the feature-management admin UI and serve as fixtures for the
        // browser test suite (tests/admin/test_features.py).
        .flags = .{
            .dark_mode = false,
            .maintenance = .{ .default = false, .description = "Enable maintenance mode" },
        },
        .experiments = .{
            .onboarding_flow = .{
                .variants = .{ "control", "streamlined" },
                .weights = .{ 70, 30 },
                .description = "Onboarding flow A/B test",
            },
        },
    }).runCli(init);
}
