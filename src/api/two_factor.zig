const std = @import("std");
const http = @import("../http.zig");
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const collections = @import("../collections.zig");
const records = @import("../records.zig");
const auth = @import("auth.zig");
const core = @import("../auth/two_factor.zig");
const attempts = @import("../auth/two_factor_attempt.zig");
const store = @import("../auth/two_factor_store.zig");
const selection = @import("../auth/two_factor_config.zig");
const aead = @import("../aead.zig");
const ApiError = @import("error.zig").ApiError;
const events = @import("../events.zig");

const Pending = struct {
    principal: []const u8,
    generation: []const u8,
    primary: events.AuthMethod,
    purpose: attempts.Purpose,
};

fn json(ctx: *http.RequestCtx, value: anytype) !http.Response {
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.allocator.a, value, .{}), .extra_headers = &.{.{ .name = "Cache-Control", .value = "no-store" }} };
}

fn field(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const v = value.object.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn generation(ctx: *http.RequestCtx, conn: *db.Db, col: schema.Collection, id: []const u8) ![]const u8 {
    const ke = (try auth.tokenKeyAndEpochFor(ctx.allocator.a, conn, col.name, id)) orelse return error.NotFound;
    const value = try std.fmt.allocPrint(ctx.allocator.a, "{s}:{d}", .{ ke.token_key, ke.epoch });
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &hash, .{});
    return ctx.allocator.a.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}

fn binding(col: schema.Collection, pending: Pending) attempts.Binding {
    return .{ .collection = col.name, .principal = pending.principal, .generation = pending.generation, .purpose = pending.purpose };
}

