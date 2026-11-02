test "documented abilities example provisions its built-in account relation" {
    var t = try zigbase.testing.start(App, .{});
    defer t.deinit();
    try std.testing.expect(t.app().tenancy.enabled);
}
