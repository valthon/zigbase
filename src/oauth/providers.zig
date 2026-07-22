const std = @import("std");

pub const ProviderMapping = struct {
    id: []const u8,
    email: ?[]const u8 = null,
    emailVerified: ?[]const u8 = null,
    name: ?[]const u8 = null,
    avatar: ?[]const u8 = null,
};

pub const Provider = struct {
    name: []const u8,
    authURL: []const u8,
    tokenURL: []const u8,
    userinfoURL: []const u8,
    scopes: []const []const u8,
    mapping: ProviderMapping,
};

pub const Identity = struct {
    providerUserId: []const u8,
    email: ?[]const u8 = null,
    emailVerified: bool = false,
    name: ?[]const u8 = null,
    avatarUrl: ?[]const u8 = null,
};

pub const ExtractError = error{NoProviderId} || std.mem.Allocator.Error || error{InvalidJson};

const presets = [_]Provider{
    .{
        .name = "google",
        .authURL = "https://accounts.google.com/o/oauth2/v2/auth",
        .tokenURL = "https://oauth2.googleapis.com/token",
        .userinfoURL = "https://openidconnect.googleapis.com/v1/userinfo",
        .scopes = &.{ "openid", "email", "profile" },
        .mapping = .{ .id = "sub", .email = "email", .emailVerified = "email_verified", .name = "name", .avatar = "picture" },
    },
    .{
        .name = "github",
        .authURL = "https://github.com/login/oauth/authorize",
        .tokenURL = "https://github.com/login/oauth/access_token",
        .userinfoURL = "https://api.github.com/user",
        .scopes = &.{ "read:user", "user:email" },
        .mapping = .{ .id = "id", .email = "email", .emailVerified = null, .name = "name", .avatar = "avatar_url" },
    },
    .{
        .name = "microsoft",
        .authURL = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
        .tokenURL = "https://login.microsoftonline.com/common/oauth2/v2.0/token",
        .userinfoURL = "https://graph.microsoft.com/oidc/userinfo",
        .scopes = &.{ "openid", "email", "profile" },
        .mapping = .{ .id = "sub", .email = "email", .emailVerified = "email_verified", .name = "name", .avatar = null },
    },
    .{
        .name = "discord",
        .authURL = "https://discord.com/api/oauth2/authorize",
        .tokenURL = "https://discord.com/api/oauth2/token",
        .userinfoURL = "https://discord.com/api/users/@me",
        .scopes = &.{ "identify", "email" },
        .mapping = .{ .id = "id", .email = "email", .emailVerified = "verified", .name = "username", .avatar = "avatar" },
    },
};

/// Look up a built-in preset by name. Returns null for an unknown name.
pub fn lookup(name: []const u8) ?Provider {
    for (presets) |p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

/// Coerce a JSON value to an allocated string. Strings pass through; integers are formatted;
/// bools render "true"/"false"; everything else -> null.
fn jsonToStr(alloc: std.mem.Allocator, v: std.json.Value) !?[]const u8 {
    return switch (v) {
        .string => |s| try alloc.dupe(u8, s),
        .integer => |n| try std.fmt.allocPrint(alloc, "{d}", .{n}),
        .bool => |b| try alloc.dupe(u8, if (b) "true" else "false"),
        else => null,
    };
}

fn jsonToBool(v: std.json.Value) bool {
    return switch (v) {
        .bool => |b| b,
        .string => |s| std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1"),
        else => false,
    };
}

/// Extract a normalized Identity from a userinfo JSON document using `provider.mapping`.
pub fn extractIdentity(alloc: std.mem.Allocator, provider: Provider, json: []const u8) ExtractError!Identity {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch return error.InvalidJson;
    defer parsed.deinit(); // scratch tree; the fields we keep are duped onto `alloc` below
    const root = parsed.value;
    if (root != .object) return error.InvalidJson;
    const obj = root.object;

    const id_val = obj.get(provider.mapping.id) orelse return error.NoProviderId;
    const pid = (try jsonToStr(alloc, id_val)) orelse return error.NoProviderId;
    errdefer alloc.free(pid);

    var out = Identity{ .providerUserId = pid };
    errdefer if (out.email) |e| alloc.free(e);
    errdefer if (out.name) |n| alloc.free(n);
    errdefer if (out.avatarUrl) |v| alloc.free(v);
    if (provider.mapping.email) |k| if (obj.get(k)) |v| {
        out.email = try jsonToStr(alloc, v);
    };
    if (provider.mapping.emailVerified) |k| if (obj.get(k)) |v| {
        out.emailVerified = jsonToBool(v);
    };
    if (provider.mapping.name) |k| if (obj.get(k)) |v| {
        out.name = try jsonToStr(alloc, v);
    };
    if (provider.mapping.avatar) |k| if (obj.get(k)) |v| {
        out.avatarUrl = try jsonToStr(alloc, v);
    };
    return out;
}

test "lookup returns presets and null for unknown" {
    try std.testing.expect(lookup("google") != null);
    try std.testing.expect(lookup("github") != null);
    try std.testing.expect(lookup("microsoft") != null);
    try std.testing.expect(lookup("discord") != null);
    try std.testing.expect(lookup("nope") == null);
    const g = lookup("google").?;
    try std.testing.expectEqualStrings("https://oauth2.googleapis.com/token", g.tokenURL);
    try std.testing.expectEqualStrings("sub", g.mapping.id);
}

fn freeIdentity(alloc: std.mem.Allocator, id: Identity) void {
    alloc.free(id.providerUserId);
    if (id.email) |e| alloc.free(e);
    if (id.name) |n| alloc.free(n);
    if (id.avatarUrl) |v| alloc.free(v);
}

test "extractIdentity reads google-shaped userinfo" {
    const a = std.testing.allocator;
    const json =
        \\{"sub":"123","email":"u@x.io","email_verified":true,"name":"U","picture":"http://p"}
    ;
    const id = try extractIdentity(a, lookup("google").?, json);
    defer freeIdentity(a, id);
    try std.testing.expectEqualStrings("123", id.providerUserId);
    try std.testing.expectEqualStrings("u@x.io", id.email.?);
    try std.testing.expectEqual(true, id.emailVerified);
    try std.testing.expectEqualStrings("U", id.name.?);
}

test "extractIdentity reads github-shaped userinfo (numeric id, no email_verified)" {
    const a = std.testing.allocator;
    const json =
        \\{"id":456,"login":"octo","email":"o@x.io","avatar_url":"http://a"}
    ;
    const id = try extractIdentity(a, lookup("github").?, json);
    defer freeIdentity(a, id);
    try std.testing.expectEqualStrings("456", id.providerUserId);
    try std.testing.expectEqualStrings("o@x.io", id.email.?);
    try std.testing.expectEqual(false, id.emailVerified);
}

test "extractIdentity fails when the id field is missing" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.NoProviderId, extractIdentity(a, lookup("google").?, "{\"email\":\"x@y.z\"}"));
}
