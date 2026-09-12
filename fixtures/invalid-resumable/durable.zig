const zigbase = @import("zigbase");
pub fn main() void {
    _ = zigbase.App(.{ .files = .{ .resumable = .{ .durable = true } } }).files_config;
}
