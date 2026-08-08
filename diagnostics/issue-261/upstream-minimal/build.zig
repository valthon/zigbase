const std = @import("std");

pub fn build(b: *std.Build) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("test.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    });
    mod.addCSourceFile(.{ .file = b.path("newline_destructor.c") });

    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Reproduce misleading diagnostics from successful test stderr").dependOn(&b.addRunArtifact(tests).step);
}
