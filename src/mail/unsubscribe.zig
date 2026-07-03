//! RFC 8058 one-click unsubscribe token (#154 round 2). STATELESS + SIGNED + NON-ORACLE:
//!   token = base64url(payload) ++ "." ++ base64url(HMAC-SHA256(key, payload))
//!   payload = "v1\x00" ++ account ++ "\x00" ++ list ++ "\x00" ++ recipient
//! (NUL-delimited — every field is CRLF/NUL-rejected upstream, so the framing is
//! unambiguous; mint re-rejects embedded NULs as a fail-closed backstop.)
//!
//! key = HMAC-SHA256(jwt_secret, "zigbase.mail.unsub.v1") — a LABELED derivation of the
//! already-persisted app secret: no new secret to configure, and the mail-unsubscribe
//! key can never be confused with a JWT signature. NO EXPIRY by design: unsubscribe
//! links must keep working from years-old inboxes, and the worst-case "attack" is
//! unsubscribing an address whose mail the attacker already possesses.
//!
//! Verification is length-checked and CONSTANT-TIME on the MAC (crypto.timingSafeEql,
//! the same discipline as the inbound-webhook HMAC); every failure collapses to null
//! so the endpoint can emit one generic 400 (no bad-MAC vs unknown-account oracle).

const std = @import("std");
const crypto = @import("../crypto.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const b64 = std.base64.url_safe_no_pad;

/// Key-derivation label. Versioned so a future token format can rotate cleanly.
pub const key_label = "zigbase.mail.unsub.v1";
/// Hard cap on an encoded token part (payload is account+list+email ≤ a few hundred
/// bytes in practice; the cap bounds attacker-supplied decode work).
pub const max_part_len = 1024;

/// Derive the unsubscribe MAC key from the app JWT secret (labeled, stable).
pub fn deriveKey(jwt_secret: []const u8) [HmacSha256.mac_length]u8 {
    var key: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&key, key_label, jwt_secret);
    return key;
}

fn buildPayload(alloc: std.mem.Allocator, account: []const u8, list: []const u8, recipient: []const u8) ![]u8 {
    // Fail-closed framing backstop: NULs would make the payload ambiguous.
    for ([_][]const u8{ account, list, recipient }) |f| {
        if (std.mem.indexOfScalar(u8, f, 0) != null) return error.InvalidField;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "v1\x00");
    try out.appendSlice(alloc, account);
    try out.append(alloc, 0);
    try out.appendSlice(alloc, list);
    try out.append(alloc, 0);
    try out.appendSlice(alloc, recipient);
    return out.toOwnedSlice(alloc);
}

/// Mint a token for (account, list, recipient). Caller-owned bytes.
pub fn mint(alloc: std.mem.Allocator, jwt_secret: []const u8, account: []const u8, list: []const u8, recipient: []const u8) ![]u8 {
    const payload = try buildPayload(alloc, account, list, recipient);
    defer alloc.free(payload);
    const key = deriveKey(jwt_secret);
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, payload, &key);
    const p_len = b64.Encoder.calcSize(payload.len);
    const m_len = b64.Encoder.calcSize(mac.len);
    const out = try alloc.alloc(u8, p_len + 1 + m_len);
    _ = b64.Encoder.encode(out[0..p_len], payload);
    out[p_len] = '.';
    _ = b64.Encoder.encode(out[p_len + 1 ..], &mac);
    return out;
}

/// The verified token fields (slices into an alloc'd decode buffer — arena usage).
pub const Parts = struct { account: []const u8, list: []const u8, recipient: []const u8 };

/// Verify `token`. Returns null on ANY failure — malformed, oversized, bad MAC,
/// wrong version, wrong field count — deliberately indistinguishable (non-oracle).
pub fn verify(alloc: std.mem.Allocator, jwt_secret: []const u8, token: []const u8) ?Parts {
    const dot = std.mem.indexOfScalar(u8, token, '.') orelse return null;
    const p_enc = token[0..dot];
    const m_enc = token[dot + 1 ..];
    if (p_enc.len == 0 or p_enc.len > max_part_len or m_enc.len == 0 or m_enc.len > max_part_len) return null;

    const p_len = b64.Decoder.calcSizeForSlice(p_enc) catch return null;
    const payload = alloc.alloc(u8, p_len) catch return null;
    b64.Decoder.decode(payload, p_enc) catch return null;

    var mac_given: [HmacSha256.mac_length]u8 = undefined;
    const m_len = b64.Decoder.calcSizeForSlice(m_enc) catch return null;
    if (m_len != mac_given.len) return null; // length-checked before any compare
    b64.Decoder.decode(&mac_given, m_enc) catch return null;

    const key = deriveKey(jwt_secret);
    var mac_want: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac_want, payload, &key);
    if (!crypto.timingSafeEql(&mac_want, &mac_given)) return null; // constant-time

    // Parse "v1\x00account\x00list\x00recipient" — exactly four NUL-framed fields.
    var it = std.mem.splitScalar(u8, payload, 0);
    const ver = it.next() orelse return null;
    if (!std.mem.eql(u8, ver, "v1")) return null;
    const account = it.next() orelse return null;
    const list = it.next() orelse return null;
    const recipient = it.next() orelse return null;
    if (it.next() != null) return null;
    if (recipient.len == 0) return null;
    return .{ .account = account, .list = list, .recipient = recipient };
}

