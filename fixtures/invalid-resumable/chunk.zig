const zigbase = @import("zigbase");
pub fn main() void {
    _ = zigbase.App(.{ .files = .{ .resumable = .{ .max_upload_bytes = 8, .max_chunk_bytes = 9 } } }).files_config;
}
