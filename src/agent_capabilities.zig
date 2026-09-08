//! Development-time discovery, not a remote execution protocol. The catalog
//! contains argument vectors, never shell strings, and never loads deployment
//! settings or opens the application database (CLI logging initializes separately).
const std = @import("std");

pub const Operation = struct {
    id: []const u8,
    argv: []const []const u8,
    output: enum { json, ndjson, openapi },
    effect: enum { read_only, may_write },
    requires_database: bool,
    notes: []const u8 = "",
};

pub const Manifest = struct {
    protocol_version: u32 = 1,
    scope: []const u8 = "development-cli-discovery",
    operations: [7]Operation,
};

pub fn manifest() Manifest {
    return .{ .operations = .{
        .{ .id = "build-info", .argv = &.{ "version", "--json" }, .output = .json, .effect = .read_only, .requires_database = false },
        .{ .id = "routes", .argv = &.{ "routes", "--json" }, .output = .json, .effect = .read_only, .requires_database = false, .notes = "Compiled route registrations and redacted declarative auth metadata; not runtime authorization or a complete static/admin endpoint inventory." },
        .{ .id = "diagnostics", .argv = &.{ "doctor", "--json" }, .output = .ndjson, .effect = .may_write, .requires_database = true, .notes = "Probes filesystem writability; may initialize the migration ledger. Nonzero exit can accompany valid diagnostic output." },
        .{ .id = "schema", .argv = &.{ "schema", "dump", "--json" }, .output = .json, .effect = .may_write, .requires_database = true, .notes = "Opens the database pool; may create local database state or configure journaling." },
        .{ .id = "migration-status", .argv = &.{ "migrate", "status", "--json" }, .output = .json, .effect = .may_write, .requires_database = true, .notes = "Opens the database pool and ensures the migration ledger exists. Nonzero exit can accompany valid status output." },
        .{ .id = "http-contract", .argv = &.{"openapi"}, .output = .openapi, .effect = .read_only, .requires_database = true, .notes = "Requires an existing database; includes this binary's declared routes." },
        .{ .id = "error-codes", .argv = &.{ "explain-code", "--json" }, .output = .json, .effect = .read_only, .requires_database = false },
    } };
}

pub fn write(writer: *std.Io.Writer) !void {
    try writer.print("{f}\n", .{std.json.fmt(manifest(), .{})});
}

test "capability manifest has versioned unique operation identifiers" {
    const m = manifest();
    try std.testing.expectEqual(@as(u32, 1), m.protocol_version);
    for (m.operations, 0..) |op, i| {
        try std.testing.expect(op.argv.len > 0);
        for (m.operations[i + 1 ..]) |other|
            try std.testing.expect(!std.mem.eql(u8, op.id, other.id));
    }
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer);
    const parsed = try std.json.parseFromSlice(Manifest, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 7), parsed.value.operations.len);
}
