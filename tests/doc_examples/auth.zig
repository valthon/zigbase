test "documented custom method boots and rejects unverified link proofs" {
    var t = try zigbase.testing.start(RecipeApp, .{});
    defer t.deinit();
    const begin = try t.request(.POST, "/api/collections/members/auth/signed-link/initiate", .{});
    try std.testing.expectEqual(@as(u16, 204), begin.status);
    const invalid = try t.request(.POST, "/api/collections/members/auth/signed-link/complete", .{ .json = .{ .token = "not-a-signed-token" } });
    try std.testing.expectEqual(@as(u16, 400), invalid.status);
    const body = try invalid.json(struct { code: []const u8 });
    try std.testing.expectEqualStrings("bad_request", body.code);
    const missing = try t.request(.POST, "/api/collections/members/auth/signed-link/complete", .{ .json = .{} });
    try std.testing.expectEqual(@as(u16, 400), missing.status);
}
