const zb = @import("zigbase");
pub fn main() void {
    _ = zb.App(.{ .files = .{ .thumbnails = .{ .imagemagick = .{ .executable = "convert" }, .profiles = .{ .tiny = .{ .width = 1, .height = 1 } } } } }).files_config;
}
