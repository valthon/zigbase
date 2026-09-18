const std = @import("std");

pub fn build(b: *std.Build) void {
    const Case = enum { newline, meaningful, assertion, signal, leak, error_log, skip };
    const case = b.option(Case, "case", "Exit-time diagnostic regression") orelse .newline;
    const simple = b.option(bool, "simple", "Use the shipped ZigBase runner") orelse false;
    const mod = b.createModule(.{
        .root_source_file = b.path("test.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = .Debug,
        .link_libc = true,
    });
    const options = b.addOptions();
    options.addOption(Case, "case", case);
    mod.addOptions("repro_options", options);
    mod.addCSourceFile(.{ .file = b.path("newline_destructor.c"), .flags = switch (case) {
        .meaningful => &.{"-DREPRO_MEANINGFUL"},
        .signal => &.{"-DREPRO_SIGNAL"},
        else => &.{},
    } });

    const tests = b.addTest(.{
        .root_module = mod,
        .test_runner = if (simple) .{ .path = b.path("simple_runner.zig"), .mode = .simple } else null,
    });
    b.step("test", "Reproduce misleading diagnostics from successful test stderr").dependOn(&b.addRunArtifact(tests).step);
}
