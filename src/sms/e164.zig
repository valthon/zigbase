//! Framework-owned E.164 phone-number normalization + validation (#224). This is the
//! single place a `to`/`from` number is sanitized before ANY byte reaches an SMS provider
//! or a durable queue row — a consumer never re-rolls it (mirrors how `mail/send.zig` owns
//! recipient-address validation). Both `ctx.sms().send` and `.enqueue` run every number
//! through `normalizeE164` first, so a malformed number fails fast at the call site.
//!
//! Normalization rules:
//!   * Common human separators — spaces, dashes, parentheses, dots, tabs — are stripped.
//!   * A leading `+` is preserved (an explicit international prefix).
//!   * With NO `+`, the number is assumed to be a national number in `opts.default_region`
//!     and that region's country code is prefixed (US → `+1`).
//!   * The result must be `+` followed by 1–15 digits with a non-zero first digit — the
//!     E.164 shape (ITU-T E.164: at most 15 digits, country codes never start with 0).
//!     Anything else (letters, an embedded `+`, too many digits, a leading `+0`) is
//!     rejected with `error.InvalidPhoneNumber`.

const std = @import("std");

/// A dialing region, used only to supply the country code prefixed onto a national
/// number that carries no explicit `+`. Deliberately small — add regions as needed.
pub const Region = enum {
    us,

    /// The E.164 country calling code (digits only, no `+`) for this region.
    pub fn countryCode(self: Region) []const u8 {
        return switch (self) {
            .us => "1",
        };
    }
};

/// Options for `normalizeE164`. `default_region` supplies the country code when the
/// input has no leading `+`.
pub const NormalizeOpts = struct {
    default_region: Region = .us,
};

pub const Error = error{InvalidPhoneNumber};

