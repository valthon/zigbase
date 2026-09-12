const zb = @import("zigbase");
pub fn main() void {
    _ = zb.App(.{ .files = .{ .thumbnails = .{ .imagemagick = .{ .executable = "/usr/bin/convert", .command_style = .convert }, .profiles = .{ .tiny = .{ .width = 1, .height = 1, .unknown = true } } } } }).files_config;
}
