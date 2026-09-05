//! WebAuthn ceremonies scoped to a two-factor attempt and principal. Credentials
//! live separately from primary passkeys; no primary-login challenge is accepted.
const std = @import("std");
const http = @import("../../http.zig");
const db = @import("../../db.zig");
const schema = @import("../../schema.zig");
const store = @import("../two_factor_store.zig");
const ChallengeStore = @import("../challenge_store.zig").ChallengeStore;
const client_data = @import("client_data.zig");

pub const Verified = struct {
    id: []const u8,
    payload: []const u8,
    counter: u32,
};

fn field(value: std.json.Value, name: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidProof;
    const v = value.object.get(name) orelse return error.InvalidProof;
    return if (v == .string) v.string else error.InvalidProof;
}

fn decode(alloc: std.mem.Allocator, value: []const u8) ![]u8 {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const buf = try alloc.alloc(u8, decoder.calcSizeForSlice(value) catch return error.InvalidProof);
    errdefer alloc.free(buf);
    decoder.decode(buf, value) catch return error.InvalidProof;
    return buf;
}

fn domain(alloc: std.mem.Allocator, pending: []const u8, enrolling: bool) ![]const u8 {
    return std.fmt.allocPrint(alloc, "two-factor:webauthn:{s}:{s}", .{ if (enrolling) "register" else "assert", pending });
}

pub fn begin(ctx: *http.RequestCtx, conn: *db.Db, col: schema.Collection, principal: []const u8, pending: []const u8, enrolling: bool) !http.Response {
    const opts = col.options.auth.methods.webauthn orelse return error.WebAuthnNotConfigured;
    if (opts.rp_id.len == 0 or opts.origin.len == 0) return error.WebAuthnNotConfigured;
    const a = ctx.allocator.a;
    var challenge: [32]u8 = undefined;
    ctx.app.?.io.random(&challenge);
    const ceremony = try (ChallengeStore{ .conn = conn }).put(a, ctx.app.?.io, col.name, try domain(a, pending, enrolling), principal, &challenge, 300);
    const encoded = try client_data.b64urlNoPad(a, &challenge);
    if (enrolling) {
        return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(a, .{
            .ceremonyId = ceremony,
            .challenge = encoded,
            .rp = .{ .id = opts.rp_id, .name = opts.rp_name },
            .user = .{ .id = try client_data.b64urlNoPad(a, principal), .name = principal, .displayName = principal },
            .pubKeyCredParams = .{ .{ .type = "public-key", .alg = -7 }, .{ .type = "public-key", .alg = -8 } },
            .attestation = "none",
            .authenticatorSelection = .{ .userVerification = if (opts.require_uv) "required" else "preferred" },
            .timeout = 300000,
        }, .{}) };
    }
    var credentials: std.ArrayList(struct { type: []const u8 = "public-key", id: []const u8 }) = .empty;
    var st = try store.prepare(a, conn, "SELECT \"id\" FROM \"_twoFactorCredentials\" WHERE \"collectionRef\"=?1 AND \"recordRef\"=?2 AND \"kind\"='webauthn';");
    defer st.finalize();
    try st.bindText(1, col.name);
    try st.bindText(2, principal);
    while (try st.step()) try credentials.append(a, .{ .id = try a.dupe(u8, st.columnText(0)) });
    if (credentials.items.len == 0) return error.FactorNotEnrolled;
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(a, .{
        .ceremonyId = ceremony,
        .challenge = encoded,
        .rpId = opts.rp_id,
        .allowCredentials = credentials.items,
        .userVerification = if (opts.require_uv) "required" else "preferred",
        .timeout = 300000,
    }, .{}) };
}

pub fn verify(ctx: *http.RequestCtx, conn: *db.Db, col: schema.Collection, principal: []const u8, pending: []const u8, enrolling: bool, body: std.json.Value) !Verified {
    const a = ctx.allocator.a;
    const opts = col.options.auth.methods.webauthn orelse return error.WebAuthnNotConfigured;
    if (opts.rp_id.len == 0 or opts.origin.len == 0) return error.WebAuthnNotConfigured;
    const challenge = (try (ChallengeStore{ .conn = conn }).take(a, try field(body, "ceremonyId"), try domain(a, pending, enrolling))) orelse return error.InvalidCeremony;
    const client = try decode(a, try field(body, "clientDataJSON"));
    if (enrolling) {
        const attestation = try decode(a, try field(body, "attestationObject"));
        const result = @import("register.zig").verifyRegistration(a, opts.rp_id, opts.origin, challenge, client, attestation, opts.require_uv) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidProof,
        };
        return .{ .id = try client_data.b64urlNoPad(a, result.credential_id), .payload = try client_data.b64urlNoPad(a, result.cose_pubkey), .counter = result.sign_count };
    }
    const id = try field(body, "credentialId");
    const credential = (try store.get(a, conn, .{ .collection = col.name, .principal = principal, .kind = "webauthn", .id = id })) orelse return error.FactorNotEnrolled;
    const cose = try @import("cose.zig").parseCoseKey(try decode(a, credential.payload));
    const result = @import("authenticate.zig").verifyAssertion(a, opts.rp_id, opts.origin, challenge, cose.key, @intCast(credential.counter), client, try decode(a, try field(body, "authenticatorData")), try decode(a, try field(body, "signature")), opts.require_uv) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidProof,
    };
    if (result.clone_suspected) return error.CloneSuspected;
    return .{ .id = id, .payload = credential.payload, .counter = result.new_sign_count };
}
