const TestApp = zigbase.App(.{
    .collections = .{
        .users = .{ .type = .auth, .fields = .{} },
        .services = .{ .type = .auth, .fields = .{} },
        .simulators = .{ .fields = .{.{ .name = "owner", .type = .relation, .target = "users" }} },
        .listings = .{ .fields = .{.{ .name = "simulator", .type = .relation, .target = "simulators" }} },
        .bookings = .{
            .fields = .{
                .{ .name = "listing", .type = .relation, .target = "listings" },
                .{ .name = "status", .type = .text },
            },
            .rules = .{ .view = "@request.auth.id = listing.simulator.owner", .update = "@request.auth.id = listing.simulator.owner" },
        },
    },
    .routes = .{.{ .method = .POST, .path = "/api/bookings/:id/confirm", .handler = confirmBooking, .auth = .authed }},
});

test "documented booking route conceals other owners and enforces the transition" {
    var t = try zigbase.testing.start(TestApp, .{});
    defer t.deinit();
    const alice = try t.createRecord("users", .{ .email = "alice@example.test" });
    const bob = try t.createRecord("users", .{ .email = "bob@example.test" });
    const service = try t.createRecord("services", .{ .email = "service@example.test" });
    const simulator = try t.createRecord("simulators", .{ .owner = alice.object.get("id").?.string });
    const listing = try t.createRecord("listings", .{ .simulator = simulator.object.get("id").?.string });
    const booking = try t.createRecord("bookings", .{ .listing = listing.object.get("id").?.string, .status = "pending" });
    const alice_auth = try t.mintSession("users", alice.object.get("id").?.string);
    const bob_auth = try t.mintSession("users", bob.object.get("id").?.string);
    const service_auth = try t.mintSession("services", service.object.get("id").?.string);
    const id = booking.object.get("id").?.string;
    const path = try std.fmt.allocPrint(t.allocator, "/api/bookings/{s}/confirm", .{id});
    defer t.allocator.free(path);
    const rest_path = try std.fmt.allocPrint(t.allocator, "/api/collections/bookings/records/{s}", .{id});
    defer t.allocator.free(rest_path);

    const denied_rest = try t.request(.PATCH, rest_path, .{ .auth = bob_auth, .json = .{ .status = "confirmed" } });
    try std.testing.expectEqual(@as(u16, 404), denied_rest.status);
    const denied_route = try t.request(.POST, path, .{ .auth = bob_auth });
    try std.testing.expectEqual(@as(u16, 404), denied_route.status);
    const wrong_collection = try t.request(.POST, path, .{ .auth = service_auth });
    try std.testing.expectEqual(@as(u16, 403), wrong_collection.status);
    const unchanged = try t.request(.GET, rest_path, .{ .auth = alice_auth });
    const pending = try unchanged.json(struct { status: []const u8 });
    try std.testing.expectEqualStrings("pending", pending.status);
    const allowed = try t.request(.POST, path, .{ .auth = alice_auth });
    try std.testing.expectEqual(@as(u16, 200), allowed.status);
    const confirmed = try allowed.json(struct { status: []const u8 });
    try std.testing.expectEqualStrings("confirmed", confirmed.status);
    const repeated = try t.request(.POST, path, .{ .auth = alice_auth });
    try std.testing.expectEqual(@as(u16, 409), repeated.status);
    const missing = try t.request(.POST, "/api/bookings/missing/confirm", .{ .auth = alice_auth });
    try std.testing.expectEqual(@as(u16, 404), missing.status);
}
