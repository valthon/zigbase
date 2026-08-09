const std = @import("std");
const RequestArena = @import("../request_arena.zig").RequestArena;
const http = @import("../http.zig");
const app_mod = @import("../app.zig");
const build_options = @import("build_options");
const ApiError = @import("error.zig").ApiError;

/// The meta-contract version. Bump ONLY when a field is removed or changes meaning;
/// adding a field is backwards-compatible and does not bump it.
pub const api_version: u32 = 1;

/// GET /api/meta -> 200, the capability probe.
///
/// PUBLIC and UNAUTHENTICATED, and deliberately so: almost every field here is a fact
/// an anonymous client can already establish by probing. Each capability bool corresponds
/// to a route group that already answers 404 or 200 without a token; `collectionsFrozen`
/// is already readable from the 403 that the runtime DDL endpoints return (`api/collections.zig`
/// `rejectIfFrozen`); `maxUploadSize` is already discoverable by uploading. This endpoint saves
/// an agent from probing — it does not disclose anything probing would not.
///
/// `devMode` is the one deliberate exception: it gates no route, so it is not
/// independently probe-discoverable. It stays because a dev build shouldn't be
/// public-facing in the first place, so advertising it is judged acceptable and
/// useful (agents/tooling can flag "prod URL running a dev build" at a glance).
///
/// NEVER add a config value, filesystem path, hostname, connection string, or credential
/// here. Same rule as `api/health.zig`.
///
/// This is NOT `/api/health` (a liveness probe hit on a tight interval, kept small) and NOT
/// `/api/state` (the per-subject, DB-backed feature-flag projection). It touches no
/// database and is constant for the process lifetime.
pub fn handle(ctx: *http.RequestCtx) !http.Response {
    const app = ctx.app orelse return ApiError.internal().toResponse(ctx.allocator.a);
    const g = app.gates;
    const body = try std.json.Stringify.valueAlloc(ctx.allocator.a, .{
        .zigbase = build_options.version,
        .commit = build_options.commit,
        .api = api_version,
        .capabilities = .{
            .admin = g.admin,
            .analytics = g.analytics,
            .collectionsFrozen = app.collections_frozen,
            .devMode = build_options.dev_mode,
            .magicLink = g.magic_link,
            .mailUnsubscribe = g.mail_unsubscribe,
            .mailWebhook = g.mail_webhook,
            .oauth2 = g.oauth2,
            .postgres = build_options.postgres,
            .s3 = build_options.s3,
            .senders = g.senders,
            .tenancy = g.tenancy,
            .vector = build_options.vector,
            .webauthn = g.webauthn,
        },
        .endpoints = .{
            .health = "/api/health",
            .state = app.features_public_route,
            .realtimeSse = "/api/realtime/sse",
        },
        .limits = .{ .maxUploadSize = app.max_upload_size },
    }, .{});
    return .{ .status = 200, .body = body };
}

// `handle` allocates exactly ONE buffer (the response body) and returns it — not a
// graph of interlinked allocations — so it does not meet the contract-4 bar for
// running under an arena. These tests therefore use `RequestArena.forTest`, keeping
// `std.testing.allocator`'s leak detection live: an arena would free the body at
// deinit and make a leaking handler indistinguishable from a correct one.
test "meta reports the default gates, the frozen flag, and the state mount" {
    const a = std.testing.allocator;
    var app = app_mod.App{ .allocator = a, .io = std.testing.io, .pool = undefined };
    var ctx = http.RequestCtx{
        .method = .GET,
        .path = "/api/meta",
        .allocator = RequestArena.forTest(a),
        .app = &app,
    };
    const resp = try handle(&ctx);
    defer a.free(resp.body);
    try std.testing.expectEqual(@as(u16, 200), resp.status);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, resp.body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(build_options.version, root.get("zigbase").?.string);
    try std.testing.expectEqual(@as(i64, api_version), root.get("api").?.integer);
    const caps = root.get("capabilities").?.object;
    try std.testing.expectEqual(true, caps.get("admin").?.bool);
    try std.testing.expectEqual(false, caps.get("collectionsFrozen").?.bool);
    try std.testing.expectEqualStrings("/api/state", root.get("endpoints").?.object.get("state").?.string);
    try std.testing.expectEqual(@as(i64, 50 << 20), root.get("limits").?.object.get("maxUploadSize").?.integer);
}

test "meta tracks collections_frozen and a disabled/remapped state route" {
    const a = std.testing.allocator;
    var app = app_mod.App{ .allocator = a, .io = std.testing.io, .pool = undefined };
    app.collections_frozen = true;
    app.features_public_route = null;
    app.gates = .{ .webauthn = false, .oauth2 = false };
    var ctx = http.RequestCtx{ .method = .GET, .path = "/api/meta", .allocator = RequestArena.forTest(a), .app = &app };

    const resp = try handle(&ctx);
    defer a.free(resp.body);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, resp.body, .{});
    defer parsed.deinit();
    const caps = parsed.value.object.get("capabilities").?.object;
    // The whole point of the endpoint: frozen mode is a boolean, not a 403 message.
    try std.testing.expectEqual(true, caps.get("collectionsFrozen").?.bool);
    try std.testing.expectEqual(false, caps.get("webauthn").?.bool);
    try std.testing.expectEqual(false, caps.get("oauth2").?.bool);
    try std.testing.expectEqual(std.json.Value.null, parsed.value.object.get("endpoints").?.object.get("state").?);
}

test "meta never leaks a config value, path, or secret" {
    // Guard rail: if someone adds a field carrying deployment config, this fails.
    const a = std.testing.allocator;
    var app = app_mod.App{ .allocator = a, .io = std.testing.io, .pool = undefined };
    app.jwt_secret = "super-secret-value";
    app.sentry_dsn = "https://public@sentry.example.com/1234-do-not-leak";
    app.public_url = "https://internal.example.com/srv/private";
    var ctx = http.RequestCtx{ .method = .GET, .path = "/api/meta", .allocator = RequestArena.forTest(a), .app = &app };
    const body = (try handle(&ctx)).body;
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "super-secret-value") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "sentry.example.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "internal.example.com") == null);
}
