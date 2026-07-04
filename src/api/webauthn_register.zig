/// WebAuthn registration endpoints — authenticated, separate from the generic auth-method contract.
///
/// Two routes (both require an authenticated user):
///   POST /api/collections/:col/auth/webauthn/register/begin
///   POST /api/collections/:col/auth/webauthn/register/finish
///
/// SECURITY REQUIREMENTS enforced here:
/// 1. Both endpoints require an authenticated session (auth=.authed in router).
/// 2. The credential's record_ref is ALWAYS the authenticated user's id — never body-supplied.
/// 3. Registration challenges use method key "webauthn_reg" so they cannot be replayed for login.
/// 4. `existsCredentialId` is checked before insert; duplicates return 409.
const std = @import("std");
const http = @import("../http.zig");
const db = @import("../db.zig");
const collections = @import("../collections.zig");
const schema = @import("../schema.zig");
const challenge_store = @import("../auth/challenge_store.zig");
const ChallengeStore = challenge_store.ChallengeStore;
const store_mod = @import("../auth/webauthn/store.zig");
const CredentialStore = store_mod.CredentialStore;
const register_mod = @import("../auth/webauthn/register.zig");
const client_data = @import("../auth/webauthn/client_data.zig");
const auth = @import("../auth.zig");
const ApiError = @import("error.zig").ApiError;

