//! Offline comparison of supplied observations, never performance prediction.
const std = @import("std");
const ResourceReport = @import("resource_profile.zig").Report;

pub const max_input_bytes = 1024 * 1024;
pub const max_candidates = 128;
pub const max_label_bytes = 256;
pub const Candidate = struct {
    id: []const u8,
    workload: []const u8,
    revision: []const u8,
    environment: []const u8,
    measured_at_unix: i64,
    throughput_rps: f64,
    p95_ms: f64,
    peak_rss_bytes: u64,
    failed_requests: u64,
    resources: ResourceReport,
};
pub const Input = struct {
    schema_version: u8,
    workload: []const u8,
    revision: []const u8,
    environment: []const u8,
    max_age_seconds: u32,
    memory_budget_bytes: u64,
    p95_budget_ms: f64,
    candidates: []const Candidate,
};
const Reason = enum { feasible, failed_requests, context_mismatch, stale, future_measurement, memory_budget, latency_budget };
const Item = struct { candidate: Candidate, reason: Reason };

fn labelValid(value: []const u8) bool {
    if (value.len == 0 or value.len > max_label_bytes) return false;
    for (value) |c| if (c < 32 or c == 127) return false;
    return true;
}

fn positive(value: f64) bool {
    return std.math.isFinite(value) and value > 0;
}

fn better(a: Candidate, b: Candidate) bool {
    if (a.throughput_rps != b.throughput_rps) return a.throughput_rps > b.throughput_rps;
    if (a.peak_rss_bytes != b.peak_rss_bytes) return a.peak_rss_bytes < b.peak_rss_bytes;
    if (a.p95_ms != b.p95_ms) return a.p95_ms < b.p95_ms;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

/// Self-freeing: only the returned JSON allocation escapes; caller frees it.
pub fn compare(allocator: std.mem.Allocator, bytes: []const u8, now: i64) ![]u8 {
    if (bytes.len > max_input_bytes) return error.InputTooLarge;
    const parsed = try std.json.parseFromSlice(Input, allocator, bytes, .{});
    defer parsed.deinit();
    const input = parsed.value;
    if (input.schema_version != 1) return error.UnsupportedSchemaVersion;
    if (!labelValid(input.workload) or !labelValid(input.revision) or !labelValid(input.environment)) return error.InvalidContext;
    if (input.max_age_seconds == 0 or input.memory_budget_bytes == 0 or !positive(input.p95_budget_ms) or now < 0) return error.InvalidBudget;
    if (input.candidates.len == 0 or input.candidates.len > max_candidates) return error.InvalidCandidateCount;
    const items = try allocator.alloc(Item, input.candidates.len);
    defer allocator.free(items);
    var selected: ?Candidate = null;
    for (input.candidates, 0..) |candidate, i| {
        if (!labelValid(candidate.id) or !labelValid(candidate.workload) or !labelValid(candidate.revision) or !labelValid(candidate.environment)) return error.InvalidContext;
        if (!positive(candidate.throughput_rps) or !positive(candidate.p95_ms) or candidate.peak_rss_bytes == 0 or candidate.measured_at_unix < 0) return error.InvalidMeasurement;
        if (candidate.resources.schema_version != 1) return error.UnsupportedResourceVersion;
        for (input.candidates[0..i]) |previous| if (std.mem.eql(u8, previous.id, candidate.id)) return error.DuplicateCandidate;
        const reason: Reason = if (candidate.failed_requests > 0)
            .failed_requests
        else if (!std.mem.eql(u8, candidate.workload, input.workload) or !std.mem.eql(u8, candidate.revision, input.revision) or !std.mem.eql(u8, candidate.environment, input.environment))
            .context_mismatch
        else if (candidate.measured_at_unix > now)
            .future_measurement
        else if (now - candidate.measured_at_unix > input.max_age_seconds)
            .stale
        else if (candidate.peak_rss_bytes > input.memory_budget_bytes)
            .memory_budget
        else if (candidate.p95_ms > input.p95_budget_ms)
            .latency_budget
        else
            .feasible;
        items[i] = .{ .candidate = candidate, .reason = reason };
        if (reason == .feasible and (selected == null or better(candidate, selected.?))) selected = candidate;
    }
    return std.json.Stringify.valueAlloc(allocator, .{
        .schema_version = @as(u8, 1),
        .basis = "supplied_measurements",
        .as_of_unix = now,
        .workload = input.workload,
        .revision = input.revision,
        .environment = input.environment,
        .memory_budget_bytes = input.memory_budget_bytes,
        .p95_budget_ms = input.p95_budget_ms,
        .max_age_seconds = input.max_age_seconds,
        .recommendation = if (selected) |c| c.id else null,
        .items = items,
    }, .{});
}

test "tuning finite measurement and label validation" {
    try std.testing.expect(!positive(std.math.inf(f64)));
    try std.testing.expect(!positive(std.math.nan(f64)));
    try std.testing.expect(!positive(0));
    try std.testing.expect(!labelValid(""));
    try std.testing.expect(!labelValid("line\n"));
    try std.testing.expect(labelValid("sqlite-linux-releasefast"));
}

test "tuning comparison frees scratch and deterministically breaks ties" {
    const candidate = Candidate{ .id = "a", .workload = "w", .revision = "r", .environment = "e", .measured_at_unix = 100, .throughput_rps = 10, .p95_ms = 5, .peak_rss_bytes = 1024, .failed_requests = 0, .resources = .{ .profile = .minimal, .reader_pool_cap = 2, .job_workers = 1, .job_stack_bytes = 1048576, .sqlite_cache_kib_per_connection = 256, .scheduler_enabled = false, .admin_enabled = true, .postgres_compiled = false, .s3_compiled = false, .file_inventory_compiled = false } };
    var other = candidate;
    other.id = "b";
    const input = Input{ .schema_version = 1, .workload = "w", .revision = "r", .environment = "e", .max_age_seconds = 10, .memory_budget_bytes = 1024, .p95_budget_ms = 5, .candidates = &.{ other, candidate } };
    const a = std.testing.allocator;
    const bytes = try std.json.Stringify.valueAlloc(a, input, .{});
    defer a.free(bytes);
    const result = try compare(a, bytes, 110);
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"recommendation\":\"a\"") != null);
    const stale = try compare(a, bytes, 111);
    defer a.free(stale);
    try std.testing.expect(std.mem.indexOf(u8, stale, "\"recommendation\":null") != null);
}
