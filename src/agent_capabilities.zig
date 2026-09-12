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

const operations = [_]Operation{
    .{ .id = "build-info", .argv = &.{ "version", "--json" }, .output = .json, .effect = .read_only, .requires_database = false },
    .{ .id = "routes", .argv = &.{ "routes", "--json" }, .output = .json, .effect = .read_only, .requires_database = false, .notes = "Compiled route registrations and redacted declarative auth metadata; not runtime authorization or a complete static/admin endpoint inventory." },
    .{ .id = "diagnostics", .argv = &.{ "diagnostics", "--json" }, .output = .json, .effect = .may_write, .requires_database = true, .notes = "Doctor adapter: probes filesystem writability; may initialize the migration ledger. JSON remains valid on diagnostic failure; exit 0 clean, 1 errors, 2 warnings." },
    .{ .id = "schema", .argv = &.{ "schema", "dump", "--json" }, .output = .json, .effect = .may_write, .requires_database = true, .notes = "Opens the database pool; may create local database state or configure journaling." },
    .{ .id = "migration-status", .argv = &.{ "migrate", "status", "--json" }, .output = .json, .effect = .may_write, .requires_database = true, .notes = "Opens the database pool and ensures the migration ledger exists. Nonzero exit can accompany valid status output." },
    .{ .id = "migration-preview", .argv = &.{ "migrate", "preview", "--json" }, .output = .json, .effect = .read_only, .requires_database = false, .notes = "Compiled consumer declarations only; no deployment configuration, database or callbacks. CLI logging preferences still apply. Pending state, SQL, effects and runtime reversibility are unknown." },
    .{ .id = "http-contract", .argv = &.{"openapi"}, .output = .openapi, .effect = .read_only, .requires_database = true, .notes = "Requires an existing database; includes this binary's declared routes." },
    .{ .id = "error-codes", .argv = &.{ "explain-code", "--json" }, .output = .json, .effect = .read_only, .requires_database = false },
} ++ (if (@import("build_options").file_inventory) [_]Operation{
    .{ .id = "files-reconcile-preview", .argv = &.{ "files", "reconcile", "--json" }, .output = .json, .effect = .read_only, .requires_database = true, .notes = "Bounded live orphan preview, not a saved deletion approval. Existing built-in local storage and SQLite only; no migrations. Optional --data-dir, --cursor, --limit and --min-age-seconds." },
    .{ .id = "files-reconcile-apply", .argv = &.{ "files", "reconcile", "--json", "--apply" }, .output = .json, .effect = .may_write, .requires_database = true, .notes = "Explicit operator authorization required: irreversible bounded file deletion, not rolled back after partial failure. Offline local/SQLite only; exclusive root lease and database writer transaction. Stop old/external writers; dedicated storage root required. Optional --data-dir, --cursor, --limit and --min-age-seconds. Cursor is not approval." },
} else [_]Operation{});