fn strField(obj: std.json.Value, key: []const u8) ?[]const u8 {
    const v = obj.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Decode a base64url (no-pad or with-pad) string into freshly-allocated bytes.
fn b64urlDecode(alloc: std.mem.Allocator, encoded: []const u8) ![]u8 {
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

/// Load the auth collection and verify webauthn is configured.
/// Returns the collection + opts, or a response on failure.
fn loadWebAuthnCollection(ctx: *http.RequestCtx, conn: *db.Db) !?struct { col: schema.Collection, opts: schema.WebAuthnMethodOpts } {
    const col_name = ctx.param("col") orelse return null;
    const col = (try collections.get(ctx.allocator, conn, col_name)) orelse return null;
    if (col.type != .auth) return null;
    const opts = col.options.auth.methods.webauthn orelse return null;
    return .{ .col = col, .opts = opts };
}

/// Authenticate the request and extract the authed user's id.
/// Returns null (with a response already returned to the caller) when unauthenticated.
fn requireAuthed(ctx: *http.RequestCtx, conn: *db.Db) !?[]const u8 {
    const app = ctx.app orelse return null;
    const authed = (try auth.authenticate(app.io, ctx.allocator, app, ctx, conn)) orelse return null;
    const id = authed.record.object.get("id") orelse return null;
    if (id != .string) return null;
    return id.string;
}

/// POST /api/collections/:col/auth/webauthn/register/begin
///
/// Requires: authenticated session (the authed user owns the new credential).
/// Returns: PublicKeyCredentialCreationOptions JSON {rp, user, challenge, pubKeyCredParams, ceremonyId}
pub fn begin(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app orelse return (ApiError.internal()).toResponse(ctx.allocator);

    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();

    // Authenticate the caller.
    const user_id = (try requireAuthed(ctx, w)) orelse
        return (ApiError{ .status = 401, .message = "Not authenticated." }).toResponse(ctx.allocator);

    // Load the collection + webauthn opts.
    const load = (try loadWebAuthnCollection(ctx, w)) orelse
        return (ApiError.notFound()).toResponse(ctx.allocator);
    const col = load.col;
    const wa_opts = load.opts;

    // Guard: reject mis-configured webauthn (empty rp_id or origin).
    if (wa_opts.rp_id.len == 0 or wa_opts.origin.len == 0) {
        return (ApiError{ .status = 500, .message = "WebAuthn is enabled but not configured (rp_id and origin are required)." }).toResponse(ctx.allocator);
    }

    // Generate 32 random challenge bytes.
    var challenge_raw: [32]u8 = undefined;
    app.io.random(&challenge_raw);

    // Store the challenge under method "webauthn_reg" (distinct from login "webauthn").
    // SECURITY: binding "webauthn_reg" prevents a registration challenge from being
    // submitted as a login ceremony.
    const cs = ChallengeStore{ .conn = w };
    const cid = try cs.put(
        ctx.allocator,
        app.io,
        col.name,
        "webauthn_reg",
        user_id,
        &challenge_raw,
        300,
    );

    // Base64url-encode the challenge for the client.
    const challenge_b64 = try client_data.b64urlNoPad(ctx.allocator, &challenge_raw);

    // Build PublicKeyCredentialCreationOptions JSON.
    // pubKeyCredParams: ES256 (-7) and EdDSA (-8).
    const body = try std.fmt.allocPrint(
        ctx.allocator,
        "{{\"rp\":{{\"id\":\"{s}\",\"name\":\"{s}\"}},\"user\":{{\"id\":\"{s}\",\"name\":\"{s}\",\"displayName\":\"{s}\"}},\"challenge\":\"{s}\",\"pubKeyCredParams\":[{{\"type\":\"public-key\",\"alg\":-7}},{{\"type\":\"public-key\",\"alg\":-8}}],\"ceremonyId\":\"{s}\",\"timeout\":300000}}",
        .{ wa_opts.rp_id, wa_opts.rp_name, user_id, user_id, user_id, challenge_b64, cid },
    );

    return http.Response{ .status = 200, .body = body };
}

/// POST /api/collections/:col/auth/webauthn/register/finish
///
/// Requires: authenticated session.
/// Body: { ceremonyId, attestationObject, clientDataJSON }
/// Returns: 204 No Content on success.
pub fn finish(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app orelse return (ApiError.internal()).toResponse(ctx.allocator);

    // Parse the request body (no DB / no lock needed).
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.body, .{}) catch {
        return (ApiError.badRequest("Invalid JSON body.")).toResponse(ctx.allocator);
    };
    if (parsed.value != .object) {
        return (ApiError.badRequest("Invalid JSON body.")).toResponse(ctx.allocator);
    }
    const body = parsed.value;

    const ceremony_id = strField(body, "ceremonyId") orelse {
        return (ApiError.badRequest("ceremonyId is required.")).toResponse(ctx.allocator);
    };
    const att_obj_b64 = strField(body, "attestationObject") orelse {
        return (ApiError.badRequest("attestationObject is required.")).toResponse(ctx.allocator);
    };
    const cdj_b64 = strField(body, "clientDataJSON") orelse {
        return (ApiError.badRequest("clientDataJSON is required.")).toResponse(ctx.allocator);
    };

    // ---- Phase 1 (writer held): authenticate, load collection, consume the challenge ----
    // SECURITY REQUIREMENT 2: credential's record_ref is the authed user id, never body-supplied.
    // The registration challenge is single-use and consumed HERE before the (expensive) verify.
    var col_name: []const u8 = undefined;
    var user_id: []const u8 = undefined;
    var wa_opts: schema.WebAuthnMethodOpts = undefined;
    var challenge_raw_bytes: []const u8 = undefined;
    {
        const w = app.pool.acquireWriter();
        defer app.pool.releaseWriter();

        user_id = (try requireAuthed(ctx, w)) orelse
            return (ApiError{ .status = 401, .message = "Not authenticated." }).toResponse(ctx.allocator);

        const load = (try loadWebAuthnCollection(ctx, w)) orelse
            return (ApiError.notFound()).toResponse(ctx.allocator);
        wa_opts = load.opts;
        col_name = load.col.name;

        // Guard: reject mis-configured webauthn (empty rp_id or origin).
        if (wa_opts.rp_id.len == 0 or wa_opts.origin.len == 0) {
            return (ApiError{ .status = 500, .message = "WebAuthn is enabled but not configured (rp_id and origin are required)." }).toResponse(ctx.allocator);
        }

        // Atomically take (consume) the registration challenge.
        // SECURITY: take() filters by method, so a "webauthn" login challenge cannot be consumed
        // by this registration take() that passes "webauthn_reg", and vice versa.
        const cs = ChallengeStore{ .conn = w };
        challenge_raw_bytes = (try cs.take(ctx.allocator, ceremony_id, "webauthn_reg")) orelse {
            return (ApiError{ .status = 400, .message = "Invalid or expired ceremony." }).toResponse(ctx.allocator);
        };
    } // writer released — verifyRegistration below runs OFF the lock.

    // ---- Phase 2 (NO lock): decode inputs + verify the registration ceremony ----
    const att_obj_bytes = b64urlDecode(ctx.allocator, att_obj_b64) catch {
        return (ApiError.badRequest("Invalid attestationObject encoding.")).toResponse(ctx.allocator);
    };
    const cdj_bytes = b64urlDecode(ctx.allocator, cdj_b64) catch {
        return (ApiError.badRequest("Invalid clientDataJSON encoding.")).toResponse(ctx.allocator);
    };

    const reg_result = register_mod.verifyRegistration(
        ctx.allocator,
        wa_opts.rp_id,
        wa_opts.origin,
        challenge_raw_bytes,
        cdj_bytes,
        att_obj_bytes,
        wa_opts.require_uv,
    ) catch {
        return (ApiError{ .status = 400, .message = "Registration verification failed." }).toResponse(ctx.allocator);
    };

    // Base64url-encode the credential id, COSE public key, and AAGUID for storage.
    const cred_id_b64 = try client_data.b64urlNoPad(ctx.allocator, reg_result.credential_id);
    const cose_pubkey_b64 = try client_data.b64urlNoPad(ctx.allocator, reg_result.cose_pubkey);
    const aaguid_b64 = try client_data.b64urlNoPad(ctx.allocator, &reg_result.aaguid);

    // ---- Phase 3 (writer held): uniqueness check + insert (atomic) ----
    {
        const w = app.pool.acquireWriter();
        defer app.pool.releaseWriter();

        const cred_store = CredentialStore{ .conn = w };
        // SECURITY REQUIREMENT 3: check uniqueness BEFORE insert (insert also enforces UNIQUE).
        if (try cred_store.existsCredentialId(cred_id_b64)) {
            return (ApiError{ .status = 409, .message = "Credential already registered." }).toResponse(ctx.allocator);
        }

        // Insert the credential. record_ref = authed user id (never body-supplied).
        try cred_store.insert(
            ctx.allocator,
            app.io,
            col_name,
            user_id, // SECURITY: always the authenticated user, not from request body
            cred_id_b64,
            cose_pubkey_b64,
            reg_result.alg,
            reg_result.sign_count,
            aaguid_b64,
            "", // transports: not parsed from body in v1
        );
    }

    return http.Response{ .status = 204, .body = "" };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "webauthn_register begin: returns 200 with challenge + ceremonyId for authed user" {
    const api_auth = @import("auth.zig");
    const jwt = @import("../jwt.zig");
    const crypto = @import("../crypto.zig");

    var env = try api_auth.TestEnv.initWebAuthn("wrusers1");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try env.createUser(a, "wrusers1", "reg@x.io", "longenough");

    // Mint an auth token so the request is authenticated.
    // Use a scoped block so the writer is released before calling begin() —
    // begin() acquires the pool writer internally (non-reentrant mutex).
    const token = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const rid = (try api_auth.findByIdentity(a, w, (try collections.get(a, w, "wrusers1")).?, "reg@x.io")).?;
        const tk = (try api_auth.tokenKeyFor(a, w, "wrusers1", rid)).?;
        const key = crypto.deriveKey(env.app.jwt_secret, tk);
        const now_ts = try api_auth.nowUnix(w);
        break :blk try jwt.sign(a, .{
            .id = rid,
            .collection = "wrusers1",
            .type = .auth,
            .iat = now_ts,
            .exp = now_ts + 86400,
        }, &key);
    };

    const params = [_]http.Param{.{ .key = "col", .value = "wrusers1" }};
    var ctx = env.ctx(a, .POST, "{}", &params);
    ctx.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token});

    // Writer is released; begin() can now acquire it without deadlocking.
    const res = try begin(&ctx);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"challenge\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"ceremonyId\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"rp\":{") != null);
}

