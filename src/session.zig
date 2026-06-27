//! Session-cookie policy — the single source of truth for the framework's auth
//! cookies (`zb_auth` + `zb_csrf`). Both the built-in login/logout endpoints and the
//! consumer-facing `clearSession` helper build their cookies here, so the attributes
//! (http_only / secure / same_site / path) can never drift between them.
const std = @import("std");
const http = @import("http.zig");

/// The session JWT cookie (HttpOnly — never readable by JS).
pub const auth_cookie = "zb_auth";
/// The CSRF double-submit cookie (readable by JS so the SPA can echo it in a header).
pub const csrf_cookie = "zb_csrf";

/// Build the pair of session cookies. `max_age_s` < 0 clears them (logout); a positive
/// value is the session lifetime. `secure` follows the app's `cookie_secure` policy.
/// Returns a fixed `[2]` array; callers that need a slice for `Response.cookies`
/// dupe it onto their arena (see `clearedCookies` callers / `Issued`).
pub fn sessionCookies(secure: bool, token: []const u8, csrf: []const u8, max_age_s: i32) [2]http.Cookie {
    // `.path` is set explicitly (not left to http.Cookie's default) so this module is the
    // authoritative source for EVERY attribute — and the cleared variant matches it exactly.
    return .{
        .{ .name = auth_cookie, .value = token, .max_age_s = max_age_s, .http_only = true, .secure = secure, .same_site = .strict, .path = "/" },
        .{ .name = csrf_cookie, .value = csrf, .max_age_s = max_age_s, .http_only = false, .secure = secure, .same_site = .strict, .path = "/" },
    };
}

/// The cleared session cookies (logout): empty values with a negative max-age so the
/// browser drops them, carrying the same name/secure/http_only/same_site/path policy
/// as the cookies `sessionCookies` set — so logout reliably matches the original.
pub fn clearedCookies(secure: bool) [2]http.Cookie {
    return sessionCookies(secure, "", "", -1);
}

test "clearedCookies clears both session cookies with the framework's policy" {
    inline for (.{ true, false }) |secure| {
        const c = clearedCookies(secure);
        try std.testing.expectEqual(@as(usize, 2), c.len);
        try std.testing.expectEqualStrings(auth_cookie, c[0].name);
        try std.testing.expectEqualStrings(csrf_cookie, c[1].name);
        // Both cleared: empty value + negative max-age.
        try std.testing.expectEqualStrings("", c[0].value);
        try std.testing.expectEqualStrings("", c[1].value);
        try std.testing.expect(c[0].max_age_s < 0);
        try std.testing.expect(c[1].max_age_s < 0);
        // Policy: auth is HttpOnly, csrf is not; both follow `secure`; both Strict + "/".
        try std.testing.expect(c[0].http_only);
        try std.testing.expect(!c[1].http_only);
        try std.testing.expectEqual(secure, c[0].secure);
        try std.testing.expectEqual(secure, c[1].secure);
        try std.testing.expect(c[0].same_site == .strict and c[1].same_site == .strict);
        try std.testing.expectEqualStrings("/", c[0].path);
        try std.testing.expectEqualStrings("/", c[1].path);
    }
}

test "sessionCookies carries the token/csrf and a positive lifetime" {
    const c = sessionCookies(true, "tok", "csrf", 3600);
    try std.testing.expectEqualStrings("tok", c[0].value);
    try std.testing.expectEqualStrings("csrf", c[1].value);
    try std.testing.expectEqual(@as(i32, 3600), c[0].max_age_s);
    try std.testing.expectEqual(@as(i32, 3600), c[1].max_age_s);
    try std.testing.expect(c[0].http_only and !c[1].http_only);
}
