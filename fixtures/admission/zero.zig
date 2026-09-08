const zigbase = @import("zigbase");
pub fn main() void {
    _ = zigbase.App(.{ .admission = .{ .max_requests = 0 } }).admission_config;
}