test "webauthn_register begin: unauthenticated returns 401" {
    const api_auth = @import("auth.zig");

    var env = try api_auth.TestEnv.initWebAuthn("wrusers2");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const params = [_]http.Param{.{ .key = "col", .value = "wrusers2" }};
    var ctx = env.ctx(a, .POST, "{}", &params);
    // No authorization header.

    const res = try begin(&ctx);
    try std.testing.expectEqual(@as(u16, 401), res.status);
}

test "webauthn_register finish: stores credential and returns 204" {
    const api_auth = @import("auth.zig");
    const jwt = @import("../jwt.zig");
    const crypto = @import("../crypto.zig");
    const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    const alloc = std.testing.allocator;

    var env = try api_auth.TestEnv.initWebAuthn("wrusers3");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    try env.createUser(a, "wrusers3", "fin@x.io", "longenough");

    // Build a real registration ceremony.
    const rp_id = "example.test";
    const origin = "https://example.test";

    const seed = [_]u8{0x33} ** 32;
    const kp = try Ecdsa.KeyPair.generateDeterministic(seed);
    const sec1 = kp.public_key.toUncompressedSec1();
    var x_bytes: [32]u8 = undefined;
    var y_bytes: [32]u8 = undefined;
    @memcpy(&x_bytes, sec1[1..33]);
    @memcpy(&y_bytes, sec1[33..65]);

    const cose_key_buf = try buildEc2CoseKeyBytes(a, x_bytes, y_bytes);

    // Build rpIdHash.
    var rp_id_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(rp_id, &rp_id_hash, .{});

    const cred_id_raw = [_]u8{ 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33 };
    const aaguid = [_]u8{0} ** 16;

    // Build authData with AT|UP|UV flags.
    const auth_data_buf = try buildAuthDataWithCred(a, rp_id_hash, 0x45, 0, aaguid, &cred_id_raw, cose_key_buf);

    // Build attestationObject.
    const att_obj_buf = try buildAttestationObj(a, auth_data_buf);

    // Scoped block: acquire writer for setup (mint JWT + store challenge), release BEFORE
    // calling finish() — finish() acquires the pool writer internally (non-reentrant mutex).
    const token, const cid, const rid = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const r = (try api_auth.findByIdentity(a, w, (try collections.get(a, w, "wrusers3")).?, "fin@x.io")).?;
        const tk = (try api_auth.tokenKeyFor(a, w, "wrusers3", r)).?;
        const key = crypto.deriveKey(env.app.jwt_secret, tk);
        const now_ts = try api_auth.nowUnix(w);
        const tkn = try jwt.sign(a, .{
            .id = r,
            .collection = "wrusers3",
            .type = .auth,
            .iat = now_ts,
            .exp = now_ts + 86400,
        }, &key);
        // Build challenge + store it with method "webauthn_reg".
        const challenge_raw = [_]u8{0x33} ** 32;
        const cs = ChallengeStore{ .conn = w };
        const c = try cs.put(a, std.testing.io, "wrusers3", "webauthn_reg", r, &challenge_raw, 300);
        break :blk .{ tkn, c, r };
    };

    // Build clientDataJSON now that cid is known (challenge bytes are fixed above).
    const challenge_raw = [_]u8{0x33} ** 32;
    const challenge_b64 = try client_data.b64urlNoPad(a, &challenge_raw);
    const cdj = try std.fmt.allocPrint(
        a,
        "{{\"type\":\"webauthn.create\",\"challenge\":\"{s}\",\"origin\":\"{s}\"}}",
        .{ challenge_b64, origin },
    );

    const att_obj_b64 = try client_data.b64urlNoPad(a, att_obj_buf);
    const cdj_b64 = try client_data.b64urlNoPad(a, cdj);

    const body_str = try std.fmt.allocPrint(
        a,
        "{{\"ceremonyId\":\"{s}\",\"attestationObject\":\"{s}\",\"clientDataJSON\":\"{s}\"}}",
        .{ cid, att_obj_b64, cdj_b64 },
    );

    const params = [_]http.Param{.{ .key = "col", .value = "wrusers3" }};
    var ctx = env.ctx(a, .POST, body_str, &params);
    ctx.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token});

    // Writer is released; finish() can now acquire it without deadlocking.
    const res = try finish(&ctx);
    try std.testing.expectEqual(@as(u16, 204), res.status);
    try std.testing.expectEqualStrings("", res.body);

    // Post-verify: re-acquire writer in a new scoped block to check stored credential.
    // Use alloc (testing allocator) so the explicit defer frees are valid.
    const cred_id_b64 = try client_data.b64urlNoPad(alloc, &cred_id_raw);
    defer alloc.free(cred_id_b64);
    {
        const w2 = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const cred_store = CredentialStore{ .conn = w2 };
        const cred = (try cred_store.getByCredentialId(alloc, cred_id_b64)).?;
        defer {
            alloc.free(cred.id);
            alloc.free(cred.collection_ref);
            alloc.free(cred.record_ref);
            alloc.free(cred.credential_id);
            alloc.free(cred.public_key);
            alloc.free(cred.aaguid);
        }
        // SECURITY: record_ref must be the authed user id, not anything from the body.
        try std.testing.expectEqualStrings(rid, cred.record_ref);
        try std.testing.expectEqualStrings("wrusers3", cred.collection_ref);
    }
}

