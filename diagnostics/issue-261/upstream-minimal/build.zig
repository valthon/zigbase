const std = @import("std");

pub fn build(b: *std.Build) void {
    const Case = enum { newline, meaningful, assertion, signal };
    const case = b.option(Case, "case", "Exit-time diagnostic regression") orelse .newline;
    const mod = b.createModule(.{
        .root_source_file = b.path("test.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    });
    const options = b.addOptions();
    options.addOption(bool, "fail_test", case == .assertion);
    mod.addOptions("repro_options", options);
    mod.addCSourceFile(.{ .file = b.path("newline_destructor.c"), .flags = switch (case) {
        .meaningful => &.{"-DREPRO_MEANINGFUL"},
        .signal => &.{"-DREPRO_SIGNAL"},
        else => &.{},
    } });

    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Reproduce misleading diagnostics from successful test stderr").dependOn(&b.addRunArtifact(tests).step);
}
