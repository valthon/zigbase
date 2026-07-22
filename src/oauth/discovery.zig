//! OIDC discovery (spec §F4): resolve a provider's authorization/token/userinfo endpoints
//! from its `/.well-known/openid-configuration` document — ONCE, AT STARTUP, through the
//! same injectable Transport every OAuth token/userinfo call already uses (zero new
//! networking/TLS code). Failure is a loud, fatal startup error (fail closed — a
//! half-configured IdP must not silently disable login). No JWKS / id_token validation:
//! identity keeps flowing through the userinfo endpoint over TLS (documented model).
const std = @import("std");
const client = @import("client.zig");

pub const Endpoints = struct {
    authURL: []const u8,
    tokenURL: []const u8,
    userinfoURL: []const u8,

    /// Free all three owned strings. Startup callers (provision.zig) run this under a
    /// request/startup arena and never call it directly — fields are copied out and reclaimed
    /// on arena teardown; this exists for callers on a non-arena allocator (e.g. tests).
    pub fn deinit(self: Endpoints, alloc: std.mem.Allocator) void {
        alloc.free(self.authURL);
        alloc.free(self.tokenURL);
        alloc.free(self.userinfoURL);
    }
};

pub const DiscoveryError = error{ DiscoveryFetchFailed, InvalidDiscoveryDocument, InsecureEndpoint, IssuerMismatch } || client.TransportError;

fn isHttps(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://") and url.len > "https://".len;
}

/// Parse an already-fetched discovery document. Split from `resolve` so unit tests cover
/// every failure mode with plain fixture strings (no transport).
///   - `authorization_endpoint`/`token_endpoint`/`userinfo_endpoint`: ALL required strings.
///   - every endpoint must be https:// (mirrors resolveProvider's isHttps gate).
///   - `issuer` must be a required https string AND a prefix-origin of `discovery_url`
///     (RFC 8414 §3.3-style sanity check: the well-known URL is derived from the issuer,
///     so a document whose issuer does not prefix it is mis-served or spoofed).
pub fn parseDocument(alloc: std.mem.Allocator, discovery_url: []const u8, body: []const u8) DiscoveryError!Endpoints {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return error.InvalidDiscoveryDocument;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidDiscoveryDocument;
    const obj = parsed.value.object;
    const getStr = struct {
        fn f(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
            const v = o.get(key) orelse return null;
            return if (v == .string and v.string.len > 0) v.string else null;
        }
    }.f;
    const issuer = getStr(obj, "issuer") orelse return error.InvalidDiscoveryDocument;
    const auth_ep = getStr(obj, "authorization_endpoint") orelse return error.InvalidDiscoveryDocument;
    const token_ep = getStr(obj, "token_endpoint") orelse return error.InvalidDiscoveryDocument;
    const userinfo_ep = getStr(obj, "userinfo_endpoint") orelse return error.InvalidDiscoveryDocument;
    if (!isHttps(auth_ep) or !isHttps(token_ep) or !isHttps(userinfo_ep)) return error.InsecureEndpoint;
    if (!isHttps(issuer) or !std.mem.startsWith(u8, discovery_url, issuer)) return error.IssuerMismatch;
    return .{
        .authURL = try alloc.dupe(u8, auth_ep),
        .tokenURL = try alloc.dupe(u8, token_ep),
        .userinfoURL = try alloc.dupe(u8, userinfo_ep),
    };
}

/// Fetch + parse `discovery_url` through `transport`. HTTPS-only by construction (the URL
/// is comptime-validated operator input, not user input — no request-time SSRF surface).
pub fn resolve(transport: client.Transport, alloc: std.mem.Allocator, discovery_url: []const u8) DiscoveryError!Endpoints {
    const headers = [_]client.Header{.{ .name = "accept", .value = "application/json" }};
    const resp = try transport.call(transport.ctx, alloc, .GET, discovery_url, &headers, null);
    // `resp.body` is transport-owned — do NOT free it (same contract as `client.exchangeCode`).
    // The production transport returns a sub-slice of a larger fixed response buffer, so
    // `alloc.free(resp.body)` would be an invalid free; `parseDocument` dupes what it keeps.
    if (resp.status < 200 or resp.status >= 300) return error.DiscoveryFetchFailed;
    return parseDocument(alloc, discovery_url, resp.body);
}

const okta_document =
    \\{
    \\  "issuer": "https://acme.okta.com",
    \\  "authorization_endpoint": "https://acme.okta.com/oauth2/v1/authorize",
    \\  "token_endpoint": "https://acme.okta.com/oauth2/v1/token",
    \\  "userinfo_endpoint": "https://acme.okta.com/oauth2/v1/userinfo"
    \\}
