const zb = @import("zigbase");
pub fn main() void {
    _ = zb.App(.{ .files = .{ .thumbnails = .{ .profiles = .{} } } }).files_config;
}
