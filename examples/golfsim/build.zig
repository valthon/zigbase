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
    });
    // Adds the import AND sets link_libc, which zigbase requires.
    zigbase_build.addTo(zigbase, exe_mod);

    const exe = b.addExecutable(.{ .name = "golfsim", .root_module = exe_mod });
    b.installArtifact(exe);

    // In-process tests through the real pipeline. Reuses exe_mod on purpose:
    // a second module rooted at src/main.zig would put one file in two modules.
    const tests = zigbase_build.addTest(b, zigbase, .{ .root_module = exe_mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the golfsim example's in-process tests").dependOn(&run_tests.step);

    // --- codegen: golfsim's typed client (Plan 2) ---
    // app_mod's root is the same main.zig that defines `pub const App` at module scope. A
    // separate module object is safe here because gen_exe (below) is its own Step.Compile,
    // disjoint from `exe`/`tests` above -- not the same "test artifact reuse" hazard.
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