/// Build the full public unsubscribe URL: `<base>/api/mail/unsubscribe?t=<token>`.
/// The token alphabet (base64url + '.') is URL- and header-safe as-is.
pub fn buildUrl(alloc: std.mem.Allocator, base_url: []const u8, jwt_secret: []const u8, account: []const u8, list: []const u8, recipient: []const u8) ![]u8 {
    const token = try mint(alloc, jwt_secret, account, list, recipient);
    defer alloc.free(token);
    const base = std.mem.trimEnd(u8, base_url, "/");
    return std.fmt.allocPrint(alloc, "{s}/api/mail/unsubscribe?t={s}", .{ base, token });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// `verify` never frees its internal decode buffer (it's designed for arena-allocator
// callers — see the `Parts` doc comment), so every test that calls `verify` runs its
// alloc through a scratch arena rather than `testing.allocator` directly.

test "mint -> verify round-trips the exact fields, including empty account and empty list" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const token = try mint(a, "s3cret", "acc1", "news", "user@x.io");
    defer a.free(token);
    const parts = verify(arena.allocator(), "s3cret", token) orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("acc1", parts.account);
    try testing.expectEqualStrings("news", parts.list);
    try testing.expectEqualStrings("user@x.io", parts.recipient);

    // Empty account AND empty list (a system/unscoped send) round-trip too.
    const token2 = try mint(a, "s3cret", "", "", "user@x.io");
    defer a.free(token2);
    const parts2 = verify(arena.allocator(), "s3cret", token2) orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("", parts2.account);
    try testing.expectEqualStrings("", parts2.list);
    try testing.expectEqualStrings("user@x.io", parts2.recipient);
}

test "verify rejects a tampered payload half" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const token = try mint(a, "s3cret", "acc1", "news", "user@x.io");
    defer a.free(token);
    const bad = try a.dupe(u8, token);
    defer a.free(bad);
    // Flip one byte in the payload half.
    bad[0] = if (bad[0] == 'A') 'B' else 'A';
    try testing.expect(verify(arena.allocator(), "s3cret", bad) == null);
}

test "verify rejects a tampered MAC half" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const token = try mint(a, "s3cret", "acc1", "news", "user@x.io");
    defer a.free(token);
    const bad = try a.dupe(u8, token);
    defer a.free(bad);
    const last = bad.len - 1;
    bad[last] = if (bad[last] == 'A') 'B' else 'A';
    try testing.expect(verify(arena.allocator(), "s3cret", bad) == null);
}

test "verify rejects the wrong secret" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const token = try mint(a, "s3cret", "acc1", "news", "user@x.io");
    defer a.free(token);
    try testing.expect(verify(arena.allocator(), "other-secret", token) == null);
}

test "verify rejects malformed tokens: truncated, dot-less, oversized" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    try testing.expect(verify(aa, "s3cret", "") == null);
    try testing.expect(verify(aa, "s3cret", "no-dot-here") == null);
    try testing.expect(verify(aa, "s3cret", ".") == null);
    try testing.expect(verify(aa, "s3cret", "ab.") == null);
    try testing.expect(verify(aa, "s3cret", ".cd") == null);

    const token = try mint(a, "s3cret", "acc1", "news", "user@x.io");
    defer a.free(token);
    const truncated = token[0 .. token.len - 5];
    try testing.expect(verify(aa, "s3cret", truncated) == null);

    const oversized = try aa.alloc(u8, max_part_len + 10);
    @memset(oversized, 'A');
    const oversized_token = try std.fmt.allocPrint(aa, "{s}.AAAA", .{oversized});
    try testing.expect(verify(aa, "s3cret", oversized_token) == null);
}

test "deriveKey is stable and secret-dependent" {
    const k1 = deriveKey("s");
    const k1b = deriveKey("s");
    const k2 = deriveKey("t");
    try testing.expectEqualSlices(u8, &k1, &k1b);
    try testing.expect(!std.mem.eql(u8, &k1, &k2));
}

test "buildUrl starts with the trimmed base and contains the token param" {
    const a = testing.allocator;
    const url = try buildUrl(a, "https://app.example.com/", "s3cret", "acc1", "news", "user@x.io");
    defer a.free(url);
    try testing.expect(std.mem.startsWith(u8, url, "https://app.example.com/api/mail/unsubscribe?t="));
    try testing.expect(std.mem.indexOf(u8, url, "?t=") != null);
}
