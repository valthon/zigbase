const std = @import("std");

/// The per-request context rules evaluate against. SP4 builds an empty one (no auth yet);
/// SP5's auth middleware fills `auth`/`is_superuser`.
pub const RequestContext = struct {
    auth: ?std.json.Value = null, // authenticated record object; null = unauthenticated
    is_superuser: bool = false,
    data: ?std.json.Value = null, // request body (create/update rules)
    method: []const u8 = "",

    /// Resolve a `@request.*` macro path to a text value. Returns null for an unknown macro.
    /// `@request.auth.<field>` and `@request.data.<field>` yield "" when absent/unauthenticated.
    pub fn resolveMacro(self: *const RequestContext, path: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, path, "@request.method")) return self.method;
        if (std.mem.startsWith(u8, path, "@request.auth.")) {
            const field = path["@request.auth.".len..];
            return objField(self.auth, field);
        }
        if (std.mem.startsWith(u8, path, "@request.data.")) {
            const field = path["@request.data.".len..];
            return objField(self.data, field);
        }
        return null;
    }
};

/// Read a string-ish field from an optional JSON object; "" when the object is null/absent or
/// the field is missing; non-string values render as "" (SP4 macros are text-only).
fn objField(obj: ?std.json.Value, field: []const u8) []const u8 {
    const o = obj orelse return "";
    if (o != .object) return "";
    const v = o.object.get(field) orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

test "resolveMacro: auth absent -> empty, present -> value; data; method" {
    var ctx = RequestContext{ .method = "GET" };
    try std.testing.expectEqualStrings("", ctx.resolveMacro("@request.auth.id").?);
    try std.testing.expectEqualStrings("GET", ctx.resolveMacro("@request.method").?);
    try std.testing.expect(ctx.resolveMacro("@request.bogus") == null);

    var auth_obj: std.json.ObjectMap = .empty;
    try auth_obj.put(std.testing.allocator, "id", .{ .string = "u1" });
    defer auth_obj.deinit(std.testing.allocator);
    ctx.auth = .{ .object = auth_obj };
    try std.testing.expectEqualStrings("u1", ctx.resolveMacro("@request.auth.id").?);
}
