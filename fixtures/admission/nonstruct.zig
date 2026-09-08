const zigbase = @import("zigbase");
pub fn main() void {
    _ = zigbase.App(.{ .admission = true }).admission_config;
}
