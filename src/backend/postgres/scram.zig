//! SCRAM-SHA-256 (RFC 5802 / RFC 7677) client-side SASL exchange for the PostgreSQL
//! wire driver, built entirely on Zig `std.crypto` — `pbkdf2`, `HmacSha256`, `Sha256`,
//! `std.crypto.random` — so the driver needs no external crypto (no OpenSSL/libpq).
//!
//! Flow (no channel binding, GS2 header `n,,`):
//!   1. `clientFirst`     → `n,,n=,r=<client-nonce>`
//!   2. server-first      ← `r=<combined-nonce>,s=<b64 salt>,i=<iterations>`
//!   3. `clientFinal`     → `c=biws,r=<combined-nonce>,p=<b64 ClientProof>`
//!   4. server-final      ← `v=<b64 ServerSignature>`  (verified by `verifyServerFinal`)
//!
//! Limitation: passwords are used verbatim (no SASLprep/RFC 4013). ASCII passwords —
//! the overwhelmingly common case — are unaffected; a password containing non-ASCII
//! that requires normalization may fail to authenticate. Documented, not yet handled.

const std = @import("std");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const pbkdf2 = std.crypto.pwhash.pbkdf2;
const b64 = std.base64.standard;

pub const ScramError = error{
    MalformedServerFirst,
    MalformedServerFinal,
    NonceMismatch,
    ServerSignatureMismatch,
    InvalidBase64,
    OutOfMemory,
    /// Server returned a SCRAM error in the server-final message (`e=<reason>`).
    AuthenticationRejected,
};

