const std = @import("std");
const zb = @import("zigbase");
pub fn main(init: std.process.Init) !void {
    return zb.App(.{ .tenancy = .{ .enabled = true, .auth_collection = "users" }, .rest_idempotency = .{ .collections = .{ "posts", "tasks" }, .limits = .{ .namespace = "rest-fixture", .max_entries = 8, .max_result_bytes = 4096 } } }).runCli(init);
}
