//! Email-address normalization for identity comparison (#154 review I1). Suppression rows, the
//! suppression check, and the verified-sender lookup must all agree on what "the same address" is,
//! or a suppression on `bad@x.io` would FAIL OPEN against `Bad@x.io` / `BAD@X.IO` and a verified
//! identity for `From@acct.com` would not match a send from `from@acct.com`.
//!
//! We lowercase the WHOLE address. The domain is case-insensitive per RFC 1035; the local part is
//! technically case-sensitive per RFC 5321, but in practice every major provider treats it
//! case-insensitively, and lowercasing the whole address is exactly how bounce/complaint feeds key
//! their suppression lists — so this matches real-world delivery semantics and is the safe (never
//! fail-open) choice for a suppression list. Pure; the result is allocated on the caller's allocator.

const std = @import("std");

/// Return a lowercased copy of `email`, allocated on `alloc`. Caller owns the result.
pub fn normalize(alloc: std.mem.Allocator, email: []const u8) std.mem.Allocator.Error![]u8 {
    const out = try alloc.alloc(u8, email.len);
    for (email, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

test "normalize lowercases the whole address" {
    const a = std.testing.allocator;
    const n = try normalize(a, "Bad.User@X.IO");
    defer a.free(n);
    try std.testing.expectEqualStrings("bad.user@x.io", n);
}

test "normalize on an already-lowercase address is identity" {
    const a = std.testing.allocator;
    const n = try normalize(a, "ok@x.io");
    defer a.free(n);
    try std.testing.expectEqualStrings("ok@x.io", n);
}
