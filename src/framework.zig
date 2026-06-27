const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const static_files = @import("static_files.zig");
const app_mod = @import("app.zig");
const events = @import("events.zig");
const config = @import("config.zig");
const cli = @import("cli.zig");
const server = @import("server.zig");
const migrations = @import("migrations.zig");
const files_storage = @import("files/storage.zig");
const db = @import("db.zig");
const crypto = @import("crypto.zig");
const id_gen = @import("id.zig");
const scheduler = @import("scheduler.zig");
const schedule = @import("schedule.zig");
const clock = @import("clock.zig");
const mail = @import("mail/mailer.zig");
const provision = @import("provision.zig");
const schema = @import("schema.zig");
const ratelimit = @import("ratelimit.zig");
const pagination = @import("pagination.zig");
const registry = @import("auth/registry.zig");
const field_policy = @import("field_policy.zig");

/// True if any collection declares an `.encrypted` field (Theme B1). Drives the
/// fail-closed startup check (refuse to serve without ZIGBASE_FIELD_KEY).
fn anyEncryptedField(cols: []const schema.Collection) bool {
    for (cols) |c| if (schema.hasEncryptedField(c)) return true;
    return false;
}

// ============================================================================
// Comptime plugins (storage + mailer)
// ----------------------------------------------------------------------------
// A *plugin* is a comptime TYPE selected via `App(.{ .storage = T, .mailer = T })`
// and instantiated in serveImpl. Both contracts are uniform:
//
//   pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config) !Self;
//   pub fn interface(self: *Self) <Storage|Mailer>;  // returns the vtable view
//   pub fn deinit(self: *Self) void;                 // release any owned resources
//
// `create` builds the backend from runtime config; `interface` returns the
// type-erased vtable handle stored on `App`; `deinit` tears it down. The instance
// is a serveImpl stack var that outlives the server (the vtable points at it).
//
// Defaults below reproduce the historical wiring: LocalStorage rooted at
// <data_dir>/storage, and a mailer that logs (LogMailer) unless SMTP is
// configured, in which case it speaks SMTP (SmtpMailer). A consumer overrides
// either by supplying their own comptime type implementing the same contract.
// ============================================================================

/// Default storage plugin: wraps `LocalStorage` rooted at `<data_dir>/storage`,
/// reproducing the pre-plugin file wiring. Owns the heap-allocated root string.
pub const DefaultStoragePlugin = struct {
    gpa: std.mem.Allocator,
    root: []const u8,
    backend: files_storage.LocalStorage,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config) !DefaultStoragePlugin {
        _ = io;
        const root = try std.fmt.allocPrint(gpa, "{s}/storage", .{cfg.data_dir});
        return .{ .gpa = gpa, .root = root, .backend = files_storage.LocalStorage.init(root) };
    }

    pub fn interface(self: *DefaultStoragePlugin) files_storage.Storage {
        return self.backend.storage();
    }

    pub fn deinit(self: *DefaultStoragePlugin) void {
        self.gpa.free(self.root);
    }
};

/// Default mailer plugin, config-driven with a fixed precedence and no code
/// change to switch between backends:
///   1. `cfg.sendmail_command` non-empty → `CommandMailer` (pipe to a local MTA).
///   2. else `cfg.smtp_host` non-empty   → `SmtpMailer` (direct SMTP/TLS).
///   3. else                             → `LogMailer` (logs; dev/CI default).
pub const DefaultMailerPlugin = struct {
    log_backend: mail.LogMailer = .{},
    smtp_backend: ?mail.SmtpMailer = null,
    command_backend: ?mail.CommandMailer = null,
    /// Owned argv parsed from `cfg.sendmail_command`; freed in `deinit`.
    command_argv: ?[][]const u8 = null,
    gpa: std.mem.Allocator = undefined,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config) !DefaultMailerPlugin {
        _ = io;
        if (cfg.sendmail_command.len > 0) {
            const argv = try parseCommand(gpa, cfg.sendmail_command);
            errdefer gpa.free(argv);
            if (argv.len == 0) return error.EmptySendmailCommand;
            return .{
                .gpa = gpa,
                .command_argv = argv,
                .command_backend = mail.CommandMailer.init(argv, cfg.smtp_from),
            };
        }
        if (cfg.smtp_host.len == 0) return .{ .gpa = gpa };
        return .{ .gpa = gpa, .smtp_backend = mail.SmtpMailer.initTls(
            cfg.smtp_host,
            cfg.smtp_port,
            cfg.smtp_username,
            cfg.smtp_password,
            cfg.smtp_from,
            cfg.smtp_tls,
            cfg.smtp_insecure_skip_verify,
        ) };
    }

    pub fn interface(self: *DefaultMailerPlugin) mail.Mailer {
        if (self.command_backend) |*c| return c.mailer();
        if (self.smtp_backend) |*s| return s.mailer();
        return self.log_backend.mailer();
    }

    pub fn deinit(self: *DefaultMailerPlugin) void {
        if (self.command_argv) |argv| self.gpa.free(argv);
    }

    /// Split a command string into argv on ASCII whitespace runs (no quoting —
    /// argv elements with embedded spaces aren't expressible this way; a consumer
    /// needing that supplies a `CommandMailer` directly via `.mailer = T`). The
    /// returned slice borrows `cmd`'s bytes (which live in the config), so only
    /// the outer slice is heap-allocated.
    fn parseCommand(gpa: std.mem.Allocator, cmd: []const u8) ![][]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(gpa);
        var it = std.mem.tokenizeAny(u8, cmd, " \t\r\n");
        while (it.next()) |tok| try parts.append(gpa, tok);
        return parts.toOwnedSlice(gpa);
    }
};

/// True iff a value of type `M` coerces to `[]const provision.Migration` — i.e. it is
/// the slice itself or a pointer to an array of `Migration` (`&[_]Migration{ ... }`).
/// A bare anonymous tuple (`.{ .{ ... } }`) does NOT, which is the footgun P2-b guards.
fn migrationsCoerce(comptime M: type) bool {
    if (M == []const provision.Migration) return true;
    const info = @typeInfo(M);
    if (info != .pointer) return false;
    const ptr = info.pointer;
    if (ptr.size == .slice) return ptr.child == provision.Migration;
    if (ptr.size == .one) {
        const child = @typeInfo(ptr.child);
        return child == .array and child.array.child == provision.Migration;
    }
    return false;
}

/// `@compileError` unless plugin type `P` (selected via `.storage`/`.mailer`) declares
/// the three contract methods. Without this, a missing method surfaces as a generic
/// "no member named 'deinit'" at the instantiation site rather than a contract message.
fn assertPluginContract(comptime P: type, comptime kind: []const u8) void {
    inline for (.{ "create", "interface", "deinit" }) |decl| {
        if (!@hasDecl(P, decl)) {
            @compileError("'." ++ kind ++ "' plugin type '" ++ @typeName(P) ++ "' is missing the '" ++ decl ++
                "' method; a plugin must declare create(gpa, io, cfg) !Self / interface(*Self) view / deinit(*Self) void");
        }
    }
}

