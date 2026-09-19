const std = @import("std");
const zb = @import("zigbase");

// A project/task application for tools/application_capacity.py. All measured
// traffic uses ordinary records APIs as tenant members, never a privileged route.
pub fn main(init: std.process.Init) !void {
    const member = "@request.auth.id != \"\"";
    return zb.App(.{
        .tenancy = .{ .enabled = true, .auth_collection = "users" },
        .collections = .{
            .users = .{ .type = .auth, .fields = .{} },
            .projects = .{
                .fields = .{
                    .{ .name = "account", .type = .text, .required = true },
                    .{ .name = "title", .type = .text, .required = true, .max = 128 },
                },
                .tenant_field = "account",
                .rules = .{ .list = member, .view = member },
            },
            .tasks = .{
                .fields = .{
                    .{ .name = "account", .type = .text, .required = true },
                    .{ .name = "project", .type = .relation, .target = "projects", .required = true },
                    .{ .name = "title", .type = .text, .required = true, .max = 128 },
                },
                .tenant_field = "account",
                .rules = .{ .list = member, .view = member, .update = member },
                .indexes = .{.{ .name = "capacity_tasks_account_id", .fields = .{ "account", "id" } }},
            },
        },
    }).runCli(init);
}
