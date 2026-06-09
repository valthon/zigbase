const std = @import("std");
const providers = @import("providers.zig");

pub const Method = enum { GET, POST };
pub const Header = struct { name: []const u8, value: []const u8 };
pub const Response = struct { status: u16, body: []const u8 };

pub const TransportError = error{ TransportFailed, ResponseTooLarge } || std.mem.Allocator.Error;

/// Injectable HTTP transport. Production wraps std.http.Client (Plan 6b); tests inject a stub.
pub const Transport = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, method: Method, url: []const u8, headers: []const Header, body: ?[]const u8) TransportError!Response,
};

pub const ClientError = error{ ProviderError, InvalidResponse } || TransportError || providers.ExtractError;

fn is2xx(status: u16) bool {
    return status >= 200 and status < 300;
}

/// URL-encode `s` (RFC 3986 unreserved kept; everything else %XX).
fn urlEncode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const hex = "0123456789ABCDEF";
    for (s) |ch| {
        const unreserved = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (unreserved) {
            try out.append(alloc, ch);
        } else {
            try out.append(alloc, '%');
            try out.append(alloc, hex[ch >> 4]);
            try out.append(alloc, hex[ch & 0x0f]);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Exchange an authorization code for an access token (form-encoded POST to tokenURL).
pub fn exchangeCode(
    transport: Transport,
    alloc: std.mem.Allocator,
    provider: providers.Provider,
    client_id: []const u8,
    client_secret: []const u8,
    code: []const u8,
    code_verifier: []const u8,
    redirect_uri: []const u8,
) ClientError![]const u8 {
    const body = try std.fmt.allocPrint(alloc, "grant_type=authorization_code&code={s}&redirect_uri={s}&code_verifier={s}&client_id={s}&client_secret={s}", .{
        try urlEncode(alloc, code),
        try urlEncode(alloc, redirect_uri),
        try urlEncode(alloc, code_verifier),
        try urlEncode(alloc, client_id),
        try urlEncode(alloc, client_secret),
    });
    const headers = [_]Header{
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "accept", .value = "application/json" },
    };
    const resp = try transport.call(transport.ctx, alloc, .POST, provider.tokenURL, &headers, body);
    if (!is2xx(resp.status)) return error.ProviderError;

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch return error.InvalidResponse;
    if (parsed.value != .object) return error.InvalidResponse;
    const at = parsed.value.object.get("access_token") orelse return error.InvalidResponse;
    if (at != .string) return error.InvalidResponse;
    return try alloc.dupe(u8, at.string);
}

/// Fetch + normalize the user's identity from the provider's userinfo endpoint.
pub fn fetchIdentity(
    transport: Transport,
    alloc: std.mem.Allocator,
    provider: providers.Provider,
    access_token: []const u8,
) ClientError!providers.Identity {
    const auth_value = try std.fmt.allocPrint(alloc, "Bearer {s}", .{access_token});
    const headers = [_]Header{
        .{ .name = "authorization", .value = auth_value },
        .{ .name = "accept", .value = "application/json" },
    };
    const resp = try transport.call(transport.ctx, alloc, .GET, provider.userinfoURL, &headers, null);
    if (!is2xx(resp.status)) return error.ProviderError;
    return providers.extractIdentity(alloc, provider, resp.body);
}

// A stub transport that returns canned responses keyed by URL substring.
const StubTransport = struct {
    token_status: u16 = 200,
    token_body: []const u8 = "{\"access_token\":\"AT123\",\"token_type\":\"bearer\"}",
    userinfo_status: u16 = 200,
    userinfo_body: []const u8 = "{\"sub\":\"P1\",\"email\":\"u@x.io\",\"email_verified\":true}",

    fn call(ctx: *anyopaque, alloc: std.mem.Allocator, method: Method, url: []const u8, headers: []const Header, body: ?[]const u8) TransportError!Response {
        _ = method;
        _ = headers;
        _ = body;
        const self: *StubTransport = @ptrCast(@alignCast(ctx));
        if (std.mem.indexOf(u8, url, "token") != null)
            return .{ .status = self.token_status, .body = try alloc.dupe(u8, self.token_body) };
        return .{ .status = self.userinfo_status, .body = try alloc.dupe(u8, self.userinfo_body) };
    }

    fn transport(self: *StubTransport) Transport {
        return .{ .ctx = self, .call = call };
    }
};

test "exchangeCode returns the access token on 200" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var stub = StubTransport{};
    const tok = try exchangeCode(stub.transport(), a, providers.lookup("google").?, "cid", "secret", "code", "verifier", "https://app/cb");
    try std.testing.expectEqualStrings("AT123", tok);
}

test "exchangeCode fails on a non-2xx token response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var stub = StubTransport{ .token_status = 400, .token_body = "{\"error\":\"invalid_grant\"}" };
    try std.testing.expectError(error.ProviderError, exchangeCode(stub.transport(), a, providers.lookup("google").?, "cid", "secret", "code", "verifier", "https://app/cb"));
}

test "fetchIdentity returns a normalized identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var stub = StubTransport{};
    const id = try fetchIdentity(stub.transport(), a, providers.lookup("google").?, "AT123");
    try std.testing.expectEqualStrings("P1", id.providerUserId);
    try std.testing.expectEqualStrings("u@x.io", id.email.?);
    try std.testing.expectEqual(true, id.emailVerified);
}

test "fetchIdentity fails on a non-2xx userinfo response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var stub = StubTransport{ .userinfo_status = 401, .userinfo_body = "unauthorized" };
    try std.testing.expectError(error.ProviderError, fetchIdentity(stub.transport(), a, providers.lookup("google").?, "AT"));
}