test "webauthn_register begin: webauthn enabled but empty rp_id returns 500" {
    const api_auth = @import("auth.zig");
    const jwt = @import("../jwt.zig");
    const crypto = @import("../crypto.zig");
    const migrations = @import("../migrations.zig");

    // Build a TestEnv manually with a webauthn collection that has empty rp_id and origin.
    const env = try std.testing.allocator.create(api_auth.TestEnv);
    env.tmp = std.testing.tmpDir(.{});
    const dir = try env.tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/test.db", .{dir}, 0);
    defer std.testing.allocator.free(path);
    env.pool = try db.Pool.init(std.testing.allocator, std.testing.io, path);
    defer env.deinit();
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try migrations.run(w);
        var setup_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer setup_arena.deinit();
        const sa = setup_arena.allocator();
        _ = try collections.create(sa, std.testing.io, w, .{
            .id = "",
            .name = "wrusers_empty_rp",
            .type = .auth,
            .fields = &[_]schema.Field{},
            .listRule = "",
            .viewRule = "",
            .createRule = "",
            .updateRule = "",
            .deleteRule = "",
            // webauthn enabled but rp_id="" and origin="" (defaults) — mis-configured.
            .options = .{ .auth = .{ .methods = .{ .webauthn = .{} } } },
        });
    }
    env.app = .{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = &env.pool };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Create a user and mint a valid JWT so the request is authenticated.
    try env.createUser(a, "wrusers_empty_rp", "empty@x.io", "longenough");
    const token = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const rid = (try api_auth.findByIdentity(a, w, (try collections.get(a, w, "wrusers_empty_rp")).?, "empty@x.io")).?;
        const tk = (try api_auth.tokenKeyFor(a, w, "wrusers_empty_rp", rid)).?;
        const key = crypto.deriveKey(env.app.jwt_secret, tk);
        const now_ts = try api_auth.nowUnix(w);
        break :blk try jwt.sign(a, .{
            .id = rid,
            .collection = "wrusers_empty_rp",
            .type = .auth,
            .iat = now_ts,
            .exp = now_ts + 86400,
        }, &key);
    };
    // Writer released; begin() can now acquire it.

    const params = [_]http.Param{.{ .key = "col", .value = "wrusers_empty_rp" }};
    var ctx = env.ctx(a, .POST, "{}", &params);
    ctx.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token});

    const res = try begin(&ctx);
    try std.testing.expectEqual(@as(u16, 500), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "not configured") != null);
}

