//! The SP2.1b dating-app coverage fixture — exercises every schema capability in
//! one coherent domain. The generator reads this via @import("app").App.collections.
const std = @import("std");
const zigbase = @import("zigbase");

pub const App = zigbase.App(.{
    .collections = .{
        .profiles = .{
            .type = .auth,
            .fields = .{
                .{ .name = "name", .type = .text },
                .{ .name = "bio", .type = .editor },
                .{ .name = "website", .type = .url },
                .{ .name = "age", .type = .number, .mode = .int },
                .{ .name = "gender", .type = .select, .values = .{ "female", "male", "nonbinary", "other" } },
                .{ .name = "avatar", .type = .file },
            },
        },
        .tags = .{
            .fields = .{
                .{ .name = "label", .type = .text, .required = true, .unique = true },
            },
        },
        .photos = .{
            .fields = .{
                .{ .name = "owner", .type = .relation, .target = "profiles" },
                .{ .name = "image", .type = .file },
                .{ .name = "visibility", .type = .select, .values = .{ "public", "private" } },
                .{ .name = "caption", .type = .text },
                .{ .name = "tags", .type = .relation, .target = "tags", .maxSelect = 20 },
            },
        },
        .messages = .{
            .fields = .{
                .{ .name = "from", .type = .relation, .target = "profiles" },
                .{ .name = "to", .type = .relation, .target = "profiles" },
                .{ .name = "body", .type = .text, .required = true },
                .{ .name = "sentAt", .type = .autodate, .onCreate = true },
                .{ .name = "read", .type = .@"bool" },
            },
        },
        .winks = .{
            .fields = .{
                .{ .name = "from", .type = .relation, .target = "profiles" },
                .{ .name = "to", .type = .relation, .target = "profiles" },
                .{ .name = "createdAt", .type = .autodate, .onCreate = true },
            },
        },
        .subscriptions = .{
            .fields = .{
                .{ .name = "profile", .type = .relation, .target = "profiles" },
                .{ .name = "plan", .type = .select, .values = .{ "free", "plus", "premium" } },
                .{ .name = "price", .type = .number, .mode = .fixed, .scale = 2 },
                .{ .name = "renewsAt", .type = .date, .min = "2020-01-01", .max = "2099-12-31" },
                .{ .name = "active", .type = .@"bool" },
                .{ .name = "metadata", .type = .json },
            },
        },
    },
});

// The generator's `app` module import resolves `App.collections`. A thin `main`
// keeps the module runnable as a normal zigbase app too (not required by codegen).
pub fn main(init: std.process.Init) !void {
    return App.runCli(init);
}
