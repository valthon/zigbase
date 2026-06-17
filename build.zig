const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zap = b.dependency("zap", .{ .target = target, .optimize = optimize });

    // The public library module. Consumers `zig fetch` this and import "zigbase".
    const zigbase_mod = b.addModule("zigbase", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zigbase_mod.addIncludePath(b.path("vendor/sqlite"));
    zigbase_mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DQS=0",
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION=1",
        },
    });
    zigbase_mod.addImport("zap", zap.module("zap"));

    // The shipped binary: a thin consumer of the library module.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("zigbase", zigbase_mod);

    const exe = b.addExecutable(.{ .name = "zigbase", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zigbase");
    run_step.dependOn(&run_cmd.step);

    // Unit tests run against the library module (where all internal test{} live).
    const tests = b.addTest(.{ .root_module = zigbase_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);

    // --- codegen: generate the dating fixture's typed client -------------------
    // This is the Plan-1 Definition of Done for Task 7. Uses b.path(...) directly
    // (no b.dependency) since the dating fixture lives in this repo.
    const dating_app_mod = b.createModule(.{
        .root_source_file = b.path("fixtures/dating/schema.zig"),
        .target = target,
        .optimize = optimize,
    });
    dating_app_mod.addImport("zigbase", zigbase_mod);

    // B1: exe must link_libc because mainWithCollections uses std.c.getenv.
    // In Zig 0.16, link_libc is set on the module, not via exe.linkLibC().
    //
    // Module design (Zig 0.16 "file in one module" constraint):
    // gen_client.zig uses relative @imports (../schema.zig, emit.zig, etc.) which
    // claim those files for whichever module it belongs to. Since zigbase_mod already
    // owns those files, gen_client.zig cannot be the exe module root when zigbase is
    // in scope. Instead we use gen_main.zig as the root — it imports "zigbase" and
    // "app" as named modules, delegating to zigbase.codegen.gen_client.mainWithCollections.
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("src/codegen/gen_main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    });
    gen_mod.addImport("zigbase", zigbase_mod);
    gen_mod.addImport("app", dating_app_mod);
    const gen_exe = b.addExecutable(.{ .name = "zbase-gen-client", .root_module = gen_mod });

    const gen_run = b.addRunArtifact(gen_exe);
    gen_run.setEnvironmentVariable("ZBASE_INREPO", "1");
    gen_run.addArgs(&.{ "--out", "clients/typescript/test/codegen/dating/zbase.gen.ts", "--api-prefix", "/api" });
    const gen_step = b.step("gen-dating-client", "Generate the dating fixture's typed TS client");
    gen_step.dependOn(&gen_run.step);

    // staleness guard: same exe with --check
    const check_run = b.addRunArtifact(gen_exe);
    check_run.setEnvironmentVariable("ZBASE_INREPO", "1");
    check_run.addArgs(&.{ "--out", "clients/typescript/test/codegen/dating/zbase.gen.ts", "--api-prefix", "/api", "--check" });
    const check_step = b.step("gen-dating-client-check", "Fail if the dating client snapshot is stale");
    check_step.dependOn(&check_run.step);
}

// ---------------------------------------------------------------------------
// Codegen helpers
// ---------------------------------------------------------------------------

pub const GenOpts = struct {
    out: []const u8,
    api_prefix: []const u8 = "/api",
    check: bool = false,
    in_repo: bool = false,
};

/// Build the pure-Zig client generator with `app_mod` (a module exposing
/// `pub const App = zigbase.App(.{...})`) + zigbase imported, and return the Run
/// step that emits `opts.out`. Consumers wire `zig build gen-client` to this.
/// NOTE (I5): the `zigbase_dep.builder.path(...)` resolution for external consumers
/// is Plan-2 / unverified. Plan 1's DoD is on the repo-local gen-dating-client step.
pub fn genClientStep(
    b: *std.Build,
    zigbase_dep: *std.Build.Dependency,
    app_mod: *std.Build.Module,
    opts: GenOpts,
) *std.Build.Step.Run {
    const zigbase_mod = zigbase_dep.module("zigbase");
    // Plan-2: verify dependency source resolution — zigbase_dep.builder.path(...)
    // resolves the generator source from the dependency's own source tree.
    return genClientStepInner(b, zigbase_mod, zigbase_dep.builder, app_mod, opts);
}

fn genClientStepInner(
    b: *std.Build,
    zigbase_mod: *std.Build.Module,
    zigbase_builder: *std.Build,
    app_mod: *std.Build.Module,
    opts: GenOpts,
) *std.Build.Step.Run {
    // B1: exe must link_libc because mainWithCollections uses std.c.getenv.
    // In Zig 0.16, link_libc is set on the module, not via exe.linkLibC().
    //
    // Module design (Zig 0.16 "file in one module" constraint):
    // gen_client.zig uses relative @imports (../schema.zig, emit.zig, etc.) which
    // claim those files for whichever module it belongs to. Since zigbase_mod already
    // owns those files, gen_client.zig cannot be the exe module root when zigbase is
    // in scope. Instead we use gen_main.zig as the root — it imports "zigbase" and
    // "app" as named modules, delegating to zigbase.codegen.gen_client.mainWithCollections.
    // Plan-2 / unverified for external consumers — see I5 note above.
    const gen_mod = b.createModule(.{
        .root_source_file = zigbase_builder.path("src/codegen/gen_main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    });
    gen_mod.addImport("zigbase", zigbase_mod);
    gen_mod.addImport("app", app_mod);

    const gen_exe = b.addExecutable(.{ .name = "zbase-gen-client", .root_module = gen_mod });
    const run = b.addRunArtifact(gen_exe);
    run.addArg("--out");
    run.addArg(opts.out);
    run.addArg("--api-prefix");
    run.addArg(opts.api_prefix);
    if (opts.check) run.addArg("--check");
    if (opts.in_repo) run.setEnvironmentVariable("ZBASE_INREPO", "1");
    return run;
}

/// Embed every file under `dir_rel` (relative to the consumer's build root) into
/// the binary as a static-asset manifest module. Wire it up like:
///
///     const zigbase_build = @import("zigbase");                  // dep's build.zig
///     const assets = zigbase_build.embedStaticDir(b, "frontend/dist");
///     exe_mod.addImport("static_assets", assets);
///
/// and in main.zig:
///
///     .static_files = .{ .embedded = &@import("static_assets").files }
///
/// The generated module declares `pub const files = [_]StaticFile{...}` with one
/// `@embedFile` per asset and a precomputed CRC32 content ETag.
pub fn embedStaticDir(b: *std.Build, dir_rel: []const u8) *std.Build.Module {
    const alloc = b.allocator;
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, dir_rel, .{ .iterate = true }) catch
        std.debug.panic("embedStaticDir: cannot open '{s}' — build the frontend first (e.g. `cd {s}/.. && npm install && npm run build`)", .{ dir_rel, dir_rel });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var walker = dir.walk(alloc) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch |e| std.debug.panic("embedStaticDir: walk failed: {s}", .{@errorName(e)})) |entry| {
        if (entry.kind != .file) continue;
        const path = alloc.dupe(u8, entry.path) catch @panic("OOM");
        // walk() joins with the native separator; manifest paths must be
        // '/'-separated to match HTTP request paths (matters on Windows; a
        // no-op on POSIX given the no-backslash filename assumption below).
        std.mem.replaceScalar(u8, path, '\\', '/');
        names.append(alloc, path) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    const wf = b.addWriteFiles();
    var src: std.ArrayList(u8) = .empty;
    src.appendSlice(alloc,
        \\//! Generated by zigbase's embedStaticDir — do not edit.
        \\pub const StaticFile = struct { path: []const u8, bytes: []const u8, etag: []const u8 };
        \\pub const files = [_]StaticFile{
        \\
    ) catch @panic("OOM");
    for (names.items) |rel| {
        _ = wf.addCopyFile(b.path(b.fmt("{s}/{s}", .{ dir_rel, rel })), rel);
        // no size limit: runs at build time on the developer's machine, not in the server
        const data = dir.readFileAlloc(io, rel, alloc, .unlimited) catch |e|
            std.debug.panic("embedStaticDir: cannot read '{s}/{s}': {s}", .{ dir_rel, rel, @errorName(e) });
        defer alloc.free(data);
        const crc = std.hash.Crc32.hash(data);
        // Assumes asset filenames are ASCII without '"' or '\' — true for Vite/Astro hashed output.
        src.appendSlice(alloc, b.fmt(
            "    .{{ .path = \"{s}\", .bytes = @embedFile(\"{s}\"), .etag = \"\\\"{x:0>8}\\\"\" }},\n",
            .{ rel, rel, crc },
        )) catch @panic("OOM");
    }
    src.appendSlice(alloc, "};\n") catch @panic("OOM");
    const manifest = wf.add("static_assets.zig", src.items);
    return b.createModule(.{ .root_source_file = manifest });
}