/// Comptime application builder. `cfg` is an anonymous struct VALUE with optional
/// `.hooks` (record hook groups) and optional `.onError` (an ErrorHandler).
/// Returns a type exposing the prebuilt `dispatch` and the CLI/serve entry points.
pub fn App(comptime cfg: anytype) type {
    return struct {
        /// Prebuilt at comptime; the runtime app holds a pointer to it (static lifetime).
        pub const dispatch: events.Dispatch = blk: {
            // Guard top-level cfg keys so a typo (e.g. `.hook`, `.on_error`) fails
            // loudly at comptime instead of silently producing an empty Dispatch.
            const allowed = .{ "hooks", "onError", "routes", "onAuth", "beforeAuthSuccess", "onFileServe", "onFileUpload", "onBootstrap", "onBeforeServe", "onBeforeTerminate", "cron", "jobs", "storage", "mailer", "pools", "collections", "migrations", "static_files", "pagination", "enable_typegen", "auth_methods" };
            const allowed_list = blk2: {
                var s: []const u8 = "";
                for (allowed, 0..) |name, i| s = s ++ (if (i == 0) "" else "/") ++ name;
                break :blk2 s;
            };
            for (std.meta.fields(@TypeOf(cfg))) |f| {
                var ok = false;
                for (allowed) |name| {
                    if (std.mem.eql(u8, f.name, name)) ok = true;
                }
                if (!ok) @compileError("unknown App cfg field '" ++ f.name ++ "'; expected one of " ++ allowed_list);
            }
            var d = events.Dispatch{};
            if (@hasField(@TypeOf(cfg), "hooks")) d.record = events.buildRecordDispatcher(cfg.hooks);
            if (@hasField(@TypeOf(cfg), "onError")) d.on_error = cfg.onError;
            if (@hasField(@TypeOf(cfg), "routes")) d.routes = events.buildRoutes(cfg.routes);
            if (@hasField(@TypeOf(cfg), "onAuth")) d.on_auth = cfg.onAuth;
            if (@hasField(@TypeOf(cfg), "beforeAuthSuccess")) d.before_auth_success = cfg.beforeAuthSuccess;
            if (@hasField(@TypeOf(cfg), "onFileServe")) d.on_file_serve = cfg.onFileServe;
            if (@hasField(@TypeOf(cfg), "onFileUpload")) d.on_file_upload = cfg.onFileUpload;
            if (@hasField(@TypeOf(cfg), "onBootstrap")) d.on_bootstrap = cfg.onBootstrap;
            if (@hasField(@TypeOf(cfg), "onBeforeServe")) d.on_before_serve = cfg.onBeforeServe;
            if (@hasField(@TypeOf(cfg), "onBeforeTerminate")) d.on_before_terminate = cfg.onBeforeTerminate;
            break :blk d;
        };

        /// The consumer's cron/interval/reactive job table (empty when no `.cron`).
        const user_jobs: []const scheduler.RuntimeJob = if (@hasField(@TypeOf(cfg), "cron")) scheduler.buildJobs(cfg.cron) else &.{};

        /// True when ANY comptime collection opts into TTL (`.ttl_field`). Gates the
        /// framework-internal `_ttl_gc` job and the startup one-shot sweep.
        pub const has_ttl_collection: bool = blk: {
            for (collections) |col| if (col.options.ttl_field != null) break :blk true;
            break :blk false;
        };

        /// Framework-internal jobs: a periodic TTL sweep when any collection opts in,
        /// else empty. Appended after the consumer's jobs so user `.cron` names win the
        /// lower indices and the internal job runs even with no user cron.
        const internal_jobs: []const scheduler.RuntimeJob = if (has_ttl_collection)
            scheduler.buildJobs(.{
                .{ .name = "_ttl_gc", .schedule = schedule.Schedule{ .interval = .{ .minutes = 5 } }, .handler = ttlGcJob },
            })
        else
            &.{};

        /// The full job table = consumer jobs ++ framework-internal jobs. The scheduler
        /// starts whenever this is non-empty, so a TTL collection alone starts it.
        pub const jobs: []const scheduler.RuntimeJob = scheduler.concatJobs(user_jobs, internal_jobs);
        /// Worker pool size for the scheduler. Precedence: `.pools.jobs` (the new
        /// unified lever), then the legacy `.jobs.pool_size`, then the default 2.
        pub const job_pool_size: usize = blk: {
            if (@hasField(@TypeOf(cfg), "pools") and @hasField(@TypeOf(cfg.pools), "jobs")) break :blk cfg.pools.jobs;
            if (@hasField(@TypeOf(cfg), "jobs") and @hasField(@TypeOf(cfg.jobs), "pool_size")) break :blk cfg.jobs.pool_size;
            break :blk 2;
        };

        /// Comptime warm-reader-pool cap (the `.pools.readers` lever). Defaults to 16,
        /// the historical hardcoded value; shrink it to reduce the connection footprint.
        pub const reader_pool_size: usize = if (@hasField(@TypeOf(cfg), "pools") and @hasField(@TypeOf(cfg.pools), "readers")) cfg.pools.readers else 16;

        /// Whether to compile the `typegen` CLI subcommand into the binary.
        /// Off by default so production builds carry no codegen weight.
        pub const enable_typegen: bool = if (@hasField(@TypeOf(cfg), "enable_typegen")) cfg.enable_typegen else false;

        /// Per-thread stack size (bytes) for the scheduler/job-pool/submit threads
        /// (the `.pools.stack_size` lever). Defaults to `scheduler.default_job_stack_size`
        /// (1 MiB), far below `std.Thread`'s 16 MiB default; raise it for unusually deep
        /// job handlers. Clamped up to `scheduler.min_job_stack_size` — a below-floor value
        /// would EINVAL-abort `pthread_create` in the full binary, so the lever can only
        /// raise the stack, never crash the server. Only consumed when jobs are configured.
        pub const job_stack_size: usize = @max(scheduler.min_job_stack_size, if (@hasField(@TypeOf(cfg), "pools") and @hasField(@TypeOf(cfg.pools), "stack_size")) cfg.pools.stack_size else scheduler.default_job_stack_size);

        /// Per-connection SQLite page-cache budget in KiB (the `.pools.cache_kib` lever).
        /// Defaults to `db.default_cache_kib` (1024 KiB); shrink it to reduce the page-cache
        /// footprint across the writer + warm readers, or raise it for large working sets.
        pub const cache_kib: u32 = if (@hasField(@TypeOf(cfg), "pools") and @hasField(@TypeOf(cfg.pools), "cache_kib")) cfg.pools.cache_kib else db.default_cache_kib;

        /// Comptime-selected storage plugin type (defaults to `DefaultStoragePlugin`).
        /// A custom type missing a contract method fails with a contract-specific message.
        pub const StoragePlugin: type = blk: {
            const P = if (@hasField(@TypeOf(cfg), "storage")) cfg.storage else DefaultStoragePlugin;
            assertPluginContract(P, "storage");
            break :blk P;
        };
        /// Comptime pagination config resolved from `.pagination` (defaults: both modes on,
        /// stateless tokens). `@compileError`s on an unknown sub-field or both modes disabled.
        pub const pagination_config: pagination.Config = pagination.resolve(cfg);

        /// Comptime-selected mailer plugin type (defaults to `DefaultMailerPlugin`).
        /// A custom type missing a contract method fails with a contract-specific message.
        pub const MailerPlugin: type = blk: {
            const P = if (@hasField(@TypeOf(cfg), "mailer")) cfg.mailer else DefaultMailerPlugin;
            assertPluginContract(P, "mailer");
            break :blk P;
        };

        /// Comptime-assembled list of auth method TYPES (built-ins ++ consumer types from
        /// `.auth_methods`). Each type in the list is validated against the auth-method
        /// contract (create/method/deinit) at compile time. Used in serveImpl to
        /// instantiate the Registry stack vars.
        pub const auth_method_types: []const type = blk: {
            const am = @import("auth/method.zig");
            const types = registry.assembleTypes(cfg);
            // Validate every method type (built-ins AND consumer types) against the
            // contract, mirroring how assertPluginContract always runs on storage/mailer
            // — so a broken built-in can't silently escape comptime validation either.
            for (types) |T| am.assertAuthMethodContract(T);
            break :blk types;
        };

        /// Comptime static-files mode (see static_files.Mode). Field absent -> .default,
        /// which enables the runtime `--serve-static <dir>` flag on `serve`.
        pub const static_mode: static_files.Mode = blk: {
            if (!@hasField(@TypeOf(cfg), "static_files")) break :blk .default;
            const sf = cfg.static_files;
            const T = @TypeOf(sf);
            if (T == @TypeOf(.enum_literal)) {
                if (std.mem.eql(u8, @tagName(sf), "disabled")) break :blk .disabled;
                @compileError("static_files: unknown value '." ++ @tagName(sf) ++ "'; expected .disabled, .{ .dir = \"<path>\" }, or .{ .embedded = &<manifest>.files }");
            }
            if (@hasField(T, "dir")) break :blk .{ .dir = sf.dir };
            if (@hasField(T, "embedded")) {
                // Coerce the generated manifest's structurally-identical struct type
                // into static_files.StaticFile (the generated module can't import it).
                const src = sf.embedded;
                var out: [src.len]static_files.StaticFile = undefined;
                for (src, 0..) |f, i| out[i] = .{ .path = f.path, .bytes = f.bytes, .etag = f.etag };
                const final = out;
                break :blk .{ .embedded = &final };
            }
            @compileError("static_files: expected .disabled, .{ .dir = \"<path>\" }, or .{ .embedded = &<manifest>.files }");
        };

        /// Comptime-lowered collection specs from `.collections` (empty when absent).
        /// Relation fields carry their target collection BY NAME in `targetCollectionId`;
        /// `provision.applySpecs` resolves names -> ids at startup. When empty, no
        /// provisioning runs and the binary behaves byte-for-byte as before.
        pub const collections: []const schema.Collection = if (@hasField(@TypeOf(cfg), "collections"))
            provision.buildCollections(cfg.collections)
        else
            &.{};

        /// Comptime-reflected route metadata from `.routes` (empty when absent).
        /// Mirrors `App.collections`; consumed by the SP2.2b TS client generator to
        /// emit typed fetch wrappers. Each entry carries the derived camelCase name,
        /// method, path, auth level, and the handler's Input/Output types.
        pub const routes: []const events.RouteMeta = if (@hasField(@TypeOf(cfg), "routes"))
            events.routeMeta(cfg.routes)
        else
            &.{};

        /// Explicit migrations (the escape hatch for non-additive changes), run in
        /// order before provisioning and recorded once in `_migrations`. Empty by default.
        ///
        /// `.migrations` must be a TYPED slice `&[_]zigbase.Migration{ ... }`; a bare
        /// anonymous tuple does not coerce to `[]const Migration`. Guard it here so the
        /// failure names the PUBLIC type and the fix, rather than the raw coercion error
        /// (which leaks the internal `provision.Migration` name).
        pub const provision_migrations: []const provision.Migration = blk: {
            if (!@hasField(@TypeOf(cfg), "migrations")) break :blk &.{};
            if (!migrationsCoerce(@TypeOf(cfg.migrations))) {
                @compileError("'.migrations' must be a typed slice '&[_]zigbase.Migration{ ... }' " ++
                    "(a bare tuple does not coerce to []const Migration); got '" ++ @typeName(@TypeOf(cfg.migrations)) ++ "'");
            }
            break :blk cfg.migrations;
        };

        /// Bundle of comptime-resolved knobs threaded into the serve path: the
        /// selected storage/mailer plugin TYPES, the auth method type list,
        /// and the reader-pool cap.
        const Opts = ServeOpts{
            .StoragePlugin = StoragePlugin,
            .MailerPlugin = MailerPlugin,
            .auth_method_types = auth_method_types,
            .reader_pool_size = reader_pool_size,
            .job_stack_size = job_stack_size,
            .cache_kib = cache_kib,
            .static_mode = static_mode,
            .pagination = pagination_config,
            .enable_typegen = enable_typegen,
            .has_ttl = has_ttl_collection,
        };

        /// Parse argv and dispatch the CLI (serve / migrate / superuser create / help),
        /// wiring this app's `dispatch` into the runtime context for `serve`.
        pub fn runCli(init: std.process.Init) !void {
            return runCliImpl(init, &dispatch, jobs, job_pool_size, collections, provision_migrations, Opts);
        }

        /// Start the HTTP server directly with an explicit config (no CLI parsing).
        pub fn run(init: std.process.Init, cfg_runtime: config.Config) !void {
            return serveImpl(init.gpa, init.io, cfg_runtime, &dispatch, jobs, job_pool_size, collections, provision_migrations, Opts, init.environ_map);
        }
    };
}

