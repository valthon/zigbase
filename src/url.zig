//! URL / form percent-encoding (RFC 3986).
//!
//! One home for the "keep the unreserved set, %XX-escape everything else" primitive that
//! `application/x-www-form-urlencoded` bodies and URL components need. Consolidates three
//! byte-identical copies that previously lived in `captcha.zig`, `sms/twilio.zig`, and
//! `oauth/client.zig` (#46) — a single implementation so an encoding fix reaches every caller.

const std = @import("std");

/// RFC 3986 unreserved set: `A-Z a-z 0-9 - _ . ~`. Every other byte is percent-encoded.
fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => true,
        else => false,
    };
}

/// Percent-encode `input` per RFC 3986: unreserved bytes pass through, every other byte
/// becomes `%XX` with UPPERCASE hex (a space is `%20`, never `+`). Suitable for a
/// form-urlencoded field value or a URL component. Allocates the result on `alloc` (caller
/// owns it). Two-pass (count then fill) so the output is a single exact allocation.
pub fn percentEncode(alloc: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]u8 {
    var len: usize = 0;
    for (input) |c| len += if (isUnreserved(c)) @as(usize, 1) else 3; // %XX = 3 bytes

    const out = try alloc.alloc(u8, len);
    const hex = "0123456789ABCDEF";
    var i: usize = 0;
    for (input) |c| {
        if (isUnreserved(c)) {
            out[i] = c;
            i += 1;
        } else {
            out[i] = '%';
            out[i + 1] = hex[c >> 4];
            out[i + 2] = hex[c & 0x0F];
            i += 3;
        }
    }
    return out;
}

// Registered + exercised via `captcha.zig` (which delegates to this helper and is imported by
// `root.zig`'s test block); see its "percentEncode" test for the focused coverage. This module
// has no test block of its own so its coverage runs in CI without touching `root.zig`.
