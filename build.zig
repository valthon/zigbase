const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Strip debug info from the shipped binaries in release builds. An unstripped
    // release build is ~24 MiB of mostly compressible debug_info; stripped it
    // is ~7 MiB — and the @zigbase/server npm packages ship the unpacked binary,
    // so this is a direct ~72% cut to install size. Debug builds keep symbols;
    // override with -Dstrip=false to keep them in a release build too.
    const strip = b.option(bool, "strip", "Strip debug info from shipped binaries (default: on except in Debug)") orelse (optimize != .Debug);

    const zap = b.dependency("zap", .{ .target = target, .optimize = optimize });

    // The public library module. Consumers `zig fetch` this and import "zigbase".
    const zigbase_mod = b.addModule("zigbase", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Build provenance for `zigbase --version`. The server version is single-sourced
    // from build.zig.zon; the commit is captured at configure time.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    build_options.addOption([]const u8, "commit", gitCommit(b));
    // Dev-only injectable clock (ZIGBASE_FAKE_NOW). Compiled in ONLY when this is true so
    // a production binary can never freeze time. Defaults to on in Debug, off in any
    // release/optimized build; the release script cross-compiles ReleaseFast/ReleaseSafe,
    // so shipped binaries get `false` and the override code folds to comptime-dead. Override
    // with -Ddev-clock=true to build a debuggable binary that still honors the env (e2e dev).
    const dev_clock = b.option(bool, "dev-clock", "Compile in the dev-only ZIGBASE_FAKE_NOW test clock (default: on in Debug, off in release)") orelse (optimize == .Debug);
    build_options.addOption(bool, "dev_clock", dev_clock);
    // Opt-in vector search (#157; Postgres pgvector port #159). OFF by default: the default build
    // does NOT compile or link the sqlite-vec amalgamation, and every vector code path folds to
    // comptime-dead — the shipped binary is byte-for-byte unaffected. `-Dvector=true` enables vector
    // KNN on BOTH backends from this ONE flag: it compiles vendor/sqlite-vec/sqlite-vec.c into the
    // SQLite build (below; db.zig registers the extension per connection), AND emits the Postgres
    // pgvector lowering (`?vector=` → `<=>`/`<->`; provision runs `CREATE EXTENSION vector`). pgvector
    // is a server EXTENSION (no C to compile here); the target PG must have it available (e.g. the
    // `pgvector/pgvector:pgNN` image). One flag keeps the opt-in symmetric across backends.
    const vector = b.option(bool, "vector", "Compile in opt-in vector search — sqlite-vec on SQLite, pgvector on Postgres (default: off)") orelse false;
    build_options.addOption(bool, "vector", vector);
    // Opt-in pure-Zig PostgreSQL backend (#159). OFF by default: when false, the entire
    // src/backend/postgres/ subtree is comptime-unreachable (gated in src/root.zig and, in
    // PR-1b, db.zig), so the default build links zero new symbols and is byte-identical.
    // The driver is pure Zig std (TLS via std.crypto.tls.Client, SCRAM via std.crypto) — no
    // C/libpq/OpenSSL to compile, so unlike -Dvector there is no extra C source to add here.
    const postgres = b.option(bool, "postgres", "Compile in the opt-in pure-Zig PostgreSQL wire-protocol backend (default: off)") orelse false;
    build_options.addOption(bool, "postgres", postgres);
    // Opt-in S3-compatible storage backend (SP3 Theme D §D). OFF by default: when false,
    // src/files/s3.zig is comptime-unreachable (conditional @import in framework.zig /
    // root.zig — the db.zig:27 postgres pattern), so the default build compiles zero S3
    // code. Pure Zig (the shared http_client + the aws/sigv4 signer, both of which the
    // default build already ships via SES) — no extra C sources.
    const s3 = b.option(bool, "s3", "Compile in the opt-in S3-compatible storage backend (default: off)") orelse false;
    build_options.addOption(bool, "s3", s3);
    zigbase_mod.addOptions("build_options", build_options);

    zigbase_mod.addIncludePath(b.path("vendor/sqlite"));
    zigbase_mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DQS=0",
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION=1",
            // Omit SQLite subsystems the framework provably never touches — db.zig uses
            // only the UTF-8 prepare/step/bind/column/exec surface. This trims the
            // amalgamation (smaller binary, ~10% faster C compile) with no behavior
            // change. NOT trimmed: FTS5 (kept above; a deliberate roadmap bet per
            // docs/ideas.md) and anything the query/provision layers rely on.
            "-DSQLITE_OMIT_UTF16", // no _text16/_prepare16/_column_text16 anywhere
            "-DSQLITE_OMIT_DECLTYPE", // we read sqlite3_column_type, never _column_decltype
            "-DSQLITE_OMIT_DEPRECATED", // no legacy APIs in use
            "-DSQLITE_OMIT_PROGRESS_CALLBACK", // no sqlite3_progress_handler
            "-DSQLITE_OMIT_TRACE", // no sqlite3_trace/profile
            "-DSQLITE_OMIT_SHARED_CACHE", // single-process reader pool + one writer; never shared-cache
            "-DSQLITE_DEFAULT_MEMSTATUS=0", // we never query sqlite3_memory_used/high_water
        },
    });
    // Opt-in vector search: compile the sqlite-vec amalgamation STATICALLY into the same module
    // (SQLITE_CORE => it includes our vendored sqlite3.h and links against the in-tree SQLite;
    // SQLITE_VEC_STATIC => no dllexport shims). Only when -Dvector=true, so the default build is
    // untouched. db.zig calls sqlite3_vec_init on each connection (gated on build_options.vector).
    if (vector) {
        zigbase_mod.addIncludePath(b.path("vendor/sqlite-vec"));
        zigbase_mod.addCSourceFile(.{
            .file = b.path("vendor/sqlite-vec/sqlite-vec.c"),
            .flags = &.{ "-DSQLITE_CORE", "-DSQLITE_VEC_STATIC" },
        });
    }
    zigbase_mod.addImport("zap", zap.module("zap"));

    // The shipped binary: a thin consumer of the library module.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
    });
    exe_mod.addImport("zigbase", zigbase_mod);

    const exe = b.addExecutable(.{ .name = "zigbase", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zigbase");
    run_step.dependOn(&run_cmd.step);

    // --- dating-server: the dating fixture compiled as a runnable server ----------
    // Plan 2: the e2e harness spawns THIS binary so client and server share the exact
    // comptime schema the dating client was generated from. Links libc (facil.io C deps).
    const dating_srv_mod = b.createModule(.{
        .root_source_file = b.path("fixtures/dating/schema.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dating_srv_mod.addImport("zigbase", zigbase_mod);
    const dating_srv_exe = b.addExecutable(.{ .name = "dating-server", .root_module = dating_srv_mod });
    const dating_srv_step = b.step("dating-server", "Build the dating fixture as a runnable server");
    dating_srv_step.dependOn(&b.addInstallArtifact(dating_srv_exe, .{}).step);

    // --- auth2-server: the auth-round-2 e2e fixture as a runnable server ----------
    // Table-mode sessions + a registered beforeAuthSuccess hook, so the browser suite
    // can drive the legacy login paths (including _superusers) and per-device session
    // REST against a real server. Links libc (facil.io C deps).
    const auth2_srv_mod = b.createModule(.{
        .root_source_file = b.path("fixtures/auth2/schema.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    auth2_srv_mod.addImport("zigbase", zigbase_mod);
    const auth2_srv_exe = b.addExecutable(.{ .name = "auth2-server", .root_module = auth2_srv_mod });
    const auth2_srv_step = b.step("auth2-server", "Build the auth-round-2 e2e fixture server (table sessions + beforeAuthSuccess)");
    auth2_srv_step.dependOn(&b.addInstallArtifact(auth2_srv_exe, .{}).step);

    // --- features-fixture: demo flags/experiments server for the browser suite ---
    const features_fix_mod = b.createModule(.{
        .root_source_file = b.path("fixtures/features/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    features_fix_mod.addImport("zigbase", zigbase_mod);
    const features_fix_exe = b.addExecutable(.{ .name = "features-fixture", .root_module = features_fix_mod });
    const features_fix_step = b.step("features-fixture", "Build the demo-features fixture server (browser tests)");
    features_fix_step.dependOn(&b.addInstallArtifact(features_fix_exe, .{}).step);

    // --- minimal-server: gating-invariant fixture (R2-7) --------------------------
    // A consumer App with NOTHING optional configured. scripts/check-gating.sh nm-scans
    // this binary to prove deselected subsystems (webauthn/magic_link/oauth2, analytics,
    // senders, mail webhook, webhook/mail job kinds, admin SPA) leave zero symbols. Debug
    // (the default optimize) keeps `strip` off (see the `strip` option above), so a plain
    // `zig build minimal-server` is unstripped — no extra flag needed.
    const minimal_mod = b.createModule(.{
        .root_source_file = b.path("fixtures/minimal/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    minimal_mod.addImport("zigbase", zigbase_mod);
    const minimal_exe = b.addExecutable(.{ .name = "minimal-server", .root_module = minimal_mod });
    const minimal_step = b.step("minimal-server", "Build the lean gating-invariant fixture (Debug, unstripped)");
    minimal_step.dependOn(&b.addInstallArtifact(minimal_exe, .{}).step);

    // --- full-fixture: gating-invariant POSITIVE control (R2-7) -------------------
    // The stock `zigbase` binary above doesn't configure .mail/.webhooks/.analytics,
    // so scripts/check-gating.sh needs a binary that does, to prove those patterns
    // aren't just drifted/vacuous. See fixtures/full/main.zig for the full rationale.
    const full_fix_mod = b.createModule(.{
        .root_source_file = b.path("fixtures/full/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    full_fix_mod.addImport("zigbase", zigbase_mod);
    const full_fix_exe = b.addExecutable(.{ .name = "full-fixture", .root_module = full_fix_mod });
    const full_fix_step = b.step("full-fixture", "Build the gating-invariant positive-control fixture (Debug, unstripped)");
    full_fix_step.dependOn(&b.addInstallArtifact(full_fix_exe, .{}).step);

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

    // The generator itself needs no libc: mainWithCollections reads env via
    // init.environ_map (pure-Zig). It still links libc transitively through
    // zigbase_mod (facil.io C deps), so we don't set link_libc here.
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

    // --- runtime-introspection golden: provision the dating app in-memory, read
    // it back via the data-dir adapter, and generate. Needs libc/sqlite (provision).
    const gen_rt_mod = b.createModule(.{
        .root_source_file = b.path("src/codegen/gen_runtime_main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    });
    gen_rt_mod.addImport("zigbase", zigbase_mod);
    gen_rt_mod.addImport("app", dating_app_mod);
    const gen_rt_exe = b.addExecutable(.{ .name = "zbase-gen-runtime-client", .root_module = gen_rt_mod });

    const rt_out = "clients/typescript/test/codegen/dating/zbase.runtime.gen.ts";
    const gen_rt_run = b.addRunArtifact(gen_rt_exe);
    gen_rt_run.setEnvironmentVariable("ZBASE_INREPO", "1");
    gen_rt_run.addArgs(&.{ "--out", rt_out, "--api-prefix", "/api" });
    const gen_rt_step = b.step("gen-dating-runtime-client", "Generate the dating runtime-introspection client golden");
    gen_rt_step.dependOn(&gen_rt_run.step);

    const rt_check_run = b.addRunArtifact(gen_rt_exe);
    rt_check_run.setEnvironmentVariable("ZBASE_INREPO", "1");
    rt_check_run.addArgs(&.{ "--out", rt_out, "--api-prefix", "/api", "--check" });
    const rt_check_step = b.step("gen-dating-runtime-client-check", "Fail if the dating runtime client golden is stale");
    rt_check_step.dependOn(&rt_check_run.step);

    // --- gen-test: golden snapshot byte-exact test (Task 8) -------------------
    // Builds gen_test_root.zig as a test binary with both zigbase_mod (for
    // gen_client.generate) and dating_app_mod (for App.collections) injected.
    // gen_test_root.zig is the module root — it does NOT share files with zigbase_mod,
    // avoiding the Zig 0.16 "file in two modules" constraint.
    // NOTE: this step re-runs generate() to compare against the committed snapshot.
    // Run `zig build gen-dating-client` first if the snapshot does not yet exist.
    const gen_test_mod = b.createModule(.{
        .root_source_file = b.path("src/codegen/gen_test_root.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    gen_test_mod.addImport("zigbase", zigbase_mod);
    gen_test_mod.addImport("app", dating_app_mod);
    const gen_test_exe = b.addTest(.{ .root_module = gen_test_mod });
    const run_gen_test = b.addRunArtifact(gen_test_exe);
    const gen_test_step = b.step("gen-test", "Run the golden byte-exact snapshot test for the dating client");
    gen_test_step.dependOn(&run_gen_test.step);
    // Wire into the main test_step so `zig build test` also runs the golden assertion.
    test_step.dependOn(&run_gen_test.step);
}

/// Capture the short git commit at configure time; "unknown" outside a repo.
fn gitCommit(b: *std.Build) []const u8 {
    const root = b.build_root.path orelse ".";
    var code: u8 = undefined;
    const stdout = b.runAllowFail(&.{ "git", "-C", root, "rev-parse", "--short", "HEAD" }, &code, .ignore) catch return "unknown";
    if (code != 0) return "unknown";
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    return if (trimmed.len == 0) "unknown" else trimmed;
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
    // The generator itself needs no libc: mainWithCollections reads env via
    // init.environ_map (pure-Zig). It still links libc transitively through
    // zigbase_mod (facil.io C deps), so we don't set link_libc here.
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
