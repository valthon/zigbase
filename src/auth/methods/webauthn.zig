const std = @import("std");
const method_mod = @import("../method.zig");
const AuthMethod = method_mod.AuthMethod;
const AuthCtx = method_mod.AuthCtx;
const InitiateResult = method_mod.InitiateResult;
const Resolution = method_mod.Resolution;
const challenge_store = @import("../challenge_store.zig");
const ChallengeStore = challenge_store.ChallengeStore;
const store_mod = @import("../webauthn/store.zig");
const CredentialStore = store_mod.CredentialStore;
const cose = @import("../webauthn/cose.zig");
const authenticate_mod = @import("../webauthn/authenticate.zig");
const client_data = @import("../webauthn/client_data.zig");
const api_auth = @import("../../api/auth.zig");

// ---------------------------------------------------------------------------
// WebAuthnMethod — passkey login via the AuthMethod contract
// ---------------------------------------------------------------------------

pub const WebAuthnMethod = struct {
    pub fn create(_: std.mem.Allocator, _: std.Io, _: anytype) !WebAuthnMethod {
        return .{};
    }

    pub fn method(self: *WebAuthnMethod) AuthMethod {
        return .{ .slug = "webauthn", .ctx = self, .vtable = &vtable };
    }

    pub fn deinit(_: *WebAuthnMethod) void {}
};