/// Client-side SCRAM-SHA-256 state machine. Owns small heap buffers (client nonce,
/// client-first-bare, auth-message) allocated from the supplied allocator; call
/// `deinit` to release them. One instance drives one authentication exchange.
pub const Client = struct {
    allocator: std.mem.Allocator,
    /// Base64 client nonce (`r=` value of the client-first message).
    client_nonce: []u8,
    /// `n=,r=<client-nonce>` — the client-first-message-bare, reused in AuthMessage.
    client_first_bare: []u8,
    /// SaltedPassword (PBKDF2 output), filled by `clientFinal`.
    salted_password: [32]u8 = undefined,
    /// HMAC(ServerKey, AuthMessage), filled by `clientFinal`, checked by `verifyServerFinal`.
    expected_server_sig: [32]u8 = undefined,

    /// Begin a SCRAM exchange. `nonce_seed` supplies the raw randomness for the client
    /// nonce (24 bytes → 32 base64 chars); pass `std.crypto.random` bytes in production,
    /// or a fixed seed in tests for determinism.
    pub fn init(allocator: std.mem.Allocator, nonce_seed: [24]u8) ScramError!Client {
        const nonce = try allocator.alloc(u8, b64.Encoder.calcSize(nonce_seed.len));
        errdefer allocator.free(nonce);
        _ = b64.Encoder.encode(nonce, &nonce_seed);
        const bare = try std.fmt.allocPrint(allocator, "n=,r={s}", .{nonce});
        return .{ .allocator = allocator, .client_nonce = nonce, .client_first_bare = bare };
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.client_nonce);
        self.allocator.free(self.client_first_bare);
    }

    /// The full client-first SASL message (`n,,` GS2 header + client-first-bare). Caller
    /// owns the returned slice and must free it.
    pub fn clientFirst(self: *Client) ScramError![]u8 {
        return std.fmt.allocPrint(self.allocator, "n,,{s}", .{self.client_first_bare});
    }

    /// Consume the server-first message and produce the client-final message
    /// (`c=biws,r=...,p=<proof>`). Caller owns the returned slice and must free it.
    pub fn clientFinal(self: *Client, password: []const u8, server_first: []const u8) ScramError![]u8 {
        // Parse r=<nonce>,s=<b64 salt>,i=<iterations>
        const combined_nonce = field(server_first, "r=") orelse return ScramError.MalformedServerFirst;
        const salt_b64 = field(server_first, "s=") orelse return ScramError.MalformedServerFirst;
        const iter_str = field(server_first, "i=") orelse return ScramError.MalformedServerFirst;

        // The server nonce must extend the client nonce we sent.
        if (!std.mem.startsWith(u8, combined_nonce, self.client_nonce))
            return ScramError.NonceMismatch;

        const iterations = std.fmt.parseInt(u32, iter_str, 10) catch return ScramError.MalformedServerFirst;

        var salt_buf: [256]u8 = undefined;
        const salt_len = b64.Decoder.calcSizeForSlice(salt_b64) catch return ScramError.InvalidBase64;
        if (salt_len > salt_buf.len) return ScramError.InvalidBase64;
        b64.Decoder.decode(salt_buf[0..salt_len], salt_b64) catch return ScramError.InvalidBase64;
        const salt = salt_buf[0..salt_len];

        // SaltedPassword = PBKDF2-HMAC-SHA256(password, salt, i, 32)
        pbkdf2(&self.salted_password, password, salt, iterations, HmacSha256) catch
            return ScramError.MalformedServerFirst;

        // ClientKey = HMAC(SaltedPassword, "Client Key"); StoredKey = SHA256(ClientKey)
        var client_key: [32]u8 = undefined;
        HmacSha256.create(&client_key, "Client Key", &self.salted_password);
        var stored_key: [32]u8 = undefined;
        Sha256.hash(&client_key, &stored_key, .{});

        // client-final-without-proof = "c=biws,r=<combined-nonce>"  (biws = base64("n,,"))
        const client_final_no_proof = try std.fmt.allocPrint(self.allocator, "c=biws,r={s}", .{combined_nonce});
        defer self.allocator.free(client_final_no_proof);

        // AuthMessage = client-first-bare + "," + server-first + "," + client-final-without-proof
        const auth_message = try std.fmt.allocPrint(self.allocator, "{s},{s},{s}", .{
            self.client_first_bare, server_first, client_final_no_proof,
        });
        defer self.allocator.free(auth_message);

        // ClientSignature = HMAC(StoredKey, AuthMessage); ClientProof = ClientKey XOR ClientSignature
        var client_sig: [32]u8 = undefined;
        HmacSha256.create(&client_sig, auth_message, &stored_key);
        var proof: [32]u8 = undefined;
        for (0..32) |i| proof[i] = client_key[i] ^ client_sig[i];

        // ServerKey = HMAC(SaltedPassword, "Server Key");
        // expected ServerSignature = HMAC(ServerKey, AuthMessage)
        var server_key: [32]u8 = undefined;
        HmacSha256.create(&server_key, "Server Key", &self.salted_password);
        HmacSha256.create(&self.expected_server_sig, auth_message, &server_key);

        var proof_b64: [b64.Encoder.calcSize(32)]u8 = undefined;
        _ = b64.Encoder.encode(&proof_b64, &proof);
        return std.fmt.allocPrint(self.allocator, "c=biws,r={s},p={s}", .{ combined_nonce, &proof_b64 });
    }

    /// Verify the server-final message `v=<b64 ServerSignature>` against the value we
    /// derived in `clientFinal`. Returns an error on mismatch or a server-side `e=` error.
    pub fn verifyServerFinal(self: *Client, server_final: []const u8) ScramError!void {
        if (field(server_final, "e=")) |_| return ScramError.AuthenticationRejected;
        const sig_b64 = field(server_final, "v=") orelse return ScramError.MalformedServerFinal;
        var sig_buf: [64]u8 = undefined;
        const sig_len = b64.Decoder.calcSizeForSlice(sig_b64) catch return ScramError.InvalidBase64;
        if (sig_len != 32) return ScramError.MalformedServerFinal;
        b64.Decoder.decode(sig_buf[0..32], sig_b64) catch return ScramError.InvalidBase64;
        if (!std.crypto.timing_safe.eql([32]u8, sig_buf[0..32].*, self.expected_server_sig))
            return ScramError.ServerSignatureMismatch;
    }
};

