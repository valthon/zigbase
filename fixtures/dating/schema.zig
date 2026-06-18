//! The SP2.1b dating-app coverage fixture — exercises every schema capability in
//! one coherent domain. The generator reads this via @import("app").App.collections.
//! Plan 2: collection-scoped photo privacy (public `photos` vs auth-required
//! `privatePhotos`) + access rules so a live client can exercise the API.
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
            // Public signup + public profile browsing; self-service edits.
            .rules = .{ .list = "@public", .view = "@public", .create = "@public", .update = "@request.auth.id = id", .delete = "@request.auth.id = id" },
        },
        .tags = .{
            .fields = .{
                .{ .name = "label", .type = .text, .required = true, .unique = true },
            },
            .rules = .{ .list = "@public", .view = "@public", .create = "@public", .update = "@public", .delete = "@public" },
        },
        .photos = .{
            .fields = .{
                .{ .name = "owner", .type = .relation, .target = "profiles" },
                .{ .name = "image", .type = .file },
                .{ .name = "caption", .type = .text },
                .{ .name = "tags", .type = .relation, .target = "tags", .maxSelect = 20 },
            },
            // Public photos: anyone can browse; create/edit need auth.
            .rules = .{ .list = "@public", .view = "@public", .create = "@request.auth.id != \"\"", .update = "@request.auth.id != \"\"", .delete = "@request.auth.id != \"\"" },
        },
        // Private photos as a separate dependent collection (no per-field privacy):
        // owner-only list/view, so the IMAGE FILE is gated by the auth-required
        // viewRule — accessing it requires a files/token. Individual records so a
        // future feature could grant access to a specific private photo.
        .privatePhotos = .{
            .fields = .{
                .{ .name = "owner", .type = .relation, .target = "profiles" },
                .{ .name = "image", .type = .file },
                .{ .name = "caption", .type = .text },
            },
            .rules = .{ .list = "@request.auth.id = owner", .view = "@request.auth.id = owner", .create = "@request.auth.id != \"\"", .update = "@request.auth.id = owner", .delete = "@request.auth.id = owner" },
        },
        .messages = .{
            .fields = .{
                .{ .name = "from", .type = .relation, .target = "profiles" },
                .{ .name = "to", .type = .relation, .target = "profiles" },
                .{ .name = "body", .type = .text, .required = true },
                .{ .name = "sentAt", .type = .autodate, .onCreate = true },
                .{ .name = "read", .type = .@"bool" },
            },
            .rules = .{ .list = "@public", .view = "@public", .create = "@request.auth.id != \"\"", .update = "@request.auth.id != \"\"", .delete = "@request.auth.id != \"\"" },
        },
        .winks = .{
            .fields = .{
                .{ .name = "from", .type = .relation, .target = "profiles" },
                .{ .name = "to", .type = .relation, .target = "profiles" },
                .{ .name = "createdAt", .type = .autodate, .onCreate = true },
            },
            .rules = .{ .list = "@public", .view = "@public", .create = "@request.auth.id != \"\"", .update = "@request.auth.id != \"\"", .delete = "@request.auth.id != \"\"" },
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
            .rules = .{ .list = "@public", .view = "@public", .create = "@request.auth.id != \"\"", .update = "@request.auth.id != \"\"", .delete = "@request.auth.id != \"\"" },
        },
    },
});

// The generator's `app` module import resolves `App.collections`. A thin `main`
// keeps the module runnable as a normal zigbase app (Task 2 builds it as a server).
pub fn main(init: std.process.Init) !void {
    return App.runCli(init);
}
