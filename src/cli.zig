const std = @import("std");

pub const ServeArgs = struct {
    http_host: ?[]const u8 = null,
    http_port: ?u16 = null,
    data_dir: ?[]const u8 = null,
    serve_static: ?[]const u8 = null,
    static_cache_control: ?[]const u8 = null,
    // Secure-by-default opt-outs / opt-ins (F8/F12). null = leave the config default.
    insecure_cookies: bool = false, // --insecure-cookies => cookie_secure=false (plain-HTTP local dev)
    trust_proxy: bool = false, // --trust-proxy => honor X-Forwarded-For/X-Real-IP
    realtime_origins: ?[]const u8 = null, // --realtime-origins CSV => allowed WS Origins
    sse_heartbeat_seconds: ?u16 = null, // --sse-heartbeat-seconds N => SSE ping interval (0 = inherit listener timeout)
    realtime_outbound_hwm: ?u32 = null, // --realtime-outbound-hwm N => slow-consumer disconnect bound in frames (0 disables); issue #203
};

pub const SuperuserArgs = struct {
    data_dir: ?[]const u8 = null,
    email: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

pub const RewrapArgs = struct {
    data_dir: ?[]const u8 = null,
    /// --dry-run: report what would change without writing anything.
    dry_run: bool = false,
};

/// `migrate-db`: copy an existing SQLite instance into a PostgreSQL target (issue #159).
pub const MigrateDbArgs = struct {
    /// Source SQLite `data.db` path (required).
    from: ?[]const u8 = null,
    /// Target `postgres://…` connection URL (required).
    to: ?[]const u8 = null,
    /// Overwrite a target that already contains a ZigBase schema.
    force: bool = false,
};

pub const TypegenArgs = struct {
    data_dir: ?[]const u8 = null,
    url: ?[]const u8 = null,
    out: ?[]const u8 = null,
    api_prefix: []const u8 = "/api",
    client_name: []const u8 = "ZbClient",
    admin_email: ?[]const u8 = null,
    admin_password: ?[]const u8 = null,
    check: bool = false,
};

/// Identifies which command a per-command `--help` request targets.
pub const HelpTopic = enum { top, serve, migrate, superuser_create, typegen, rewrap, migrate_db, vapid_keygen };

pub const Command = union(enum) {
    /// `help`/`--help`/`-h`/no-args -> top-level usage; `<cmd> --help` -> that command's usage.
    help: HelpTopic,
    /// `version`/`--version`/`-V` -> print build provenance and exit.
    version: void,
    serve: ServeArgs,
    migrate: ServeArgs,
    superuser_create: SuperuserArgs,
    typegen: TypegenArgs,
    rewrap: RewrapArgs,
    migrate_db: MigrateDbArgs,
    /// `vapid-keygen` -> generate a fresh VAPID (Web Push) keypair, print it, and exit.
    vapid_keygen: void,
};

/// True when an arg is a help flag (`--help` or `-h`).
fn isHelpFlag(a: []const u8) bool {
    return std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h");
}

pub const ParseError = error{ UnknownCommand, UnknownFlag, MissingValue, BadValue };

/// Comptime-derived parser switches. `serve_static` is true only in the default
/// static-files mode — in .disabled/.dir/.embedded the flag is rejected as unknown.
pub const ParseOpts = struct {
    serve_static: bool = true,
    /// --static-cache-control is rejected as unknown when static serving is disabled
    /// at comptime (`.static_files = .disabled`), mirroring the --serve-static gate.
    /// Unlike serve_static it stays available in .dir/.embedded modes (the knob
    /// applies to comptime-configured sources too).
    static_cache_control: bool = true,
};

/// Parse argv (excluding the program name).
pub fn parse(args: []const []const u8, popts: ParseOpts) ParseError!Command {
    if (args.len == 0) return .{ .help = .top };
    if (std.mem.eql(u8, args[0], "help") or isHelpFlag(args[0]))
        return .{ .help = .top };
    if (std.mem.eql(u8, args[0], "version") or
        std.mem.eql(u8, args[0], "--version") or
        std.mem.eql(u8, args[0], "-V"))
        return .{ .version = {} };
    if (std.mem.eql(u8, args[0], "migrate-db")) {
        var ma = MigrateDbArgs{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (isHelpFlag(a)) {
                return .{ .help = .migrate_db };
            } else if (std.mem.eql(u8, a, "--from")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ma.from = args[i];
            } else if (std.mem.eql(u8, a, "--to")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ma.to = args[i];
            } else if (std.mem.eql(u8, a, "--force")) {
                ma.force = true;
            } else return ParseError.UnknownFlag;
        }
        return .{ .migrate_db = ma };
    }
    if (std.mem.eql(u8, args[0], "migrate")) {
        var sa = ServeArgs{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (isHelpFlag(a)) {
                return .{ .help = .migrate };
            } else if (std.mem.eql(u8, a, "--data-dir")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                sa.data_dir = args[i];
            } else return ParseError.UnknownFlag;
        }
        return .{ .migrate = sa };
    }
    if (std.mem.eql(u8, args[0], "vapid-keygen")) {
        // No flags; `--help`/`-h` routes to its help screen, anything else is unknown.
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (isHelpFlag(args[i])) return .{ .help = .vapid_keygen };
            return ParseError.UnknownFlag;
        }
        return .{ .vapid_keygen = {} };
    }
    if (std.mem.eql(u8, args[0], "rewrap")) {
        var ra = RewrapArgs{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (isHelpFlag(a)) {
                return .{ .help = .rewrap };
            } else if (std.mem.eql(u8, a, "--data-dir")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ra.data_dir = args[i];
            } else if (std.mem.eql(u8, a, "--dry-run")) {
                ra.dry_run = true;
            } else return ParseError.UnknownFlag;
        }
        return .{ .rewrap = ra };
    }
    if (std.mem.eql(u8, args[0], "superuser")) {
        // `superuser --help` / `superuser -h` -> the superuser-create help screen.
        if (args.len >= 2 and isHelpFlag(args[1])) return .{ .help = .superuser_create };
        if (args.len < 2 or !std.mem.eql(u8, args[1], "create")) return ParseError.UnknownCommand;
        var sa = SuperuserArgs{};
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (isHelpFlag(a)) {
                return .{ .help = .superuser_create };
            } else if (std.mem.eql(u8, a, "--email")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                sa.email = args[i];
            } else if (std.mem.eql(u8, a, "--password")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                sa.password = args[i];
            } else if (std.mem.eql(u8, a, "--data-dir")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                sa.data_dir = args[i];
            } else return ParseError.UnknownFlag;
        }
        return .{ .superuser_create = sa };
    }
    if (std.mem.eql(u8, args[0], "typegen")) {
        var ta = TypegenArgs{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (isHelpFlag(a)) return .{ .help = .typegen };
            if (std.mem.eql(u8, a, "--data-dir")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ta.data_dir = args[i];
            } else if (std.mem.eql(u8, a, "--url")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ta.url = args[i];
            } else if (std.mem.eql(u8, a, "--out")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ta.out = args[i];
            } else if (std.mem.eql(u8, a, "--api-prefix")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ta.api_prefix = args[i];
            } else if (std.mem.eql(u8, a, "--client-name")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ta.client_name = args[i];
            } else if (std.mem.eql(u8, a, "--admin-email")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ta.admin_email = args[i];
            } else if (std.mem.eql(u8, a, "--admin-password")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ta.admin_password = args[i];
            } else if (std.mem.eql(u8, a, "--check")) {
                ta.check = true;
            } else return ParseError.UnknownFlag;
        }
        return .{ .typegen = ta };
    }
    if (!std.mem.eql(u8, args[0], "serve")) return ParseError.UnknownCommand;

    var sa = ServeArgs{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (isHelpFlag(a)) {
            return .{ .help = .serve };
        } else if (std.mem.eql(u8, a, "--http-host")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            sa.http_host = args[i];
        } else if (std.mem.eql(u8, a, "--http-port")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            sa.http_port = std.fmt.parseInt(u16, args[i], 10) catch return ParseError.BadValue;
        } else if (std.mem.eql(u8, a, "--data-dir")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            sa.data_dir = args[i];
        } else if (popts.serve_static and std.mem.eql(u8, a, "--serve-static")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            sa.serve_static = args[i];
        } else if (popts.static_cache_control and std.mem.eql(u8, a, "--static-cache-control")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            sa.static_cache_control = args[i];
        } else if (std.mem.eql(u8, a, "--insecure-cookies")) {
            sa.insecure_cookies = true;
        } else if (std.mem.eql(u8, a, "--trust-proxy")) {
            sa.trust_proxy = true;
        } else if (std.mem.eql(u8, a, "--realtime-origins")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            sa.realtime_origins = args[i];
        } else if (std.mem.eql(u8, a, "--sse-heartbeat-seconds")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            sa.sse_heartbeat_seconds = std.fmt.parseInt(u16, args[i], 10) catch return ParseError.BadValue;
        } else if (std.mem.eql(u8, a, "--realtime-outbound-hwm")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            sa.realtime_outbound_hwm = std.fmt.parseInt(u32, args[i], 10) catch return ParseError.BadValue;
        } else {
            return ParseError.UnknownFlag;
        }
    }
    return .{ .serve = sa };
}

