//! Resource defaults, shared reader-retention capacity and compiled envelopes;
//! not a memory limit or feature selector. Explicit App(.pools) fields win.
//! Also imported by build.zig: keep this module free of application/backend
//! dependencies and generated build options; standard-library imports are safe.
const std = @import("std");
/// Shared backing-array capacity for both database backends' idle free lists.
pub const reader_pool_size = 16;
pub fn retainedReaderCap(requested: usize) usize {
    return @min(requested, reader_pool_size);
}
/// Null preserves SQLite's engine default; otherwise a soft KiB cache target.
pub fn cacheTargetKib(requested: u32) ?u32 {
    return if (requested == 0) null else @min(requested, std.math.maxInt(i32));
}
pub const Profile = enum { minimal, balanced, throughput };
pub const max_memory_workers = 64;
pub const default_memory_workers = 4;

pub const Pools = struct {
    readers: usize,
    jobs: usize,
    memory_jobs: usize,
    cache_kib: u32,
};

pub fn defaults(profile: Profile) Pools {
    return switch (profile) {
        .minimal => .{ .readers = 2, .jobs = 1, .memory_jobs = 1, .cache_kib = 256 },
        .balanced => .{ .readers = 16, .jobs = 2, .memory_jobs = default_memory_workers, .cache_kib = 1024 },
        .throughput => .{ .readers = 64, .jobs = 8, .memory_jobs = 8, .cache_kib = 4096 },
    };
}

/// Allowlisted compiled configuration: never contains deployment secrets or
/// claims to describe live connections, measured memory, or runtime backend selection.
pub const Report = struct {
    schema_version: u8 = 1,
    profile: ?Profile,
    reader_pool_cap: usize,
    // Older saved tuning reports predate configurability and used this fixed cap.
    realtime_connection_cap: u32 = 10_000,
    job_workers: usize,
    job_stack_bytes: usize,
    /// Configured lazy memory-job pool, not actual spawned threads or RSS.
    /// Null when loading reports produced before this field was introduced.
    memory_job_workers: ?usize = null,
    sqlite_cache_kib_per_connection: u32,
    scheduler_enabled: bool,
    admin_enabled: bool,
    postgres_compiled: bool,
    s3_compiled: bool,
    file_inventory_compiled: bool,
    // Old saved measurement documents lack this additive field.
    envelope: ?Envelope = null,
};

/// Independent configured quantities; never sum these into an RSS prediction.
pub const Envelope = struct {
    basis: []const u8 = "compiled_configuration_not_rss",
    http_admission_max_requests: ?u32,
    /// Shared count of synchronous HTTP callbacks and outstanding memory jobs.
    coordinated_admission_max_work: ?u32 = null,
    http_body_limit_source: []const u8 = "runtime_ZIGBASE_MAX_UPLOAD_SIZE",
    retained_reader_cap: usize,
    sqlite_cache_target_bytes_per_connection: ?u64,
    sqlite_writer_and_retained_readers_cache_target_bytes: ?u64,
    scheduler_stack_bytes: u64,
    /// Up to the configured lazy memory-job/submit workers' virtual stacks.
    memory_job_stack_bytes: u64,
    resumable: ?Resumable,
    exclusions: []const []const u8 = &.{
        "overflow_database_connections_and_non_cache_database_memory",
        "transport_buffers_before_admission_and_realtime_connections",
        "request_arenas_responses_and_upload_commit_copies",
        "queue_workers_plugins_runtime_and_allocator_overhead",
        "resumable_metadata_and_storage",
    },

    pub const Resumable = struct {
        max_sessions: usize,
        max_upload_bytes: usize,
        max_total_payload_bytes: usize,
        max_chunk_bytes: usize,
    };
};

pub const EnvelopeInput = struct {
    readers: usize,
    cache_kib: u32,
    scheduler_enabled: bool,
    job_workers: usize,
    memory_job_workers: usize,
    job_stack_bytes: usize,
    admission_max_requests: ?u32 = null,
    admission_max_work: ?u32 = null,
    resumable: ?Envelope.Resumable = null,
};

pub fn envelope(comptime input: EnvelopeInput) Envelope {
    const retained = retainedReaderCap(input.readers);
    const cache_bytes: ?u64 = if (cacheTargetKib(input.cache_kib)) |kib| @as(u64, kib) * 1024 else null;
    return .{
        .http_admission_max_requests = input.admission_max_requests,
        .coordinated_admission_max_work = input.admission_max_work,
        .retained_reader_cap = retained,
        .sqlite_cache_target_bytes_per_connection = cache_bytes,
        .sqlite_writer_and_retained_readers_cache_target_bytes = if (cache_bytes) |bytes| bytes * (retained + 1) else null,
        .scheduler_stack_bytes = if (input.scheduler_enabled) (@as(u64, input.job_workers) + 1) * input.job_stack_bytes else 0,
        .memory_job_stack_bytes = @as(u64, input.memory_job_workers) * input.job_stack_bytes,
        .resumable = input.resumable,
    };
}

test "resource envelope uses actual SQLite clamps and unknown engine defaults" {
    const input = EnvelopeInput{ .readers = 64, .cache_kib = std.math.maxInt(u32), .scheduler_enabled = false, .job_workers = 8, .memory_job_workers = 4, .job_stack_bytes = 1048576 };
    const e = envelope(input);
    try std.testing.expectEqual(@as(usize, 16), e.retained_reader_cap);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(i32)) * 1024, e.sqlite_cache_target_bytes_per_connection.?);
    try std.testing.expectEqual(e.sqlite_cache_target_bytes_per_connection.? * 17, e.sqlite_writer_and_retained_readers_cache_target_bytes.?);
    try std.testing.expectEqual(@as(u64, 0), e.scheduler_stack_bytes);
    try std.testing.expectEqual(@as(u64, 4 * 1048576), e.memory_job_stack_bytes);
    const zero = comptime blk: {
        var value = input;
        value.readers = 0;
        value.cache_kib = 0;
        break :blk value;
    };
    try std.testing.expectEqual(@as(usize, 0), envelope(zero).retained_reader_cap);
    try std.testing.expectEqual(null, envelope(zero).sqlite_writer_and_retained_readers_cache_target_bytes);
}

test "resource envelope includes scheduler workers and tick thread" {
    const e = envelope(.{ .readers = 0, .cache_kib = 1, .scheduler_enabled = true, .job_workers = 2, .memory_job_workers = 1, .job_stack_bytes = 1048576 });
    try std.testing.expectEqual(@as(u64, 3 * 1048576), e.scheduler_stack_bytes);
    try std.testing.expectEqual(@as(u64, 1048576), e.memory_job_stack_bytes);
    try std.testing.expectEqual(@as(u64, 1024), e.sqlite_writer_and_retained_readers_cache_target_bytes.?);
}
