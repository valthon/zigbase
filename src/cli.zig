const std = @import("std");

pub const ServeArgs = struct {
    http_host: ?[]const u8 = null,
    http_port: ?u16 = null,
    data_dir: ?[]const u8 = null,
    serve_static: ?[]const u8 = null,
    // Secure-by-default opt-outs / opt-ins (F8/F12). null = leave the config default.
    insecure_cookies: bool = false, // --insecure-cookies => cookie_secure=false (plain-HTTP local dev)
    trust_proxy: bool = false, // --trust-proxy => honor X-Forwarded-For/X-Real-IP
    realtime_origins: ?[]const u8 = null, // --realtime-origins CSV => allowed WS Origins
};

pub const SuperuserArgs = struct {
    data_dir: ?[]const u8 = null,
    email: ?[]const u8 = null,
    password: ?[]const u8 = null,
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
pub const HelpTopic = enum { top, serve, migrate, superuser_create, typegen };

pub const Command = union(enum) {
    /// `help`/`--help`/`-h`/no-args -> top-level usage; `<cmd> --help` -> that command's usage.
    help: HelpTopic,
    /// `version`/`--version`/`-V` -> print build provenance and exit.
    version: void,
    serve: ServeArgs,
    migrate: ServeArgs,
    superuser_create: SuperuserArgs,
    typegen: TypegenArgs,
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
        } else if (std.mem.eql(u8, a, "--insecure-cookies")) {
            sa.insecure_cookies = true;
        } else if (std.mem.eql(u8, a, "--trust-proxy")) {
            sa.trust_proxy = true;
        } else if (std.mem.eql(u8, a, "--realtime-origins")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            sa.realtime_origins = args[i];
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

test "--serve-static is an unknown flag when disabled at comptime" {
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "serve", "--serve-static", "public" }, .{ .serve_static = false }));
}

test "--serve-static without a value errors" {
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "serve", "--serve-static" }, .{}));
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
    try std.testing.expectEqual(std.meta.activeTag(try parse(&.{"version"}, .{})), .version);
    try std.testing.expectEqual(std.meta.activeTag(try parse(&.{"--version"}, .{})), .version);
    try std.testing.expectEqual(std.meta.activeTag(try parse(&.{"-V"}, .{})), .version);
}
