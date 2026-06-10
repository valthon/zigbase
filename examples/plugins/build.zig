const std = @import("std");
const zigbase_build = @import("zigbase");

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

    // Embed the built Astro frontend into the binary (fails with a clear message
    // if frontend/dist is missing — run `npm run build` in frontend/ first).
    const assets = zigbase_build.embedStaticDir(b, "frontend/dist");
    exe_mod.addImport("static_assets", assets);

    const exe = b.addExecutable(.{ .name = "plugins", .root_module = exe_mod });
    b.installArtifact(exe);
}
