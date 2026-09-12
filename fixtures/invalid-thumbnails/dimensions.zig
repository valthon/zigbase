const zb = @import("zigbase");
pub fn main() void {
    _ = zb.App(.{ .files = .{ .thumbnails = .{ .profiles = .{ .tiny = .{ .width = 0, .height = 1 } } } } }).files_config;
}