test "no args -> top-level help" {
    // Use std.meta.activeTag for union-tag comparison; direct `== .help` on a
    // tagged union value does not compile in Zig 0.16.0.
    const cmd = try parse(&.{}, .{});
    try std.testing.expect(std.meta.activeTag(cmd) == .help);
    try std.testing.expectEqual(HelpTopic.top, cmd.help);
}

test "--help and -h and help -> top-level help" {
    try std.testing.expectEqual(HelpTopic.top, (try parse(&.{"--help"}, .{})).help);
    try std.testing.expectEqual(HelpTopic.top, (try parse(&.{"-h"}, .{})).help);
    try std.testing.expectEqual(HelpTopic.top, (try parse(&.{"help"}, .{})).help);
}

test "per-command --help routes to that command's help topic" {
    try std.testing.expectEqual(HelpTopic.serve, (try parse(&.{ "serve", "--help" }, .{})).help);
    try std.testing.expectEqual(HelpTopic.serve, (try parse(&.{ "serve", "-h" }, .{})).help);
    try std.testing.expectEqual(HelpTopic.migrate, (try parse(&.{ "migrate", "--help" }, .{})).help);
    try std.testing.expectEqual(HelpTopic.superuser_create, (try parse(&.{ "superuser", "create", "--help" }, .{})).help);
    try std.testing.expectEqual(HelpTopic.superuser_create, (try parse(&.{ "superuser", "--help" }, .{})).help);
}