/// The framework-internal `_ttl_gc` job handler: acquires the writer and reaps
/// expired rows across every TTL-enabled collection. Registered only when the
/// comptime schema declares at least one `.ttl_field` (see `App.internal_jobs`).
fn ttlGcJob(ctx: *@import("ctx.zig").Ctx, ev: *events.JobEvent) anyerror!void {
    _ = ev;
    const w = ctx.app.pool.acquireWriter();
    defer ctx.app.pool.releaseWriter();
    _ = try @import("records.zig").gcExpiredRecords(ctx.arena, w);
}

/// Comptime knobs threaded from `App(cfg)` into the serve path: which storage /
/// mailer plugin TYPES to instantiate, the assembled auth method type list,
/// and the warm-reader-pool cap.
pub const ServeOpts = struct {
    StoragePlugin: type,
    MailerPlugin: type,
    /// Comptime-assembled list of auth method types (built-ins ++ consumer types).
    /// Defaults to just PasswordMethod when absent. serveImpl uses this to
    /// instantiate the Registry via registry.build/deinit.
    auth_method_types: []const type = &.{@import("auth/methods/password.zig").PasswordMethod},
    reader_pool_size: usize,
    job_stack_size: usize = scheduler.default_job_stack_size,
    cache_kib: u32 = db.default_cache_kib,
    static_mode: static_files.Mode = .default,
    pagination: pagination.Config = .{},
    /// When true, compiles the `typegen` CLI subcommand into the binary.
    /// Off by default so production builds carry no codegen.
    enable_typegen: bool = false,
    /// True when the comptime schema declares at least one `.ttl_field`. Gates the
    /// startup one-shot TTL sweep in serveImpl (the periodic job is gated separately
    /// by `jobs`).
    has_ttl: bool = false,
};

/// Zig 0.16 entry point body: parse argv from `init.minimal.args` and dispatch.
fn runCliImpl(init: std.process.Init, dispatch: *const events.Dispatch, jobs: []const scheduler.RuntimeJob, pool_size: usize, schema_collections: []const schema.Collection, schema_migrations: []const provision.Migration, comptime opts: ServeOpts) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(arena);
    // cli.parse wants []const []const u8; argv is []const [:0]const u8. Copy
    // the (sentinel-bearing) slices into plain []const u8 views.
    const args = try arena.alloc([]const u8, argv.len);
    for (argv, 0..) |a, i| args[i] = a;

    const cmd = cli.parse(args[1..], .{ .serve_static = std.meta.activeTag(opts.static_mode) == .default }) catch |err| {
        std.log.err("argument error: {s}", .{@errorName(err)});
        printUsage(init.io, std.Io.File.stderr(), std.meta.activeTag(opts.static_mode) == .default);
        return;
    };

    switch (cmd) {
        .help => |topic| switch (topic) {
            .top => printUsage(init.io, std.Io.File.stdout(), std.meta.activeTag(opts.static_mode) == .default),
            .serve => printServeUsage(init.io, std.Io.File.stdout(), std.meta.activeTag(opts.static_mode) == .default),
            .migrate => printMigrateUsage(init.io, std.Io.File.stdout()),
            .superuser_create => printSuperuserUsage(init.io, std.Io.File.stdout()),
            .typegen => printTypegenUsage(init.io, std.Io.File.stdout()),
        },
        .version => printVersion(init.io, std.Io.File.stdout()),
        .serve => |sa| {
            const cfg = try loadCfg(init.environ_map, sa);
            try serveImpl(allocator, init.io, cfg, dispatch, jobs, pool_size, schema_collections, schema_migrations, opts, init.environ_map);
        },
        .migrate => |sa| try migrateImpl(allocator, init.io, init.environ_map, sa),
        .superuser_create => |sa| try superuserCreateImpl(allocator, init.io, init.environ_map, sa),
        .typegen => |ta| {
            if (opts.enable_typegen) {
                const tgen = @import("codegen/typegen_cli.zig");
                var arena_state = std.heap.ArenaAllocator.init(init.gpa);
                defer arena_state.deinit();
                const a = arena_state.allocator();
                const out = ta.out orelse {
                    std.log.err("typegen: --out <path> is required", .{});
                    return error.MissingOut;
                };
                try tgen.run(a, init.io, .{
                    .data_dir = ta.data_dir,
                    .url = ta.url,
                    .out = out,
                    .api_prefix = ta.api_prefix,
                    .client_name = ta.client_name,
                    .check = ta.check,
                    .in_repo = init.environ_map.contains("ZBASE_INREPO"),
                    .admin_email = ta.admin_email,
                    .admin_password = ta.admin_password,
                });
            } else {
                std.log.err("typegen: this binary was not built with .enable_typegen = true", .{});
                return;
            }
        },
    }
}

