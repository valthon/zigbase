fn magicApp(comptime requires_factor: bool) type {
    return zigbase.App(.{
        .auth = .{ .two_factor = .{ .factors = .{.totp} } },
        .collections = .{
            .members = .{ .type = .auth, .fields = .{}, .auth = .{ .two_factor = if (requires_factor) .required else .disabled } },
        },
        .routes = .{
            .{ .method = .POST, .path = "/api/members/magic/request", .handler = magicRequest, .auth = .public },
            .{ .method = .POST, .path = "/api/members/magic/confirm", .handler = magicConfirm, .auth = .public },
        },
    });
}

test "documented magic link authenticates once and binds email input" {
    var t = try zigbase.testing.start(magicApp(false), .{});
    defer t.deinit();
    const mail = try t.captureMail();
    _ = try t.createRecord("members", .{ .email = "member@example.test" });
    const missing = try t.request(.POST, "/api/members/magic/request", .{ .json = .{ .email = "unknown@example.test" } });
    try std.testing.expectEqual(@as(u16, 204), missing.status);
    const injected = try t.request(.POST, "/api/members/magic/request", .{ .json = .{ .email = "\" || true || email = \"" } });
    try std.testing.expectEqual(@as(u16, 204), injected.status);
    try std.testing.expectEqual(@as(usize, 0), mail.messages.items.len);
    const requested = try t.request(.POST, "/api/members/magic/request", .{ .json = .{ .email = "member@example.test" } });
    try std.testing.expectEqual(@as(u16, 204), requested.status);
    try std.testing.expectEqual(@as(usize, 1), mail.messages.items.len);
    const text = mail.messages.items[0].text;
    const start = (std.mem.indexOf(u8, text, "token=") orelse return error.MissingToken) + 6;
    const token = text[start..];
    const confirmed = try t.request(.POST, "/api/members/magic/confirm", .{ .json = .{ .token = token } });
    try std.testing.expectEqual(@as(u16, 200), confirmed.status);
    const issued = try confirmed.json(struct { token: []const u8 });
    try std.testing.expect(issued.token.len > 0);
    try std.testing.expect(confirmed.cookie("zb_auth") != null);
    const replay = try t.request(.POST, "/api/members/magic/confirm", .{ .json = .{ .token = token } });
    try std.testing.expectEqual(@as(u16, 400), replay.status);
}

test "documented magic link returns pending enrollment instead of a full session" {
    var t = try zigbase.testing.start(magicApp(true), .{});
    defer t.deinit();
    const mail = try t.captureMail();
    _ = try t.createRecord("members", .{ .email = "factor@example.test" });
    _ = try t.request(.POST, "/api/members/magic/request", .{ .json = .{ .email = "factor@example.test" } });
    try std.testing.expectEqual(@as(usize, 1), mail.messages.items.len);
    const text = mail.messages.items[0].text;
    const start = (std.mem.indexOf(u8, text, "token=") orelse return error.MissingToken) + 6;
    const confirmed = try t.request(.POST, "/api/members/magic/confirm", .{ .json = .{ .token = text[start..] } });
    try std.testing.expectEqual(@as(u16, 200), confirmed.status);
    const pending = try confirmed.json(struct { status: []const u8, pendingToken: []const u8 });
    try std.testing.expectEqualStrings("enrollment_required", pending.status);
    try std.testing.expect(pending.pendingToken.len > 0);
    try std.testing.expect(confirmed.cookie("zb_auth") == null);
}
