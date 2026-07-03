//! RFC 4013 SASLprep for SCRAM passwords — minimal-correct (SP3 Theme A, item 2).
//!
//! Contract (mirrors the spec exactly):
//!   1. ASCII fast path: all bytes 0x20..0x7E -> the input slice VERBATIM, zero alloc
//!      (SASLprep is the identity on printable ASCII — the overwhelmingly common case).
//!   2. Invalid UTF-8 -> PG-parity verbatim (PostgreSQL's own pg_saslprep uses the
//!      password as-is whenever prep fails, on the server AND in libpq; hard-erroring
//!      would break auth against verifiers PG itself created from such passwords).
//!   3. Mapping: RFC 3454 B.1 map-to-nothing; C.1.2 non-ASCII spaces -> U+0020.
//!      Empty result after mapping -> PG-parity verbatim.
//!   4. Prohibited output (C.1.2, C.2.1, C.2.2, C.3–C.9) or an RFC 3454 §6 bidi
//!      violation -> PG-parity verbatim. RFC 3454 A.1 (unassigned) is deliberately
//!      NOT checked: §7 permits unassigned in query strings, the assigned set has
//!      grown enormously since Unicode 3.2 (rejecting emoji passwords would be a
//!      self-inflicted footgun), and PG interops fine without it.
//!   5. NFKC — the one deliberate gap: we do NOT normalize. An NFKC quick-check
//!      (every code point NFKC_QC=Yes AND combining classes canonically ordered)
//!      proves the string is definitionally NFKC-normal, in which case the prepped
//!      string is correct as-is. Quick-check No/Maybe -> error.PasswordNeedsNormalization
//!      (never silently wrong, always loud, names the fix at the connect site).
//!
//! The bytes feed PBKDF2 either way, so the verbatim fallback is not a security
//! downgrade — it is bug-for-bug interop with PostgreSQL.

const std = @import("std");
const tables = @import("saslprep_tables.zig");

pub const PrepareError = error{
    OutOfMemory,
    /// The password's SASLprep output would require real NFKC normalization, which this
    /// driver does not perform. Surfaced at connect with an actionable message.
    PasswordNeedsNormalization,
};

pub const Prepared = struct {
    bytes: []const u8,
    /// True when `bytes` was allocated (mapping changed the string); false when it
    /// aliases the caller's input (ASCII fast path / PG-parity verbatim).
    owned: bool,

    pub fn deinit(self: Prepared, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.bytes);
    }
};

fn verbatim(password: []const u8) Prepared {
    return .{ .bytes = password, .owned = false };
}

fn inRanges(ranges: []const tables.Range, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid].lo) {
            hi = mid;
        } else if (cp > ranges[mid].hi) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

/// Canonical combining class of `cp` (0 for starters / anything not in the table).
fn combiningClass(cp: u21) u8 {
    const ranges = &tables.combining_class;
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid].lo) {
            hi = mid;
        } else if (cp > ranges[mid].hi) {
            lo = mid + 1;
        } else return ranges[mid].ccc;
    }
    return 0;
}

/// SASLprep `password`. See the module doc for the exact contract. The returned
/// `Prepared` must be `deinit`ed with the same allocator (a no-op for unowned results).
pub fn prepare(allocator: std.mem.Allocator, password: []const u8) PrepareError!Prepared {
    // 1. ASCII fast path — alias the input, zero allocation.
    var ascii = true;
    for (password) |b| {
        if (b < 0x20 or b > 0x7E) {
            ascii = false;
            break;
        }
    }
    if (ascii) return verbatim(password);

    // 2. Decode; invalid UTF-8 -> PG-parity verbatim.
    const view = std.unicode.Utf8View.init(password) catch return verbatim(password);

    // 3. Mapping (B.1 delete, C.1.2 -> space) into a code-point list.
    var cps: std.ArrayList(u21) = .empty;
    defer cps.deinit(allocator);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (inRanges(&tables.map_to_nothing, cp)) continue;
        if (inRanges(&tables.map_to_space, cp)) {
            try cps.append(allocator, ' ');
            continue;
        }
        try cps.append(allocator, cp);
    }
    if (cps.items.len == 0) return verbatim(password); // PG parity: empty result -> as-is

    // 4a. Prohibited output -> PG-parity verbatim.
    for (cps.items) |cp| {
        if (inRanges(&tables.prohibited, cp)) return verbatim(password);
    }

    // 4b. Bidi (RFC 3454 §6): with any RandALCat present, LCat is forbidden and the
    // first AND last characters must be RandALCat. Violation -> PG-parity verbatim.
    var has_ral = false;
    var has_l = false;
    for (cps.items) |cp| {
        if (inRanges(&tables.rand_al_cat, cp)) has_ral = true;
        if (inRanges(&tables.l_cat, cp)) has_l = true;
    }
    if (has_ral) {
        if (has_l) return verbatim(password);
        if (!inRanges(&tables.rand_al_cat, cps.items[0]) or
            !inRanges(&tables.rand_al_cat, cps.items[cps.items.len - 1]))
            return verbatim(password);
    }

    // 5. NFKC quick-check: any NFKC_QC No/Maybe code point, or a combining mark that is
    // not canonically ordered, means the CORRECT output requires real normalization.
    var last_ccc: u8 = 0;
    for (cps.items) |cp| {
        const c = combiningClass(cp);
        if (c != 0 and last_ccc > c) return PrepareError.PasswordNeedsNormalization;
        if (inRanges(&tables.nfkc_qc_no_or_maybe, cp)) return PrepareError.PasswordNeedsNormalization;
        last_ccc = c;
    }

    // 6. Re-encode the mapped result.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [4]u8 = undefined;
    for (cps.items) |cp| {
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable; // decoded above -> valid
        try out.appendSlice(allocator, buf[0..n]);
    }
    return .{ .bytes = try out.toOwnedSlice(allocator), .owned = true };
}

