const std = @import("std");

const BuildOptionValues = struct {
    version: []const u8,
    min_zig_version: []const u8,
    commit: []const u8,
    dev_mode: bool,
    dev_tools: bool,
    internal_api: bool,
    vector: bool,
    postgres: bool,
    s3: bool,
    fts5: bool,
    sqlite_version: []const u8,
    sqlite_source_id: []const u8,
    sqlite_vec_version: []const u8,
    zap_version: []const u8,
    zap_commit: []const u8,
    facil_version: []const u8,
};

fn createBuildOptions(b: *std.Build, values: BuildOptionValues) *std.Build.Step.Options {
    const options = b.addOptions();
    inline for (@typeInfo(BuildOptionValues).@"struct".fields) |field| {
        options.addOption(field.type, field.name, @field(values, field.name));
    }
    return options;
}

fn configureZigbaseModule(
    b: *std.Build,
    module: *std.Build.Module,
    build_options: *std.Build.Step.Options,
    zap_module: *std.Build.Module,
    sqlite_flags: []const []const u8,
    vector: bool,
) void {
    module.addOptions("build_options", build_options);
    module.addIncludePath(b.path("vendor/sqlite"));
    module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = sqlite_flags,
    });
    if (vector) {
        module.addIncludePath(b.path("vendor/sqlite-vec"));
        module.addCSourceFile(.{
            .file = b.path("vendor/sqlite-vec/sqlite-vec.c"),
            .flags = &.{ "-DSQLITE_CORE", "-DSQLITE_VEC_STATIC" },
        });
    }
    module.addImport("zap", zap_module);
}

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
    // from build.zig.zon; the commit is captured at configure time. `-Dcommit=<sha>` lets
    // CI/release inject a deterministic SHA (used verbatim); otherwise `gitCommit` tries
    // `git rev-parse` and, if that's unavailable (sandboxed configure step, no git on PATH),
    // falls back to a spawn-free parse of `.git` (worktree-aware) before giving up.
    const commit_override = b.option([]const u8, "commit", "Commit SHA to bake into --version (CI/release inject the real SHA; default: auto-detect from git)");
    const commit = commit_override orelse gitCommit(b);
    // Single-source the required Zig version so the compile-time guard in
    // src/zig_compat.zig can reject an unsupported compiler with a clear message.
    // Dev-only seams (injectable clock, seeded entropy, test-capture, fake field-crypto).
    // Compiled in ONLY when this is true so a production binary can never use any of them.
    // Defaults to on in Debug, off in any release/optimized build; the release script
    // cross-compiles ReleaseFast/ReleaseSafe, so shipped binaries get `false` and the
    // override code folds to comptime-dead. Override with -Ddev-mode=true to build a
    // debuggable binary that still honors the dev-only env vars (e2e dev).
    const dev_mode = b.option(bool, "dev-mode", "Compile in the dev-only, never-in-prod seams: ZIGBASE_FAKE_NOW clock, ZIGBASE_FAKE_SEED entropy, test-capture, and ZIGBASE_FIELD_CRYPTO fake crypto (default: on in Debug, off in release)") orelse (optimize == .Debug);
    // Development-time CLI verbs: `init`, `agents-md`, `typegen`. ON by default — every
    // official artifact we publish (GitHub release tarballs, the Docker image, the
    // @zigbase/server npm packages) builds at this default and ships all three.
    // `-Ddev-tools=false` is an OPT-OUT offered to a consumer
    // compiling their OWN binary for their OWN deployment: none of the three verbs has
    // operational or runtime value on a deployed server (they're pure scaffolding + codegen),
    // so a custom build that never needs them can shed src/scaffold*.zig and src/codegen/**
    // (~24 files — typegen alone is the largest dev-only surface in the binary) by comptime-
    // eliding the whole subtree (see src/devtools.zig). A stripped binary still parses the
    // verb names, but returns an actionable "rebuild with -Ddev-tools=true" error instead of
    // a bare UnknownCommand.
    const dev_tools = b.option(bool, "dev-tools", "Compile in the development-time CLI verbs: init, agents-md, typegen (default: on; -Ddev-tools=false strips them from a custom build)") orelse true;
    // Opt-in vector search (#157; Postgres pgvector port #159). OFF by default: the default build
    // does NOT compile or link the sqlite-vec amalgamation, and every vector code path folds to
    // comptime-dead — the shipped binary is byte-for-byte unaffected. `-Dvector=true` enables vector
    // KNN on BOTH backends from this ONE flag: it compiles vendor/sqlite-vec/sqlite-vec.c into the
    // SQLite build (below; db.zig registers the extension per connection), AND emits the Postgres
    // pgvector lowering (`?vector=` → `<=>`/`<->`; provision runs `CREATE EXTENSION vector`). pgvector
    // is a server EXTENSION (no C to compile here); the target PG must have it available (e.g. the
    // `pgvector/pgvector:pgNN` image). One flag keeps the opt-in symmetric across backends.
    const vector = b.option(bool, "vector", "Compile in opt-in vector search — sqlite-vec on SQLite, pgvector on Postgres (default: off)") orelse false;
    // Opt-in pure-Zig PostgreSQL backend (#159). OFF by default: when false, the entire
    // src/backend/postgres/ subtree is comptime-unreachable (gated in src/root.zig and, in
    // PR-1b, db.zig), so the default build links zero new symbols and is byte-identical.
    // The driver is pure Zig std (TLS via std.crypto.tls.Client, SCRAM via std.crypto) — no
    // C/libpq/OpenSSL to compile, so unlike -Dvector there is no extra C source to add here.
    const postgres = b.option(bool, "postgres", "Compile in the opt-in pure-Zig PostgreSQL wire-protocol backend (default: off)") orelse false;
    // Opt-in S3-compatible storage backend (SP3 Theme D §D). OFF by default: when false,
    // src/files/s3.zig is comptime-unreachable (conditional @import in framework.zig /
    // root.zig — the db.zig:27 postgres pattern), so the default build compiles zero S3
    // code. Pure Zig (the shared http_client + the aws/sigv4 signer, both of which the
    // default build already ships via SES) — no extra C sources.
    const s3 = b.option(bool, "s3", "Compile in the opt-in S3-compatible storage backend (default: off)") orelse false;
    // SQLite FTS5 full-text search (#157). ON by default — it's a core feature, not an
    // experiment. `-Dfts5=false` is the opt-OUT for lean custom builds that never declare a
    // `.searchable` field: it drops `-DSQLITE_ENABLE_FTS5` from the SQLite C build (~250-400 KB
    // smaller) and folds every FTS5 code path in src/search/fts.zig to comptime-dead. A disabled
    // build fails a `?search=` request with a clean 400 and REFUSES TO START if any collection in
    // the comptime schema declares a `.searchable` field (fail loud at boot, never a silent
    // runtime 500 on first search). Postgres full-text search (tsvector/GIN) is a server-native
    // feature and is NOT gated by this flag.
    const fts5 = b.option(bool, "fts5", "Compile SQLite FTS5 full-text search into the binary (default true; -Dfts5=false for lean builds without .searchable fields)") orelse true;

    // --- Vendored/native component version transparency (#282) ---------------------
    // Single-source the pinned versions of the vendored/native dependencies at CONFIGURE
    // time so `--version`, `zig build versions`, the startup log, and `GET /api/health`
    // can surface exactly what is baked into this binary — with zero runtime cost (each
    // becomes a build_options string constant). SQLite + sqlite-vec are read straight from
    // their vendored headers (so a bumped amalgamation flows through automatically). zap is
    // read from the build.zig.zon pin (version curated, commit parsed from the url); facil.io
    // ships bundled inside the pinned zap and has no in-tree header, so it is a curated const
    // tied to the zap pin — bump it when re-pinning zap. See docs/security-advisories.md and
    // docs/security-audit.md ("Dependency version transparency & supply-chain auditing").
    const option_values: BuildOptionValues = .{
        .version = @import("build.zig.zon").version,
        .min_zig_version = @import("build.zig.zon").minimum_zig_version,
        .commit = commit,
        .dev_mode = dev_mode,
        .dev_tools = dev_tools,
        .internal_api = false,
        .vector = vector,
        .postgres = postgres,
        .s3 = s3,
        .fts5 = fts5,
        .sqlite_version = readCDefineStr(b, "vendor/sqlite/sqlite3.h", "SQLITE_VERSION"),
        .sqlite_source_id = readCDefineStr(b, "vendor/sqlite/sqlite3.h", "SQLITE_SOURCE_ID"),
        .sqlite_vec_version = readCDefineStr(b, "vendor/sqlite-vec/sqlite-vec.h", "SQLITE_VEC_VERSION"),
        // Curated: the UPSTREAM tag the zap pin is based on. The pin itself is a fork
        // carrying one facil.io fix (see the comment on `.zap` in build.zig.zon), so
        // `zap_commit` reports the fork's SHA while these two name the upstream base.
        .zap_version = "0.10.6", // curated: matches the zap pin in build.zig.zon
        .zap_commit = zapPinnedCommit(),
        .facil_version = "0.7.4", // curated: facil.io bundled inside the pinned zap (bump on zap re-pin)
    };
    const build_options = createBuildOptions(b, option_values);

    const sqlite_base_flags = [_][]const u8{
        "-DSQLITE_THREADSAFE=1",
        "-DSQLITE_DQS=0",
        "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
        "-DSQLITE_OMIT_LOAD_EXTENSION=1",
        // Omit SQLite subsystems the framework provably never touches — db.zig uses
        // only the UTF-8 prepare/step/bind/column/exec surface. This trims the
        // amalgamation (smaller binary, ~10% faster C compile) with no behavior
        // change. NOT trimmed by default: FTS5 (see `-Dfts5` above; a deliberate
        // roadmap bet per docs/ideas.md) and anything the query/provision layers rely on.
        "-DSQLITE_OMIT_UTF16", // no _text16/_prepare16/_column_text16 anywhere
        "-DSQLITE_OMIT_DECLTYPE", // we read sqlite3_column_type, never _column_decltype
        "-DSQLITE_OMIT_DEPRECATED", // no legacy APIs in use
        "-DSQLITE_OMIT_PROGRESS_CALLBACK", // no sqlite3_progress_handler
        "-DSQLITE_OMIT_TRACE", // no sqlite3_trace/profile
        "-DSQLITE_OMIT_SHARED_CACHE", // single-process reader pool + one writer; never shared-cache
        "-DSQLITE_DEFAULT_MEMSTATUS=0", // we never query sqlite3_memory_used/high_water
    };
    const sqlite_flags: []const []const u8 = if (fts5)
        &(sqlite_base_flags ++ [_][]const u8{"-DSQLITE_ENABLE_FTS5"})
    else
        &sqlite_base_flags;
    // Opt-in vector search compiles sqlite-vec statically into each ZigBase module.
    configureZigbaseModule(b, zigbase_mod, build_options, zap.module("zap"), sqlite_flags, vector);

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

    // --- versions: print every baked-in component version (#282) ------------------
    // Runs the freshly-built binary with `--version`, whose enriched output lists
    // zigbase + commit, SQLite + source id, sqlite-vec, zap + commit, facil.io, and the
    // Zig compiler. Single command, no drift: the same string the running server reports.
    const versions_run = b.addRunArtifact(exe);
    versions_run.addArg("--version");
    const versions_step = b.step("versions", "Print baked-in component versions (SQLite, sqlite-vec, zap, facil.io, zigbase)");
    versions_step.dependOn(&versions_run.step);

    // --- audit: compare pinned dep versions against the curated advisory table (#282)
    // Runs scripts/audit-deps.sh, which reads the pinned versions from vendor/ + the
    // curated consts and checks them against docs/security-advisories.md. Exits non-zero
    // if any pinned version falls in a listed affected range.
    const audit_cmd = b.addSystemCommand(&.{"bash"});
    audit_cmd.addFileArg(b.path("scripts/audit-deps.sh"));
    const audit_step = b.step("audit", "Audit pinned dependency versions against docs/security-advisories.md");
    audit_step.dependOn(&audit_cmd.step);

    // --- bench: allocation + timing harness (report-only; see the allocator-ownership spec)
    // Benchmarks have an independent optimization mode: ReleaseFast by default,
    // overridable with -Dbench-optimize=Debug|ReleaseSafe|ReleaseFast|ReleaseSmall.
    // Their private ZigBase module enables only the internal benchmark API surface;
    // dev-only clock, entropy, capture, and fake-crypto seams remain compiled out so
    // measured record paths match the production shape.
    const bench_optimize = b.option(std.builtin.OptimizeMode, "bench-optimize", "Optimization mode for `zig build bench` (default: ReleaseFast)") orelse .ReleaseFast;
    var bench_option_values = option_values;
    bench_option_values.dev_mode = false;
    bench_option_values.internal_api = true;
    const bench_build_options = createBuildOptions(b, bench_option_values);
    const bench_zap = b.dependency("zap", .{ .target = target, .optimize = bench_optimize });
    const bench_zigbase_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = bench_optimize,
        .link_libc = true,
    });
    configureZigbaseModule(b, bench_zigbase_mod, bench_build_options, bench_zap.module("zap"), sqlite_flags, vector);
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = bench_optimize,
        .link_libc = true,
    });
    bench_mod.addImport("zigbase", bench_zigbase_mod);
    const bench_exe = b.addExecutable(.{ .name = "zigbase-bench", .root_module = bench_mod });
    const bench_run = b.addRunArtifact(bench_exe);
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("bench", "Run the benchmark harness (ns/op + allocation profile)");
    bench_step.dependOn(&bench_run.step);

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

    // --- import-fixture: offline-import e2e fixture (#283) ------------------------
    // Comptime .collections with an auth collection (password hashing) and a base
    // collection carrying an .encrypted field (at-rest envelope), so tests/admin/test_import.py
    // can drive `zigbase import` against a real boot (provisioning + cipher stamping) and
    // verify the round-trip + ciphertext-at-rest + hashed password over REST. Links libc.
    const import_fix_mod = b.createModule(.{
        .root_source_file = b.path("fixtures/import/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    import_fix_mod.addImport("zigbase", zigbase_mod);
    const import_fix_exe = b.addExecutable(.{ .name = "import-fixture", .root_module = import_fix_mod });
    const import_fix_step = b.step("import-fixture", "Build the offline-import e2e fixture server (#283)");
    import_fix_step.dependOn(&b.addInstallArtifact(import_fix_exe, .{}).step);

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

    // Feature-route protocol fixtures: real servers for the remapped and disabled
    // GET/HEAD mount behavior. Keeping these as separate App instantiations exercises
    // the compile-time route configuration used by production applications.
    const features_remapped_mod = b.createModule(.{
        .root_source_file = b.path("fixtures/features-remapped/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    features_remapped_mod.addImport("zigbase", zigbase_mod);
    const features_remapped_exe = b.addExecutable(.{ .name = "feature-remapped-fixture", .root_module = features_remapped_mod });
    const features_remapped_step = b.step("feature-remapped-fixture", "Build the remapped feature-route protocol fixture");
    features_remapped_step.dependOn(&b.addInstallArtifact(features_remapped_exe, .{}).step);

    const features_disabled_mod = b.createModule(.{
        .root_source_file = b.path("fixtures/features-disabled/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    features_disabled_mod.addImport("zigbase", zigbase_mod);
    const features_disabled_exe = b.addExecutable(.{ .name = "feature-disabled-fixture", .root_module = features_disabled_mod });
    const features_disabled_step = b.step("feature-disabled-fixture", "Build the disabled feature-route protocol fixture");
    features_disabled_step.dependOn(&b.addInstallArtifact(features_disabled_exe, .{}).step);

    // Compile-fail contract fixtures. Merely declaring these lazy steps does not build
    // them during normal gates; the Python contract tests invoke each step and assert
    // the framework's comptime diagnostic instead of allowing an exporter panic.
    inline for (&.{
        .{ .step = "invalid-route-unknown-method", .file = "fixtures/invalid-routes/unknown-method.zig" },
        .{ .step = "invalid-route-noncanonical-path", .file = "fixtures/invalid-routes/noncanonical-path.zig" },
        .{ .step = "invalid-route-missing-secret-capture", .file = "fixtures/invalid-routes/missing-secret-capture.zig" },
        .{ .step = "invalid-route-typed-missing-secret-capture", .file = "fixtures/invalid-routes/typed-missing-secret-capture.zig" },
    }) |invalid| {
        const invalid_mod = b.createModule(.{
            .root_source_file = b.path(invalid.file),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        invalid_mod.addImport("zigbase", zigbase_mod);
        const invalid_exe = b.addExecutable(.{ .name = invalid.step, .root_module = invalid_mod });
        const invalid_step = b.step(invalid.step, "Compile-fail consumer route contract fixture");
        invalid_step.dependOn(&b.addInstallArtifact(invalid_exe, .{}).step);
    }
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

    // Wire the bench harness's own test{} blocks (counting_allocator.zig, harness.zig)
    // into `zig build test`. Without this, nothing in CI ever compiles or runs `bench/`
    // (this test_step is rooted at src/root.zig, which can't see bench/, and `bench_step`
    // above is manual and not part of CI) — a jwt/crypto API change could silently break
    // the harness the allocator-ownership migration depends on. Rooted at harness.zig
    // (not zigbase-importing main.zig) so counting_allocator.zig's tests come along via
    // its `@import`, with no libc/facil.io/sqlite recompile needed for a std-only test.
    const bench_test_mod = b.createModule(.{
        .root_source_file = b.path("bench/harness.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bench_tests = b.addTest(.{ .root_module = bench_test_mod });
    const run_bench_tests = b.addRunArtifact(bench_tests);
    test_step.dependOn(&run_bench_tests.step);

    // Coverage-guided targets for parsers that consume attacker-controlled bytes.
    // Keep this off `test_step`: importing the parser modules into this root also
    // discovers their unit tests, so wiring it there would run 56 duplicate tests in
    // every CI test configuration. `zig build fuzz` runs seeds; --fuzz=N generates.
    const fuzz_step = b.step("fuzz", "Fuzz attacker-controlled parser surfaces (pass --fuzz=N)");
    const fuzz_compile_step = b.step("fuzz-compile", "Compile fuzz harnesses without running imported tests");
    inline for (.{
        "src/fuzz_filter.zig",
        "src/fuzz_query_connstr.zig",
        "src/fuzz_webauthn.zig",
    }) |root_source_file| {
        const parser_fuzz_mod = b.createModule(.{
            .root_source_file = b.path(root_source_file),
            .target = target,
            // Zig 0.16.0's Debug test runner has a StackTrace type mismatch when it
            // rebuilds fuzz mode. ReleaseSafe preserves runtime safety while also
            // making campaigns fast enough for useful local iteration counts.
            .optimize = .ReleaseSafe,
        });
        const parser_fuzz_tests = b.addTest(.{ .root_module = parser_fuzz_mod });
        fuzz_compile_step.dependOn(&parser_fuzz_tests.step);
        fuzz_step.dependOn(&b.addRunArtifact(parser_fuzz_tests).step);
    }

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

    // --- Dart codegen: generate the dating fixture's typed Dart client. Reuses
    // the same comptime generator exe (`zbase-gen-client`) with `--lang dart`.
    const dart_out = "clients/dart/test/codegen/dating/zbase.gen.dart";
    const gen_dart_run = b.addRunArtifact(gen_exe);
    gen_dart_run.setEnvironmentVariable("ZBASE_INREPO", "1");
    gen_dart_run.addArgs(&.{ "--out", dart_out, "--api-prefix", "/api", "--lang", "dart" });
    // The Dart golden is committed `dart format`-clean, so its staleness gate is a
    // regenerate-then-`dart format`-then-`git diff` shell step in CI (the raw
    // generator output differs from the formatted golden only in line wrapping).
    const gen_dart_step = b.step("gen-dating-dart-client", "Generate the dating fixture's typed Dart client (run `dart format` after)");
    gen_dart_step.dependOn(&gen_dart_run.step);

    // --- Python codegen: generate the dating fixture's typed Python client. Reuses
    // the same comptime generator exe (`zbase-gen-client`) with `--lang python`.
    const python_out = "clients/python/tests/codegen/dating/zbase_gen.py";
    const gen_python_run = b.addRunArtifact(gen_exe);
    gen_python_run.setEnvironmentVariable("ZBASE_INREPO", "1");
    gen_python_run.addArgs(&.{ "--out", python_out, "--api-prefix", "/api", "--lang", "python" });
    // The Python golden is committed `ruff format`-clean, so its staleness gate is a
    // regenerate-then-`ruff format`-then-`git diff` shell step in CI, mirroring the
    // Dart golden's freshness check.
    const gen_python_step = b.step("gen-dating-python-client", "Generate the dating fixture's typed Python client (run `ruff format` after)");
    gen_python_step.dependOn(&gen_python_run.step);

    // --- Kotlin codegen: generate the dating fixture's typed Kotlin client. Reuses
    // the same comptime generator exe (`zbase-gen-client`) with `--lang kotlin`.
    const kotlin_out = "clients/kotlin/src/test/kotlin/io/github/valthon/zigbase/codegen/dating/ZbaseGen.kt";
    const gen_kotlin_run = b.addRunArtifact(gen_exe);
    gen_kotlin_run.setEnvironmentVariable("ZBASE_INREPO", "1");
    gen_kotlin_run.addArgs(&.{ "--out", kotlin_out, "--api-prefix", "/api", "--lang", "kotlin" });
    // The Kotlin golden is committed Spotless/ktlint-clean, so its staleness gate is a
    // regenerate-then-`spotlessApply`-then-`git diff` shell step in CI, mirroring the
    // Dart/Python goldens' freshness checks.
    const gen_kotlin_step = b.step("gen-dating-kotlin-client", "Generate the dating fixture's typed Kotlin client (run `spotlessApply` after)");
    gen_kotlin_step.dependOn(&gen_kotlin_run.step);

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

/// Read a `#define <macro> "value"` string constant out of a vendored C header at
/// configure time (#282). Single-sources the pinned SQLite / sqlite-vec versions from
/// the headers themselves so a bumped amalgamation flows through to every version
/// surface automatically. Panics loudly if the macro or its quoted value is absent, so
/// a header reshuffle fails the build rather than silently shipping a wrong version.
fn readCDefineStr(b: *std.Build, rel_path: []const u8, macro: []const u8) []const u8 {
    const data = b.build_root.handle.readFileAlloc(b.graph.io, rel_path, b.allocator, .unlimited) catch |e|
        std.debug.panic("version aggregation: cannot read '{s}': {s}", .{ rel_path, @errorName(e) });
    // The whole header (sqlite3.h is ~600 KB) is read into this buffer; we only dupe the
    // matched substring out, so free the buffer before returning.
    defer b.allocator.free(data);
    var it = std.mem.tokenizeScalar(u8, data, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "#define")) continue;
        const rest = std.mem.trimStart(u8, trimmed["#define".len..], " \t");
        if (!std.mem.startsWith(u8, rest, macro)) continue;
        // Require the token to be exactly `macro` (the next char must be whitespace),
        // so SQLITE_VERSION doesn't match SQLITE_VERSION_NUMBER.
        const after = rest[macro.len..];
        if (after.len == 0 or (after[0] != ' ' and after[0] != '\t')) continue;
        const q1 = std.mem.indexOfScalar(u8, after, '"') orelse continue;
        const q2 = std.mem.indexOfScalarPos(u8, after, q1 + 1, '"') orelse continue;
        return b.allocator.dupe(u8, after[q1 + 1 .. q2]) catch @panic("OOM");
    }
    std.debug.panic("version aggregation: '#define {s} \"...\"' not found in '{s}'", .{ macro, rel_path });
}

/// The pinned zap dependency's git commit, parsed from its `build.zig.zon` url
/// (`git+https://…#<commit>`). "unknown" if the url carries no `#<commit>` fragment.
fn zapPinnedCommit() []const u8 {
    const url = @import("build.zig.zon").dependencies.zap.url;
    const hash = std.mem.indexOfScalar(u8, url, '#') orelse return "unknown";
    return url[hash + 1 ..];
}

/// Capture the short git commit at configure time; "unknown" outside a repo.
///
/// Two strategies, in order: (1) `git rev-parse --short HEAD` — works in a normal checkout
/// with git on PATH; but a sandboxed configure step (e.g. an agent harness) can block the
/// spawn, so (2) fall back to a spawn-free filesystem parse of `.git` that also handles the
/// linked-worktree case (`.git` is a *file* pointing at the real gitdir, whose branch refs
/// live in the shared common dir). Both failing → "unknown" (graceful, never a crash).
fn gitCommit(b: *std.Build) []const u8 {
    const root = b.build_root.path orelse ".";
    var code: u8 = undefined;
    if (b.runAllowFail(&.{ "git", "-C", root, "rev-parse", "--short", "HEAD" }, &code, .ignore)) |stdout| {
        if (code == 0) {
            const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
            if (trimmed.len > 0) return trimmed;
        }
    } else |_| {}
    return gitCommitFromFs(b) orelse "unknown";
}

/// Spawn-free short-SHA detection by parsing `.git` directly (sandbox- and worktree-proof).
/// Returns null on any read/parse failure so the caller degrades to "unknown".
fn gitCommitFromFs(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const alloc = b.allocator;
    const cwd = std.Io.Dir.cwd();
    const root = b.build_root.path orelse return null;
    const small: std.Io.Limit = .limited(64 * 1024);

    // 1. Resolve the git dir. `.git` is a directory (normal repo) or a file
    //    "gitdir: <path>" (linked worktree / submodule). readFileAlloc errors on a dir.
    const dot_git = b.fmt("{s}/.git", .{root});
    const git_dir: []const u8 = blk: {
        const contents = cwd.readFileAlloc(io, dot_git, alloc, small) catch break :blk dot_git;
        const trimmed = std.mem.trim(u8, contents, " \t\r\n");
        const gd = "gitdir:";
        if (std.mem.startsWith(u8, trimmed, gd)) {
            const p = std.mem.trim(u8, trimmed[gd.len..], " \t\r\n");
            break :blk if (std.fs.path.isAbsolute(p)) p else b.fmt("{s}/{s}", .{ root, p });
        }
        break :blk dot_git;
    };

    // 2. Read HEAD. Either "ref: refs/heads/<branch>" or a detached raw SHA.
    const head = cwd.readFileAlloc(io, b.fmt("{s}/HEAD", .{git_dir}), alloc, small) catch return null;
    const head_trim = std.mem.trim(u8, head, " \t\r\n");
    const rp = "ref:";
    if (!std.mem.startsWith(u8, head_trim, rp)) return shortSha(b, head_trim);
    const ref = std.mem.trim(u8, head_trim[rp.len..], " \t\r\n"); // e.g. refs/heads/main

    // 3. Branch refs live in the COMMON dir. In a linked worktree, gitdir/commondir points
    //    at it (relative to gitdir); a normal repo has no commondir, so gitdir IS the common dir.
    const common_dir: []const u8 = blk: {
        const cd = cwd.readFileAlloc(io, b.fmt("{s}/commondir", .{git_dir}), alloc, small) catch break :blk git_dir;
        const cd_trim = std.mem.trim(u8, cd, " \t\r\n");
        break :blk if (std.fs.path.isAbsolute(cd_trim)) cd_trim else b.fmt("{s}/{s}", .{ git_dir, cd_trim });
    };

    // 3a. Loose ref file.
    if (cwd.readFileAlloc(io, b.fmt("{s}/{s}", .{ common_dir, ref }), alloc, small)) |loose| {
        return shortSha(b, std.mem.trim(u8, loose, " \t\r\n"));
    } else |_| {}

    // 3b. Packed refs: lines are "<sha> <refname>" (skip comments and "^" peel lines).
    if (cwd.readFileAlloc(io, b.fmt("{s}/packed-refs", .{common_dir}), alloc, .unlimited)) |packed_refs| {
        var it = std.mem.tokenizeScalar(u8, packed_refs, '\n');
        while (it.next()) |line| {
            if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            if (std.mem.eql(u8, std.mem.trim(u8, line[sp + 1 ..], " \t\r\n"), ref)) {
                return shortSha(b, line[0..sp]);
            }
        }
    } else |_| {}
    return null;
}

/// Validate that `full` looks like a hex object id and return a short (first 12 chars)
/// duplicated copy; null if it isn't hex or is too short to be a SHA.
fn shortSha(b: *std.Build, full: []const u8) ?[]const u8 {
    if (full.len < 7) return null;
    for (full) |ch| {
        const is_hex = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
        if (!is_hex) return null;
    }
    return b.allocator.dupe(u8, full[0..@min(full.len, 12)]) catch null;
}

// ---------------------------------------------------------------------------
// Codegen helpers
// ---------------------------------------------------------------------------

pub const GenOpts = struct {
    out: []const u8,
    api_prefix: []const u8 = "/api",
    check: bool = false,
    in_repo: bool = false,
    /// Output language: "ts" (default), "dart", or "python".
    lang: []const u8 = "ts",
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
    run.addArg("--lang");
    run.addArg(opts.lang);
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
        // Assumes asset filenames are ASCII without '"' or '\' — true for generated hashed output.
        src.appendSlice(alloc, b.fmt(
            "    .{{ .path = \"{s}\", .bytes = @embedFile(\"{s}\"), .etag = \"\\\"{x:0>8}\\\"\" }},\n",
            .{ rel, rel, crc },
        )) catch @panic("OOM");
    }
    src.appendSlice(alloc, "};\n") catch @panic("OOM");
    const manifest = wf.add("static_assets.zig", src.items);
    return b.createModule(.{ .root_source_file = manifest });
}

/// Wire the `zigbase` module into a consumer module, and set everything the module
/// requires — today that is `link_libc`, because zigbase carries the SQLite C
/// amalgamation and zap transitively. Forgetting `link_libc` by hand is the classic
/// first-build failure; going through this helper makes it unrepresentable.
///
///     const zigbase = @import("zigbase");           // the dependency's build.zig
///     const dep = b.dependency("zigbase", .{ .target = target, .optimize = optimize });
///     zigbase.addTo(dep, exe_mod);
pub fn addTo(dep: *std.Build.Dependency, mod: *std.Build.Module) void {
    mod.link_libc = true;
    mod.addImport("zigbase", dep.module("zigbase"));
}

pub const TestOptions = struct {
    /// The module under test. Pass the SAME module you passed to `addTo` — rooting a
    /// second module at the same file puts one file in two modules, which Zig rejects.
    root_module: *std.Build.Module,
    name: []const u8 = "test",
    filters: []const []const u8 = &.{},
};

/// A test artifact for a consumer app, wired with ZigBase's `.simple`-mode runner.
///
/// The runner matters: `zig build test` otherwise runs the test binary in server mode
/// (`--listen=-`), and an app booted by `zigbase.testing` does enough work at process
/// exit that Zig 0.16's build runner can mis-read a normal exit as a crash. `.simple`
/// mode rides the exit code instead. The runner also fails the build on a leaked
/// allocation.
///
///     const tests = zigbase.addTest(b, dep, .{ .root_module = app_mod });
///     b.step("test", "run tests").dependOn(&b.addRunArtifact(tests).step);
pub fn addTest(b: *std.Build, dep: *std.Build.Dependency, opts: TestOptions) *std.Build.Step.Compile {
    return b.addTest(.{
        .name = opts.name,
        .root_module = opts.root_module,
        .filters = opts.filters,
        .test_runner = .{ .path = dep.path("src/simple_runner.zig"), .mode = .simple },
    });
}