test "webauthn_register finish: duplicate credentialId returns 409" {
    const api_auth = @import("auth.zig");
    const jwt = @import("../jwt.zig");
    const crypto = @import("../crypto.zig");
    const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    const alloc = std.testing.allocator;

    var env = try api_auth.TestEnv.initWebAuthn("wrusers4");
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    try env.createUser(a, "wrusers4", "dup@x.io", "longenough");

    const rp_id = "example.test";
    const origin = "https://example.test";

    const seed = [_]u8{0x44} ** 32;
    const kp = try Ecdsa.KeyPair.generateDeterministic(seed);
    const sec1 = kp.public_key.toUncompressedSec1();
    var x_bytes: [32]u8 = undefined;
    var y_bytes: [32]u8 = undefined;
    @memcpy(&x_bytes, sec1[1..33]);
    @memcpy(&y_bytes, sec1[33..65]);
    const cose_key_buf = try buildEc2CoseKeyBytes(a, x_bytes, y_bytes);

    var rp_id_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(rp_id, &rp_id_hash, .{});

    const cred_id_raw = [_]u8{ 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44 };
    const aaguid = [_]u8{0} ** 16;
    const auth_data_buf = try buildAuthDataWithCred(a, rp_id_hash, 0x45, 0, aaguid, &cred_id_raw, cose_key_buf);
    const att_obj_buf = try buildAttestationObj(a, auth_data_buf);

    const cred_id_b64 = try client_data.b64urlNoPad(a, &cred_id_raw);

    // Scoped block: acquire writer for setup (mint JWT, pre-insert credential, store challenge),
    // release BEFORE calling finish() — finish() acquires the pool writer internally (non-reentrant mutex).
    const token, const cid = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const rid = (try api_auth.findByIdentity(a, w, (try collections.get(a, w, "wrusers4")).?, "dup@x.io")).?;
        const tk = (try api_auth.tokenKeyFor(a, w, "wrusers4", rid)).?;
        const key = crypto.deriveKey(env.app.jwt_secret, tk);
        const now_ts = try api_auth.nowUnix(w);
        const tkn = try jwt.sign(a, .{
            .id = rid,
            .collection = "wrusers4",
            .type = .auth,
            .iat = now_ts,
            .exp = now_ts + 86400,
        }, &key);
        // Pre-insert the credential to trigger the duplicate check.
        const cred_store = CredentialStore{ .conn = w };
        const cose_key_b64_stored = try client_data.b64urlNoPad(a, cose_key_buf);
        try cred_store.insert(a, std.testing.io, "wrusers4", rid, cred_id_b64, cose_key_b64_stored, -7, 0, "", "");
        // Now store a challenge for the duplicate registration attempt.
        const challenge_raw = [_]u8{0x44} ** 32;
        const cs = ChallengeStore{ .conn = w };
        const c = try cs.put(a, std.testing.io, "wrusers4", "webauthn_reg", rid, &challenge_raw, 300);
        break :blk .{ tkn, c };
    };

    const challenge_raw = [_]u8{0x44} ** 32;
    const challenge_b64 = try client_data.b64urlNoPad(a, &challenge_raw);
    const cdj = try std.fmt.allocPrint(
        a,
        "{{\"type\":\"webauthn.create\",\"challenge\":\"{s}\",\"origin\":\"{s}\"}}",
        .{ challenge_b64, origin },
    );
    const att_obj_b64 = try client_data.b64urlNoPad(a, att_obj_buf);
    const cdj_b64 = try client_data.b64urlNoPad(a, cdj);

    const body_str = try std.fmt.allocPrint(
        a,
        "{{\"ceremonyId\":\"{s}\",\"attestationObject\":\"{s}\",\"clientDataJSON\":\"{s}\"}}",
        .{ cid, att_obj_b64, cdj_b64 },
    );

    const params = [_]http.Param{.{ .key = "col", .value = "wrusers4" }};
    var ctx = env.ctx(a, .POST, body_str, &params);
    ctx.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{token});

    // Writer is released; finish() can now acquire it without deadlocking.
    const res = try finish(&ctx);
    try std.testing.expectEqual(@as(u16, 409), res.status);
}