/// Normalize `raw` to canonical E.164 (`+<digits>`), allocating the result on `alloc`.
/// See the file header for the full rule set. Returns `error.InvalidPhoneNumber` for any
/// input that cannot be made into a valid E.164 number.
pub fn normalizeE164(alloc: std.mem.Allocator, raw: []const u8, opts: NormalizeOpts) (Error || std.mem.Allocator.Error)![]const u8 {
    // Strip separators into a scratch buffer of digits, tracking a single leading '+'.
    // A '+' anywhere but the leading position, or any non-digit/non-separator byte
    // (letters, '#', '*', …), is a hard reject — we never silently drop unexpected input.
    var digits_buf: [64]u8 = undefined;
    var n: usize = 0;
    var has_plus = false;
    var seen_any = false;
    for (raw) |c| {
        switch (c) {
            ' ', '\t', '-', '(', ')', '.' => continue, // human separators: dropped
            '+' => {
                // Only valid as the very first meaningful character.
                if (seen_any) return error.InvalidPhoneNumber;
                has_plus = true;
                seen_any = true;
            },
            '0'...'9' => {
                if (n >= digits_buf.len) return error.InvalidPhoneNumber; // absurdly long
                digits_buf[n] = c;
                n += 1;
                seen_any = true;
            },
            else => return error.InvalidPhoneNumber, // letters, '#', '*', control chars, …
        }
    }

    // The national/international digit string (no '+').
    const national = digits_buf[0..n];

    // No actual digits (empty input, all-separators, or a bare "+") — there is nothing to
    // dial. Reject rather than silently returning just a country-code prefix ("+1").
    if (national.len == 0) return error.InvalidPhoneNumber;

    // Assemble the candidate digits: prefix the region country code when there was no '+'.
    var out: [80]u8 = undefined;
    var out_len: usize = 0;
    if (!has_plus) {
        const cc = opts.default_region.countryCode();
        for (cc) |d| {
            out[out_len] = d;
            out_len += 1;
        }
    }
    for (national) |d| {
        if (out_len >= out.len) return error.InvalidPhoneNumber;
        out[out_len] = d;
        out_len += 1;
    }
    const e164_digits = out[0..out_len];

    // E.164 validation: 1–15 digits, first digit 1–9.
    if (e164_digits.len < 1 or e164_digits.len > 15) return error.InvalidPhoneNumber;
    if (e164_digits[0] < '1' or e164_digits[0] > '9') return error.InvalidPhoneNumber;

    // Emit "+<digits>".
    const result = try alloc.alloc(u8, e164_digits.len + 1);
    result[0] = '+';
    @memcpy(result[1..], e164_digits);
    return result;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "US national number gets the default +1 country code" {
    const a = testing.allocator;
    const n = try normalizeE164(a, "555-123-4567", .{});
    defer a.free(n);
    try testing.expectEqualStrings("+15551234567", n);
}

test "separators (spaces, parens, dots, dashes, tabs) are stripped" {
    const a = testing.allocator;
    inline for (.{
        "(555) 123-4567",
        "555.123.4567",
        "555 123 4567",
        "555-123-4567",
        "\t555 123.4567 ",
    }) |raw| {
        const n = try normalizeE164(a, raw, .{});
        defer a.free(n);
        try testing.expectEqualStrings("+15551234567", n);
    }
}

test "an already-+ international number is preserved (separators still stripped)" {
    const a = testing.allocator;
    const n1 = try normalizeE164(a, "+44 20 7946 0958", .{});
    defer a.free(n1);
    try testing.expectEqualStrings("+442079460958", n1);

    const n2 = try normalizeE164(a, "+1 (555) 123-4567", .{});
    defer a.free(n2);
    try testing.expectEqualStrings("+15551234567", n2);
}

test "the region default is honored" {
    const a = testing.allocator;
    // US is the only shipped region today; assert the explicit-opts path resolves it.
    const n = try normalizeE164(a, "5551234567", .{ .default_region = .us });
    defer a.free(n);
    try testing.expectEqualStrings("+15551234567", n);
}

test "rejects letters and other junk" {
    const a = testing.allocator;
    try testing.expectError(error.InvalidPhoneNumber, normalizeE164(a, "555-CALL-NOW", .{}));
    try testing.expectError(error.InvalidPhoneNumber, normalizeE164(a, "not a number", .{}));
    try testing.expectError(error.InvalidPhoneNumber, normalizeE164(a, "+1555#123", .{}));
    try testing.expectError(error.InvalidPhoneNumber, normalizeE164(a, "*67", .{}));
}

test "rejects an empty / all-separators input" {
    const a = testing.allocator;
    try testing.expectError(error.InvalidPhoneNumber, normalizeE164(a, "", .{}));
    try testing.expectError(error.InvalidPhoneNumber, normalizeE164(a, "() - . ", .{}));
    try testing.expectError(error.InvalidPhoneNumber, normalizeE164(a, "+", .{}));
}

test "rejects a '+' that is not leading" {
    const a = testing.allocator;
    try testing.expectError(error.InvalidPhoneNumber, normalizeE164(a, "1+5551234567", .{}));
    try testing.expectError(error.InvalidPhoneNumber, normalizeE164(a, "++15551234567", .{}));
}

test "rejects a leading +0 (E.164 country codes never start with 0)" {
    const a = testing.allocator;
    try testing.expectError(error.InvalidPhoneNumber, normalizeE164(a, "+0123456789", .{}));
    // A '0' first digit after prefixing can't happen for US (always +1…), but an explicit
    // "+0…" must fail.
    try testing.expectError(error.InvalidPhoneNumber, normalizeE164(a, "+0", .{}));
}

test "rejects more than 15 digits (E.164 max)" {
    const a = testing.allocator;
    // 16 digits with a leading '+' → too long.
    try testing.expectError(error.InvalidPhoneNumber, normalizeE164(a, "+1234567890123456", .{}));
    // 15 digits is the max allowed.
    const ok = try normalizeE164(a, "+123456789012345", .{});
    defer a.free(ok);
    try testing.expectEqualStrings("+123456789012345", ok);
}

test "a single valid digit is accepted at the boundary" {
    const a = testing.allocator;
    const n = try normalizeE164(a, "+7", .{});
    defer a.free(n);
    try testing.expectEqualStrings("+7", n);
}