/// Emit `fmt` (with `args`) to `file` via a stack buffer, flushing after. Used by
/// the print* helpers so help/version go to stdout and argument errors go to stderr,
/// all without log-level/metadata prefixes that would clutter multi-section screens.
fn emit(io: std.Io, file: std.Io.File, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

/// Print the comprehensive top-level usage guide to stdout. We use emit()
/// (not std.log.info) so each line is emitted cleanly without log-level/metadata
/// prefixes, which keeps a multi-section help screen readable.
/// `show_serve_static` mirrors the parser gate: --serve-static is only listed in
/// the default comptime mode (in .disabled/.dir/.embedded it's an unknown flag).
fn printUsage(io: std.Io, file: std.Io.File, show_serve_static: bool) void {
    emit(io, file,
        \\zigbase — a single-binary backend (REST + WebSocket + admin UI)
        \\Docs & source: https://github.com/valthon/zigbase
        \\
        \\USAGE:
        \\  zigbase <command> [flags]
        \\
        \\COMMANDS:
        \\  serve               Start the HTTP server (REST + WebSocket + admin UI at /_/).
        \\  migrate             Apply database migrations, then exit.
        \\  superuser create    Create an admin (superuser) account.
        \\  help                Show this help. Also: --help, -h, or no arguments.
        \\  version             Print version + build provenance. Also: --version, -V.
        \\
        \\  Per-command help is available via `zigbase <command> --help`, e.g.
        \\  `zigbase serve --help` or `zigbase superuser create --help`.
        \\
        \\COMMON FLAGS (serve / migrate):
        \\  --http-host H       Address to bind (serve only). Default is loopback; pass
        \\                      0.0.0.0 to expose on all interfaces. [env ZIGBASE_HTTP_HOST, default 127.0.0.1]
        \\  --http-port N       TCP port to listen on (serve only). [env ZIGBASE_HTTP_PORT, default 8090]
        \\  --data-dir PATH     Directory for the SQLite db + file storage. [env ZIGBASE_DATA_DIR, default ./zb_data]
        \\  --insecure-cookies  Drop the Secure flag on auth cookies (serve only); for plain-HTTP
        \\                      local dev only. Cookies are Secure by default.
        \\  --trust-proxy       Trust X-Forwarded-For/X-Real-IP for client-IP/rate-limit keying
        \\                      (serve only). Set ONLY behind a trusted reverse proxy. [default off]
        \\  --realtime-origins CSV  Allowed WebSocket Origins (serve only). Empty denies cross-origin
        \\                      browser upgrades. [env ZIGBASE_REALTIME_ORIGINS]
        \\
    , .{});
    if (show_serve_static) emit(io, file,
        \\  --serve-static DIR  Serve static files from DIR at the root path (serve only;
        \\                      available unless the app hardcodes static files at comptime).
        \\
    , .{});
    emit(io, file,
        \\
        \\ENVIRONMENT VARIABLES:
        \\  ZIGBASE_JWT_SECRET        Token-signing secret (>= 32 bytes). When UNSET, a strong
        \\                           random secret is generated and persisted at
        \\                           <data-dir>/.jwt_secret (0600) on first run, then reused.
        \\                           A provided secret shorter than 32 bytes is refused. [default: auto-generate]
        \\  ZIGBASE_HTTP_HOST         Bind address; loopback by default. Set 0.0.0.0 to expose
        \\                           on all interfaces.              [default 127.0.0.1]
        \\  ZIGBASE_HTTP_PORT         Listen port.                   [default 8090]
        \\  ZIGBASE_DATA_DIR          Data directory (db + storage). [default ./zb_data]
        \\  ZIGBASE_COOKIE_SECURE     Secure flag on auth cookies (true/1). Secure by default; set
        \\                           false only for plain-HTTP local dev. [default true]
        \\  ZIGBASE_TRUST_PROXY       Trust X-Forwarded-For/X-Real-IP (true/1). Set ONLY behind a
        \\                           trusted reverse proxy.          [default false]
        \\  ZIGBASE_SENTRY_DSN        Sentry DSN for error reporting; empty logs errors to stderr.
        \\                           [default empty]
        \\  ZIGBASE_REALTIME_ORIGINS  CSV of allowed WebSocket Origins. Empty DENIES cross-origin
        \\                           browser upgrades.               [default empty]
        \\  ZIGBASE_MAX_UPLOAD_SIZE   Max request body for uploads, in bytes. [default 52428800 = 50 MiB]
        \\  ZIGBASE_AUTH_TOKEN_TTL    Auth token lifetime, seconds.  [default 1209600 = 14 days]
        \\  ZIGBASE_VERIFICATION_TTL  Email-verification token TTL, seconds. [default 604800 = 7 days]
        \\  ZIGBASE_PASSWORD_RESET_TTL Password-reset token TTL, seconds.    [default 3600 = 1 hour]
        \\  ZIGBASE_FILE_TOKEN_TTL    Short-lived file-access token TTL, seconds. [default 120 = 2 min]
        \\
        \\EXAMPLES:
        \\  # Create the first superuser (admin) account:
        \\  zigbase superuser create --email you@example.com --password "<a strong password>" --data-dir ./zb_data
        \\
        \\  # Serve locally (binds 127.0.0.1; a random JWT secret is generated + persisted):
        \\  zigbase serve --data-dir ./zb_data
        \\
        \\  # Local dev over plain HTTP (cookies are Secure by default, which won't send on http://):
        \\  zigbase serve --insecure-cookies --data-dir ./zb_data
        \\
        \\  # Expose on all interfaces (front with a firewall / reverse proxy):
        \\  zigbase serve --http-host 0.0.0.0 --http-port 9000 --trust-proxy --data-dir /var/lib/zigbase
        \\
        \\  # Apply pending migrations and exit:
        \\  zigbase migrate --data-dir ./zb_data
        \\
        \\After `serve` starts, open http://127.0.0.1:8090/_/ for the admin UI.
        \\More docs: README.md, docs/api.md, docs/framework.md, docs/tutorial.md.
        \\
    , .{});
}

/// Print build provenance (for `--version`) to stdout. emit() keeps it prefix-free.
fn printVersion(io: std.Io, file: std.Io.File) void {
    emit(io, file,
        \\zigbase {s}
        \\commit:  {s}
        \\build:   {s}
        \\target:  {s}-{s}-{s}
        \\zig:     {s}
        \\
    , .{
        build_options.version,
        build_options.commit,
        @tagName(builtin.mode),
        @tagName(builtin.target.cpu.arch),
        @tagName(builtin.target.os.tag),
        @tagName(builtin.target.abi),
        builtin.zig_version_string,
    });
}

fn printServeUsage(io: std.Io, file: std.Io.File, show_serve_static: bool) void {
    emit(io, file,
        \\zigbase serve — start the HTTP server (REST API + WebSocket + admin UI at /_/).
        \\
        \\USAGE:
        \\  zigbase serve [--http-host H] [--http-port N] [--data-dir PATH]
        \\                [--insecure-cookies] [--trust-proxy] [--realtime-origins CSV]{s}
        \\
        \\FLAGS:
        \\  --http-host H    Address to bind; loopback by default. Pass 0.0.0.0 for all
        \\                   interfaces.        [env ZIGBASE_HTTP_HOST, default 127.0.0.1]
        \\  --http-port N    TCP port to listen. [env ZIGBASE_HTTP_PORT, default 8090]
        \\  --data-dir PATH  SQLite db + file storage directory. [env ZIGBASE_DATA_DIR, default ./zb_data]
        \\  --insecure-cookies   Drop the Secure cookie flag (plain-HTTP local dev only).
        \\  --trust-proxy        Trust X-Forwarded-For/X-Real-IP (behind a trusted proxy only).
        \\  --realtime-origins CSV  Allowed WebSocket Origins; empty denies cross-origin upgrades.
        \\
    , .{if (show_serve_static) " [--serve-static DIR]" else ""});
    if (show_serve_static) emit(io, file,
        \\  --serve-static DIR  Serve static files from DIR at the root path (anything
        \\                      not matching /api/, /_/, or custom routes). [default: off]
        \\
    , .{});
    emit(io, file,
        \\KEY ENVIRONMENT VARIABLES:
        \\  ZIGBASE_JWT_SECRET      Token-signing secret (>= 32 bytes). When unset, a random secret
        \\                         is generated + persisted at <data-dir>/.jwt_secret (0600) on first run.
        \\  ZIGBASE_COOKIE_SECURE  Secure flag on auth cookies (true/1). Secure by default. [default true]
        \\  ZIGBASE_TRUST_PROXY    Trust X-Forwarded-For/X-Real-IP (true/1). [default false]
        \\  ZIGBASE_SENTRY_DSN     Sentry DSN for error reporting; empty logs to stderr.
        \\  (See `zigbase help` for the full list of ZIGBASE_* variables.)
        \\
        \\EXAMPLE:
        \\  zigbase serve --http-port 9000 --data-dir ./zb_data
        \\
    , .{});
}

fn printMigrateUsage(io: std.Io, file: std.Io.File) void {
    emit(io, file,
        \\zigbase migrate — apply pending database migrations, then exit.
        \\
        \\USAGE:
        \\  zigbase migrate [--data-dir PATH]
        \\
        \\FLAGS:
        \\  --data-dir PATH  SQLite db + file storage directory. [env ZIGBASE_DATA_DIR, default ./zb_data]
        \\
        \\Note: `zigbase serve` also runs migrations on startup; use `migrate` to apply
        \\them ahead of time (e.g. in a deploy step) without starting the server.
        \\
        \\EXAMPLE:
        \\  zigbase migrate --data-dir ./zb_data
        \\
    , .{});
}

fn printSuperuserUsage(io: std.Io, file: std.Io.File) void {
    emit(io, file,
        \\zigbase superuser create — create an admin (superuser) account.
        \\
        \\USAGE:
        \\  zigbase superuser create --email E --password P [--data-dir PATH]
        \\
        \\FLAGS:
        \\  --email E        Superuser email address (required).
        \\  --password P     Superuser password (required, at least 8 characters).
        \\  --data-dir PATH  SQLite db + file storage directory. [env ZIGBASE_DATA_DIR, default ./zb_data]
        \\
        \\Collection management and the admin UI at /_/ are superuser-only, so create one
        \\before configuring collections.
        \\
        \\EXAMPLE:
        \\  zigbase superuser create --email you@example.com --password "<a strong password>" --data-dir ./zb_data
        \\
    , .{});
}

fn loadCfg(environ: *const std.process.Environ.Map, sa: cli.ServeArgs) !config.Config {
    var cfg = try config.Config.load(config.EnvGetter{ .environ = environ });
    if (sa.http_host) |v| cfg.http_host = v;
    if (sa.http_port) |v| cfg.http_port = v;
    if (sa.data_dir) |v| cfg.data_dir = v;
    if (sa.serve_static) |v| cfg.static_dir = v;
    // Secure-by-default opt-outs/opt-ins (flags override toward the explicit choice).
    if (sa.insecure_cookies) cfg.cookie_secure = false;
    if (sa.trust_proxy) cfg.trust_proxy = true;
    if (sa.realtime_origins) |v| cfg.realtime_allowed_origins = v;
    return cfg;
}

fn openPool(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config, options: db.PoolOptions) !db.Pool {
    std.Io.Dir.cwd().createDirPath(io, cfg.data_dir) catch {};
    const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/data.db", .{cfg.data_dir}, 0);
    defer allocator.free(db_path);
    return db.Pool.initOpts(allocator, io, db_path, options);
}

fn migrateImpl(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, sa: cli.ServeArgs) !void {
    const cfg = try loadCfg(environ, sa);
    var pool = try openPool(allocator, io, cfg, .{});
    defer pool.deinit();
    const w = pool.acquireWriter();
    defer pool.releaseWriter();
    try migrations.run(w);
    std.log.info("migrations applied", .{});
}

/// Minimum acceptable length for an operator-provided JWT secret.
pub const min_jwt_secret_len = 32;
/// Filename (under the data dir) of the auto-generated, persisted JWT secret.
pub const jwt_secret_filename = ".jwt_secret";
/// Length (chars) of an auto-generated JWT secret. 64 base36 chars ~= 331 bits.
const generated_jwt_secret_len = 64;

/// Resolve the effective JWT secret (F6/F12). Three cases:
///   - operator provided a secret (`cfg.jwt_secret` non-empty): use it, but REFUSE
///     to start if it is shorter than `min_jwt_secret_len` (the old shared
///     "dev-insecure-secret-change-me" default is gone — "unset" means auto-generate).
///   - unset (empty) and `<data_dir>/.jwt_secret` exists: reuse the persisted secret.
///   - unset and no file: generate a strong random secret, persist it 0600, use it.
/// The returned slice is owned by `allocator` (caller frees). Never logs the secret.
fn resolveJwtSecret(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config) ![]const u8 {
    if (cfg.jwt_secret.len > 0) {
        if (cfg.jwt_secret.len < min_jwt_secret_len) {
            std.log.err("refusing to start: ZIGBASE_JWT_SECRET is too short ({d} bytes); use at least {d} bytes", .{ cfg.jwt_secret.len, min_jwt_secret_len });
            return error.WeakJwtSecret;
        }
        return allocator.dupe(u8, cfg.jwt_secret);
    }
    // Unset: persist a per-deployment secret under the data dir so "unset" is never
    // a shared, guessable default. Ensure the data dir exists first.
    std.Io.Dir.cwd().createDirPath(io, cfg.data_dir) catch {};
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cfg.data_dir, jwt_secret_filename });
    defer allocator.free(path);
    if (std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096))) |existing| {
        const trimmed = std.mem.trim(u8, existing, " \t\r\n");
        if (trimmed.len >= min_jwt_secret_len) {
            // Re-own just the trimmed bytes so the caller's free matches the alloc.
            const owned = try allocator.dupe(u8, trimmed);
            allocator.free(existing);
            std.log.info("using persisted JWT secret from {s}/{s}", .{ cfg.data_dir, jwt_secret_filename });
            return owned;
        }
        allocator.free(existing);
        std.log.warn("persisted JWT secret at {s}/{s} is too short; regenerating", .{ cfg.data_dir, jwt_secret_filename });
    } else |err| switch (err) {
        error.FileNotFound => {}, // first run: fall through to generate
        else => return err,
    }
    const secret = try @import("crypto.zig").genToken(io, allocator, generated_jwt_secret_len);
    // Write 0600 (owner read/write only). createFile truncates by default.
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = secret,
        .flags = .{ .permissions = std.Io.File.Permissions.fromMode(0o600) },
    }) catch |err| {
        allocator.free(secret);
        std.log.err("could not persist generated JWT secret to {s}: {s}", .{ path, @errorName(err) });
        return err;
    };
    std.log.info("generated a new random JWT secret and persisted it to {s}/{s} (0600)", .{ cfg.data_dir, jwt_secret_filename });
    return secret;
}