;
const okta_discovery_url = "https://acme.okta.com/.well-known/openid-configuration";

const StubTransport = struct {
    status: u16 = 200,
    body: []const u8 = okta_document,

    fn call(ctx: *anyopaque, alloc: std.mem.Allocator, method: client.Method, url: []const u8, headers: []const client.Header, req_body: ?[]const u8) client.TransportError!client.Response {
        _ = method;
        _ = url;
        _ = headers;
        _ = req_body;
        _ = alloc;
        const self: *StubTransport = @ptrCast(@alignCast(ctx));
        // Borrowed body — `resp.body` is transport-owned and the caller never frees it (matches
        // the production transport's fixed-buffer sub-slice; see client.Response).
        return .{ .status = self.status, .body = self.body };
    }

    fn transport(self: *StubTransport) client.Transport {
        return .{ .ctx = self, .call = call };
    }
};

test "discovery: happy path resolves all three endpoints" {
    const a = std.testing.allocator;
    var stub = StubTransport{};
    const eps = try resolve(stub.transport(), a, okta_discovery_url);
    defer eps.deinit(a);
    try std.testing.expectEqualStrings("https://acme.okta.com/oauth2/v1/authorize", eps.authURL);
    try std.testing.expectEqualStrings("https://acme.okta.com/oauth2/v1/token", eps.tokenURL);
    try std.testing.expectEqualStrings("https://acme.okta.com/oauth2/v1/userinfo", eps.userinfoURL);
}

test "discovery: missing endpoint / non-string endpoint -> InvalidDiscoveryDocument" {
    const a = std.testing.allocator;

    const missing_userinfo =
        \\{
        \\  "issuer": "https://acme.okta.com",
        \\  "authorization_endpoint": "https://acme.okta.com/oauth2/v1/authorize",
        \\  "token_endpoint": "https://acme.okta.com/oauth2/v1/token"
        \\}
    ;
    try std.testing.expectError(error.InvalidDiscoveryDocument, parseDocument(a, okta_discovery_url, missing_userinfo));

    const non_string_token =
        \\{
        \\  "issuer": "https://acme.okta.com",
        \\  "authorization_endpoint": "https://acme.okta.com/oauth2/v1/authorize",
        \\  "token_endpoint": 12345,
        \\  "userinfo_endpoint": "https://acme.okta.com/oauth2/v1/userinfo"
        \\}
    ;
    try std.testing.expectError(error.InvalidDiscoveryDocument, parseDocument(a, okta_discovery_url, non_string_token));
}

test "discovery: http:// endpoint -> InsecureEndpoint" {
    const a = std.testing.allocator;

    const http_userinfo =
        \\{
        \\  "issuer": "https://acme.okta.com",
        \\  "authorization_endpoint": "https://acme.okta.com/oauth2/v1/authorize",
        \\  "token_endpoint": "https://acme.okta.com/oauth2/v1/token",
        \\  "userinfo_endpoint": "http://acme.okta.com/oauth2/v1/userinfo"
        \\}
    ;
    try std.testing.expectError(error.InsecureEndpoint, parseDocument(a, okta_discovery_url, http_userinfo));
}

test "discovery: issuer mismatch and http issuer -> IssuerMismatch" {
    const a = std.testing.allocator;

    const evil_issuer =
        \\{
        \\  "issuer": "https://evil.example",
        \\  "authorization_endpoint": "https://acme.okta.com/oauth2/v1/authorize",
        \\  "token_endpoint": "https://acme.okta.com/oauth2/v1/token",
        \\  "userinfo_endpoint": "https://acme.okta.com/oauth2/v1/userinfo"
        \\}
    ;
    try std.testing.expectError(error.IssuerMismatch, parseDocument(a, okta_discovery_url, evil_issuer));

    const http_issuer =
        \\{
        \\  "issuer": "http://acme.okta.com",
        \\  "authorization_endpoint": "https://acme.okta.com/oauth2/v1/authorize",
        \\  "token_endpoint": "https://acme.okta.com/oauth2/v1/token",
        \\  "userinfo_endpoint": "https://acme.okta.com/oauth2/v1/userinfo"
        \\}
    ;
    try std.testing.expectError(error.IssuerMismatch, parseDocument(a, okta_discovery_url, http_issuer));
}

test "discovery: non-2xx fetch -> DiscoveryFetchFailed" {
    const a = std.testing.allocator;
    var stub = StubTransport{ .status = 404, .body = "not found" };
    try std.testing.expectError(error.DiscoveryFetchFailed, resolve(stub.transport(), a, okta_discovery_url));
}
