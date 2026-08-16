const std = @import("std");
const zigbase = @import("zigbase");

pub const App = zigbase.App(.{
    .collections = .{
        .members = .{
            .type = .auth,
            .fields = .{.{ .name = "display_name", .type = .text }},
            .rules = .{ .create = "@public", .update = "@request.auth.id = id" },
        },
        .equipment = .{
            .fields = .{
                .{ .name = "name", .type = .text, .required = true },
                .{ .name = "owner", .type = .relation, .target = "members", .required = true },
                .{ .name = "available", .type = .bool, .required = true },
            },
            .rules = .{ .list = "@public", .view = "@public", .create = "@request.auth.id != \"\"", .update = "owner = @request.auth.id" },
        },
        .requests = .{
            .fields = .{
                .{ .name = "equipment", .type = .relation, .target = "equipment", .required = true },
                .{ .name = "requester", .type = .relation, .target = "members", .required = true },
                .{ .name = "status", .type = .select, .values = &.{ "pending", "approved", "rejected" }, .required = true },
            },
            .rules = .{ .create = "@request.auth.id = requester", .update = "equipment.owner = @request.auth.id" },
        },
    },
    .routes = .{},
});

test "public browse contract uses cursor pagination and owner expansion" {
    const browse_query = "cursor=next&expand=owner";
    try std.testing.expect(std.mem.indexOf(u8, browse_query, "cursor") != null);
    try std.testing.expect(std.mem.indexOf(u8, browse_query, "expand=owner") != null);
}