// ---------------------------------------------------------------------------
// Test helpers — CBOR builders (mirrored from register.zig test helpers).
// ---------------------------------------------------------------------------

fn buildEc2CoseKeyBytes(alloc: std.mem.Allocator, x: [32]u8, y: [32]u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.append(alloc, 0xa5); // map(5)
    try buf.append(alloc, 0x01);
    try buf.append(alloc, 0x02); // 1: 2 (kty=EC2)
    try buf.append(alloc, 0x03);
    try buf.append(alloc, 0x26); // 3: -7 (alg=ES256)
    try buf.append(alloc, 0x20);
    try buf.append(alloc, 0x01); // -1: 1 (crv=P-256)
    try buf.append(alloc, 0x21);
    try buf.append(alloc, 0x58);
    try buf.append(alloc, 0x20);
    try buf.appendSlice(alloc, &x); // -2: x
    try buf.append(alloc, 0x22);
    try buf.append(alloc, 0x58);
    try buf.append(alloc, 0x20);
    try buf.appendSlice(alloc, &y); // -3: y
    return buf.toOwnedSlice(alloc);
}

fn buildAuthDataWithCred(
    alloc: std.mem.Allocator,
    rp_id_hash: [32]u8,
    flags: u8,
    sign_count: u32,
    aaguid: [16]u8,
    cred_id: []const u8,
    cose_key: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, &rp_id_hash);
    try buf.append(alloc, flags);
    var sc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &sc_bytes, sign_count, .big);
    try buf.appendSlice(alloc, &sc_bytes);
    try buf.appendSlice(alloc, &aaguid);
    var cil_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &cil_bytes, @intCast(cred_id.len), .big);
    try buf.appendSlice(alloc, &cil_bytes);
    try buf.appendSlice(alloc, cred_id);
    try buf.appendSlice(alloc, cose_key);
    return buf.toOwnedSlice(alloc);
}

fn buildAttestationObj(alloc: std.mem.Allocator, auth_data: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.append(alloc, 0xa3); // map(3)
    // "fmt": "none"
    try buf.append(alloc, 0x63);
    try buf.appendSlice(alloc, "fmt");
    try buf.append(alloc, 0x64);
    try buf.appendSlice(alloc, "none");
    // "attStmt": {}
    try buf.append(alloc, 0x67);
    try buf.appendSlice(alloc, "attStmt");
    try buf.append(alloc, 0xa0);
    // "authData": bstr
    try buf.append(alloc, 0x68);
    try buf.appendSlice(alloc, "authData");
    const ad_len = auth_data.len;
    if (ad_len <= 23) {
        try buf.append(alloc, 0x40 | @as(u8, @intCast(ad_len)));
    } else if (ad_len <= 255) {
        try buf.append(alloc, 0x58);
        try buf.append(alloc, @intCast(ad_len));
    } else {
        try buf.append(alloc, 0x59);
        try buf.append(alloc, @intCast(ad_len >> 8));
        try buf.append(alloc, @intCast(ad_len & 0xff));
    }
    try buf.appendSlice(alloc, auth_data);
    return buf.toOwnedSlice(alloc);
}