fn strField(obj: std.json.Value, key: []const u8) ?[]const u8 {
    const v = obj.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Decode a base64url (no-pad or with-pad) string into freshly-allocated bytes.
fn b64urlDecode(alloc: std.mem.Allocator, encoded: []const u8) ![]u8 {
    // Strip any trailing '=' padding
    var clean = encoded;
    while (clean.len > 0 and clean[clean.len - 1] == '=') {
        clean = clean[0 .. clean.len - 1];
    }
    const dec_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(clean) catch return error.InvalidBase64;
    const buf = try alloc.alloc(u8, dec_len);
    std.base64.url_safe_no_pad.Decoder.decode(buf, clean) catch {
        alloc.free(buf);
        return error.InvalidBase64;
    };
    return buf;
}

fn initiateImpl(ctx: *anyopaque, ac: *AuthCtx) anyerror!InitiateResult {
    _ = @as(*WebAuthnMethod, @ptrCast(@alignCast(ctx)));

    // Require webauthn config on the collection.
    const wa_opts = ac.collection.options.auth.methods.webauthn orelse {
        return InitiateResult{ .status = 500, .body = "{\"message\":\"WebAuthn not configured for this collection.\"}" };
    };

    // Guard: reject mis-configured webauthn (empty rp_id or origin).
    if (wa_opts.rp_id.len == 0 or wa_opts.origin.len == 0) {
        return InitiateResult{ .status = 500, .body = "{\"message\":\"WebAuthn is enabled but not configured (rp_id and origin are required).\"}" };
    }

    // Parse optional identity from body (usernameless flow supported).
    const identity: []const u8 = blk: {
        const parsed = std.json.parseFromSlice(std.json.Value, ac.ctx.allocator, ac.ctx.body, .{}) catch break :blk "";
        if (parsed.value != .object) break :blk "";
        break :blk strField(parsed.value, "identity") orelse "";
    };

    // Generate 32 random challenge bytes.
    var challenge_raw: [32]u8 = undefined;
    ac.app.io.random(&challenge_raw);

    // Persisting the challenge needs the writer.
    var w = ac.writer();
    defer w.deinit();

    // Store challenge via ChallengeStore with method key "webauthn" (login ceremony).
    const cs = ChallengeStore{ .conn = w.conn };
    const cid = try cs.put(
        ac.ctx.allocator,
        ac.app.io,
        ac.collection.name,
        "webauthn",
        identity,
        &challenge_raw,
        300,
    );

    // Base64url-encode the raw challenge bytes for the browser.
    const challenge_b64 = try client_data.b64urlNoPad(ac.ctx.allocator, &challenge_raw);

    // Build the PublicKeyCredentialRequestOptions JSON response.
    const body = try std.fmt.allocPrint(
        ac.ctx.allocator,
        "{{\"challenge\":\"{s}\",\"rpId\":\"{s}\",\"ceremonyId\":\"{s}\",\"timeout\":300000}}",
        .{ challenge_b64, wa_opts.rp_id, cid },
    );

    return InitiateResult{ .status = 200, .body = body };
}

fn completeImpl(ctx: *anyopaque, ac: *AuthCtx) anyerror!Resolution {
    _ = @as(*WebAuthnMethod, @ptrCast(@alignCast(ctx)));

    // Require webauthn config on the collection.
    const wa_opts = ac.collection.options.auth.methods.webauthn orelse {
        return Resolution{ .fail = .{ .status = 500, .message = "WebAuthn not configured for this collection." } };
    };

    // Guard: reject mis-configured webauthn (empty rp_id or origin).
    if (wa_opts.rp_id.len == 0 or wa_opts.origin.len == 0) {
        return Resolution{ .fail = .{ .status = 500, .message = "WebAuthn is enabled but not configured (rp_id and origin are required)." } };
    }

    // Parse request body.
    const parsed = std.json.parseFromSlice(std.json.Value, ac.ctx.allocator, ac.ctx.body, .{}) catch {
        return Resolution{ .fail = .{ .status = 400, .message = "Invalid JSON body." } };
    };
    if (parsed.value != .object) {
        return Resolution{ .fail = .{ .status = 400, .message = "Invalid JSON body." } };
    }
    const body = parsed.value;

    const ceremony_id = strField(body, "ceremonyId") orelse {
        return Resolution{ .fail = .{ .status = 400, .message = "ceremonyId is required." } };
    };
    const credential_id_b64 = strField(body, "credentialId") orelse {
        return Resolution{ .fail = .{ .status = 400, .message = "credentialId is required." } };
    };
    const auth_data_b64 = strField(body, "authenticatorData") orelse {
        return Resolution{ .fail = .{ .status = 400, .message = "authenticatorData is required." } };
    };
    const cdj_b64 = strField(body, "clientDataJSON") orelse {
        return Resolution{ .fail = .{ .status = 400, .message = "clientDataJSON is required." } };
    };
    const sig_b64 = strField(body, "signature") orelse {
        return Resolution{ .fail = .{ .status = 400, .message = "signature is required." } };
    };

    // Decode all base64url fields.
    const auth_data_bytes = b64urlDecode(ac.ctx.allocator, auth_data_b64) catch {
        return Resolution{ .fail = .{ .status = 400, .message = "Invalid authenticatorData encoding." } };
    };
    const cdj_bytes = b64urlDecode(ac.ctx.allocator, cdj_b64) catch {
        return Resolution{ .fail = .{ .status = 400, .message = "Invalid clientDataJSON encoding." } };
    };
    const sig_bytes = b64urlDecode(ac.ctx.allocator, sig_b64) catch {
        return Resolution{ .fail = .{ .status = 400, .message = "Invalid signature encoding." } };
    };

    // The whole verify ceremony — take challenge, read credential, verify, update
    // sign count — stays atomic under ONE writer held for the entire call.
    var w = ac.writer();
    defer w.deinit();

    // Atomically take (consume) the challenge from the store using the ceremony id.
    // SECURITY: take() filters by method, so a "webauthn_reg" registration challenge
    // cannot be consumed by this login take() that passes "webauthn".
    const cs = ChallengeStore{ .conn = w.conn };
    const challenge_raw_b64 = (try cs.take(ac.ctx.allocator, ceremony_id, "webauthn")) orelse {
        return Resolution{ .fail = .{ .status = 400, .message = "Invalid or expired ceremony." } };
    };
    // The stored payload is the raw challenge bytes (not base64url encoded).
    const challenge_raw = challenge_raw_b64;

    // Look up the credential by its base64url credential id.
    // SECURITY REQUIREMENT 1: user identity comes from the stored credential's record_ref,
    // never from the client request.
    const cred_store = CredentialStore{ .conn = w.conn };
    const cred = (try cred_store.getByCredentialId(ac.ctx.allocator, credential_id_b64)) orelse {
        return Resolution{ .fail = .{ .status = 400, .message = "Unknown credential." } };
    };

    // Decode the stored COSE public key (stored as raw COSE bytes, base64url encoded).
    const cose_key_bytes = b64urlDecode(ac.ctx.allocator, cred.public_key) catch {
        return Resolution{ .fail = .{ .status = 400, .message = "Stored credential key is invalid." } };
    };

    // Parse the COSE key.
    const cose_result = cose.parseCoseKey(cose_key_bytes) catch {
        return Resolution{ .fail = .{ .status = 400, .message = "Failed to parse credential key." } };
    };

    // Verify the assertion (§7.2).
    const assertion_result = authenticate_mod.verifyAssertion(
        ac.ctx.allocator,
        wa_opts.rp_id,
        wa_opts.origin,
        challenge_raw,
        cose_result.key,
        cred.sign_count,
        cdj_bytes,
        auth_data_bytes,
        sig_bytes,
        false, // require_uv — do not require user verification flag (passkey-safe default)
    ) catch {
        return Resolution{ .fail = .{ .status = 401, .message = "Assertion verification failed." } };
    };

    // SECURITY REQUIREMENT 2: clone_suspected=true → fail 401, do NOT update signCount.
    if (assertion_result.clone_suspected) {
        return Resolution{ .fail = .{ .status = 401, .message = "Clone suspected. Login denied." } };
    }

    // Update sign count for future clone detection.
    try cred_store.updateSignCount(credential_id_b64, assertion_result.new_sign_count);

    // SECURITY REQUIREMENT 1 (enforced): return the credential's stored record_ref, not
    // any user-supplied id from the request body.
    return Resolution{ .record = cred.record_ref };
}

const vtable = AuthMethod.VTable{
    .initiate = initiateImpl,
    .complete = completeImpl,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_db = @import("../../db.zig");
const test_migrations = @import("../../migrations.zig");
const test_schema = @import("../../schema.zig");
const test_app_mod = @import("../../app.zig");

/// Pool-backed env so methods can acquire their own pool writer (no bare db.Db).
const WaEnv = struct {
    tmp: std.testing.TmpDir,
    pool: test_db.Pool,
    app: test_app_mod.App,

    fn init() !*WaEnv {
        const env = try std.testing.allocator.create(WaEnv);
        env.tmp = std.testing.tmpDir(.{});
        const dir = try env.tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(dir);
        const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/wa.db", .{dir}, 0);
        defer std.testing.allocator.free(path);
        env.pool = try test_db.Pool.init(std.testing.allocator, std.testing.io, path);
        {
            const w = env.pool.acquireWriter();
            defer env.pool.releaseWriter();
            try test_migrations.run(w);
        }
        env.app = .{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = &env.pool };
        return env;
    }

    fn deinit(env: *WaEnv) void {
        env.pool.deinit();
        env.tmp.cleanup();
        std.testing.allocator.destroy(env);
    }
};

test "WebAuthnMethod: method() returns slug=webauthn and contract is satisfied" {
    var m = try WebAuthnMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    try std.testing.expectEqualStrings("webauthn", am.slug);
    method_mod.assertAuthMethodContract(WebAuthnMethod);
}

test "WebAuthnMethod: initiate returns 200 with challenge + rpId + ceremonyId" {
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");

    var wenv = try WaEnv.init();
    defer wenv.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const col = blk: {
        const w = wenv.pool.acquireWriter();
        defer wenv.pool.releaseWriter();
        _ = try collections.create(a, std.testing.io, w, .{
            .id = "",
            .name = "wausers",
            .type = .auth,
            .fields = &[_]test_schema.Field{},
            .options = .{ .auth = .{ .methods = .{ .webauthn = .{
                .rp_id = "example.test",
                .rp_name = "Test App",
                .origin = "https://example.test",
            } } } },
        });
        break :blk (try collections.get(a, w, "wausers")).?;
    };

    var req = http.RequestCtx{
        .method = .POST,
        .path = "/",
        .body = "{}",
        .allocator = a,
        .app = &wenv.app,
    };
    var ac = AuthCtx{
        .app = &wenv.app,
        .ctx = &req,
        .collection = col,
        .config = .null,
    };

    var m = try WebAuthnMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.initiate(am.ctx, &ac);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expect(res.body != null);
    const b = res.body.?;
    try std.testing.expect(std.mem.indexOf(u8, b, "\"challenge\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "\"rpId\":\"example.test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "\"ceremonyId\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "\"timeout\":300000") != null);
}

test "WebAuthnMethod: initiate without webauthn config returns 500" {
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");

    var wenv = try WaEnv.init();
    defer wenv.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const col = blk: {
        const w = wenv.pool.acquireWriter();
        defer wenv.pool.releaseWriter();
        _ = try collections.create(a, std.testing.io, w, .{
            .id = "",
            .name = "wausers2",
            .type = .auth,
            .fields = &[_]test_schema.Field{},
        });
        break :blk (try collections.get(a, w, "wausers2")).?;
    };

    var req = http.RequestCtx{
        .method = .POST,
        .path = "/",
        .body = "{}",
        .allocator = a,
        .app = &wenv.app,
    };
    var ac = AuthCtx{
        .app = &wenv.app,
        .ctx = &req,
        .collection = col,
        .config = .null,
    };

    var m = try WebAuthnMethod.create(std.testing.allocator, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.initiate(am.ctx, &ac);
    try std.testing.expectEqual(@as(u16, 500), res.status);
}

test "WebAuthnMethod: complete succeeds with valid fixture (ES256)" {
    // Full end-to-end test: pre-insert a credential + challenge, then drive complete().
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");

    const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    const alloc = std.testing.allocator;

    var wenv = try WaEnv.init();
    defer wenv.deinit();

    const rp_id = "example.test";
    const origin = "https://example.test";

    var setup_arena = std.heap.ArenaAllocator.init(alloc);
    defer setup_arena.deinit();
    const sa = setup_arena.allocator();

    // Generate an EC P-256 key pair deterministically.
    const seed = [_]u8{0x42} ** 32;
    const kp = try Ecdsa.KeyPair.generateDeterministic(seed);

    // Build EC2 COSE key bytes.
    const sec1 = kp.public_key.toUncompressedSec1();
    var x: [32]u8 = undefined;
    var y: [32]u8 = undefined;
    @memcpy(&x, sec1[1..33]);
    @memcpy(&y, sec1[33..65]);

    const cose_key_buf = try buildEc2CoseKeyBytes(alloc, x, y);
    defer alloc.free(cose_key_buf);

    // Base64url-encode the COSE key for storage.
    const cose_key_b64 = try client_data.b64urlNoPad(alloc, cose_key_buf);
    defer alloc.free(cose_key_b64);

    // The credential id (arbitrary 8 bytes).
    const cred_id_raw = [_]u8{ 0xC0, 0xFF, 0xEE, 0xC0, 0xFF, 0xEE, 0xC0, 0xFF };
    const cred_id_b64 = try client_data.b64urlNoPad(alloc, &cred_id_raw);
    defer alloc.free(cred_id_b64);

    // Generate a 32-byte raw challenge.
    const challenge_raw = [_]u8{0xAB} ** 32;
    const challenge_b64 = try client_data.b64urlNoPad(alloc, &challenge_raw);
    defer alloc.free(challenge_b64);

    // All DB setup under a writer that is RELEASED before complete() (which
    // acquires its own writer). Returns the ceremony id.
    const cid = blk: {
        const w = wenv.pool.acquireWriter();
        defer wenv.pool.releaseWriter();

        // Create auth collection with webauthn configured.
        _ = try collections.create(sa, std.testing.io, w, .{
            .id = "",
            .name = "wausers3",
            .type = .auth,
            .fields = &[_]test_schema.Field{},
            .options = .{ .auth = .{ .methods = .{ .webauthn = .{
                .rp_id = rp_id,
                .rp_name = "Test App",
                .origin = origin,
            } } } },
        });

        // Insert a test user record.
        try w.exec("INSERT INTO \"wausers3\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('usr001','','','w@x.io','tk001',1);");

        // Insert the credential.
        const cred_store = CredentialStore{ .conn = w };
        try cred_store.insert(
            alloc,
            std.testing.io,
            "wausers3",
            "usr001",
            cred_id_b64,
            cose_key_b64,
            -7,
            0, // initial signCount
            "",
            "",
        );

        // Store the challenge in the ChallengeStore with method "webauthn".
        const cs = ChallengeStore{ .conn = w };
        break :blk try cs.put(alloc, std.testing.io, "wausers3", "webauthn", "", &challenge_raw, 300);
    };
    defer alloc.free(cid);

    // Build authenticator data (37 bytes: rpIdHash + flags + signCount).
    var auth_data_raw: [37]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(rp_id, auth_data_raw[0..32], .{});
    auth_data_raw[32] = 0x05; // UP=1, UV=1
    std.mem.writeInt(u32, auth_data_raw[33..37], 1, .big); // signCount=1

    // Build clientDataJSON.
    const cdj = try std.fmt.allocPrint(alloc,
        "{{\"type\":\"webauthn.get\",\"challenge\":\"{s}\",\"origin\":\"{s}\"}}",
        .{ challenge_b64, origin },
    );
    defer alloc.free(cdj);

    // Build signature base: authData || SHA-256(clientDataJSON).
    var sig_base: [37 + 32]u8 = undefined;
    @memcpy(sig_base[0..37], &auth_data_raw);
    std.crypto.hash.sha2.Sha256.hash(cdj, sig_base[37..][0..32], .{});

    // Sign and DER-encode.
    const raw_sig = try kp.sign(&sig_base, null);
    var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const der = raw_sig.toDer(&der_buf);

    // Base64url-encode all the client-sent values.
    const auth_data_b64 = try client_data.b64urlNoPad(alloc, &auth_data_raw);
    defer alloc.free(auth_data_b64);
    const cdj_b64 = try client_data.b64urlNoPad(alloc, cdj);
    defer alloc.free(cdj_b64);
    const sig_b64 = try client_data.b64urlNoPad(alloc, der);
    defer alloc.free(sig_b64);

    // Build the request body.
    const body_str = try std.fmt.allocPrint(alloc,
        "{{\"ceremonyId\":\"{s}\",\"credentialId\":\"{s}\",\"authenticatorData\":\"{s}\",\"clientDataJSON\":\"{s}\",\"signature\":\"{s}\"}}",
        .{ cid, cred_id_b64, auth_data_b64, cdj_b64, sig_b64 },
    );
    defer alloc.free(body_str);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const col = blk: {
        const w = wenv.pool.acquireWriter();
        defer wenv.pool.releaseWriter();
        break :blk (try collections.get(a, w, "wausers3")).?;
    };
    var req = http.RequestCtx{
        .method = .POST,
        .path = "/",
        .body = body_str,
        .allocator = a,
        .app = &wenv.app,
    };
    var ac = AuthCtx{
        .app = &wenv.app,
        .ctx = &req,
        .collection = col,
        .config = .null,
    };

    var m = try WebAuthnMethod.create(alloc, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.complete(am.ctx, &ac);
    switch (res) {
        .record => |rid| try std.testing.expectEqualStrings("usr001", rid),
        .fail => |f| {
            std.debug.print("Expected .record but got .fail: status={d} msg={s}\n", .{ f.status, f.message });
            return error.TestFailed;
        },
    }
}

test "WebAuthnMethod: complete with tampered signature returns 401" {
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");
    const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    const alloc = std.testing.allocator;

    var wenv = try WaEnv.init();
    defer wenv.deinit();

    var setup_arena = std.heap.ArenaAllocator.init(alloc);
    defer setup_arena.deinit();
    const sa = setup_arena.allocator();

    const rp_id = "example.test";
    const origin = "https://example.test";

    const seed = [_]u8{0x43} ** 32;
    const kp = try Ecdsa.KeyPair.generateDeterministic(seed);
    const sec1 = kp.public_key.toUncompressedSec1();
    var x: [32]u8 = undefined;
    var y: [32]u8 = undefined;
    @memcpy(&x, sec1[1..33]);
    @memcpy(&y, sec1[33..65]);
    const cose_key_buf = try buildEc2CoseKeyBytes(alloc, x, y);
    defer alloc.free(cose_key_buf);
    const cose_key_b64 = try client_data.b64urlNoPad(alloc, cose_key_buf);
    defer alloc.free(cose_key_b64);

    const cred_id_raw = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0xDE, 0xAD, 0xBE, 0xEF };
    const cred_id_b64 = try client_data.b64urlNoPad(alloc, &cred_id_raw);
    defer alloc.free(cred_id_b64);

    const challenge_raw = [_]u8{0xCD} ** 32;
    const challenge_b64 = try client_data.b64urlNoPad(alloc, &challenge_raw);
    defer alloc.free(challenge_b64);

    const cid = blk: {
        const w = wenv.pool.acquireWriter();
        defer wenv.pool.releaseWriter();
        _ = try collections.create(sa, std.testing.io, w, .{
            .id = "",
            .name = "wausers4",
            .type = .auth,
            .fields = &[_]test_schema.Field{},
            .options = .{ .auth = .{ .methods = .{ .webauthn = .{
                .rp_id = rp_id,
                .rp_name = "Test App",
                .origin = origin,
            } } } },
        });
        try w.exec("INSERT INTO \"wausers4\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('usr002','','','w2@x.io','tk002',1);");
        const cred_store = CredentialStore{ .conn = w };
        try cred_store.insert(alloc, std.testing.io, "wausers4", "usr002", cred_id_b64, cose_key_b64, -7, 0, "", "");
        const cs = ChallengeStore{ .conn = w };
        break :blk try cs.put(alloc, std.testing.io, "wausers4", "webauthn", "", &challenge_raw, 300);
    };
    defer alloc.free(cid);

    var auth_data_raw: [37]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(rp_id, auth_data_raw[0..32], .{});
    auth_data_raw[32] = 0x05;
    std.mem.writeInt(u32, auth_data_raw[33..37], 1, .big);

    const cdj = try std.fmt.allocPrint(alloc,
        "{{\"type\":\"webauthn.get\",\"challenge\":\"{s}\",\"origin\":\"{s}\"}}",
        .{ challenge_b64, origin },
    );
    defer alloc.free(cdj);

    var sig_base: [37 + 32]u8 = undefined;
    @memcpy(sig_base[0..37], &auth_data_raw);
    std.crypto.hash.sha2.Sha256.hash(cdj, sig_base[37..][0..32], .{});

    const raw_sig = try kp.sign(&sig_base, null);
    var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const der_slice = raw_sig.toDer(&der_buf);

    // Tamper: flip the last byte.
    var bad_der: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    @memcpy(bad_der[0..der_slice.len], der_slice);
    bad_der[der_slice.len - 1] ^= 0xFF;

    const auth_data_b64 = try client_data.b64urlNoPad(alloc, &auth_data_raw);
    defer alloc.free(auth_data_b64);
    const cdj_b64 = try client_data.b64urlNoPad(alloc, cdj);
    defer alloc.free(cdj_b64);
    const sig_b64 = try client_data.b64urlNoPad(alloc, bad_der[0..der_slice.len]);
    defer alloc.free(sig_b64);

    const body_str = try std.fmt.allocPrint(alloc,
        "{{\"ceremonyId\":\"{s}\",\"credentialId\":\"{s}\",\"authenticatorData\":\"{s}\",\"clientDataJSON\":\"{s}\",\"signature\":\"{s}\"}}",
        .{ cid, cred_id_b64, auth_data_b64, cdj_b64, sig_b64 },
    );
    defer alloc.free(body_str);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const col = blk: {
        const w = wenv.pool.acquireWriter();
        defer wenv.pool.releaseWriter();
        break :blk (try collections.get(a, w, "wausers4")).?;
    };
    var req = http.RequestCtx{ .method = .POST, .path = "/", .body = body_str, .allocator = a, .app = &wenv.app };
    var ac = AuthCtx{ .app = &wenv.app, .ctx = &req, .collection = col, .config = .null };

    var m = try WebAuthnMethod.create(alloc, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.complete(am.ctx, &ac);
    switch (res) {
        .fail => |f| try std.testing.expectEqual(@as(u16, 401), f.status),
        .record => return error.TestFailed,
    }
}

test "WebAuthnMethod: complete with unknown credentialId returns 400" {
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");
    const alloc = std.testing.allocator;

    var wenv = try WaEnv.init();
    defer wenv.deinit();

    var setup_arena = std.heap.ArenaAllocator.init(alloc);
    defer setup_arena.deinit();
    const sa = setup_arena.allocator();

    const cid = blk: {
        const w = wenv.pool.acquireWriter();
        defer wenv.pool.releaseWriter();
        _ = try collections.create(sa, std.testing.io, w, .{
            .id = "",
            .name = "wausers5",
            .type = .auth,
            .fields = &[_]test_schema.Field{},
            .options = .{ .auth = .{ .methods = .{ .webauthn = .{
                .rp_id = "example.test",
                .rp_name = "Test App",
                .origin = "https://example.test",
            } } } },
        });
        const challenge_raw = [_]u8{0xEF} ** 32;
        const cs = ChallengeStore{ .conn = w };
        break :blk try cs.put(alloc, std.testing.io, "wausers5", "webauthn", "", &challenge_raw, 300);
    };
    defer alloc.free(cid);

    const body_str = try std.fmt.allocPrint(alloc,
        "{{\"ceremonyId\":\"{s}\",\"credentialId\":\"nonexistent_cred\",\"authenticatorData\":\"AAAA\",\"clientDataJSON\":\"AAAA\",\"signature\":\"AAAA\"}}",
        .{cid},
    );
    defer alloc.free(body_str);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const col = blk: {
        const w = wenv.pool.acquireWriter();
        defer wenv.pool.releaseWriter();
        break :blk (try collections.get(a, w, "wausers5")).?;
    };
    var req = http.RequestCtx{ .method = .POST, .path = "/", .body = body_str, .allocator = a, .app = &wenv.app };
    var ac = AuthCtx{ .app = &wenv.app, .ctx = &req, .collection = col, .config = .null };

    var m = try WebAuthnMethod.create(alloc, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.complete(am.ctx, &ac);
    switch (res) {
        .fail => |f| try std.testing.expectEqual(@as(u16, 400), f.status),
        .record => return error.TestFailed,
    }
}

test "WebAuthnMethod: complete with expired ceremonyId returns 400" {
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");
    const alloc = std.testing.allocator;

    var wenv = try WaEnv.init();
    defer wenv.deinit();

    var setup_arena = std.heap.ArenaAllocator.init(alloc);
    defer setup_arena.deinit();
    const sa = setup_arena.allocator();

    const cid = blk: {
        const w = wenv.pool.acquireWriter();
        defer wenv.pool.releaseWriter();
        _ = try collections.create(sa, std.testing.io, w, .{
            .id = "",
            .name = "wausers6",
            .type = .auth,
            .fields = &[_]test_schema.Field{},
            .options = .{ .auth = .{ .methods = .{ .webauthn = .{
                .rp_id = "example.test",
                .rp_name = "Test App",
                .origin = "https://example.test",
            } } } },
        });
        // Put a challenge with negative TTL (already expired).
        const challenge_raw = [_]u8{0xF0} ** 32;
        const cs = ChallengeStore{ .conn = w };
        break :blk try cs.put(alloc, std.testing.io, "wausers6", "webauthn", "", &challenge_raw, -1);
    };
    defer alloc.free(cid);

    const body_str = try std.fmt.allocPrint(alloc,
        "{{\"ceremonyId\":\"{s}\",\"credentialId\":\"somecred\",\"authenticatorData\":\"AAAA\",\"clientDataJSON\":\"AAAA\",\"signature\":\"AAAA\"}}",
        .{cid},
    );
    defer alloc.free(body_str);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const col = blk: {
        const w = wenv.pool.acquireWriter();
        defer wenv.pool.releaseWriter();
        break :blk (try collections.get(a, w, "wausers6")).?;
    };
    var req = http.RequestCtx{ .method = .POST, .path = "/", .body = body_str, .allocator = a, .app = &wenv.app };
    var ac = AuthCtx{ .app = &wenv.app, .ctx = &req, .collection = col, .config = .null };

    var m = try WebAuthnMethod.create(alloc, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.complete(am.ctx, &ac);
    switch (res) {
        .fail => |f| try std.testing.expectEqual(@as(u16, 400), f.status),
        .record => return error.TestFailed,
    }
}

test "WebAuthnMethod: complete with clone signal (stored count > new count) returns 401" {
    // SECURITY: clone detection must reject and NOT update signCount.
    const http = @import("../../http.zig");
    const collections = @import("../../collections.zig");
    const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    const alloc = std.testing.allocator;

    var wenv = try WaEnv.init();
    defer wenv.deinit();

    var setup_arena = std.heap.ArenaAllocator.init(alloc);
    defer setup_arena.deinit();
    const sa = setup_arena.allocator();

    const rp_id = "example.test";
    const origin = "https://example.test";

    const seed = [_]u8{0x77} ** 32;
    const kp = try Ecdsa.KeyPair.generateDeterministic(seed);
    const sec1 = kp.public_key.toUncompressedSec1();
    var x: [32]u8 = undefined;
    var y: [32]u8 = undefined;
    @memcpy(&x, sec1[1..33]);
    @memcpy(&y, sec1[33..65]);
    const cose_key_buf = try buildEc2CoseKeyBytes(alloc, x, y);
    defer alloc.free(cose_key_buf);
    const cose_key_b64 = try client_data.b64urlNoPad(alloc, cose_key_buf);
    defer alloc.free(cose_key_b64);

    const cred_id_raw = [_]u8{ 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77 };
    const cred_id_b64 = try client_data.b64urlNoPad(alloc, &cred_id_raw);
    defer alloc.free(cred_id_b64);

    const challenge_raw = [_]u8{0x77} ** 32;
    const challenge_b64 = try client_data.b64urlNoPad(alloc, &challenge_raw);
    defer alloc.free(challenge_b64);

    const cid = blk: {
        const w = wenv.pool.acquireWriter();
        defer wenv.pool.releaseWriter();
        _ = try collections.create(sa, std.testing.io, w, .{
            .id = "",
            .name = "wausers7",
            .type = .auth,
            .fields = &[_]test_schema.Field{},
            .options = .{ .auth = .{ .methods = .{ .webauthn = .{
                .rp_id = rp_id,
                .rp_name = "Test App",
                .origin = origin,
            } } } },
        });
        try w.exec("INSERT INTO \"wausers7\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('usr007','','','w7@x.io','tk007',1);");
        const cred_store = CredentialStore{ .conn = w };
        // Store signCount=5 in DB; assertion will report count=1 → clone signal.
        try cred_store.insert(alloc, std.testing.io, "wausers7", "usr007", cred_id_b64, cose_key_b64, -7, 5, "", "");
        const cs = ChallengeStore{ .conn = w };
        break :blk try cs.put(alloc, std.testing.io, "wausers7", "webauthn", "", &challenge_raw, 300);
    };
    defer alloc.free(cid);

    var auth_data_raw: [37]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(rp_id, auth_data_raw[0..32], .{});
    auth_data_raw[32] = 0x05;
    std.mem.writeInt(u32, auth_data_raw[33..37], 1, .big); // assertion reports count=1, stored=5 → clone!

    const cdj = try std.fmt.allocPrint(alloc,
        "{{\"type\":\"webauthn.get\",\"challenge\":\"{s}\",\"origin\":\"{s}\"}}",
        .{ challenge_b64, origin },
    );
    defer alloc.free(cdj);

    var sig_base: [37 + 32]u8 = undefined;
    @memcpy(sig_base[0..37], &auth_data_raw);
    std.crypto.hash.sha2.Sha256.hash(cdj, sig_base[37..][0..32], .{});

    const raw_sig = try kp.sign(&sig_base, null);
    var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const der = raw_sig.toDer(&der_buf);

    const auth_data_b64 = try client_data.b64urlNoPad(alloc, &auth_data_raw);
    defer alloc.free(auth_data_b64);
    const cdj_b64_enc = try client_data.b64urlNoPad(alloc, cdj);
    defer alloc.free(cdj_b64_enc);
    const sig_b64 = try client_data.b64urlNoPad(alloc, der);
    defer alloc.free(sig_b64);

    const body_str = try std.fmt.allocPrint(alloc,
        "{{\"ceremonyId\":\"{s}\",\"credentialId\":\"{s}\",\"authenticatorData\":\"{s}\",\"clientDataJSON\":\"{s}\",\"signature\":\"{s}\"}}",
        .{ cid, cred_id_b64, auth_data_b64, cdj_b64_enc, sig_b64 },
    );
    defer alloc.free(body_str);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const col = blk: {
        const w = wenv.pool.acquireWriter();
        defer wenv.pool.releaseWriter();
        break :blk (try collections.get(a, w, "wausers7")).?;
    };
    var req = http.RequestCtx{ .method = .POST, .path = "/", .body = body_str, .allocator = a, .app = &wenv.app };
    var ac = AuthCtx{ .app = &wenv.app, .ctx = &req, .collection = col, .config = .null };

    var m = try WebAuthnMethod.create(alloc, std.testing.io, .{});
    const am = m.method();
    const res = try am.vtable.complete(am.ctx, &ac);
    switch (res) {
        .fail => |f| {
            try std.testing.expectEqual(@as(u16, 401), f.status);
            // Verify signCount was NOT updated (still 5). Re-check under a fresh writer
            // (the method has released its own by now).
            const w = wenv.pool.acquireWriter();
            defer wenv.pool.releaseWriter();
            const cred_store = CredentialStore{ .conn = w };
            const after = (try cred_store.getByCredentialId(alloc, cred_id_b64)).?;
            defer {
                alloc.free(after.id);
                alloc.free(after.collection_ref);
                alloc.free(after.record_ref);
                alloc.free(after.credential_id);
                alloc.free(after.public_key);
                alloc.free(after.aaguid);
            }
            try std.testing.expectEqual(@as(u32, 5), after.sign_count);
        },
        .record => return error.TestFailed,
    }
}

// ---------------------------------------------------------------------------
// Helper: build a minimal EC2 COSE_Key CBOR bytes (heap-allocated slice).
// ---------------------------------------------------------------------------

fn buildEc2CoseKeyBytes(alloc: std.mem.Allocator, x: [32]u8, y: [32]u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    // map(5)
    try buf.append(alloc, 0xa5);
    // 1: 2 (kty=EC2)
    try buf.append(alloc, 0x01);
    try buf.append(alloc, 0x02);
    // 3: -7 (alg=ES256) → CBOR negative int: 0x26 (= 0x20 | 6 = (-1)-(-7))
    try buf.append(alloc, 0x03);
    try buf.append(alloc, 0x26);
    // -1: 1 (crv=P-256) → 0x20 (= 0x20 | 0), 0x01
    try buf.append(alloc, 0x20);
    try buf.append(alloc, 0x01);
    // -2: bstr(32, x) → 0x21 (= neg(-2): 0x20|1), 0x58, 0x20, x...
    try buf.append(alloc, 0x21);
    try buf.append(alloc, 0x58);
    try buf.append(alloc, 0x20);
    try buf.appendSlice(alloc, &x);
    // -3: bstr(32, y) → 0x22 (neg(-3): 0x20|2), 0x58, 0x20, y...
    try buf.append(alloc, 0x22);
    try buf.append(alloc, 0x58);
    try buf.append(alloc, 0x20);
    try buf.appendSlice(alloc, &y);
    return buf.toOwnedSlice(alloc);
}
