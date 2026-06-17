const std = @import("std");
const zigbase_build = @import("zigbase");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigbase = b.dependency("zigbase", .{ .target = target, .optimize = optimize });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("zigbase", zigbase.module("zigbase"));
    const exe = b.addExecutable(.{ .name = "golfsim", .root_module = exe_mod });
    b.installArtifact(exe);

    // --- codegen: golfsim's typed client (Plan 2) ---
    // app_mod's root is the same main.zig that defines `pub const App` at module scope.
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_mod.addImport("zigbase", zigbase.module("zigbase"));

    const out = "clients/typescript/zbase.gen.ts";
    const gen = zigbase_build.genClientStep(b, zigbase, app_mod, .{ .out = out, .api_prefix = "/api" });
    b.step("gen-client", "Generate the golfsim typed TS client").dependOn(&gen.step);

    const check = zigbase_build.genClientStep(b, zigbase, app_mod, .{ .out = out, .api_prefix = "/api", .check = true });
    b.step("gen-client-check", "Fail if the golfsim client snapshot is stale").dependOn(&check.step);
}
