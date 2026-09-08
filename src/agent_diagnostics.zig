//! Versioned doctor adapter. Existing finding/check/summary semantics are reused.
const std = @import("std");
const doctor = @import("doctor.zig");
const doctor_run = @import("doctor_run.zig");
const config = @import("config.zig");
const cli = @import("cli.zig");
const provision = @import("provision.zig");

pub fn output(io: std.Io, document: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buf);
    try writer.interface.writeAll(document);
    try writer.interface.flush();
}

pub fn writeError(writer: *std.Io.Writer, phase: []const u8, code: []const u8, subject: ?[]const u8, expected: ?[]const u8) !void {
    try writer.print("{f}\n", .{std.json.fmt(.{
        .protocol_version = @as(u8, 1),
        .scope = "development-diagnostics",
        .status = "error",
        .exit_code = @as(u8, 1),
        .failure = .{ .phase = phase, .code = code, .subject = subject, .expected = expected },
    }, .{})});
}

/// Command-scoped graph: gather/evaluate findings share the caller's arena.
/// Config errors intentionally omit supplied values (which can contain secrets).
pub fn run(command_arena: @import("request_arena.zig").RequestArena, io: std.Io, environ: *const std.process.Environ.Map, args: cli.DiagnosticsArgs, migrations: []const provision.Migration, writer: *std.Io.Writer) !u8 {
    const arena = command_arena.a;
    var diagnostic: config.LoadDiag = .{};
    var cfg = config.Config.loadDiag(config.EnvGetter{ .environ = environ }, &diagnostic) catch {
        try writeError(writer, "configuration", "invalid_environment", diagnostic.var_name, diagnostic.expected);
        return 1;
    };
    if (args.data_dir) |path| cfg.data_dir = path;
    const facts = doctor_run.gather(arena, io, cfg, environ, migrations);
    const findings = try doctor.evaluate(arena, facts, args.production);
    const summary = doctor.summarize(findings, args.production);
    const exit_code = doctor_run.exitCode(summary);
    try writer.print("{f}\n", .{std.json.fmt(.{
        .protocol_version = @as(u8, 1),
        .scope = "development-diagnostics",
        .status = "complete",
        .exit_code = exit_code,
        .findings = findings,
        .summary = summary,
    }, .{})});
    return exit_code;
}

test "diagnostic errors are escaped JSON with no supplied value" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeError(&out.writer, "arguments", "invalid_arguments", null, null);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("error", parsed.value.object.get("status").?.string);
}