pub fn write(writer: *std.Io.Writer) !void {
    // Only operations[].argv is directly runnable; input operations have a
    // separate prefix plus descriptors, never placeholders.
    const tuning = @import("tuning.zig");
    const label = .{ .type = "string", .min_bytes = 1, .max_bytes = tuning.max_label_bytes, .forbidden_byte_ranges = .{ .{ .minimum = 0, .maximum = 31 }, .{ .minimum = 127, .maximum = 127 } } };
    const positive_float = .{ .type = "f64", .finite = true, .exclusive_minimum = 0 };
    try writer.print("{f}\n", .{std.json.fmt(.{
        .protocol_version = @as(u8, 1),
        .scope = "development-cli-discovery",
        .operations = operations,
        .input_operations = .{.{
            .id = "tune",
            .argv_prefix = &[_][]const u8{ "tune", "--json" },
            .output = "json",
            .effect = "read_only",
            .requires_database = false,
            .inputs = .{
                .{ .flag = "--input", .required = true, .kind = "json_file", .schema_id = "zigbase-tuning-input-v1", .max_bytes = @import("tuning.zig").max_input_bytes },
                .{ .flag = "--as-of", .required = false, .kind = "integer", .minimum_decimal = "0", .maximum_decimal = "9223372036854775807", .default = "current_unix_seconds" },
            },
            .input_contract = .{
                .schema_version = 1,
                .required_fields = &[_][]const u8{ "schema_version", "workload", "revision", "environment", "max_age_seconds", "memory_budget_bytes", "p95_budget_ms", "candidates" },
                .candidate_required_fields = &[_][]const u8{ "id", "workload", "revision", "environment", "measured_at_unix", "throughput_rps", "p95_ms", "peak_rss_bytes", "failed_requests", "resources" },
                .min_candidates = 1,
                .max_candidates = tuning.max_candidates,
                .fields = .{
                    .schema_version = .{ .type = "u8", .constant = 1 },
                    .workload = label,
                    .revision = label,
                    .environment = label,
                    .max_age_seconds = .{ .type = "u32", .minimum_decimal = "1", .maximum_decimal = "4294967295" },
                    .memory_budget_bytes = .{ .type = "u64", .minimum_decimal = "1", .maximum_decimal = "18446744073709551615" },
                    .p95_budget_ms = positive_float,
                    .candidates = .{ .type = "array", .min_items = 1, .max_items = tuning.max_candidates, .unique_by = "id" },
                },
                .candidate_fields = .{
                    .id = label,
                    .workload = label,
                    .revision = label,
                    .environment = label,
                    .measured_at_unix = .{ .type = "i64", .minimum_decimal = "0", .maximum_decimal = "9223372036854775807" },
                    .throughput_rps = positive_float,
                    .p95_ms = positive_float,
                    .peak_rss_bytes = .{ .type = "u64", .minimum_decimal = "1", .maximum_decimal = "18446744073709551615" },
                    .failed_requests = .{ .type = "u64", .minimum_decimal = "0", .maximum_decimal = "18446744073709551615" },
                    .resources = .{ .type = "object", .schema_version = 1, .capture_argv = &[_][]const u8{"resources"} },
                },
                .resources = "Captured resource report schema_version 1; caller-supplied provenance, not validated compiled configuration.",
                .reference = "docs/framework.md#offline-measurement-advisor-zigbase-tune",
                .descriptor_coverage = "Required fields, scalar constraints and transport bounds; not a complete validation schema (nested resource report is captured, not described). Integer minimum_decimal/maximum_decimal are inclusive base-10 strings for lossless parsing, not JSON input field types. forbidden_byte_ranges contain inclusive numeric minimum/maximum byte values applied to UTF-8. Unknown fields are rejected. See reference for measurement semantics.",
            },
            .notes = "Append each supplied flag and value as separate argv elements; prefix alone is not executable. Never substitute shell strings. Compares measurements, does not predict performance. Tune keeps its existing output/error behavior.",
        }},
    }, .{})});
}

test "capability catalog has versioned unique operation identifiers and inputs" {
    for (operations, 0..) |op, i| {
        try std.testing.expect(op.argv.len > 0);
        for (operations[i + 1 ..]) |other|
            try std.testing.expect(!std.mem.eql(u8, op.id, other.id));
    }
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), root.get("protocol_version").?.integer);
    const ops = root.get("operations").?.array.items;
    try std.testing.expectEqual(@as(usize, if (@import("build_options").file_inventory) 10 else 8), ops.len);
    var found_preview = false;
    var found_apply = false;
    var found_diagnostics = false;
    for (ops) |op| {
        const id = op.object.get("id").?.string;
        if (std.mem.eql(u8, id, "files-reconcile-preview")) {
            found_preview = true;
            try std.testing.expectEqualStrings("read_only", op.object.get("effect").?.string);
        } else if (std.mem.eql(u8, id, "files-reconcile-apply")) {
            found_apply = true;
            try std.testing.expectEqualStrings("may_write", op.object.get("effect").?.string);
            try std.testing.expectEqualStrings("--apply", op.object.get("argv").?.array.items[3].string);
        } else if (std.mem.eql(u8, id, "diagnostics")) {
            found_diagnostics = true;
            try std.testing.expectEqualStrings("diagnostics", op.object.get("argv").?.array.items[0].string);
            try std.testing.expectEqualStrings("json", op.object.get("output").?.string);
        }
    }
    try std.testing.expectEqual(@import("build_options").file_inventory, found_preview);
    try std.testing.expectEqual(@import("build_options").file_inventory, found_apply);
    try std.testing.expect(found_diagnostics);
    const inputs = root.get("input_operations").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), inputs.len);
    for (inputs, 0..) |input, i| {
        const id = input.object.get("id").?.string;
        try std.testing.expect(input.object.get("argv") == null);
        try std.testing.expect(input.object.get("argv_prefix").?.array.items.len > 0);
        for (ops) |op| try std.testing.expect(!std.mem.eql(u8, id, op.object.get("id").?.string));
        for (inputs[i + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, id, other.object.get("id").?.string));
    }
}
