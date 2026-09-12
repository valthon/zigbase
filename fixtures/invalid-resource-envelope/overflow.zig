const std = @import("std");
const resources = @import("resources");
const report = resources.envelope(.{
    .readers = 0,
    .cache_kib = 0,
    .scheduler_enabled = true,
    .job_workers = 1,
    .memory_job_workers = 1,
    .job_stack_bytes = std.math.maxInt(usize),
});
pub fn main() void {
    _ = report;
}
