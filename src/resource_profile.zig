//! Transparent defaults for existing resource levers, not a memory limit or
//! feature selector. Explicit App(.pools) fields always override these values.
pub const Profile = enum { minimal, balanced, throughput };

pub const Pools = struct {
    readers: usize,
    jobs: usize,
    cache_kib: u32,
};

pub fn defaults(profile: Profile) Pools {
    return switch (profile) {
        .minimal => .{ .readers = 2, .jobs = 1, .cache_kib = 256 },
        .balanced => .{ .readers = 16, .jobs = 2, .cache_kib = 1024 },
        .throughput => .{ .readers = 64, .jobs = 8, .cache_kib = 4096 },
    };
}

/// Allowlisted compiled configuration: never contains deployment secrets or
/// claims to describe live connections, measured memory, or runtime backend selection.
pub const Report = struct {
    schema_version: u8 = 1,
    profile: ?Profile,
    reader_pool_cap: usize,
    job_workers: usize,
    job_stack_bytes: usize,
    sqlite_cache_kib_per_connection: u32,
    scheduler_enabled: bool,
    admin_enabled: bool,
    postgres_compiled: bool,
    s3_compiled: bool,
    file_inventory_compiled: bool,
};
