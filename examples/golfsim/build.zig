const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const zigbase = b.dependency("zigbase", .{ .target = target, .optimize = optimize });
    exe_mod.addImport("zigbase", zigbase.module("zigbase"));

    const exe = b.addExecutable(.{ .name = "golfsim", .root_module = exe_mod });
    b.installArtifact(exe);
}
