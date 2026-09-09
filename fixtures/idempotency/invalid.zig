const zb = @import("zigbase");
pub fn main() void {
    _ = zb.Idempotency(.{ .namespace = "test", .max_entries = 0 });
}
