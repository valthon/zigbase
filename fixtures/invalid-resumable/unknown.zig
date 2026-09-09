const zigbase = @import("zigbase");
pub fn main() void {
    _ = zigbase.App(.{ .files = .{ .resumable = .{ .unknown_limit = 3 } } }).files_config;
}