fn serveImpl(allocator: std.mem.Allocator, io: std.Io, cfg_in: config.Config, dispatch: *const events.Dispatch, jobs: []const scheduler.RuntimeJob, pool_size: usize, schema_collections: []const schema.Collection, schema_migrations: []const provision.Migration, comptime opts: ServeOpts, environ: *const std.process.Environ.Map) !void {
    var cfg = cfg_in;
    const jwt_secret = try resolveJwtSecret(allocator, io, cfg);
    defer allocator.free(jwt_secret);
    cfg.jwt_secret = jwt_secret;
    // Install the dev-only frozen clock (ZIGBASE_FAKE_NOW) so every framework "now" — token
    // expiry, scheduling, challenge/cursor TTLs — reads the override. No-op + null on a prod
    // build (the gate is comptime-off; see clock.zig).
    clock.install(cfg.fake_now_unix);
    if (std.mem.eql(u8, cfg.http_host, "0.0.0.0") or std.mem.eql(u8, cfg.http_host, "::")) {
        std.log.warn("binding to all interfaces ({s}); ensure a firewall/reverse proxy is in front (default is loopback 127.0.0.1)", .{cfg.http_host});
    }
    if (cfg.realtime_allowed_origins.len == 0) {
        std.log.info("realtime: no allowed Origins configured; cross-origin browser WebSocket upgrades are DENIED (set ZIGBASE_REALTIME_ORIGINS)", .{});
    }
    var pool = try openPool(allocator, io, cfg, .{ .reader_cap = opts.reader_pool_size, .cache_kib = opts.cache_kib });
    defer pool.deinit();
    // Transparent at-rest field encryption (Theme B1). Resolve the cipher ONCE from
    // ZIGBASE_FIELD_KEY and stamp it onto the pool so every acquired connection carries
    // it (db.zig). FAIL-CLOSED: if any collection declares an `.encrypted` field but no
    // key is configured, refuse to start rather than silently storing plaintext. The
    // cipher is a serveImpl stack var that outlives srv.listen(); pool points at it.
    var field_cipher: field_policy.Cipher = undefined;
    if (cfg.field_key.len > 0) {
        field_cipher = field_policy.Cipher.fromEnv(io, cfg.field_key);
        pool.field_cipher = @ptrCast(&field_cipher);
    } else if (anyEncryptedField(schema_collections)) {
        std.log.err("refusing to start: a collection declares an .encrypted field but ZIGBASE_FIELD_KEY is not set (encrypted data would be unreadable / stored as plaintext)", .{});
        return error.FieldKeyRequired;
    }
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try migrations.run(w);
        // Comptime-schema provisioning. When `.collections`/`.migrations` are absent
        // both slices are empty, so this whole block is a no-op and the binary behaves
        // exactly as before the feature. Otherwise: run the explicit escape-hatch
        // migrations (once each, recorded in _migrations), then idempotently provision
        // the comptime collections (create-missing + additive field-add + name->id
        // relation resolution; destructive diffs are logged and skipped).
        if (schema_migrations.len > 0) {
            try provision.runMigrations(allocator, io, w, schema_migrations);
        }
        if (schema_collections.len > 0) {
            // injectOAuthSecrets allocates a rewritten collections slice (+ provider arrays
            // and encrypted secret strings) only needed through provisioning; applySpecs
            // persists the encrypted secret into the DB. Scope those in an arena so they are
            // freed after provisioning instead of leaking once at startup (the e2e
            // leak-checker flags the leak).
            var prov_arena = std.heap.ArenaAllocator.init(allocator);
            defer prov_arena.deinit();
            const resolved = try provision.injectOAuthSecrets(
                prov_arena.allocator(), io, jwt_secret,
                config.EnvGetter{ .environ = environ },
                schema_collections,
            );
            try provision.applySpecs(allocator, io, w, resolved);
        }
        // Stateful cursor mode accumulates rows in `_cursorStates`; sweep expired entries at
        // startup. (Lookups already ignore expired rows, so this is purely space reclamation.)
        // For long-lived servers, schedule `records.gcCursorStates` on a `.cron` interval too.
        if (opts.pagination.cursor_token == .stateful) {
            @import("records.zig").gcCursorStates(w) catch |e| std.log.warn("cursor-state GC at startup failed: {s}", .{@errorName(e)});
        }
        // Sweep expired and consumed auth challenge entries at startup. This is purely space
        // reclamation; both `take` paths already reject expired/consumed rows at query time.
        @import("auth/challenge_store.zig").gcAuthChallenges(w) catch |e| std.log.warn("auth-challenge GC at startup failed: {s}", .{@errorName(e)});
        // One-shot TTL sweep at startup (the periodic `_ttl_gc` job handles the rest). Only
        // compiled in when the comptime schema declares at least one `.ttl_field`.
        if (opts.has_ttl) {
            var ttl_arena = std.heap.ArenaAllocator.init(allocator);
            defer ttl_arena.deinit();
            _ = @import("records.zig").gcExpiredRecords(ttl_arena.allocator(), w) catch |e| std.log.warn("TTL GC at startup failed: {s}", .{@errorName(e)});
        }
    }
    // Instantiate the comptime-selected storage + mailer plugins. The instances are
    // serveImpl stack vars that outlive the server (srv.listen() runs to shutdown),
    // and the vtable handles below point at them.
    var storage_inst = try opts.StoragePlugin.create(allocator, io, cfg);
    defer storage_inst.deinit();
    const storage_iface = storage_inst.interface();

    var mailer_inst = try opts.MailerPlugin.create(allocator, io, cfg);
    defer mailer_inst.deinit();
    const mailer_iface = mailer_inst.interface();

    // Instantiate the comptime-assembled auth method registry. `am_insts` and `am_views`
    // are serveImpl stack vars that outlive the server (like storage/mailer). The Registry
    // value points into `am_views`, so all three must remain in scope across srv.listen().
    const am_types = comptime opts.auth_method_types;
    var am_insts: registry.Instances(am_types) = undefined;
    var am_views: [am_types.len]@import("auth/method.zig").AuthMethod = undefined;
    var am_registry = try registry.build(am_types, &am_insts, &am_views, allocator, io, cfg);
    defer registry.deinit(am_types, &am_insts);

    // In-memory rate limiter for sensitive auth endpoints. A serveImpl stack var that
    // outlives the server (like storage/mailer); skipped entirely when disabled.
    var rate_limiter = ratelimit.RateLimiter.init(allocator, cfg.rate_limit_max, cfg.rate_limit_window_s);
    defer rate_limiter.deinit();

    // Resolve the static-file source from the comptime mode (+ --serve-static in
    // default mode). A configured-but-missing dir is a fatal startup error.
    const static_source: static_files.Source = switch (opts.static_mode) {
        .disabled => .none,
        .dir => |d| .{ .dir = d },
        .embedded => |files| .{ .embedded = files },
        .default => if (cfg.static_dir.len > 0) static_files.Source{ .dir = cfg.static_dir } else .none,
    };
    switch (static_source) {
        .dir => |dir_path| {
            const probe = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch {
                std.log.err("static dir '{s}' is missing or unreadable (from {s})", .{
                    dir_path,
                    if (std.meta.activeTag(opts.static_mode) == .dir) "comptime .static_files" else "--serve-static",
                });
                return error.StaticDirUnavailable;
            };
            probe.close(io);
        },
        else => {},
    }

    var app = app_mod.App{
        .allocator = allocator,
        .io = io,
        .pool = &pool,
        .jwt_secret = cfg.jwt_secret,
        .public_url = cfg.public_url,
        .cookie_secure = cfg.cookie_secure,
        .auth_token_ttl_s = cfg.auth_token_ttl_s,
        .verification_ttl_s = cfg.verification_ttl_s,
        .password_reset_ttl_s = cfg.password_reset_ttl_s,
        .oauth_state_server = cfg.oauth_state_server,
        .oauth_state_ttl_s = cfg.oauth_state_ttl_s,
        .realtime_allowed_origins = cfg.realtime_allowed_origins,
        .trust_proxy = cfg.trust_proxy,
        .max_upload_size = cfg.max_upload_size,
        .file_token_ttl_s = cfg.file_token_ttl_s,
        .sentry_dsn = cfg.sentry_dsn,
        .static_source = static_source,
        .pagination = .{
            .offset_enabled = opts.pagination.offset,
            .cursor_enabled = opts.pagination.cursor,
            .cursor_token = opts.pagination.cursor_token,
        },
        .storage = &storage_iface,
        .mailer = &mailer_iface,
        .auth_methods = @ptrCast(&am_registry),
        .dispatch = dispatch,
        .rate_limiter = if (cfg.rate_limit_max == 0) null else &rate_limiter,
    };
    const Ctx = @import("ctx.zig").Ctx;
    // Each lifecycle hook gets a per-invocation arena owning any ctx.records()
    // results, declared before cx so its deinit runs last (LIFO).
    if (dispatch.on_bootstrap) |h| {
        var ev = events.LifecycleEvent{ .app = &app };
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var cx = Ctx{ .app = &app, .arena = arena.allocator(), .rctx = .{}, .request = null, .bound_conn = null };
        defer cx.deinit();
        h(&cx, &ev);
    }
    if (dispatch.on_before_serve) |h| {
        var ev = events.LifecycleEvent{ .app = &app };
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var cx = Ctx{ .app = &app, .arena = arena.allocator(), .rctx = .{}, .request = null, .bound_conn = null };
        defer cx.deinit();
        h(&cx, &ev);
    }
    // before_terminate fires when listen() returns (graceful shutdown / error).
    defer if (dispatch.on_before_terminate) |h| {
        var ev = events.LifecycleEvent{ .app = &app };
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var cx = Ctx{ .app = &app, .arena = arena.allocator(), .rctx = .{}, .request = null, .bound_conn = null };
        defer cx.deinit();
        h(&cx, &ev);
    };
    const host_z = try allocator.dupeZ(u8, cfg.http_host);
    defer allocator.free(host_z);
    var srv = server.Server{ .app = &app, .host = host_z, .port = cfg.http_port };
    // Start the scheduler only when jobs are configured. Registered LAST among the teardown
    // defers, so (LIFO) its stop()+deinit() runs FIRST on return — joining worker threads
    // before pool.deinit()/storage_inst go out of scope, since workers touch app.pool/storage.
    var sched: ?scheduler.Scheduler = if (jobs.len > 0) try scheduler.Scheduler.initSized(allocator, &app, jobs, pool_size, opts.job_stack_size) else null;
    if (sched) |*s| try s.start();
    defer if (sched) |*s| {
        s.stop();
        s.deinit();
    };
    try srv.listen();
}