// --- tests: RFC 4013 §3 vectors + spec-mandated cases -----------------------------

test "saslprep: ASCII fast path is alias-identical (no alloc)" {
    const input = "correct horse battery staple";
    const p = try prepare(std.testing.allocator, input);
    defer p.deinit(std.testing.allocator);
    try std.testing.expect(!p.owned);
    try std.testing.expectEqual(input.ptr, p.bytes.ptr);
    try std.testing.expectEqualStrings(input, p.bytes);
}

test "saslprep: RFC 4013 — I<SOFT HYPHEN>X maps to IX; user/USER unchanged" {
    const a = std.testing.allocator;
    const p = try prepare(a, "I\u{00AD}X");
    defer p.deinit(a);
    try std.testing.expect(p.owned);
    try std.testing.expectEqualStrings("IX", p.bytes);

    const lower = try prepare(a, "user");
    defer lower.deinit(a);
    try std.testing.expectEqualStrings("user", lower.bytes);
    const upper = try prepare(a, "USER");
    defer upper.deinit(a);
    try std.testing.expectEqualStrings("USER", upper.bytes);
}

test "saslprep: NBSP maps to plain space" {
    const a = std.testing.allocator;
    const p = try prepare(a, "a\u{00A0}b");
    defer p.deinit(a);
    try std.testing.expectEqualStrings("a b", p.bytes);
}

test "saslprep: needs-NFKC code points are a HARD error (never silently wrong)" {
    const a = std.testing.allocator;
    // U+00AA FEMININE ORDINAL INDICATOR (NFKC -> "a") and U+2168 ROMAN NUMERAL NINE
    // (NFKC -> "IX"): both NFKC_QC=No.
    try std.testing.expectError(error.PasswordNeedsNormalization, prepare(a, "\u{00AA}"));
    try std.testing.expectError(error.PasswordNeedsNormalization, prepare(a, "\u{2168}"));
}

test "saslprep: prohibited output and bidi violations fall back to PG-parity verbatim" {
    const a = std.testing.allocator;
    // U+0007 BEL is C.2.1-prohibited (and outside the ASCII fast path's 0x20..0x7E).
    const bel = try prepare(a, "pass\u{0007}word");
    defer bel.deinit(a);
    try std.testing.expect(!bel.owned);
    try std.testing.expectEqualStrings("pass\u{0007}word", bel.bytes);
    // U+0627 ARABIC LETTER ALEF (RandALCat) followed by '1': last char is not RandALCat
    // -> RFC 3454 §6 violation -> verbatim (RFC 4013 §3's own failing vector).
    const bidi = try prepare(a, "\u{0627}1");
    defer bidi.deinit(a);
    try std.testing.expect(!bidi.owned);
    try std.testing.expectEqualStrings("\u{0627}1", bidi.bytes);
}

test "saslprep: invalid UTF-8 and an all-mapped-away password are verbatim" {
    const a = std.testing.allocator;
    const bad = try prepare(a, "\xff\xfe");
    defer bad.deinit(a);
    try std.testing.expect(!bad.owned);
    try std.testing.expectEqualStrings("\xff\xfe", bad.bytes);
    // Only soft hyphens -> empty mapped result -> PG parity: as-is.
    const empty = try prepare(a, "\u{00AD}\u{00AD}");
    defer empty.deinit(a);
    try std.testing.expect(!empty.owned);
}

test "saslprep: already-NFC non-ASCII passes prep unchanged (owned copy)" {
    const a = std.testing.allocator;
    const p = try prepare(a, "crème-brûlée");
    defer p.deinit(a);
    try std.testing.expectEqualStrings("crème-brûlée", p.bytes);
}

test "saslprep: generated tables are sorted and non-overlapping" {
    inline for (.{
        tables.map_to_nothing,
        tables.map_to_space,
        tables.prohibited,
        tables.rand_al_cat,
        tables.l_cat,
        tables.nfkc_qc_no_or_maybe,
    }) |table| {
        var prev_hi: u21 = 0;
        var first = true;
        for (table) |r| {
            try std.testing.expect(r.lo <= r.hi);
            if (!first) try std.testing.expect(r.lo > prev_hi);
            prev_hi = r.hi;
            first = false;
        }
    }
    var prev_hi: u21 = 0;
    var first = true;
    for (tables.combining_class) |r| {
        try std.testing.expect(r.lo <= r.hi);
        try std.testing.expect(r.ccc != 0);
        if (!first) try std.testing.expect(r.lo > prev_hi);
        prev_hi = r.hi;
        first = false;
    }
}
