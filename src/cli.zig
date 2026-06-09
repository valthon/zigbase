const std = @import("std");

pub const ServeArgs = struct {
    http_host: ?[]const u8 = null,
    http_port: ?u16 = null,
    data_dir: ?[]const u8 = null,
};

pub const SuperuserArgs = struct {
    data_dir: ?[]const u8 = null,
    email: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

pub const Command = union(enum) {
    help,
    serve: ServeArgs,
    migrate: ServeArgs,
    superuser_create: SuperuserArgs,
};

pub const ParseError = error{ UnknownCommand, UnknownFlag, MissingValue, BadValue };

/// Parse argv (excluding the program name).
pub fn parse(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return .help;
    if (std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h"))
        return .help;
    if (std.mem.eql(u8, args[0], "migrate")) {
        var sa = ServeArgs{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--data-dir")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                sa.data_dir = args[i];
            } else return ParseError.UnknownFlag;
        }
        return .{ .migrate = sa };
    }
    if (std.mem.eql(u8, args[0], "superuser")) {
        if (args.len < 2 or !std.mem.eql(u8, args[1], "create")) return ParseError.UnknownCommand;
        var sa = SuperuserArgs{};
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--email")) {
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
    if (!std.mem.eql(u8, args[0], "serve")) return ParseError.UnknownCommand;

    var sa = ServeArgs{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--http-host")) {
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
        } else {
            return ParseError.UnknownFlag;
        }
    }
    return .{ .serve = sa };
}

test "no args -> help" {
    // Use std.meta.activeTag for union-tag comparison; direct `== .help` on a
    // tagged union value does not compile in Zig 0.16.0.
    try std.testing.expect(std.meta.activeTag(try parse(&.{})) == .help);
}

test "serve with all three flags" {
    const cmd = try parse(&.{ "serve", "--http-host", "127.0.0.1", "--http-port", "9000", "--data-dir", "/tmp/zb" });
    try std.testing.expectEqualStrings("127.0.0.1", cmd.serve.http_host.?);
    try std.testing.expectEqual(@as(u16, 9000), cmd.serve.http_port.?);
    try std.testing.expectEqualStrings("/tmp/zb", cmd.serve.data_dir.?);
}

test "migrate command parses --data-dir" {
    const cmd = try parse(&.{ "migrate", "--data-dir", "/tmp/zb" });
    try std.testing.expectEqualStrings("/tmp/zb", cmd.migrate.data_dir.?);
}

test "unknown command errors" {
    try std.testing.expectError(ParseError.UnknownCommand, parse(&.{"frobnicate"}));
}

test "unknown flag errors" {
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "serve", "--nope" }));
}

test "missing flag value errors" {
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "serve", "--http-port" }));
}

test "non-numeric port errors with BadValue" {
    try std.testing.expectError(ParseError.BadValue, parse(&.{ "serve", "--http-port", "abc" }));
}

test "superuser create parses email and password" {
    const cmd = try parse(&.{ "superuser", "create", "--email", "a@b.c", "--password", "secret123" });
    try std.testing.expectEqualStrings("a@b.c", cmd.superuser_create.email.?);
    try std.testing.expectEqualStrings("secret123", cmd.superuser_create.password.?);
}