fn superuserCreateImpl(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, sa: cli.SuperuserArgs) !void {
    const email = sa.email orelse {
        std.log.err("--email is required", .{});
        return;
    };
    const password = sa.password orelse {
        std.log.err("--password is required", .{});
        return;
    };
    if (password.len < 8) {
        std.log.err("password must be at least 8 characters", .{});
        return;
    }
    const cfg = try loadCfg(environ, .{ .data_dir = sa.data_dir });
    var pool = try openPool(allocator, io, cfg, .{});
    defer pool.deinit();
    const w = pool.acquireWriter();
    defer pool.releaseWriter();
    try migrations.run(w);

    const phc = try crypto.hashPassword(io, allocator, password);
    defer allocator.free(phc);
    const tk = try crypto.genToken(io, allocator, 32);
    defer allocator.free(tk);
    var rid = id_gen.collectionId(io);

    var st = try w.prepare(
        \\INSERT INTO "_superusers" ("id","created","updated","email","username","passwordHash","tokenKey","verified")
        \\ VALUES (?1, datetime('now'), datetime('now'), ?2, '', ?3, ?4, 1);
    );
    defer st.finalize();
    try st.bindText(1, &rid);
    try st.bindText(2, email);
    try st.bindText(3, phc);
    try st.bindText(4, tk);
    _ = st.step() catch {
        std.log.err("could not create superuser (email already exists?)", .{});
        return;
    };
    std.log.info("superuser created: {s}", .{email});
}

