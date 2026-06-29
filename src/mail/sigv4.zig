//! AWS Signature Version 4 signing for the SES HTTP provider (#154). Pure (no I/O): given the
//! request parts + a clock-supplied timestamp, it produces the `Authorization` header value and
//! the `X-Amz-Date` header. This is isolated and test-vectored so the (untestable-here) live SES
//! POST in `ses.zig` rides a verified signer.
//!
//! Reference: docs.aws.amazon.com/general/latest/gr/sigv4_signing.html. We implement the subset
//! SES SendEmail needs: a single POST with a JSON body, `host` + `x-amz-date` signed headers, and
//! the payload hash. No query-string signing, no STS session token (callers using temporary
//! credentials can extend `signedHeaders`/`credential` later behind this same surface).

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const algorithm = "AWS4-HMAC-SHA256";

/// Lowercase hex SHA-256 of `data`. Used for the payload hash and the hashed canonical request.
pub fn sha256Hex(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return alloc.dupe(u8, &hex);
}

fn hmac(key: []const u8, data: []const u8) [HmacSha256.mac_length]u8 {
    var out: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&out, data, key);
    return out;
}

/// Derive the SigV4 signing key: HMAC chain over date → region → service → "aws4_request",
/// seeded with `"AWS4" ++ secret`. Returns the 32-byte key.
pub fn signingKey(secret: []const u8, date: []const u8, region: []const u8, service: []const u8) [HmacSha256.mac_length]u8 {
    var seed_buf: [256]u8 = undefined;
    const seed = std.fmt.bufPrint(&seed_buf, "AWS4{s}", .{secret}) catch unreachable;
    const k_date = hmac(seed, date);
    const k_region = hmac(&k_date, region);
    const k_service = hmac(&k_region, service);
    return hmac(&k_service, "aws4_request");
}

/// The inputs needed to sign one SES POST.
pub const Request = struct {
    access_key: []const u8,
    secret_key: []const u8,
    region: []const u8,
    service: []const u8 = "ses",
    host: []const u8,
    /// Request path (e.g. "/v2/email/outbound-emails"). Must be already-canonical (no encoding
    /// needed for SES's fixed paths).
    path: []const u8,
    body: []const u8,
    /// `YYYYMMDDTHHMMSSZ` UTC timestamp (the value of the `X-Amz-Date` header).
    amz_date: []const u8,
};

/// The computed signing artifacts to attach to the outbound request.
pub const Signed = struct {
    authorization: []const u8,
    amz_date: []const u8,
    payload_sha256: []const u8,
};

/// Produce the `Authorization` header value (and echo `x-amz-date` + payload hash) for `req`.
/// Caller owns the returned slices (allocated with `alloc`). Signs `host`, `x-amz-date`, and
/// `content-type: application/json` (SES requires JSON), with `content-type` first in canonical order.
pub fn sign(alloc: std.mem.Allocator, req: Request) !Signed {
    const date = req.amz_date[0..8]; // YYYYMMDD
    const payload_hash = try sha256Hex(alloc, req.body);

    // Canonical headers MUST be sorted by lowercase name. content-type < host < x-amz-date.
    const signed_headers = "content-type;host;x-amz-date";
    const canonical_headers = try std.fmt.allocPrint(
        alloc,
        "content-type:application/json\nhost:{s}\nx-amz-date:{s}\n",
        .{ req.host, req.amz_date },
    );
    defer alloc.free(canonical_headers);

    // Canonical request: METHOD \n PATH \n QUERY \n CANONICAL_HEADERS \n SIGNED_HEADERS \n PAYLOAD_HASH.
    const canonical_request = try std.fmt.allocPrint(
        alloc,
        "POST\n{s}\n\n{s}\n{s}\n{s}",
        .{ req.path, canonical_headers, signed_headers, payload_hash },
    );
    defer alloc.free(canonical_request);
    const canonical_hash = try sha256Hex(alloc, canonical_request);
    defer alloc.free(canonical_hash);

    const scope = try std.fmt.allocPrint(alloc, "{s}/{s}/{s}/aws4_request", .{ date, req.region, req.service });
    defer alloc.free(scope);

    const string_to_sign = try std.fmt.allocPrint(
        alloc,
        "{s}\n{s}\n{s}\n{s}",
        .{ algorithm, req.amz_date, scope, canonical_hash },
    );
    defer alloc.free(string_to_sign);

    const key = signingKey(req.secret_key, date, req.region, req.service);
    const sig = hmac(&key, string_to_sign);
    const sig_hex = std.fmt.bytesToHex(sig, .lower);

    const authorization = try std.fmt.allocPrint(
        alloc,
        "{s} Credential={s}/{s}, SignedHeaders={s}, Signature={s}",
        .{ algorithm, req.access_key, scope, signed_headers, sig_hex },
    );
    return .{ .authorization = authorization, .amz_date = req.amz_date, .payload_sha256 = payload_hash };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "sha256Hex matches a known empty-string digest" {
    const a = testing.allocator;
    const h = try sha256Hex(a, "");
    defer a.free(h);
    // SHA-256("") is the well-known constant.
    try testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", h);
}

test "signingKey matches the AWS documented derivation vector" {
    // From docs.aws.amazon.com/general/latest/gr/sigv4-calculate-signature.html — the canonical
    // worked example: secret/date/region/service below yield this exact derived signing key.
    const key = signingKey("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "20150830", "us-east-1", "iam");
    const hex = std.fmt.bytesToHex(key, .lower);
    try testing.expectEqualStrings("c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9", &hex);
}

test "sign produces a well-formed SigV4 Authorization header" {
    const a = testing.allocator;
    const signed = try sign(a, .{
        .access_key = "AKIDEXAMPLE",
        .secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        .region = "us-east-1",
        .host = "email.us-east-1.amazonaws.com",
        .path = "/v2/email/outbound-emails",
        .body = "{\"x\":1}",
        .amz_date = "20150830T123600Z",
    });
    defer a.free(signed.authorization);
    defer a.free(signed.payload_sha256);
    try testing.expect(std.mem.startsWith(u8, signed.authorization, "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/ses/aws4_request"));
    try testing.expect(std.mem.indexOf(u8, signed.authorization, "SignedHeaders=content-type;host;x-amz-date") != null);
    // 64-hex-char signature suffix.
    const sig_marker = "Signature=";
    const idx = std.mem.indexOf(u8, signed.authorization, sig_marker).?;
    const sig = signed.authorization[idx + sig_marker.len ..];
    try testing.expectEqual(@as(usize, 64), sig.len);
    for (sig) |c| try testing.expect(std.ascii.isHex(c));
}

test "sign is deterministic for identical inputs" {
    const a = testing.allocator;
    const req = Request{
        .access_key = "AKIDEXAMPLE",
        .secret_key = "secret",
        .region = "eu-west-1",
        .host = "email.eu-west-1.amazonaws.com",
        .path = "/v2/email/outbound-emails",
        .body = "{}",
        .amz_date = "20240101T000000Z",
    };
    const s1 = try sign(a, req);
    defer a.free(s1.authorization);
    defer a.free(s1.payload_sha256);
    const s2 = try sign(a, req);
    defer a.free(s2.authorization);
    defer a.free(s2.payload_sha256);
    try testing.expectEqualStrings(s1.authorization, s2.authorization);
}
