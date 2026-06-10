const std = @import("std");
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

/// Comptime application builder. `cfg` is an anonymous struct VALUE with optional
/// `.hooks` (record hook groups) and optional `.onError` (an ErrorHandler).
/// Returns a type exposing the prebuilt `dispatch` and the CLI/serve entry points.
pub fn App(comptime cfg: anytype) type {
    return struct {
        /// Prebuilt at comptime; the runtime app holds a pointer to it (static lifetime).
        pub const dispatch: events.Dispatch = blk: {
            // Guard top-level cfg keys so a typo (e.g. `.hook`, `.on_error`) fails
            // loudly at comptime instead of silently producing an empty Dispatch.
            const allowed = .{ "hooks", "onError", "routes", "onAuth", "onFileServe", "onFileUpload", "onBootstrap", "onBeforeServe", "onBeforeTerminate", "cron", "jobs" };
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
            if (@hasField(@TypeOf(cfg), "onFileServe")) d.on_file_serve = cfg.onFileServe;
            if (@hasField(@TypeOf(cfg), "onFileUpload")) d.on_file_upload = cfg.onFileUpload;
            if (@hasField(@TypeOf(cfg), "onBootstrap")) d.on_bootstrap = cfg.onBootstrap;
            if (@hasField(@TypeOf(cfg), "onBeforeServe")) d.on_before_serve = cfg.onBeforeServe;
            if (@hasField(@TypeOf(cfg), "onBeforeTerminate")) d.on_before_terminate = cfg.onBeforeTerminate;
            break :blk d;
        };

        /// The comptime-assembled cron/interval/reactive job table (empty when no `.cron`).
        pub const jobs: []const scheduler.RuntimeJob = if (@hasField(@TypeOf(cfg), "cron")) scheduler.buildJobs(cfg.cron) else &.{};
        /// Worker pool size for the scheduler (defaults to 2 when `.jobs.pool_size` is unset).
        pub const job_pool_size: usize = if (@hasField(@TypeOf(cfg), "jobs") and @hasField(@TypeOf(cfg.jobs), "pool_size")) cfg.jobs.pool_size else 2;

        /// Parse argv and dispatch the CLI (serve / migrate / superuser create / help),
        /// wiring this app's `dispatch` into the runtime context for `serve`.
        pub fn runCli(init: std.process.Init) !void {
            return runCliImpl(init, &dispatch, jobs, job_pool_size);
        }

        /// Start the HTTP server directly with an explicit config (no CLI parsing).
        pub fn run(init: std.process.Init, cfg_runtime: config.Config) !void {
            return serveImpl(init.gpa, init.io, cfg_runtime, &dispatch, jobs, job_pool_size);
        }
    };
}

/// Zig 0.16 entry point body: parse argv from `init.minimal.args` and dispatch.
fn runCliImpl(init: std.process.Init, dispatch: *const events.Dispatch, jobs: []const scheduler.RuntimeJob, pool_size: usize) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(arena);
    // cli.parse wants []const []const u8; argv is []const [:0]const u8. Copy
    // the (sentinel-bearing) slices into plain []const u8 views.
    const args = try arena.alloc([]const u8, argv.len);
    for (argv, 0..) |a, i| args[i] = a;

    const cmd = cli.parse(args[1..]) catch |err| {
        std.log.err("argument error: {s}", .{@errorName(err)});
        printUsage();
        return;
    };

    switch (cmd) {
        .help => |topic| switch (topic) {
            .top => printUsage(),
            .serve => printServeUsage(),
            .migrate => printMigrateUsage(),
            .superuser_create => printSuperuserUsage(),
        },
        .serve => |sa| {
            const cfg = try loadCfg(sa);
            try serveImpl(allocator, init.io, cfg, dispatch, jobs, pool_size);
        },
        .migrate => |sa| try migrateImpl(allocator, init.io, sa),
        .superuser_create => |sa| try superuserCreateImpl(allocator, init.io, sa),
    }
}

