const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/repro.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const zigbase = b.dependency("zigbase", .{ .target = target, .optimize = optimize });
    mod.addImport("zigbase", zigbase.module("zigbase"));

    const tests = b.addTest(.{ .root_module = mod });
    const run = b.addRunArtifact(tests);
    b.step("test", "Run the issue 261 reproduction through Zig's server-mode runner").dependOn(&run.step);

    const install = b.addInstallArtifact(tests, .{});
    b.step("install-test", "Install the exact test binary for standalone/protocol diagnostics").dependOn(&install.step);

    const control_mod = b.createModule(.{
        .root_source_file = b.path("src/no_boot_control.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    control_mod.addImport("zigbase", zigbase.module("zigbase"));
    const control_tests = b.addTest(.{ .root_module = control_mod });
    b.step("control", "Run a linked zigbase test that does not boot the harness").dependOn(&b.addRunArtifact(control_tests).step);
}