test "serve with all three flags" {
    const cmd = try parse(&.{ "serve", "--http-host", "127.0.0.1", "--http-port", "9000", "--data-dir", "/tmp/zb" }, .{});
    try std.testing.expectEqualStrings("127.0.0.1", cmd.serve.http_host.?);
    try std.testing.expectEqual(@as(u16, 9000), cmd.serve.http_port.?);
    try std.testing.expectEqualStrings("/tmp/zb", cmd.serve.data_dir.?);
}

test "migrate command parses --data-dir" {
    const cmd = try parse(&.{ "migrate", "--data-dir", "/tmp/zb" }, .{});
    try std.testing.expectEqualStrings("/tmp/zb", cmd.migrate.data_dir.?);
}

test "rewrap parses --data-dir and --dry-run" {
    const cmd = try parse(&.{ "rewrap", "--data-dir", "/tmp/zb", "--dry-run" }, .{});
    try std.testing.expect(std.meta.activeTag(cmd) == .rewrap);
    try std.testing.expectEqualStrings("/tmp/zb", cmd.rewrap.data_dir.?);
    try std.testing.expect(cmd.rewrap.dry_run);
}

test "rewrap --help routes to rewrap help topic" {
    try std.testing.expectEqual(HelpTopic.rewrap, (try parse(&.{ "rewrap", "--help" }, .{})).help);
}

test "rewrap rejects unknown flags" {
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "rewrap", "--nope" }, .{}));
}

test "migrate-db parses --from/--to/--force" {
    const cmd = try parse(&.{ "migrate-db", "--from", "/tmp/zb/data.db", "--to", "postgres://h/db", "--force" }, .{});
    try std.testing.expect(std.meta.activeTag(cmd) == .migrate_db);
    try std.testing.expectEqualStrings("/tmp/zb/data.db", cmd.migrate_db.from.?);
    try std.testing.expectEqualStrings("postgres://h/db", cmd.migrate_db.to.?);
    try std.testing.expect(cmd.migrate_db.force);
}

test "migrate-db --help routes to its help topic" {
    try std.testing.expectEqual(HelpTopic.migrate_db, (try parse(&.{ "migrate-db", "--help" }, .{})).help);
}

test "migrate-db rejects unknown flags and missing values" {
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "migrate-db", "--nope" }, .{}));
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "migrate-db", "--from" }, .{}));
}

test "vapid-keygen parses and routes --help to its topic" {
    try std.testing.expectEqual(.vapid_keygen, std.meta.activeTag(try parse(&.{"vapid-keygen"}, .{})));
    try std.testing.expectEqual(HelpTopic.vapid_keygen, (try parse(&.{ "vapid-keygen", "--help" }, .{})).help);
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "vapid-keygen", "--nope" }, .{}));
}

test "unknown command errors" {
    try std.testing.expectError(ParseError.UnknownCommand, parse(&.{"frobnicate"}, .{}));
}

