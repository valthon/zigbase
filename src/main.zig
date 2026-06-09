const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const db = @import("db.zig");
const server = @import("server.zig");
const app_mod = @import("app.zig");
const migrations = @import("migrations.zig");

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
    var pool = try openPool(allocator, io, cfg);
    defer pool.deinit();
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try migrations.run(w);
    }
    var app = app_mod.App{ .allocator = allocator, .io = io, .pool = &pool };
    const host_z = try allocator.dupeZ(u8, cfg.http_host);
    defer allocator.free(host_z);
    var srv = server.Server{ .app = &app, .host = host_z, .port = cfg.http_port };
    try srv.listen();
}

test "smoke" {
    try std.testing.expect(true);
}

test {
    _ = @import("db.zig");
    _ = @import("config.zig");
    _ = @import("cli.zig");
    _ = @import("api/error.zig");
    _ = @import("api/health.zig");
    _ = @import("api/collections.zig");
    _ = @import("server.zig");
    _ = @import("id.zig");
    _ = @import("schema.zig");
    _ = @import("ddl.zig");
    _ = @import("migrations.zig");
    _ = @import("collections.zig");
    _ = @import("app.zig");
    _ = @import("http.zig");
    _ = @import("router.zig");
    _ = @import("values.zig");
}