fn recoveryDigest(code: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(code, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

fn replaceRecovery(ctx: *http.RequestCtx, conn: *db.Db, col: schema.Collection, id: []const u8) ![]const []const u8 {
    const a = ctx.allocator.a;
    var deletion = try store.prepare(a, conn, "DELETE FROM \"_twoFactorCredentials\" WHERE \"collectionRef\"=?1 AND \"recordRef\"=?2 AND \"kind\"='recovery';");
    defer deletion.finalize();
    try deletion.bindText(1, col.name);
    try deletion.bindText(2, id);
    _ = try deletion.step();
    const codes = try a.alloc([]const u8, 10);
    for (codes) |*code| {
        var random: [16]u8 = undefined;
        ctx.app.?.io.random(&random);
        code.* = try a.dupe(u8, &std.fmt.bytesToHex(random, .lower));
        const digest = recoveryDigest(code.*);
        try store.insert(a, conn, .{ .collection = col.name, .principal = id, .kind = "recovery", .id = &digest }, "", -1);
    }
    return codes;
}

fn createPending(ctx: *http.RequestCtx, conn: *db.Db, col: schema.Collection, id: []const u8, primary: events.AuthMethod, purpose: attempts.Purpose) ![]const u8 {
    try attempts.gc(ctx.allocator.a, conn);
    const pending = Pending{ .principal = id, .generation = try generation(ctx, conn, col, id), .primary = primary, .purpose = purpose };
    const payload = try std.json.Stringify.valueAlloc(ctx.allocator.a, pending, .{});
    return attempts.create(ctx.allocator.a, ctx.app.?.io, conn, binding(col, pending), payload);
}

fn loadPending(ctx: *http.RequestCtx, conn: *db.Db, col: schema.Collection, token: []const u8) !?Pending {
    const payload = (try attempts.inspect(ctx.allocator.a, conn, token, col.name)) orelse return null;
    const parsed = try std.json.parseFromSlice(Pending, ctx.allocator.a, payload, .{});
    const current = generation(ctx, conn, col, parsed.value.principal) catch |err| switch (err) {
        error.NotFound => return null,
        else => return err,
    };
    if (!std.mem.eql(u8, current, parsed.value.generation)) return null;
    return parsed.value;
}

/// Serialize factor mutations with principal revocation across database clients.
/// Preflight checks are not authority: recheck after acquiring the row lock and
/// before any credential/recovery writes. A false result has already rolled back.
fn beginVerifiedTransaction(ctx: *http.RequestCtx, conn: *db.Db, col: schema.Collection, pending: Pending) !bool {
    try conn.beginImmediate();
    errdefer conn.rollback() catch |err| std.log.err("two-factor rollback failed: {s}", .{@errorName(err)});
    const a = ctx.allocator.a;
    if (!try store.lockPrincipal(a, conn, col.name, pending.principal)) {
        try conn.rollback();
        return false;
    }
    if (!std.mem.eql(u8, try generation(ctx, conn, col, pending.principal), pending.generation) or
        (pending.purpose == .enrollment and try store.enrolled(a, conn, col.name, pending.principal)))
    {
        try conn.rollback();
        return false;
    }
    return true;
}

pub fn Subsystem(comptime selected: selection.Selection, comptime hook: ?core.PolicyHook) type {
    return struct {
        pub const runtime = core.Runtime{ .policy_hook = hook, .evaluate = evaluatePolicy, .begin = begin, .dispatch = handle };

        fn evaluatePolicy(arena: @import("../request_arena.zig").RequestArena, conn: *db.Db, rt: *const core.Runtime, col: schema.Collection, rec: std.json.Value, verified: bool) !@import("../auth/two_factor_policy.zig").Decision {
            const id = rec.object.get("id").?.string;
            var context = core.PolicyContext{ .arena = arena, .connection = conn, .collection = col.name, .record = rec };
            const required = if (rt.policy_hook) |policy_hook| try policy_hook(&context) else false;
            return @import("../auth/two_factor_policy.zig").evaluate(.{
                .mode = col.options.auth.two_factor,
                .application_required = required,
                .enrolled = try store.enrolled(arena.a, conn, col.name, id),
                .factor_verified = verified,
            });
        }

        fn begin(ctx: *http.RequestCtx, conn: *db.Db, col: schema.Collection, id: []const u8, primary: events.AuthMethod) !?http.Response {
            const rec = (try records.get(ctx.allocator.a, conn, col, id)) orelse return error.NotFound;
            const decision = try core.decision(ctx.allocator, conn, &runtime, col, rec, false);
            if (decision == .authenticated) return null;
            const purpose: attempts.Purpose = if (decision == .enrollment_required) .enrollment else .login;
            return try json(ctx, .{
                .status = @tagName(decision),
                .pendingToken = try createPending(ctx, conn, col, id, primary, purpose),
                .expiresIn = attempts.ttl_seconds,
                .factors = .{ .totp = selected.totp, .webauthn = selected.webauthn and primary != .webauthn },
                .recoveryCodes = selected.recovery_codes and purpose != .enrollment,
            });
        }

        fn handle(ctx: *http.RequestCtx) anyerror!http.Response {
            const app = ctx.app.?;
            const a = ctx.allocator.a;
            const body = std.json.parseFromSlice(std.json.Value, a, ctx.body, .{}) catch
                return ApiError.badRequest("Invalid JSON body.").toResponse(a);
            const action = ctx.param("action") orelse return ApiError.notFound().toResponse(a);
            const col_name = ctx.param("col") orelse return ApiError.notFound().toResponse(a);
            const w = app.pool.acquireWriter();
            defer app.pool.releaseWriter();
            const col = (try collections.get(a, w, col_name)) orelse return ApiError.notFound().toResponse(a);
            if (col.type != .auth or col.options.auth.two_factor == .disabled) return ApiError.notFound().toResponse(a);

            // Optional first enrollment begins from an authenticated account.
            // Already-enrolled users must complete a fresh factor challenge.
            if (std.mem.eql(u8, action, "enroll")) {
                const identity = (try @import("../auth.zig").authenticate(app.io, a, app, ctx, w)) orelse
                    return ApiError.withCode(401, .unauthorized, "Not authenticated.").toResponse(a);
                if (!std.mem.eql(u8, identity.collection, col.name)) return ApiError.forbidden().toResponse(a);
                const id = identity.record.object.get("id").?.string;
                if (try store.enrolled(a, w, col.name, id)) return ApiError.badRequest("Verify an existing factor before changing enrollment.").toResponse(a);
                return json(ctx, .{ .status = "enrollment_required", .pendingToken = try createPending(ctx, w, col, id, .custom, .enrollment), .expiresIn = attempts.ttl_seconds });
            }

            const token = field(body.value, "pendingToken") orelse return ApiError.badRequest("pendingToken is required.").toResponse(a);
            const pending = (try loadPending(ctx, w, col, token)) orelse return ApiError.withCode(401, .unauthorized, "Invalid or expired authentication attempt.").toResponse(a);
            if (!try store.allowAttempt(a, w, col.name, pending.principal))
                return ApiError.withCode(429, .too_many_requests, "Too many second-factor attempts. Try again later.").toResponse(a);

            const kind = field(body.value, "factor") orelse "totp";
            if (pending.purpose == .management and !std.mem.startsWith(u8, action, "enroll-")) {
                if (!try beginVerifiedTransaction(ctx, w, col, pending)) return ApiError.unauthorized().toResponse(a);
                errdefer w.rollback() catch |err| std.log.err("two-factor rollback failed: {s}", .{@errorName(err)});
                if ((try attempts.reserve(a, w, token, binding(col, pending))) == null or !try attempts.consume(a, w, token, binding(col, pending))) {
                    try w.rollback();
                    return ApiError.unauthorized().toResponse(a);
                }
                if (comptime selected.recovery_codes) {
                    if (std.mem.eql(u8, action, "replace-recovery")) {
                        const codes = try replaceRecovery(ctx, w, col, pending.principal);
                        _ = try auth.bumpTokenEpoch(a, w, col.name, pending.principal);
                        try w.commit();
                        return json(ctx, .{ .recoveryCodes = codes, .reauthenticate = true });
                    }
                }
                if (std.mem.eql(u8, action, "remove")) {
                    const id = field(body.value, "credentialId") orelse "default";
                    if (!try store.remove(a, w, .{ .collection = col.name, .principal = pending.principal, .kind = kind, .id = id })) {
                        try w.rollback();
                        return ApiError.notFound().toResponse(a);
                    }
                    const rec = (try records.get(a, w, col, pending.principal)) orelse return error.NotFound;
                    if (try core.decision(ctx.allocator, w, &runtime, col, rec, true) == .enrollment_required) {
                        try w.rollback();
                        return ApiError.badRequest("A required second factor cannot be removed without a replacement.").toResponse(a);
                    }
                    _ = try auth.bumpTokenEpoch(a, w, col.name, pending.principal);
                    try w.commit();
                    return .{ .status = 204, .body = "" };
                }
                try w.rollback();
                return ApiError.badRequest("Invalid factor-management action.").toResponse(a);
            }
            if (comptime selected.recovery_codes) {
                if (std.mem.eql(u8, kind, "recovery") and std.mem.eql(u8, action, "complete") and pending.purpose == .login) {
                    const code = field(body.value, "code") orelse return ApiError.badRequest("code is required.").toResponse(a);
                    if ((try attempts.reserve(a, w, token, binding(col, pending))) == null) return ApiError.unauthorized().toResponse(a);
                    const digest = recoveryDigest(code);
                    if (!try beginVerifiedTransaction(ctx, w, col, pending)) return ApiError.unauthorized().toResponse(a);
                    errdefer w.rollback() catch |err| std.log.err("two-factor rollback failed: {s}", .{@errorName(err)});
                    if (!try store.remove(a, w, .{ .collection = col.name, .principal = pending.principal, .kind = "recovery", .id = &digest })) {
                        try w.rollback();
                        return ApiError.withCode(401, .unauthorized, "Invalid recovery code.").toResponse(a);
                    }
                    return finish(ctx, w, col, pending, token);
                }
            }
            if (comptime selected.webauthn) {
                if (std.mem.eql(u8, kind, "webauthn")) {
                    if (pending.primary == .webauthn) return ApiError.badRequest("Choose a different second factor after passkey login.").toResponse(a);
                    const wa = @import("../auth/webauthn/second_factor.zig");
                    const enrolling = std.mem.startsWith(u8, action, "enroll-");
                    if (enrolling and pending.purpose != .management and (pending.purpose != .enrollment or try store.enrolled(a, w, col.name, pending.principal))) return ApiError.forbidden().toResponse(a);
                    if (!enrolling and pending.purpose != .login) return ApiError.forbidden().toResponse(a);
                    if (std.mem.eql(u8, action, "initiate") or std.mem.eql(u8, action, "enroll-begin")) {
                        return wa.begin(ctx, w, col, pending.principal, token, enrolling) catch |err| switch (err) {
                            error.WebAuthnNotConfigured, error.FactorNotEnrolled => return ApiError.badRequest("WebAuthn factor is unavailable or not configured.").toResponse(a),
                            else => return err,
                        };
                    }
                    if (!std.mem.eql(u8, action, "complete") and !std.mem.eql(u8, action, "enroll-complete")) return ApiError.badRequest("Invalid WebAuthn action.").toResponse(a);
                    if ((try attempts.reserve(a, w, token, binding(col, pending))) == null) return ApiError.unauthorized().toResponse(a);
                    const verified = wa.verify(ctx, w, col, pending.principal, token, enrolling, body.value) catch |err| switch (err) {
                        error.InvalidProof, error.InvalidCeremony, error.FactorNotEnrolled, error.CloneSuspected => return ApiError.withCode(401, .unauthorized, "Invalid WebAuthn proof.").toResponse(a),
                        error.WebAuthnNotConfigured => return ApiError.badRequest("WebAuthn factor is not configured.").toResponse(a),
                        else => return err,
                    };
                    const key = store.Key{ .collection = col.name, .principal = pending.principal, .kind = "webauthn", .id = verified.id };
                    if (!try beginVerifiedTransaction(ctx, w, col, pending)) return ApiError.unauthorized().toResponse(a);
                    errdefer w.rollback() catch |err| std.log.err("two-factor rollback failed: {s}", .{@errorName(err)});
                    if (enrolling) {
                        try store.insert(a, w, key, verified.payload, verified.counter);
                    } else if (verified.counter > 0 and !try store.advance(a, w, key, verified.counter)) {
                        try w.rollback();
                        return ApiError.unauthorized().toResponse(a);
                    }
                    return finish(ctx, w, col, pending, token);
                }
            }
            if (comptime selected.totp) {
                if (std.mem.eql(u8, kind, "totp")) {
                    const totp = @import("../auth/totp.zig");
                    const key = store.Key{ .collection = col.name, .principal = pending.principal, .kind = "totp" };
                    if (std.mem.eql(u8, action, "enroll-begin")) {
                        if (pending.purpose != .management and (pending.purpose != .enrollment or try store.enrolled(a, w, col.name, pending.principal)))
                            return ApiError.forbidden().toResponse(a);
                        var secret: [totp.secret_length]u8 = undefined;
                        app.io.random(&secret);
                        const envelope = try aead.sealV1(app.io, a, aead.deriveKey(app.jwt_secret, "zigbase-two-factor-totp-v1"), &secret);
                        const ceremony = try @import("../auth/challenge_store.zig").ChallengeStore.put(.{ .conn = w }, a, app.io, col.name, token, pending.principal, envelope, attempts.ttl_seconds);
                        const encoded = totp.encodeSecret(secret);
                        return json(ctx, .{ .ceremonyId = ceremony, .secret = encoded[0..], .algorithm = "SHA1", .digits = 6, .period = 30 });
                    }
                    const code = field(body.value, "code") orelse return ApiError.badRequest("code is required.").toResponse(a);
                    const reserved = (try attempts.reserve(a, w, token, binding(col, pending))) orelse
                        return ApiError.withCode(401, .unauthorized, "Authentication attempt exhausted.").toResponse(a);
                    _ = reserved;
                    var credential: store.Credential = undefined;
                    const enrolling = std.mem.eql(u8, action, "enroll-complete");
                    if (enrolling) {
                        if (pending.purpose != .management and (pending.purpose != .enrollment or try store.enrolled(a, w, col.name, pending.principal))) return ApiError.forbidden().toResponse(a);
                        const ceremony = field(body.value, "ceremonyId") orelse return ApiError.badRequest("ceremonyId is required.").toResponse(a);
                        const envelope = (try @import("../auth/challenge_store.zig").ChallengeStore.take(.{ .conn = w }, a, ceremony, token)) orelse
                            return ApiError.withCode(401, .unauthorized, "Invalid enrollment ceremony.").toResponse(a);
                        credential = .{ .payload = envelope, .counter = -1 };
                    } else {
                        if (!std.mem.eql(u8, action, "complete") or pending.purpose != .login) return ApiError.badRequest("Invalid authentication action.").toResponse(a);
                        credential = (try store.get(a, w, key)) orelse return ApiError.withCode(401, .unauthorized, "Factor not enrolled.").toResponse(a);
                    }
                    const secret = try aead.openV1(a, aead.deriveKey(app.jwt_secret, "zigbase-two-factor-totp-v1"), credential.payload);
                    const step = totp.verify(secret, code, try @import("../clock.zig").sqlNowUnix(w), credential.counter) orelse
                        return ApiError.withCode(401, .unauthorized, "Invalid second factor.").toResponse(a);
                    if (!try beginVerifiedTransaction(ctx, w, col, pending)) return ApiError.unauthorized().toResponse(a);
                    errdefer w.rollback() catch |err| std.log.err("two-factor rollback failed: {s}", .{@errorName(err)});
                    if (enrolling) {
                        if (pending.purpose == .management) _ = try store.remove(a, w, key);
                        try store.insert(a, w, key, credential.payload, step);
                    } else if (!try store.advance(a, w, key, step)) {
                        try w.rollback();
                        return ApiError.withCode(401, .unauthorized, "Second factor already used.").toResponse(a);
                    }
                    return finish(ctx, w, col, pending, token);
                }
            }
            return ApiError.badRequest("Unsupported factor.").toResponse(a);
        }

        /// Caller holds an open writer transaction containing factor verification.
        fn finish(ctx: *http.RequestCtx, w: *db.Db, col: schema.Collection, pending: Pending, token: []const u8) !http.Response {
            const a = ctx.allocator.a;
            if (!try attempts.consume(a, w, token, binding(col, pending))) {
                try w.rollback();
                return ApiError.withCode(401, .unauthorized, "Authentication attempt already used.").toResponse(a);
            }
            const rec = (try records.get(a, w, col, pending.principal)) orelse return error.NotFound;
            if (col.options.auth.require_verified and !auth.recordVerified(rec)) {
                try w.rollback();
                return ApiError.withCode(403, .email_not_verified, "Email not verified.").toResponse(a);
            }
            if (try auth.fireBeforeAuthSuccess(ctx, w, col.name, pending.principal, pending.primary, rec)) |response| {
                try w.rollback();
                return response;
            }
            ctx.two_factor_assurance = .{ .collection = col.name, .principal = pending.principal };
            defer ctx.two_factor_assurance = null;
            const recovery_codes: ?[]const []const u8 = if (comptime selected.recovery_codes)
                (if (pending.purpose == .enrollment) try replaceRecovery(ctx, w, col, pending.principal) else null)
            else
                null;
            if (pending.purpose != .login) _ = try auth.bumpTokenEpoch(a, w, col.name, pending.principal);
            const management = try createPending(ctx, w, col, pending.principal, pending.primary, .management);
            const issued = try auth.issueSessionNoEmit(ctx, w, col.name, pending.principal);
            try w.commit();
            auth.emitAuth(ctx, col.name, rec, pending.primary);
            return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(a, .{ .status = "authenticated", .token = issued.token, .record = rec, .managementToken = management, .recoveryCodes = recovery_codes }, .{ .emit_null_optional_fields = false }), .cookies = try a.dupe(http.Cookie, &issued.cookies) };
        }
    };
}

pub fn dispatch(ctx: *http.RequestCtx) anyerror!http.Response {
    const rt = core.runtime(ctx.app.?) orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    var response = try rt.dispatch(ctx);
    response.extra_headers = &.{.{ .name = "Cache-Control", .value = "no-store" }};
    return response;
}

test "comptime two-factor subsystem selects routes and instantiates both implementations" {
    const Framework = @import("../framework.zig");
    const Disabled = Framework.App(.{});
    try std.testing.expect(!Disabled.route_gates.two_factor);
    try std.testing.expect(Disabled.Opts.two_factor == null);
    const Enabled = Framework.App(.{ .auth = .{ .two_factor = .{ .factors = .{ .totp, .webauthn } } } });
    try std.testing.expect(Enabled.route_gates.two_factor);
    try std.testing.expect(Enabled.Opts.two_factor != null);
    _ = Enabled.Opts.two_factor.?.dispatch;
}

test "required TOTP gates password, rejects pending as session, completes once and refreshes assurance" {
    const TestArena = @import("../request_arena.zig").RequestArena;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env = try auth.TestEnv.initAuth("users");
    defer env.deinit();
    const System = Subsystem(.{ .enabled = true, .totp = true }, null);
    env.app.two_factor = @ptrCast(&System.runtime);
    try env.createUser(a, "users", "alice@example.test", "longenough");
    const secret = "12345678901234567890";
    const id = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        var col = (try collections.get(a, w, "users")).?;
        col.options.auth.two_factor = .required;
        col.fields = &.{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }};
        _ = try collections.update(a, env.app.io, w, col.name, col);
        const id = (try auth.findByIdentity(a, w, col, "alice@example.test")).?;
        const encrypted = try aead.sealV1(env.app.io, a, aead.deriveKey(env.app.jwt_secret, "zigbase-two-factor-totp-v1"), secret);
        try store.insert(a, w, .{ .collection = "users", .principal = id, .kind = "totp" }, encrypted, -1);
        break :blk id;
    };
    const params = [_]http.Param{.{ .key = "col", .value = "users" }};
    var login = env.ctx(TestArena.from(&arena), .POST, "{\"identity\":\"alice@example.test\",\"password\":\"longenough\"}", &params);
    const first = try auth.authWithPassword(&login);
    try std.testing.expectEqual(@as(u16, 200), first.status);
    try std.testing.expectEqual(@as(usize, 0), first.cookies.len);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, first.body, .{});
    try std.testing.expectEqualStrings("factor_required", field(parsed.value, "status").?);
    try std.testing.expectEqual(null, field(parsed.value, "token"));
    const token = field(parsed.value, "pendingToken").?;
    const code = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try std.testing.expect(@import("../auth.zig").verifyToken(a, &env.app, w, token) == null);
        try std.testing.expectError(error.SecondFactorRequired, auth.issueSession(&login, w, "users", id, .custom));
        break :blk @import("../auth/totp.zig").code(secret, @intCast(@divFloor(try @import("../clock.zig").sqlNowUnix(w), 30)));
    };
    const completion_params = [_]http.Param{ .{ .key = "col", .value = "users" }, .{ .key = "action", .value = "complete" } };
    const body = try std.json.Stringify.valueAlloc(a, .{ .pendingToken = token, .factor = "totp", .code = code[0..] }, .{});
    var completion = env.ctx(TestArena.from(&arena), .POST, body, &completion_params);
    const Veto = struct {
        fn before(cx: *@import("../ctx.zig").Ctx, _: *events.AuthSuccessEvent) anyerror!void {
            return cx.fail(451, "factor completion vetoed");
        }
    };
    var dispatcher = events.Dispatch{ .before_auth_success = Veto.before };
    env.app.dispatch = &dispatcher;
    const denied = try dispatch(&completion);
    try std.testing.expectEqual(@as(u16, 451), denied.status);
    try std.testing.expectEqual(@as(usize, 0), denied.cookies.len);
    // The session transaction rolls back the counter and capability consumption,
    // while the verification budget remains spent. The same proof can now commit.
    env.app.dispatch = null;
    const response = try dispatch(&completion);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    const result = try std.json.parseFromSlice(std.json.Value, a, response.body, .{});
    const session_token = field(result.value, "token").?;
    const replay = try dispatch(&completion);
    try std.testing.expectEqual(@as(u16, 401), replay.status);
    var refresh = env.ctx(TestArena.from(&arena), .POST, "{}", &params);
    refresh.authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{session_token});
    const renewed = try auth.authRefresh(&refresh);
    try std.testing.expectEqual(@as(u16, 200), renewed.status);
    const renewal = try std.json.parseFromSlice(std.json.Value, a, renewed.body, .{});
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    const verified = @import("../auth.zig").verifyToken(a, &env.app, w, field(renewal.value, "token").?).?;
    try std.testing.expect(verified.two_factor);
    env.app.two_factor = null;
    try std.testing.expect(@import("../auth.zig").verifyToken(a, &env.app, w, session_token) == null);
    // Model a second process that already passed preflight before the first
    // process committed a factor mutation. Its loaded binding must be rejected
    // at the transactional gate, not accepted against the stored old attempt.
    const col = (try collections.get(a, w, "users")).?;
    const stale_token = try createPending(&completion, w, col, id, .password, .login);
    const stale = (try loadPending(&completion, w, col, stale_token)).?;
    _ = try auth.bumpTokenEpoch(a, w, "users", id);
    try std.testing.expect(!try beginVerifiedTransaction(&completion, w, col, stale));
    try std.testing.expect(!w.inTransaction());
    // Even without an epoch change, an initial enrollment cannot install a
    // second credential after another ceremony activated the first factor.
    const enrollment_token = try createPending(&completion, w, col, id, .password, .enrollment);
    const enrollment = (try loadPending(&completion, w, col, enrollment_token)).?;
    try std.testing.expect(!try beginVerifiedTransaction(&completion, w, col, enrollment));
    try std.testing.expect(!w.inTransaction());
    const fresh_token = try createPending(&completion, w, col, id, .password, .login);
    const fresh = (try loadPending(&completion, w, col, fresh_token)).?;
    try std.testing.expect(try beginVerifiedTransaction(&completion, w, col, fresh));
    try w.rollback();
}
