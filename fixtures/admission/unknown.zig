const zigbase = @import("zigbase");
pub fn main() void {
    _ = zigbase.App(.{ .admission = .{ .max_requests = 1, .queue_size = 4 } }).admission_config;
}