test "unknown flag errors" {
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "serve", "--nope" }, .{}));
}

test "missing flag value errors" {
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "serve", "--http-port" }, .{}));
}

test "non-numeric port errors with BadValue" {
    try std.testing.expectError(ParseError.BadValue, parse(&.{ "serve", "--http-port", "abc" }, .{}));
}

test "superuser create parses email and password" {
    const cmd = try parse(&.{ "superuser", "create", "--email", "a@b.c", "--password", "secret123" }, .{});
    try std.testing.expectEqualStrings("a@b.c", cmd.superuser_create.email.?);
    try std.testing.expectEqualStrings("secret123", cmd.superuser_create.password.?);
}

test "serve parses --serve-static when enabled" {
    const cmd = try parse(&.{ "serve", "--serve-static", "public" }, .{});
    try std.testing.expectEqualStrings("public", cmd.serve.serve_static.?);
}

test "serve --sse-heartbeat-seconds parses; bad/missing values rejected" {
    const c = try parse(&.{ "serve", "--sse-heartbeat-seconds", "2" }, .{});
    try std.testing.expectEqual(@as(?u16, 2), c.serve.sse_heartbeat_seconds);
    try std.testing.expectError(ParseError.BadValue, parse(&.{ "serve", "--sse-heartbeat-seconds", "abc" }, .{}));
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "serve", "--sse-heartbeat-seconds" }, .{}));
}

test "serve --realtime-outbound-hwm parses; bad/missing values rejected (issue #203)" {
    const c = try parse(&.{ "serve", "--realtime-outbound-hwm", "16" }, .{});
    try std.testing.expectEqual(@as(?u32, 16), c.serve.realtime_outbound_hwm);
    // 0 is a valid value (disables the bound); not the same as absent (null).
    const z = try parse(&.{ "serve", "--realtime-outbound-hwm", "0" }, .{});
    try std.testing.expectEqual(@as(?u32, 0), z.serve.realtime_outbound_hwm);
    try std.testing.expectError(ParseError.BadValue, parse(&.{ "serve", "--realtime-outbound-hwm", "nope" }, .{}));
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "serve", "--realtime-outbound-hwm" }, .{}));
}

test "--serve-static is an unknown flag when disabled at comptime" {
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "serve", "--serve-static", "public" }, .{ .serve_static = false }));
}

test "--serve-static without a value errors" {
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "serve", "--serve-static" }, .{}));
}

test "--static-cache-control parses, requires a value, and is gated by ParseOpts" {
    const c = try parse(&.{ "serve", "--static-cache-control", "public, max-age=86400" }, .{});
    try std.testing.expectEqualStrings("public, max-age=86400", c.serve.static_cache_control.?);
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "serve", "--static-cache-control" }, .{}));
    try std.testing.expectError(ParseError.UnknownFlag, parse(
        &.{ "serve", "--static-cache-control", "x" },
        .{ .static_cache_control = false },
    ));
}

test "parse typegen: data-dir + out + flags" {
    const args = [_][]const u8{ "typegen", "--data-dir", "./zb_data", "--out", "c.ts", "--client-name", "Api", "--check" };
    const cmd = try parse(&args, .{ .serve_static = true });
    try std.testing.expect(cmd == .typegen);
    try std.testing.expectEqualStrings("./zb_data", cmd.typegen.data_dir.?);
    try std.testing.expectEqualStrings("c.ts", cmd.typegen.out.?);
    try std.testing.expectEqualStrings("Api", cmd.typegen.client_name);
    try std.testing.expect(cmd.typegen.check);
}

test "parse typegen: url + admin creds" {
    const args = [_][]const u8{ "typegen", "--url", "http://x", "--admin-email", "a@b.c", "--admin-password", "pw", "--out", "c.ts" };
    const cmd = try parse(&args, .{ .serve_static = true });
    try std.testing.expectEqualStrings("http://x", cmd.typegen.url.?);
    try std.testing.expectEqualStrings("a@b.c", cmd.typegen.admin_email.?);
}

test "parse typegen: missing flag value errors" {
    const args = [_][]const u8{ "typegen", "--out" };
    try std.testing.expectError(ParseError.MissingValue, parse(&args, .{ .serve_static = true }));
}

test "version / --version / -V -> version command" {
    try std.testing.expectEqual(.version, std.meta.activeTag(try parse(&.{"version"}, .{})));
    try std.testing.expectEqual(.version, std.meta.activeTag(try parse(&.{"--version"}, .{})));
    try std.testing.expectEqual(.version, std.meta.activeTag(try parse(&.{"-V"}, .{})));
}
