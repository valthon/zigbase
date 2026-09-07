//! Offline registration inventory, not an authorization decision or OpenAPI schema.
//! Streams borrowed comptime metadata; no database, allocation, or handler calls.
const std = @import("std");
const server = @import("server.zig");
const events = @import("events.zig");

const Item = struct {
    method: []const u8,
    path: []const u8,
    source: enum { builtin, custom, realtime, feature_state },
    name: ?[]const u8 = null,
    // This is a declaration only. Handlers/hooks and deployment state can add gates.
    declared_access: ?[]const u8 = null,
    path_secret: ?events.PathSecretMeta = null,
    authed_collection: ?events.AuthedCollection = null,
};

fn emit(writer: *std.Io.Writer, first: *bool, item: Item) std.Io.Writer.Error!void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try writer.print("{f}", .{std.json.fmt(item, .{})});
}

pub fn write(comptime gates: server.Gates, comptime feature_path: ?[]const u8, comptime custom: []const events.RouteMeta, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("{\"protocol_version\":1,\"scope\":\"compiled-route-registrations\",\"items\":[");
    var first = true;
    // Preserve each dispatch table's declaration order. Registration is not proof
    // that a runtime handler accepts this deployment, principal, or request.
    for (server.Server(gates).routes) |route| {
        var item = Item{ .method = @tagName(route.method), .path = route.pattern, .source = .builtin };
        for (server.migration_builtin_operations) |operation| {
            if (route.method == operation.method and std.mem.eql(u8, route.pattern, operation.pattern)) {
                item.name = operation.operation_id;
                item.declared_access = operation.access;
                break;
            }
        }
        try emit(writer, &first, item);
    }
    for (server.realtime_upgrade_routes) |route| {
        try emit(writer, &first, .{ .method = @tagName(route.method), .path = route.pattern, .source = .realtime });
    }
    if (feature_path) |path| {
        for (server.feature_route_methods) |method| {
            try emit(writer, &first, .{ .method = @tagName(method), .path = path, .source = .feature_state, .declared_access = "public" });
        }
    }
    inline for (custom) |meta| {
        try emit(writer, &first, .{
            .method = @tagName(meta.method),
            .path = meta.path,
            .source = .custom,
            .name = meta.name,
            .declared_access = @tagName(meta.auth),
            .path_secret = meta.path_secret,
            .authed_collection = meta.authed_collection,
        });
    }
    try writer.writeAll("],\"reserved_prefixes\":[");
    if (gates.admin) try writer.writeAll("{\"path\":\"/_\",\"source\":\"admin\"}");
    try writer.writeAll("],\"coverage\":{\"static_files\":false,\"admin_endpoints\":false,\"runtime_authorization\":false},\"notes\":\"Registered patterns only; runtime configuration, collection rules, hooks and handlers may deny access. Null declared_access means unknown. A public declaration with path_secret still requires that secret. Order is preserved within each source, not a cross-source dispatch priority.\"}\n");
}

test "route inventory uses gated dispatch tables and redacted custom metadata" {
    const Handler = struct {
        fn route(_: *@import("ctx.zig").Ctx) anyerror!@import("http.zig").Response {
            unreachable; // discovery must never invoke a handler
        }
    };
    const App = @import("framework.zig").App(.{
        .admin = .disabled,
        .features = .{ .public_route = .disabled },
        .routes = .{.{ .method = .POST, .path = "/hook/:token", .handler = Handler.route, .auth = .{ .path_secret = .{ .param = "token", .source = .{ .config = "must-not-export" } } } }},
    });
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(App.route_gates, App.features_public_route, App.routes, &out.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const items = parsed.value.object.get("items").?.array.items;
    try std.testing.expectEqual(server.Server(App.route_gates).routes.len + server.realtime_upgrade_routes.len + 1, items.len);
    for (server.Server(App.route_gates).routes, 0..) |route, i| {
        try std.testing.expectEqualStrings(route.pattern, items[i].object.get("path").?.string);
        try std.testing.expectEqualStrings(@tagName(route.method), items[i].object.get("method").?.string);
    }
    const custom = items[items.len - 1].object;
    try std.testing.expectEqualStrings("token", custom.get("path_secret").?.object.get("param").?.string);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "must-not-export") == null);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("reserved_prefixes").?.array.items.len);
}

test "route inventory propagates writer failure" {
    var buf: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(error.WriteFailed, write(.{}, null, &.{}, &writer));
}
