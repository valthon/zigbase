const std = @import("std");
const zb = @import("zigbase");
pub fn main(init: std.process.Init) !void {
    return zb.App(.{
        .routes = .{.{ .method = .POST, .path = "/api/bookings/:id/cancel-idempotent", .handler = @import("cancel_example").handle, .auth = .authed }},
    }).runCli(init);
}
