const std = @import("std");
const providers = @import("providers.zig");
const urlenc = @import("../url.zig");

pub const Method = enum { GET, POST };
pub const Header = struct { name: []const u8, value: []const u8 };
/// A transport response. OWNERSHIP CONTRACT: `body` is **transport-owned** — a caller must NOT
/// free it and must `dupe` anything it needs to retain. The production transport (`httpCall`)
/// backs `body` with a sub-slice of a fixed response buffer scoped to the request arena, so an
/// `alloc.free(resp.body)` would be an invalid free. Stubs return a borrowed/static slice for the
/// same reason. (See `exchangeCode` and `discovery.resolve`.)
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
    // Callers pass a request arena in practice, but this owns its scratch either way: each
    // percent-encoded field, the form body, and the JSON tree are released on every exit path.
    // (`resp.body` is deliberately NOT freed — it belongs to the Transport, and the production
    // one returns a sub-slice of a larger fixed buffer, so freeing it would be an invalid free.)
    const enc_code = try urlenc.percentEncode(alloc, code);
    defer alloc.free(enc_code);
    const enc_redirect = try urlenc.percentEncode(alloc, redirect_uri);
    defer alloc.free(enc_redirect);
    const enc_verifier = try urlenc.percentEncode(alloc, code_verifier);
    defer alloc.free(enc_verifier);
    const enc_client_id = try urlenc.percentEncode(alloc, client_id);
    defer alloc.free(enc_client_id);
    const enc_secret = try urlenc.percentEncode(alloc, client_secret);
    defer alloc.free(enc_secret);

    const body = try std.fmt.allocPrint(alloc, "grant_type=authorization_code&code={s}&redirect_uri={s}&code_verifier={s}&client_id={s}&client_secret={s}", .{
        enc_code, enc_redirect, enc_verifier, enc_client_id, enc_secret,
    });
    defer alloc.free(body);
    const headers = [_]Header{
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "accept", .value = "application/json" },
    };
    const resp = try transport.call(transport.ctx, alloc, .POST, provider.tokenURL, &headers, body);
    if (!is2xx(resp.status)) return error.ProviderError;

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch return error.InvalidResponse;
    defer parsed.deinit(); // the returned token is duped below, so it outlives the tree
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
    defer alloc.free(auth_value);
    const headers = [_]Header{
        .{ .name = "authorization", .value = auth_value },
        .{ .name = "accept", .value = "application/json" },
    };
    const resp = try transport.call(transport.ctx, alloc, .GET, provider.userinfoURL, &headers, null);
    if (!is2xx(resp.status)) return error.ProviderError;
    return providers.extractIdentity(alloc, provider, resp.body);
}

const HttpCtx = struct { io: std.Io, alloc: std.mem.Allocator };

fn httpCall(ctx: *anyopaque, alloc: std.mem.Allocator, method: Method, url: []const u8, headers: []const Header, body: ?[]const u8) TransportError!Response {
    const hc: *HttpCtx = @ptrCast(@alignCast(ctx));
    var client = std.http.Client{ .allocator = alloc, .io = hc.io };
    defer client.deinit();

    const extra = alloc.alloc(std.http.Header, headers.len) catch return error.TransportFailed;
    for (headers, 0..) |h, i| extra[i] = .{ .name = h.name, .value = h.value };

    const MAX_RESP = 1 << 20; // 1 MiB
    const resp_buf = alloc.alloc(u8, MAX_RESP) catch return error.TransportFailed;
    var fw = std.Io.Writer.fixed(resp_buf);
    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = if (method == .POST) .POST else .GET,
        .payload = body,
        .extra_headers = extra,
        .response_writer = &fw,
    }) catch |e| {
        // A body exceeding the fixed buffer surfaces as a write failure from fetch.
        return switch (e) {
            error.WriteFailed => error.ResponseTooLarge,
            else => error.TransportFailed,
        };
    };

    return .{ .status = @intFromEnum(res.status), .body = fw.buffered() };
}

