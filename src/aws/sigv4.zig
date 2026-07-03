//! AWS Signature Version 4 signing, shared by every AWS-flavored HTTP integration in the tree
//! (the SES mail provider (#154) and the S3-compatible storage backend). Pure (no I/O): given
//! the request parts + a clock-supplied timestamp, it produces the `Authorization` header value.
//! Callers own timestamp formatting (`ses.zig`'s `amzDate` helper) and payload hashing.
//!
//! Reference: docs.aws.amazon.com/general/latest/gr/sigv4_signing.html. We implement
//! header-based signing of a single request: `host` + `x-amz-date` are always signed, callers
//! add extra signed headers (`content-type`, `x-amz-content-sha256`, ...) as needed. No
//! query-string signing/presigning yet (a future additive mode on this same surface), no STS
//! session token.

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
    // "AWS4" + secret. 1024 bytes comfortably covers any realistic AWS secret (long-term keys are 40
    // chars; even an SSO/STS-derived secret is far below this), so `bufPrint` cannot overflow — the
    // `unreachable` would only fire on a >1019-char secret, which is not a valid AWS credential. We do
    // NOT fall back to a truncated/raw seed: a wrong seed silently computes the WRONG signing key (a
    // confusing auth failure at AWS), which is worse than a clear crash on impossible input.
    var seed_buf: [1024]u8 = undefined;
    const seed = std.fmt.bufPrint(&seed_buf, "AWS4{s}", .{secret}) catch unreachable;
    const k_date = hmac(seed, date);
    const k_region = hmac(&k_date, region);
    const k_service = hmac(&k_region, service);
    return hmac(&k_service, "aws4_request");
}

pub const Header = struct { name: []const u8, value: []const u8 };

/// The inputs to sign one HTTP request (SigV4, header-based signing; query-string
/// signing/presigning is a future additive mode on this same surface).
pub const SignInput = struct {
    access_key: []const u8,
    secret_key: []const u8,
    region: []const u8,
    service: []const u8, // "ses", "s3", ...
    method: []const u8, // "GET" | "PUT" | "POST" | "DELETE" | "HEAD"
    host: []const u8,
    /// RAW request path ("/" prefixed). Each '/'-separated segment is S3-UriEncoded
    /// into the canonical URI ('/' preserved). SES's fixed paths are unaffected
    /// (no reserved characters).
    path: []const u8,
    /// Pre-canonicalized query string (sorted, encoded). "" for every current caller;
    /// the seam presigning will use later.
    query: []const u8 = "",
    /// EXTRA headers to sign beyond host + x-amz-date (e.g. content-type,
    /// x-amz-content-sha256 — S3 REQUIRES the latter signed). Names must be
    /// lowercase, values trimmed; the signer sorts the merged list.
    headers: []const Header = &.{},
    /// Lowercase-hex SHA-256 of the payload (sha256Hex; empty body => hash of "").
    payload_sha256: []const u8,
    /// `YYYYMMDDTHHMMSSZ` UTC timestamp (the X-Amz-Date header value).
    amz_date: []const u8,
};

