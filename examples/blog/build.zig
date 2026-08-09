const std = @import("std");
const zigbase = @import("zigbase");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zb = b.dependency("zigbase", .{ .target = target, .optimize = optimize });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Adds the import AND sets link_libc, which zigbase requires.
    zigbase.addTo(zb, exe_mod);

    const exe = b.addExecutable(.{ .name = "blog", .root_module = exe_mod });
    b.installArtifact(exe);

    // In-process tests through the real pipeline. Reuses exe_mod on purpose:
    // a second module rooted at src/main.zig would put one file in two modules.
    const tests = zigbase.addTest(b, zb, .{ .root_module = exe_mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the blog example's in-process tests").dependOn(&run_tests.step);
}
