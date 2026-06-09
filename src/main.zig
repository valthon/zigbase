const std = @import("std");
const zigbase = @import("zigbase");
const cli = zigbase.@"internal".cli;
const config = zigbase.@"internal".config;
const db = zigbase.@"internal".db;
const server = zigbase.@"internal".server;
const app_mod = zigbase.@"internal".app;
const migrations = zigbase.@"internal".migrations;
const crypto = zigbase.@"internal".crypto;
const id_gen = zigbase.@"internal".id;
const files_storage = zigbase.@"internal".files_storage;

/// Zig 0.16 entry point: `main` receives a `std.process.Init` which carries the
/// process gpa, an arena, and the command-line args. `std.process.argsAlloc`
/// was removed in this std, so we pull argv from `init.minimal.args`.
pub fn main(init: std.process.Init) !void {
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
        .help => printUsage(),
        .serve => |sa| try runServe(allocator, init.io, sa),
        .migrate => |sa| try runMigrate(allocator, init.io, sa),
        .superuser_create => |sa| try runSuperuserCreate(allocator, init.io, sa),
    }
}

fn printUsage() void {
    std.log.info("usage: zigbase serve [--http-host H] [--http-port N] [--data-dir PATH]", .{});
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

fn runMigrate(allocator: std.mem.Allocator, io: std.Io, sa: cli.ServeArgs) !void {
    const cfg = try loadCfg(sa);
    var pool = try openPool(allocator, io, cfg);
    defer pool.deinit();
    const w = pool.acquireWriter();
    defer pool.releaseWriter();
    try migrations.run(w);
    std.log.info("migrations applied", .{});
}

fn runServe(allocator: std.mem.Allocator, io: std.Io, sa: cli.ServeArgs) !void {
    const cfg = try loadCfg(sa);
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
    };
    const host_z = try allocator.dupeZ(u8, cfg.http_host);
    defer allocator.free(host_z);
    var srv = server.Server{ .app = &app, .host = host_z, .port = cfg.http_port };
    try srv.listen();
}

fn runSuperuserCreate(allocator: std.mem.Allocator, io: std.Io, sa: cli.SuperuserArgs) !void {
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
