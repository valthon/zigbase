const std = @import("std");
const zigbase = @import("zigbase");

/// The gating-invariant probe (audit: gating-consistency §4): a consumer-shaped
/// build with NOTHING optional configured. scripts/check-gating.sh asserts that
/// deselected subsystems leave no symbols in this binary. Update the App literal
/// when config keys move (e.g. the .auth grouping) — the script is the guard.
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .admin = .disabled,
        .auth_methods = .{ .builtins = .{ .password } },
    }).runCli(init);
}
