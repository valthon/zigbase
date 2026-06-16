const std = @import("std");

/// Which opaque-cursor TOKEN FORMAT the server mints/accepts, selected at comptime via
/// `App(.{ .pagination = .{ .cursor_token = ... } })`. All three carry the SAME internal
/// keyset payload (boundary sort-key values + direction + sort/filter binding); only the
/// outer encoding differs. See `docs/superpowers/specs/2026-06-16-native-cursor-pagination-*`.
pub const CursorToken = enum {
    /// Approach A (default, recommended): base64url JSON payload, validated structurally and
    /// against the request's effective sort + filter hash. No secret, stateless, CDN-friendly,
    /// byte-compatible with the SDK's client-synthesized cursors.
    stateless,
    /// Approach B: the stateless payload plus an HMAC-SHA256 tag keyed by the server's JWT
    /// secret. Tamper-evident; a bad/absent MAC is rejected with a 400. Not synthesizable by a
    /// client that lacks the secret.
    signed,
    /// Approach C: the token is a random opaque id; the payload is stored server-side in
    /// `_cursorStates` with a TTL and periodically GC'd. Unknown/expired -> 410. Stateful (a DB
    /// write per minted cursor) and NOT compatible with client-synthesized cursors.
    stateful,
};

/// Comptime pagination configuration resolved from `App(.{ .pagination = ... })`.
/// Defaults reproduce the stock binary: both modes enabled, stateless tokens.
pub const Config = struct {
    /// Enable offset pagination (`page`/`perPage`). When false, those params are rejected 400.
    offset: bool = true,
    /// Enable cursor pagination (`cursor`). When false, the `cursor` param is rejected 400.
    cursor: bool = true,
    /// Which cursor token format to mint/accept (only meaningful when `cursor == true`).
    cursor_token: CursorToken = .stateless,
};

/// Runtime mirror of `Config`, threaded onto `app.App` in `framework.serveImpl` so request
/// handlers (which read runtime state off `app.*`, not the comptime cfg) can gate by it.
/// Defaults match `Config` defaults so a hand-built `App` literal (tests/CLI) is stock.
pub const Runtime = struct {
    offset_enabled: bool = true,
    cursor_enabled: bool = true,
    cursor_token: CursorToken = .stateless,
};

/// Resolve a comptime `.pagination` block (an anonymous struct value, or absent) into a `Config`.
/// `@compileError`s on an unknown field, a wrong-typed field, or both modes disabled (the
/// stricter choice: a list endpoint with no pagination mode is always a misconfiguration).
pub fn resolve(comptime cfg: anytype) Config {
    if (!@hasField(@TypeOf(cfg), "pagination")) return .{};
    const p = cfg.pagination;
    const T = @TypeOf(p);
    // Guard unknown keys so a typo fails loudly instead of silently defaulting.
    inline for (std.meta.fields(T)) |f| {
        comptime var ok = false;
        inline for (.{ "offset", "cursor", "cursor_token" }) |name| {
            if (comptime std.mem.eql(u8, f.name, name)) ok = true;
        }
        if (!ok) @compileError("unknown '.pagination' field '" ++ f.name ++ "'; expected .offset / .cursor / .cursor_token");
    }
    comptime var out = Config{};
    if (@hasField(T, "offset")) out.offset = p.offset;
    if (@hasField(T, "cursor")) out.cursor = p.cursor;
    if (@hasField(T, "cursor_token")) out.cursor_token = p.cursor_token;
    if (comptime (!out.offset and !out.cursor))
        @compileError("'.pagination': both .offset and .cursor are false; at least one pagination mode must be enabled");
    return out;
}

test "resolve: absent block -> stock defaults" {
    const c = resolve(.{});
    try std.testing.expect(c.offset);
    try std.testing.expect(c.cursor);
    try std.testing.expectEqual(CursorToken.stateless, c.cursor_token);
}

test "resolve: explicit fields are honored" {
    const c = resolve(.{ .pagination = .{ .offset = false, .cursor = true, .cursor_token = .signed } });
    try std.testing.expect(!c.offset);
    try std.testing.expect(c.cursor);
    try std.testing.expectEqual(CursorToken.signed, c.cursor_token);

    const d = resolve(.{ .pagination = .{ .cursor_token = .stateful } });
    try std.testing.expect(d.offset); // unspecified -> default true
    try std.testing.expect(d.cursor);
    try std.testing.expectEqual(CursorToken.stateful, d.cursor_token);
}

test "resolve: cursor-only (offset disabled) is allowed" {
    const c = resolve(.{ .pagination = .{ .offset = false } });
    try std.testing.expect(!c.offset);
    try std.testing.expect(c.cursor);
}