/// A production transport backed by std.http.Client (TLS via std.crypto.tls). `hc` must outlive use.
pub fn httpTransport(hc: *HttpCtx) Transport {
    return .{ .ctx = hc, .call = httpCall };
}

/// Allocate an HttpCtx bound to (io, alloc) for httpTransport. Caller owns it (arena-friendly).
pub fn httpContext(alloc: std.mem.Allocator, io: std.Io) !*HttpCtx {
    const hc = try alloc.create(HttpCtx);
    hc.* = .{ .io = io, .alloc = alloc };
    return hc;
}

// A stub transport that returns canned responses keyed by URL substring.
const StubTransport = struct {
    token_status: u16 = 200,
    token_body: []const u8 = "{\"access_token\":\"AT123\",\"token_type\":\"bearer\"}",
    userinfo_status: u16 = 200,
    userinfo_body: []const u8 = "{\"sub\":\"P1\",\"email\":\"u@x.io\",\"email_verified\":true}",

    fn call(ctx: *anyopaque, alloc: std.mem.Allocator, method: Method, url: []const u8, headers: []const Header, body: ?[]const u8) TransportError!Response {
        _ = alloc;
        _ = method;
        _ = headers;
        _ = body;
        const self: *StubTransport = @ptrCast(@alignCast(ctx));
        // Bodies are returned as-is (not duped): they're comptime/caller-owned string data,
        // matching the Transport contract that exchangeCode/fetchIdentity never free resp.body
        // themselves (see the comment in exchangeCode) — nothing here needs freeing.
        if (std.mem.indexOf(u8, url, "token") != null)
            return .{ .status = self.token_status, .body = self.token_body };
        return .{ .status = self.userinfo_status, .body = self.userinfo_body };
    }

    fn transport(self: *StubTransport) Transport {
        return .{ .ctx = self, .call = call };
    }
};

test "exchangeCode returns the access token on 200" {
    const a = std.testing.allocator;
    var stub = StubTransport{};
    const tok = try exchangeCode(stub.transport(), a, providers.lookup("google").?, "cid", "secret", "code", "verifier", "https://app/cb");
    defer a.free(tok);
    try std.testing.expectEqualStrings("AT123", tok);
}

test "exchangeCode fails on a non-2xx token response" {
    const a = std.testing.allocator;
    var stub = StubTransport{ .token_status = 400, .token_body = "{\"error\":\"invalid_grant\"}" };
    try std.testing.expectError(error.ProviderError, exchangeCode(stub.transport(), a, providers.lookup("google").?, "cid", "secret", "code", "verifier", "https://app/cb"));
}

test "fetchIdentity returns a normalized identity" {
    const a = std.testing.allocator;
    var stub = StubTransport{};
    const id = try fetchIdentity(stub.transport(), a, providers.lookup("google").?, "AT123");
    defer {
        a.free(id.providerUserId);
        if (id.email) |e| a.free(e);
        if (id.name) |n| a.free(n);
        if (id.avatarUrl) |v| a.free(v);
    }
    try std.testing.expectEqualStrings("P1", id.providerUserId);
    try std.testing.expectEqualStrings("u@x.io", id.email.?);
    try std.testing.expectEqual(true, id.emailVerified);
}

test "fetchIdentity fails on a non-2xx userinfo response" {
    const a = std.testing.allocator;
    var stub = StubTransport{ .userinfo_status = 401, .userinfo_body = "unauthorized" };
    try std.testing.expectError(error.ProviderError, fetchIdentity(stub.transport(), a, providers.lookup("google").?, "AT"));
}

test "httpTransport builds a Transport bound to its context" {
    const a = std.testing.allocator;
    const hc = try httpContext(a, std.testing.io);
    defer a.destroy(hc);
    const t = httpTransport(hc);
    try std.testing.expect(t.ctx == @as(*anyopaque, @ptrCast(hc)));
}
