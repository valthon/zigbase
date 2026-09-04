const std = @import("std");
const zigbase = @import("zigbase");

fn headSuccess(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    _ = ctx;
    return .{ .status = 200, .body = "custom-head-representation", .content_type = "text/plain" };
}

fn headError(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    _ = ctx;
    return error.DeliberateHeadFailure;
}

fn noContent(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    return .{
        .status = 204,
        .body = "",
        .extra_headers = try ctx.arena.a.dupe(zigbase.http.Header, &.{
            .{ .name = "Content-Length", .value = "99" },
            .{ .name = "Transfer-Encoding", .value = "chunked" },
            .{ .name = "Date", .value = "Thu, 01 Jan 1970 00:00:00 GMT" },
        }),
    };
}

fn notModified(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    return .{
        .status = 304,
        .body = "wrong",
        .extra_headers = try ctx.arena.a.dupe(zigbase.http.Header, &.{
            .{ .name = "Content-Length", .value = "9" },
            .{ .name = "Transfer-Encoding", .value = "chunked" },
        }),
    };
}

fn resetContent(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    return .{
        .status = 205,
        .body = "wrong",
        .extra_headers = try ctx.arena.a.dupe(zigbase.http.Header, &.{
            .{ .name = "Content-Length", .value = "99" },
            .{ .name = "Transfer-Encoding", .value = "chunked" },
        }),
    };
}

fn wrongFraming(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    return .{
        .status = 200,
        .body = "framed",
        .content_type = "text/plain",
        .extra_headers = try ctx.arena.a.dupe(zigbase.http.Header, &.{
            .{ .name = "Content-Length", .value = "99" },
            .{ .name = "content-length", .value = "bogus" },
            .{ .name = "Transfer-Encoding", .value = "chunked" },
            .{ .name = "Trailer", .value = "X-Checksum" },
        }),
    };
}

fn earlyHints(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    _ = ctx;
    return .{ .status = 103, .body = "wrong" };
}

fn unnamedInformational(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    _ = ctx;
    return .{ .status = 199, .body = "wrong" };
}

fn unsupportedStatus(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    _ = ctx;
    return .{
        .status = 799,
        .body = "wrong",
        .content_type = "text/plain",
        .cookies = &.{.{ .name = "invalid-status", .value = "kept", .secure = false }},
    };
}

fn onError(ev: *zigbase.events.ErrorEvent) void {
    if (ev.err == error.InvalidResponseStatus)
        std.log.warn("fixture observed InvalidResponseStatus: {s}", .{ev.message});
}

fn ownedHeadFile(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    _ = ctx;
    return .{
        .status = 200,
        .body = "",
        .content_type = "text/plain",
        .file = .{ .path = "fixtures/features-remapped/main.zig", .offset = 0, .len = 7 },
    };
}

fn missingOwnedFile(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    _ = ctx;
    return .{
        .status = 200,
        .body = "",
        .content_type = "text/plain",
        .file = .{ .path = "fixtures/features-remapped/does-not-exist", .len = 7 },
    };
}

fn reclaimedState(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    _ = ctx;
    return .{ .status = 200, .body = "consumer-state", .content_type = "text/plain" };
}

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .onError = onError,
        .features = .{ .public_route = "/public/features" },
        .routes = .{
            .{ .method = .GET, .path = "/api/state", .name = "consumerState", .handler = reclaimedState, .auth = .public },
            .{ .method = .HEAD, .path = "/api/state", .name = "consumerStateHead", .handler = reclaimedState, .auth = .public },
            .{ .method = .HEAD, .path = "/custom/head-success", .handler = headSuccess, .auth = .public },
            .{ .method = .HEAD, .path = "/custom/head-error", .handler = headError, .auth = .public },
            .{ .method = .HEAD, .path = "/custom/no-content", .name = "customNoContentHead", .handler = noContent, .auth = .public },
            .{ .method = .POST, .path = "/custom/no-content", .name = "customNoContentPost", .handler = noContent, .auth = .public },
            .{ .method = .HEAD, .path = "/custom/not-modified", .handler = notModified, .auth = .public },
            .{ .method = .POST, .path = "/custom/not-modified", .name = "customNotModifiedPost", .handler = notModified, .auth = .public },
            .{ .method = .HEAD, .path = "/custom/reset-content", .name = "customResetContentHead", .handler = resetContent, .auth = .public },
            .{ .method = .POST, .path = "/custom/reset-content", .name = "customResetContentPost", .handler = resetContent, .auth = .public },
            .{ .method = .GET, .path = "/custom/wrong-framing", .handler = wrongFraming, .auth = .public },
            .{ .method = .POST, .path = "/custom/wrong-framing", .name = "customWrongFramingPost", .handler = wrongFraming, .auth = .public },
            .{ .method = .GET, .path = "/custom/early-hints", .handler = earlyHints, .auth = .public },
            .{ .method = .HEAD, .path = "/custom/early-hints", .name = "customEarlyHintsHead", .handler = earlyHints, .auth = .public },
            .{ .method = .GET, .path = "/custom/informational-unnamed", .handler = unnamedInformational, .auth = .public },
            .{ .method = .GET, .path = "/custom/status-unsupported", .handler = unsupportedStatus, .auth = .public },
            .{ .method = .GET, .path = "/custom/status-unsupported/:tail", .name = "unsupportedStatusCaptured", .handler = unsupportedStatus, .auth = .public },
            .{ .method = .HEAD, .path = "/custom/owned-file", .handler = ownedHeadFile, .auth = .public },
            .{ .method = .GET, .path = "/custom/missing-owned-file", .handler = missingOwnedFile, .auth = .public },
            .{ .method = .HEAD, .path = "/custom/missing-owned-file", .name = "customMissingOwnedFileHead", .handler = missingOwnedFile, .auth = .public },
            .{ .method = .GET, .path = "/api/profile/me", .name = "profileMe", .handler = headSuccess, .auth = .{ .authed = "profiles", .allow_superuser = true } },
        },
        .collections = .{
            .profiles = .{
                .type = .auth,
                .fields = .{.{ .name = "name", .type = .text }},
            },
        },
    }).runCli(init);
}