fn printTypegenUsage(io: std.Io, file: std.Io.File) void {
    emit(io, file,
        \\Usage: <app> typegen (--data-dir <path> | --url <origin>) --out <file>
        \\                     [--api-prefix <prefix>] [--client-name <name>] [--check]
        \\                     [--admin-email <e> --admin-password <p>]   (with --url)
        \\
        \\Generates a typed TypeScript client from a running instance's schema.
        \\
    , .{});
}

test "App(cfg) builds a record dispatcher only when hooks are present" {
    const Empty = App(.{});
    try std.testing.expect(Empty.dispatch.record == null);

    const H = struct {
        fn f(ctx: *@import("ctx.zig").Ctx, ev: *@import("events.zig").RecordEvent) anyerror!void {
            _ = ctx;
            _ = ev;
        }
    };
    const WithHook = App(.{ .hooks = .{ .posts = .{ .afterCreate = H.f } } });
    try std.testing.expect(WithHook.dispatch.record != null);
}

test "App(cfg) assembles custom routes onto dispatch" {
    const route_types = @import("route_types.zig");
    const H = struct {
        fn h(req: *route_types.Req(void)) route_types.RouteError!void {
            _ = req;
        }
    };
    const A = App(.{ .routes = .{ .{ .method = .GET, .path = "/api/x", .handler = H.h, .auth = .public } } });
    try std.testing.expectEqual(@as(usize, 1), A.dispatch.routes.len);
    try std.testing.expectEqualStrings("/api/x", A.dispatch.routes[0].pattern);
}

test "App(.{}) has no routes and null lifecycle/auth/file handlers" {
    const A = App(.{});
    try std.testing.expectEqual(@as(usize, 0), A.dispatch.routes.len);
    try std.testing.expect(A.dispatch.on_auth == null);
    try std.testing.expect(A.dispatch.on_bootstrap == null);
}

test "App(cfg) exposes the comptime job table and pool size" {
    const H = struct {
        fn j(ctx: *@import("ctx.zig").Ctx, ev: *@import("events.zig").JobEvent) anyerror!void {
            _ = ctx;
            _ = ev;
        }
    };
    const A = App(.{
        .jobs = .{ .pool_size = 3 },
        .cron = .{.{ .name = "n", .schedule = @import("schedule.zig").Schedule{ .interval = .hourly }, .handler = H.j }},
    });
    try std.testing.expectEqual(@as(usize, 1), A.jobs.len);
    try std.testing.expectEqual(@as(usize, 3), A.job_pool_size);
    const B = App(.{});
    try std.testing.expectEqual(@as(usize, 0), B.jobs.len);
    try std.testing.expectEqual(@as(usize, 2), B.job_pool_size); // default pool size
}

test "App(cfg) registers the internal _ttl_gc job when a collection opts into TTL" {
    // No TTL collection => no internal job, scheduler stays off (jobs empty).
    const Plain = App(.{
        .collections = .{
            .posts = .{ .fields = .{.{ .name = "title", .type = .text }} },
        },
    });
    try std.testing.expect(!Plain.has_ttl_collection);
    try std.testing.expectEqual(@as(usize, 0), Plain.jobs.len);

    // A TTL collection => has_ttl flag set and a single internal `_ttl_gc` job appended.
    const Ttl = App(.{
        .collections = .{
            .sessions = .{ .fields = .{
                .{ .name = "token", .type = .text },
                .{ .name = "expires_at", .type = .date },
            }, .ttl_field = "expires_at" },
        },
    });
    try std.testing.expect(Ttl.has_ttl_collection);
    try std.testing.expectEqual(@as(usize, 1), Ttl.jobs.len);
    try std.testing.expectEqualStrings("_ttl_gc", Ttl.jobs[0].name);
    try std.testing.expect(Ttl.jobs[0].schedule == .interval);
}

test "App(.{}) resolves the default storage + mailer plugins and reader pool" {
    const A = App(.{});
    try std.testing.expectEqual(DefaultStoragePlugin, A.StoragePlugin);
    try std.testing.expectEqual(DefaultMailerPlugin, A.MailerPlugin);
    try std.testing.expectEqual(@as(usize, 16), A.reader_pool_size);
}

test "DefaultMailerPlugin selects Command > SMTP > Log by config" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    // Default config → LogMailer (no SMTP host, no sendmail command).
    {
        var p = try DefaultMailerPlugin.create(a, io, .{});
        defer p.deinit();
        try std.testing.expect(p.command_backend == null);
        try std.testing.expect(p.smtp_backend == null);
    }
    // SMTP host set, no sendmail command → SmtpMailer.
    {
        var p = try DefaultMailerPlugin.create(a, io, .{ .smtp_host = "smtp.example.com" });
        defer p.deinit();
        try std.testing.expect(p.command_backend == null);
        try std.testing.expect(p.smtp_backend != null);
    }
    // sendmail command wins even when SMTP is also configured; argv is split on
    // whitespace and From: defaults from smtp_from.
    {
        var p = try DefaultMailerPlugin.create(a, io, .{
            .smtp_host = "smtp.example.com",
            .sendmail_command = "  msmtp   -t ",
            .smtp_from = "ops@zigbase.dev",
        });
        defer p.deinit();
        try std.testing.expect(p.smtp_backend == null);
        const c = p.command_backend.?;
        try std.testing.expectEqual(@as(usize, 2), c.argv.len);
        try std.testing.expectEqualStrings("msmtp", c.argv[0]);
        try std.testing.expectEqualStrings("-t", c.argv[1]);
        try std.testing.expectEqualStrings("ops@zigbase.dev", c.from);
    }
}

