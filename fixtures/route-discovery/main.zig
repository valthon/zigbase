const std = @import("std");
const zigbase = @import("zigbase");

fn handler(_: *zigbase.Ctx) anyerror!zigbase.http.Response {
    @panic("offline route discovery invoked an application handler");
}

fn migration(_: *zigbase.Migrator) !void {
    @panic("offline discovery invoked a migration callback");
}

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .admin = .disabled,
        .static_files = .disabled,
        .auth = .{ .methods = .{ .builtins = .{.password} } },
        .features = .{ .public_route = "/public/flags" },
        .collections = .{ .members = .{ .type = .auth, .fields = .{} } },
        .migrations = &[_]zigbase.Migration{
            .{ .id = "z_first", .up = migration },
            .{ .id = "a_second", .change = migration },
            .{ .id = "explicit", .change = migration, .down = migration, .transactional = false },
            .{ .id = "rejected", .change = migration, .transactional = false },
        },
        .routes = .{
            .{ .method = .GET, .path = "/api/state", .handler = handler, .auth = .public },
            .{ .method = .POST, .path = "/hooks/:token", .handler = handler, .auth = .{ .path_secret = .{ .param = "token", .source = .{ .config = "FIXTURE-PRIVATE-CREDENTIAL" } } } },
            .{ .method = .GET, .path = "/member", .handler = handler, .auth = .{ .authed = "members", .allow_superuser = true } },
            .{ .method = .GET, .path = "/privileged", .handler = handler },
            .{ .method = .GET, .path = "/ordered/:id", .name = "firstMatch", .handler = handler, .auth = .authed },
            .{ .method = .GET, .path = "/ordered/literal", .name = "shadowedLiteral", .handler = handler, .auth = .public },
        },
    }).runCli(init);
}
