const std = @import("std");
const zigbase = @import("zigbase");

/// Demo feature flags + an A/B experiment, moved OUT of the release binary
/// (they were Playwright fixtures riding in production). Built as
/// `zig build features-fixture` and driven by tests/admin/test_features.py.
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
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
