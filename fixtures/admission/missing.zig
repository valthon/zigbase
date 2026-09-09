const zigbase = @import("zigbase");
pub fn main() void {
    _ = zigbase.App(.{ .admission = .{} }).admission_config;
}