/// Print the comprehensive top-level usage guide to stderr. We use std.debug.print
/// (not std.log.info) so each line is emitted cleanly without log-level/metadata
/// prefixes, which keeps a multi-section help screen readable.
fn printUsage() void {
    std.debug.print(
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
        \\
        \\  Per-command help is available via `zigbase <command> --help`, e.g.
        \\  `zigbase serve --help` or `zigbase superuser create --help`.
        \\
        \\COMMON FLAGS (serve / migrate):
        \\  --http-host H       Address to bind (serve only).      [env ZIGBASE_HTTP_HOST, default 0.0.0.0]
        \\  --http-port N       TCP port to listen on (serve only). [env ZIGBASE_HTTP_PORT, default 8090]
        \\  --data-dir PATH     Directory for the SQLite db + file storage. [env ZIGBASE_DATA_DIR, default ./zb_data]
        \\
        \\ENVIRONMENT VARIABLES:
        \\  ZIGBASE_JWT_SECRET        Token-signing secret. REQUIRED in production; the server
        \\                           refuses to start with the insecure default when cookies are
        \\                           secure.                         [default dev-insecure-secret-change-me]
        \\  ZIGBASE_HTTP_HOST         Bind address.                  [default 0.0.0.0]
        \\  ZIGBASE_HTTP_PORT         Listen port.                   [default 8090]
        \\  ZIGBASE_DATA_DIR          Data directory (db + storage). [default ./zb_data]
        \\  ZIGBASE_COOKIE_SECURE     Set the Secure flag on auth cookies (true/1). Enable behind
        \\                           HTTPS.                          [default false]
        \\  ZIGBASE_SENTRY_DSN        Sentry DSN for error reporting; empty logs errors to stderr.
        \\                           [default empty]
        \\  ZIGBASE_REALTIME_ORIGINS  CSV of allowed WebSocket Origins; empty allows any (dev).
        \\                           [default empty]
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
        \\  # Serve with a fresh random JWT secret (recommended):
        \\  ZIGBASE_JWT_SECRET="$(head -c 32 /dev/urandom | base64)" zigbase serve --data-dir ./zb_data
        \\
        \\  # Serve on a custom host/port/data-dir:
        \\  zigbase serve --http-host 127.0.0.1 --http-port 9000 --data-dir /var/lib/zigbase
        \\
        \\  # Apply pending migrations and exit:
        \\  zigbase migrate --data-dir ./zb_data
        \\
        \\After `serve` starts, open http://127.0.0.1:8090/_/ for the admin UI.
        \\More docs: README.md, docs/api.md, docs/framework.md, docs/tutorial.md.
        \\
    , .{});
}

fn printServeUsage() void {
    std.debug.print(
        \\zigbase serve — start the HTTP server (REST API + WebSocket + admin UI at /_/).
        \\
        \\USAGE:
        \\  zigbase serve [--http-host H] [--http-port N] [--data-dir PATH]
        \\
        \\FLAGS:
        \\  --http-host H    Address to bind.    [env ZIGBASE_HTTP_HOST, default 0.0.0.0]
        \\  --http-port N    TCP port to listen. [env ZIGBASE_HTTP_PORT, default 8090]
        \\  --data-dir PATH  SQLite db + file storage directory. [env ZIGBASE_DATA_DIR, default ./zb_data]
        \\
        \\KEY ENVIRONMENT VARIABLES:
        \\  ZIGBASE_JWT_SECRET      Token-signing secret. REQUIRED in production; the server refuses
        \\                         to start with the insecure default while ZIGBASE_COOKIE_SECURE is on.
        \\  ZIGBASE_COOKIE_SECURE  Secure flag on auth cookies (true/1). Enable behind HTTPS. [default false]
        \\  ZIGBASE_SENTRY_DSN     Sentry DSN for error reporting; empty logs to stderr.
        \\  (See `zigbase help` for the full list of ZIGBASE_* variables.)
        \\
        \\EXAMPLE:
        \\  ZIGBASE_JWT_SECRET="$(head -c 32 /dev/urandom | base64)" zigbase serve --http-port 9000 --data-dir ./zb_data
        \\
    , .{});
}