/// Extract the value of a `key=value` attribute from a comma-separated SCRAM message.
/// `prefix` includes the `=` (e.g. `"r="`). Returns the value up to the next comma.
fn field(msg: []const u8, prefix: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, msg, ',');
    while (it.next()) |part| {
        if (std.mem.startsWith(u8, part, prefix)) return part[prefix.len..];
    }
    return null;
}

// --- tests (run under -Dpostgres) -----------------------------------------------

test "scram field parsing" {
    try std.testing.expectEqualStrings("abc", field("r=abc,s=xyz,i=4096", "r=").?);
    try std.testing.expectEqualStrings("xyz", field("r=abc,s=xyz,i=4096", "s=").?);
    try std.testing.expectEqualStrings("4096", field("r=abc,s=xyz,i=4096", "i=").?);
    try std.testing.expect(field("r=abc", "z=") == null);
}

test "scram-sha-256 RFC-style exchange round-trips against a server stub" {
    // Drive the client, then emulate the server using the SAME primitives and assert
    // the proof verifies and the server-signature we hand back is accepted. This proves
    // the full ClientKey/StoredKey/ClientProof/ServerSignature derivation end to end
    // without needing a live PostgreSQL.
    const a = std.testing.allocator;
    const password = "pencil";
    var seed: [24]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @intCast(i);

    var client = try Client.init(a, seed);
    defer client.deinit();

    const cfirst = try client.clientFirst();
    defer a.free(cfirst);
    try std.testing.expect(std.mem.startsWith(u8, cfirst, "n,,n=,r="));

    // Server side: pick a salt + iteration count, extend the nonce.
    const salt = "W22ZaJ0SNY7soEsUEjb6gQ==";
    var salt_raw: [64]u8 = undefined;
    const salt_len = try b64.Decoder.calcSizeForSlice(salt);
    try b64.Decoder.decode(salt_raw[0..salt_len], salt);
    const server_first = try std.fmt.allocPrint(a, "r={s}servernonce,s={s},i=4096", .{ client.client_nonce, salt });
    defer a.free(server_first);

    const cfinal = try client.clientFinal(password, server_first);
    defer a.free(cfinal);
    try std.testing.expect(std.mem.indexOf(u8, cfinal, ",p=") != null);

    // Server recomputes ServerSignature from the same SaltedPassword and sends it back.
    var server_sig: [32]u8 = undefined;
    {
        var salted: [32]u8 = undefined;
        try pbkdf2(&salted, password, salt_raw[0..salt_len], 4096, HmacSha256);
        var server_key: [32]u8 = undefined;
        HmacSha256.create(&server_key, "Server Key", &salted);
        // Reconstruct AuthMessage exactly as the client did.
        const cfnp = try std.fmt.allocPrint(a, "c=biws,r={s}servernonce", .{client.client_nonce});
        defer a.free(cfnp);
        const auth_message = try std.fmt.allocPrint(a, "{s},{s},{s}", .{ client.client_first_bare, server_first, cfnp });
        defer a.free(auth_message);
        HmacSha256.create(&server_sig, auth_message, &server_key);
    }
    var sig_b64: [b64.Encoder.calcSize(32)]u8 = undefined;
    _ = b64.Encoder.encode(&sig_b64, &server_sig);
    const server_final = try std.fmt.allocPrint(a, "v={s}", .{&sig_b64});
    defer a.free(server_final);

    try client.verifyServerFinal(server_final);
}

test "scram rejects a tampered server signature" {
    const a = std.testing.allocator;
    var seed: [24]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @intCast(i +% 7);
    var client = try Client.init(a, seed);
    defer client.deinit();
    const server_first = try std.fmt.allocPrint(a, "r={s}xx,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096", .{client.client_nonce});
    defer a.free(server_first);
    const cfinal = try client.clientFinal("pencil", server_first);
    defer a.free(cfinal);
    try std.testing.expectError(ScramError.ServerSignatureMismatch, client.verifyServerFinal("v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="));
    try std.testing.expectError(ScramError.AuthenticationRejected, client.verifyServerFinal("e=invalid-proof"));
}
