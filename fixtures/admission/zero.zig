const zigbase = @import("zigbase");
pub fn main() void {
    _ = zigbase.App(.{ .admission = .{ .max_requests = 0, .max_job_bytes = 1 } }).admission_config;
}
