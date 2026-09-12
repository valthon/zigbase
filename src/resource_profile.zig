//! Transparent defaults for existing resource levers, not a memory limit or
//! feature selector. Explicit App(.pools) fields always override these values.
//! Also imported by build.zig: keep this module free of application/backend
//! dependencies and generated build options; standard-library imports are safe.
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
};