fn printMigrateUsage() void {
    std.debug.print(
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

fn printSuperuserUsage() void {
    std.debug.print(
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

fn loadCfg(sa: cli.ServeArgs) !config.Config {
    var cfg = try config.Config.load(&config.envGetter);
    if (sa.http_host) |v| cfg.http_host = v;
    if (sa.http_port) |v| cfg.http_port = v;
    if (sa.data_dir) |v| cfg.data_dir = v;
    return cfg;
}

fn openPool(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config) !db.Pool {
    std.Io.Dir.cwd().createDirPath(io, cfg.data_dir) catch {};
    const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/data.db", .{cfg.data_dir}, 0);
    defer allocator.free(db_path);
    return db.Pool.init(allocator, db_path);
}

fn migrateImpl(allocator: std.mem.Allocator, io: std.Io, sa: cli.ServeArgs) !void {
    const cfg = try loadCfg(sa);
    var pool = try openPool(allocator, io, cfg);
    defer pool.deinit();
    const w = pool.acquireWriter();
    defer pool.releaseWriter();
    try migrations.run(w);
    std.log.info("migrations applied", .{});
}

fn serveImpl(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config, dispatch: *const events.Dispatch, jobs: []const scheduler.RuntimeJob, pool_size: usize) !void {
    if (std.mem.eql(u8, cfg.jwt_secret, "dev-insecure-secret-change-me")) {
        if (cfg.cookie_secure) {
            std.log.err("refusing to start: ZIGBASE_JWT_SECRET is unset/default while cookie_secure is enabled; set a strong secret", .{});
            return error.InsecureJwtSecret;
        }
        std.log.warn("ZIGBASE_JWT_SECRET is using the insecure default; set it before production.", .{});
    }
    var pool = try openPool(allocator, io, cfg);
    defer pool.deinit();
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try migrations.run(w);
    }
    const storage_root = try std.fmt.allocPrint(allocator, "{s}/storage", .{cfg.data_dir});
    defer allocator.free(storage_root);
    var local_storage = files_storage.LocalStorage.init(storage_root);
    const storage_iface = local_storage.storage();
    var app = app_mod.App{
        .allocator = allocator,
        .io = io,
        .pool = &pool,
        .jwt_secret = cfg.jwt_secret,
        .cookie_secure = cfg.cookie_secure,
        .auth_token_ttl_s = cfg.auth_token_ttl_s,
        .verification_ttl_s = cfg.verification_ttl_s,
        .password_reset_ttl_s = cfg.password_reset_ttl_s,
        .realtime_allowed_origins = cfg.realtime_allowed_origins,
        .max_upload_size = cfg.max_upload_size,
        .file_token_ttl_s = cfg.file_token_ttl_s,
        .sentry_dsn = cfg.sentry_dsn,
        .storage = &storage_iface,
        .dispatch = dispatch,
    };
    if (dispatch.on_bootstrap) |h| {
        var ev = events.LifecycleEvent{ .app = &app };
        h(&ev);
    }
    if (dispatch.on_before_serve) |h| {
        var ev = events.LifecycleEvent{ .app = &app };
        h(&ev);
    }
    // before_terminate fires when listen() returns (graceful shutdown / error).
    defer if (dispatch.on_before_terminate) |h| {
        var ev = events.LifecycleEvent{ .app = &app };
        h(&ev);
    };
    const host_z = try allocator.dupeZ(u8, cfg.http_host);
    defer allocator.free(host_z);
    var srv = server.Server{ .app = &app, .host = host_z, .port = cfg.http_port };
    // Start the scheduler only when jobs are configured. Registered LAST among the teardown
    // defers, so (LIFO) its stop()+deinit() runs FIRST on return — joining worker threads
    // before pool.deinit()/local_storage go out of scope, since workers touch app.pool/storage.
    var sched: ?scheduler.Scheduler = if (jobs.len > 0) try scheduler.Scheduler.init(allocator, &app, jobs, pool_size) else null;
    if (sched) |*s| try s.start();
    defer if (sched) |*s| {
        s.stop();
        s.deinit();
    };
    try srv.listen();
}

fn superuserCreateImpl(allocator: std.mem.Allocator, io: std.Io, sa: cli.SuperuserArgs) !void {
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
    const cfg = try loadCfg(.{ .data_dir = sa.data_dir });
    var pool = try openPool(allocator, io, cfg);
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

test "App(cfg) builds a record dispatcher only when hooks are present" {
    const Empty = App(.{});
    try std.testing.expect(Empty.dispatch.record == null);

    const H = struct {
        fn f(ev: *@import("events.zig").RecordEvent) anyerror!void {
            _ = ev;
        }
    };
    const WithHook = App(.{ .hooks = .{ .posts = .{ .afterCreate = H.f } } });
    try std.testing.expect(WithHook.dispatch.record != null);
}

test "App(cfg) assembles custom routes onto dispatch" {
    const H = struct {
        fn h(ev: *@import("events.zig").RouteEvent) anyerror!@import("http.zig").Response {
            _ = ev;
            return .{ .status = 200, .body = "ok" };
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
        fn j(ev: *@import("events.zig").JobEvent) anyerror!void {
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
