const zigbase = @import("zigbase");
pub fn main() void {
    _ = zigbase.App(.{ .files = .{ .resumable = .{ .max_sessions = 0 } } }).files_config;
}