/// S3 `UriEncode` of one path: unreserved chars (A-Z a-z 0-9 - . _ ~) verbatim,
/// '/' preserved as the segment separator, EVERYTHING else (incl. space as %20,
/// '+', and each raw UTF-8 byte) percent-encoded uppercase-hex.
pub fn uriEncodePath(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (path) |c| {
        const unreserved = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '-' or c == '.' or c == '_' or c == '~' or c == '/';
        if (unreserved) {
            try out.append(alloc, c);
        } else {
            try out.print(alloc, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Produce the `Authorization` header value for `in`. `host` and `x-amz-date` are
/// always signed; `in.headers` are merged in and the canonical list is sorted by
/// lowercase name (AWS requirement). Caller owns the returned slice.
pub fn signRequest(alloc: std.mem.Allocator, in: SignInput) ![]const u8 {
    const date = in.amz_date[0..8]; // YYYYMMDD

    // `in.headers` documents lowercase-name/trimmed-value as a precondition (both
    // callers currently comply — content-type/x-amz-content-sha256, hardcoded
    // lowercase); enforce it rather than silently computing a wrong signature if a
    // future caller violates it.
    for (in.headers) |h| {
        for (h.name) |c| {
            if (c >= 'A' and c <= 'Z') return error.SignHeaderNameNotLowercase;
        }
        if (!std.mem.eql(u8, h.value, std.mem.trim(u8, h.value, &std.ascii.whitespace))) return error.SignHeaderValueNotTrimmed;
    }

    // Merge host + x-amz-date + extras, then sort by name.
    var hdrs: std.ArrayList(Header) = .empty;
    defer hdrs.deinit(alloc);
    try hdrs.append(alloc, .{ .name = "host", .value = in.host });
    try hdrs.append(alloc, .{ .name = "x-amz-date", .value = in.amz_date });
    try hdrs.appendSlice(alloc, in.headers);
    std.mem.sort(Header, hdrs.items, {}, struct {
        fn lt(_: void, x: Header, y: Header) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);

    var canonical_headers: std.ArrayList(u8) = .empty;
    defer canonical_headers.deinit(alloc);
    var signed_names: std.ArrayList(u8) = .empty;
    defer signed_names.deinit(alloc);
    for (hdrs.items, 0..) |h, i| {
        try canonical_headers.print(alloc, "{s}:{s}\n", .{ h.name, h.value });
        if (i != 0) try signed_names.append(alloc, ';');
        try signed_names.appendSlice(alloc, h.name);
    }

    const canonical_uri = try uriEncodePath(alloc, in.path);
    defer alloc.free(canonical_uri);
    const canonical_request = try std.fmt.allocPrint(
        alloc,
        "{s}\n{s}\n{s}\n{s}\n{s}\n{s}",
        .{ in.method, canonical_uri, in.query, canonical_headers.items, signed_names.items, in.payload_sha256 },
    );
    defer alloc.free(canonical_request);
    const canonical_hash = try sha256Hex(alloc, canonical_request);
    defer alloc.free(canonical_hash);

    const scope = try std.fmt.allocPrint(alloc, "{s}/{s}/{s}/aws4_request", .{ date, in.region, in.service });
    defer alloc.free(scope);
    const string_to_sign = try std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}\n{s}", .{ algorithm, in.amz_date, scope, canonical_hash });
    defer alloc.free(string_to_sign);

    const key = signingKey(in.secret_key, date, in.region, in.service);
    const sig = hmac(&key, string_to_sign);
    const sig_hex = std.fmt.bytesToHex(sig, .lower);
    return std.fmt.allocPrint(
        alloc,
        "{s} Credential={s}/{s}, SignedHeaders={s}, Signature={s}",
        .{ algorithm, in.access_key, scope, signed_names.items, sig_hex },
    );
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

test "PIN: SES-shaped signature is byte-identical across the generalization" {
    // Captured from the OLD SES-only `sign()` before this refactor (same inputs, verbatim
    // output) — proves the generalized signer reproduces the exact wire bytes every stock
    // binary already ships via SesMailer.
    const a = testing.allocator;
    const payload_hash = try sha256Hex(a, "{\"x\":1}");
    defer a.free(payload_hash);
    const auth = try signRequest(a, .{
        .access_key = "AKIDEXAMPLE",
        .secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        .region = "us-east-1",
        .service = "ses",
        .method = "POST",
        .host = "email.us-east-1.amazonaws.com",
        .path = "/v2/email/outbound-emails",
        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .payload_sha256 = payload_hash,
        .amz_date = "20150830T123600Z",
    });
    defer a.free(auth);
    try testing.expectEqualStrings(
        "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/ses/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=508062528073e218234a392834decce34bb7d030379317734459879d48f95492",
        auth,
    );
}

test "signRequest produces a well-formed SES-shaped SigV4 Authorization header" {
    const a = testing.allocator;
    const payload_hash = try sha256Hex(a, "{\"x\":1}");
    defer a.free(payload_hash);
    const auth = try signRequest(a, .{
        .access_key = "AKIDEXAMPLE",
        .secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        .region = "us-east-1",
        .service = "ses",
        .method = "POST",
        .host = "email.us-east-1.amazonaws.com",
        .path = "/v2/email/outbound-emails",
        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .payload_sha256 = payload_hash,
        .amz_date = "20150830T123600Z",
    });
    defer a.free(auth);
    try testing.expect(std.mem.startsWith(u8, auth, "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/ses/aws4_request"));
    try testing.expect(std.mem.indexOf(u8, auth, "SignedHeaders=content-type;host;x-amz-date") != null);
    // 64-hex-char signature suffix.
    const sig_marker = "Signature=";
    const idx = std.mem.indexOf(u8, auth, sig_marker).?;
    const sig = auth[idx + sig_marker.len ..];
    try testing.expectEqual(@as(usize, 64), sig.len);
    for (sig) |c| try testing.expect(std.ascii.isHex(c));
}

test "signRequest is deterministic for identical inputs" {
    const a = testing.allocator;
    const payload_hash = try sha256Hex(a, "{}");
    defer a.free(payload_hash);
    const in = SignInput{
        .access_key = "AKIDEXAMPLE",
        .secret_key = "secret",
        .region = "eu-west-1",
        .service = "ses",
        .method = "POST",
        .host = "email.eu-west-1.amazonaws.com",
        .path = "/v2/email/outbound-emails",
        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .payload_sha256 = payload_hash,
        .amz_date = "20240101T000000Z",
    };
    const s1 = try signRequest(a, in);
    defer a.free(s1);
    const s2 = try signRequest(a, in);
    defer a.free(s2);
    try testing.expectEqualStrings(s1, s2);
}

test "uriEncodePath: S3 UriEncode edges (space, plus, tilde, unicode, '/')" {
    const a = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "/col/rid/a file.png", "/col/rid/a%20file.png" },
        .{ "/a+b", "/a%2Bb" },
        .{ "/a~b-c_d.e", "/a~b-c_d.e" }, // unreserved verbatim
        .{ "/ä", "/%C3%A4" }, // raw UTF-8 bytes, uppercase hex
        .{ "/a/b/c", "/a/b/c" }, // '/' preserved
        .{ "/a=b&c", "/a%3Db%26c" },
    };
    for (cases) |c| {
        const got = try uriEncodePath(a, c[0]);
        defer a.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
}

test "signRequest: AWS SigV4 official test-suite vector (get-vanilla shape)" {
    // Official aws-sig-v4-test-suite creds/date/host; service "service". <SIG> computed via
    // the reference one-liner in the plan brief (never guessed):
    //   mise exec python@3.13 -- python - <<'EOF'
    //   import hashlib, hmac
    //   def h(k, m): return hmac.new(k, m.encode(), hashlib.sha256).digest()
    //   cr = "GET\n/\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\n" + hashlib.sha256(b"").hexdigest()
    //   sts = "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n" + hashlib.sha256(cr.encode()).hexdigest()
    //   k = h(h(h(h(b"AWS4wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY","20150830"),"us-east-1"),"service"),"aws4_request")
    //   print(hmac.new(k, sts.encode(), hashlib.sha256).hexdigest())
    //   EOF
    const a = testing.allocator;
    const empty_hash = try sha256Hex(a, "");
    defer a.free(empty_hash);
    const auth = try signRequest(a, .{
        .access_key = "AKIDEXAMPLE",
        .secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        .region = "us-east-1",
        .service = "service",
        .method = "GET",
        .host = "example.amazonaws.com",
        .path = "/",
        .payload_sha256 = empty_hash,
        .amz_date = "20150830T123600Z",
    });
    defer a.free(auth);
    try testing.expectEqualStrings(
        "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31",
        auth,
    );
}

test "signRequest: S3-shaped PUT vector (content-type + x-amz-content-sha256 signed, UriEncoded path)" {
    // <SIG> computed the same way as the vector above, adapted for the S3-shaped canonical
    // request (PUT, UriEncoded path with a space, content-type + x-amz-content-sha256 signed):
    //   mise exec python@3.13 -- python - <<'EOF'
    //   import hashlib, hmac
    //   def h(k, m): return hmac.new(k, m.encode(), hashlib.sha256).digest()
    //   payload_hash = hashlib.sha256(b"hello").hexdigest()
    //   cr = ("PUT\n/bucket/col/rid/a%20file.png\n\n"
    //         "content-type:image/png\nhost:bucket.s3.us-east-1.amazonaws.com\n"
    //         f"x-amz-content-sha256:{payload_hash}\nx-amz-date:20150830T123600Z\n\n"
    //         f"content-type;host;x-amz-content-sha256;x-amz-date\n{payload_hash}")
    //   sts = "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/s3/aws4_request\n" + hashlib.sha256(cr.encode()).hexdigest()
    //   k = h(h(h(h(b"AWS4wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY","20150830"),"us-east-1"),"s3"),"aws4_request")
    //   print(hmac.new(k, sts.encode(), hashlib.sha256).hexdigest())
    //   EOF
    const a = testing.allocator;
    const payload_hash = try sha256Hex(a, "hello");
    defer a.free(payload_hash);
    const auth = try signRequest(a, .{
        .access_key = "AKIDEXAMPLE",
        .secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        .region = "us-east-1",
        .service = "s3",
        .method = "PUT",
        .host = "bucket.s3.us-east-1.amazonaws.com",
        .path = "/bucket/col/rid/a file.png",
        .headers = &.{
            .{ .name = "content-type", .value = "image/png" },
            .{ .name = "x-amz-content-sha256", .value = payload_hash },
        },
        .payload_sha256 = payload_hash,
        .amz_date = "20150830T123600Z",
    });
    defer a.free(auth);
    try testing.expectEqualStrings(
        "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/s3/aws4_request, SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, Signature=41f38683dd8281f8e069a3770076588a1ec766018b706c308b44acdee450ca5a",
        auth,
    );
}