test "App(cfg) carries comptime pool-size levers (readers + jobs)" {
    const A = App(.{ .pools = .{ .readers = 4, .jobs = 2 } });
    try std.testing.expectEqual(@as(usize, 4), A.reader_pool_size);
    try std.testing.expectEqual(@as(usize, 2), A.job_pool_size);
    // readers-only lever; jobs default preserved.
    const B = App(.{ .pools = .{ .readers = 8 } });
    try std.testing.expectEqual(@as(usize, 8), B.reader_pool_size);
    try std.testing.expectEqual(@as(usize, 2), B.job_pool_size);
}

test "App(cfg) carries comptime footprint levers (stack_size + cache_kib) with memory-conscious defaults" {
    // Defaults: 1 MiB job-thread stacks (vs std.Thread's 16 MiB) and 1024 KiB page cache.
    const D = App(.{});
    try std.testing.expectEqual(scheduler.default_job_stack_size, D.job_stack_size);
    try std.testing.expectEqual(@as(usize, 1 << 20), D.job_stack_size);
    try std.testing.expectEqual(db.default_cache_kib, D.cache_kib);
    try std.testing.expectEqual(@as(u32, 1024), D.cache_kib);

    // Both tunable via .pools, independently of the other levers. stack_size RAISES
    // above the 1 MiB default (its real use — deeper handlers); cache_kib shrinks freely.
    const A = App(.{ .pools = .{ .stack_size = 2 << 20, .cache_kib = 256 } });
    try std.testing.expectEqual(@as(usize, 2 << 20), A.job_stack_size);
    try std.testing.expectEqual(@as(u32, 256), A.cache_kib);
    // A below-floor stack request is clamped UP to the safe floor (can't crash the server).
    const C = App(.{ .pools = .{ .stack_size = 64 << 10 } });
    try std.testing.expectEqual(scheduler.min_job_stack_size, C.job_stack_size);
    // Untouched levers keep their defaults alongside the tuned ones.
    try std.testing.expectEqual(@as(usize, 16), A.reader_pool_size);
    try std.testing.expectEqual(@as(usize, 2), A.job_pool_size);
}

test "App(cfg) accepts a custom storage + mailer plugin type override" {
    const MyStorage = struct {
        backend: files_storage.LocalStorage = files_storage.LocalStorage.init("/tmp/x"),
        pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config) !@This() {
            _ = gpa;
            _ = io;
            _ = cfg;
            return .{};
        }
        pub fn interface(self: *@This()) files_storage.Storage {
            return self.backend.storage();
        }
        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };
    const A = App(.{ .storage = MyStorage, .mailer = DefaultMailerPlugin });
    try std.testing.expectEqual(MyStorage, A.StoragePlugin);
    try std.testing.expectEqual(DefaultMailerPlugin, A.MailerPlugin);
}

test "App(cfg) lowers .collections into comptime specs; name-based relation kept by name" {
    const A = App(.{ .collections = .{
        .users = .{ .type = .auth, .fields = .{
            .{ .name = "display_name", .type = .text },
        } },
        .posts = .{ .fields = .{
            .{ .name = "title", .type = .text, .required = true },
            .{ .name = "author", .type = .relation, .target = "users" },
            .{ .name = "status", .type = .select, .values = .{ "draft", "published" } },
        }, .rules = .{ .list = "status = \"published\"" } },
    } });
    try std.testing.expectEqual(@as(usize, 2), A.collections.len);
    try std.testing.expectEqualStrings("users", A.collections[0].name);
    try std.testing.expectEqual(schema.CollectionType.auth, A.collections[0].type);
    try std.testing.expectEqualStrings("posts", A.collections[1].name);
    try std.testing.expect(A.collections[1].fields[0].required);
    // relation target stored BY NAME at comptime (resolved to id at provisioning)
    try std.testing.expectEqualStrings("users", A.collections[1].fields[1].options.relation.targetCollectionId);
    try std.testing.expectEqualStrings("status = \"published\"", A.collections[1].listRule.?);
    // stable, 8-char field ids
    try std.testing.expectEqual(@as(usize, 8), A.collections[1].fields[0].id.len);
}

test "App(.{}) has no comptime collections and no provision migrations" {
    const A = App(.{});
    try std.testing.expectEqual(@as(usize, 0), A.collections.len);
    try std.testing.expectEqual(@as(usize, 0), A.provision_migrations.len);
}

test "App(cfg) resolves the comptime pagination config (defaults + overrides)" {
    // Stock binary: both modes on, stateless tokens.
    const D = App(.{});
    try std.testing.expect(D.pagination_config.offset);
    try std.testing.expect(D.pagination_config.cursor);
    try std.testing.expectEqual(pagination.CursorToken.stateless, D.pagination_config.cursor_token);

    // Token-format selector + enable/disable.
    const S = App(.{ .pagination = .{ .cursor_token = .signed } });
    try std.testing.expectEqual(pagination.CursorToken.signed, S.pagination_config.cursor_token);

    const C = App(.{ .pagination = .{ .offset = false, .cursor_token = .stateful } });
    try std.testing.expect(!C.pagination_config.offset);
    try std.testing.expect(C.pagination_config.cursor);
    try std.testing.expectEqual(pagination.CursorToken.stateful, C.pagination_config.cursor_token);
}

test "App(cfg) static_files modes: default, disabled, dir, embedded (with coercion)" {
    try std.testing.expectEqual(static_files.Mode.default, std.meta.activeTag(App(.{}).static_mode));
    try std.testing.expectEqual(static_files.Mode.disabled, std.meta.activeTag(App(.{ .static_files = .disabled }).static_mode));

    const D = App(.{ .static_files = .{ .dir = "frontend/dist" } });
    try std.testing.expectEqual(static_files.Mode.dir, std.meta.activeTag(D.static_mode));
    try std.testing.expectEqualStrings("frontend/dist", D.static_mode.dir);

    const manifest = struct {
        const F = struct { path: []const u8, bytes: []const u8, etag: []const u8 };
        pub const files = [_]F{.{ .path = "index.html", .bytes = "<p>hi</p>", .etag = "\"abc\"" }};
    };
    const E = App(.{ .static_files = .{ .embedded = &manifest.files } });
    try std.testing.expectEqual(static_files.Mode.embedded, std.meta.activeTag(E.static_mode));
    try std.testing.expectEqual(@as(usize, 1), E.static_mode.embedded.len);
    try std.testing.expectEqualStrings("index.html", E.static_mode.embedded[0].path);
    try std.testing.expectEqualStrings("\"abc\"", E.static_mode.embedded[0].etag);
}

test "App exposes route metadata for codegen" {
    const route_types = @import("route_types.zig");
    const In = struct { n: u32 };
    const TestApp = App(.{
        .routes = .{
            .{
                .method = .POST, .path = "/api/widgets/:id/poke",
                .auth = .authed,
                .handler = struct {
                    fn h(req: *route_types.Req(In)) route_types.RouteError!void { _ = req; }
                }.h,
            },
        },
    });
    try std.testing.expectEqual(@as(usize, 1), TestApp.routes.len);
    try std.testing.expectEqualStrings("widgetsPoke", TestApp.routes[0].name);
    try std.testing.expect(TestApp.routes[0].Input == In);
}

test "anyEncryptedField detects an .encrypted field (drives the startup fail-closed guard)" {
    const none = [_]schema.Collection{.{ .id = "c1", .name = "a", .fields = &[_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
    } }};
    try std.testing.expect(!anyEncryptedField(&none));
    const some = [_]schema.Collection{.{ .id = "c2", .name = "b", .fields = &[_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "secret", .encrypted = true, .options = .{ .text = .{} } },
    } }};
    try std.testing.expect(anyEncryptedField(&some));
}
