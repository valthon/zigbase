//! Authenticated, process-local upload sessions. Bearer credentials required;
//! cookie credentials are not used. Session IDs never authorize on their own.
const std = @import("std");
const http = @import("../http.zig");
const auth = @import("../auth.zig");
const collections = @import("../collections.zig");
const records = @import("../records.zig");
const schema = @import("../schema.zig");
const policy = @import("../policy.zig");
const resumable = @import("../files/resumable.zig");
const ApiError = @import("error.zig").ApiError;

fn failure(ctx: *http.RequestCtx, err: resumable.Error) !http.Response {
    return switch (err) {
        error.NotFound => ApiError.notFound().toResponse(ctx.allocator.a),
        error.Conflict => ApiError.conflict("Upload state or offset conflicts; inspect status.").toResponse(ctx.allocator.a),
        error.LimitExceeded => ApiError.withCode(429, .too_many_requests, "Upload session or memory budget exhausted.").toResponse(ctx.allocator.a),
        error.InvalidLength => ApiError.badRequest("Upload metadata or length exceeds configured limits.").toResponse(ctx.allocator.a),
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Request-arena identity graph, freshly verified for EVERY operation. No
/// privilege, tenant role, or auth record is retained in the session store.
fn identity(ctx: *http.RequestCtx) !?auth.Authed {
    if (ctx.bearerToken() == null) return null;
    const app = ctx.app.?;
    var reader = try app.pool.acquireReader();
    defer app.pool.releaseReader(&reader);
    return auth.authenticate(app.io, ctx.allocator.a, app, ctx, &reader);
}
fn binding(who: auth.Authed) resumable.Binding {
    return .{ .collection = who.collection, .principal = who.record.object.get("id").?.string };
}
fn clock(ctx: *http.RequestCtx) i64 {
    return @import("../clock.zig").nowUnix(ctx.app.?.io);
}
fn bad(ctx: *http.RequestCtx) !http.Response {
    return ApiError.badRequest("Expected filename, field, length and optional mimetype.").toResponse(ctx.allocator.a);
}

pub fn begin(ctx: *http.RequestCtx) !http.Response {
    const app = ctx.app.?;
    const store = app.resumable_uploads orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    const who = (try identity(ctx)) orelse return ApiError.unauthorized().toResponse(ctx.allocator.a);
    if (app.storage == null) return ApiError.withCode(501, .not_implemented, "File storage is unavailable.").toResponse(ctx.allocator.a);
    if (ctx.body.len > 4096) return bad(ctx);
    const Input = struct { field: []const u8, filename: []const u8, length: usize, mimetype: []const u8 = "application/octet-stream" };
    const input = std.json.parseFromSliceLeaky(Input, ctx.allocator.a, ctx.body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return bad(ctx),
    };
    if (input.field.len == 0 or input.filename.len == 0 or input.mimetype.len == 0) return bad(ctx);
    const name = ctx.param("col") orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    const rid = ctx.param("id") orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    var reader = try app.pool.acquireReader();
    defer app.pool.releaseReader(&reader);
    // Read current schema directly; never carry cached collection IDs over a
    // drop/recreate. Commit independently checks this stable ID again.
    const col = (try collections.get(ctx.allocator.a, &reader, name)) orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    var context = @import("../request.zig").RequestContext{ .auth = who.record, .is_superuser = who.is_superuser, .collection = who.collection, .method = "PATCH", .data = .{ .object = .empty }, .tenancy_enabled = app.tenancy.enabled, .role_ranking = app.role_ranking };
    @import("../tenancy/tenancy.zig").resolveRequest(ctx, &reader, app, who, &context);
    switch (policy.decide(col, .update, &context)) {
        .deny_locked => return ApiError.forbidden().toResponse(ctx.allocator.a),
        .allow => {},
        .check => if (!try policy.authorizes(ctx.allocator.a, &reader, col, .update, rid, &context)) return ApiError.notFound().toResponse(ctx.allocator.a),
    }
    // Do not expose file-field shape or record existence before the rule gate.
    const field = schema.fieldByName(col, input.field) orelse return bad(ctx);
    if (field.options != .file) return bad(ctx);
    _ = (try records.get(ctx.allocator.a, &reader, col, rid)) orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    // Fail before reserving the full payload. Commit still checks the current
    // limit, since schema constraints may change during the transfer.
    if (field.options.file.maxSize) |maximum| {
        if (input.length > maximum) return ApiError.withCode(413, .payload_too_large, "File too large.").toResponse(ctx.allocator.a);
    }
    const value = store.begin(app.io, clock(ctx), binding(who), .{ .collection = col.name, .collection_id = col.id, .record = rid, .field = input.field, .filename = input.filename, .mimetype = input.mimetype }, input.length) catch |err| return failure(ctx, err);
    return statusResponse(ctx, 201, value);
}

fn statusResponse(ctx: *http.RequestCtx, code: u16, value: resumable.Status) !http.Response {
    return .{ .status = code, .body = try std.json.Stringify.valueAlloc(ctx.allocator.a, .{ .id = @as([]const u8, &value.id), .offset = value.offset, .length = value.length, .expiresAt = value.expiresAt, .state = value.state, .durability = value.durability }, .{}) };
}

pub fn status(ctx: *http.RequestCtx) !http.Response {
    const store = ctx.app.?.resumable_uploads orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    const who = (try identity(ctx)) orelse return ApiError.unauthorized().toResponse(ctx.allocator.a);
    const value = store.status(clock(ctx), ctx.param("upload") orelse "", binding(who)) catch |err| return failure(ctx, err);
    return statusResponse(ctx, 200, value);
}
pub fn append(ctx: *http.RequestCtx) !http.Response {
    const store = ctx.app.?.resumable_uploads orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    const who = (try identity(ctx)) orelse return ApiError.unauthorized().toResponse(ctx.allocator.a);
    const offset = std.fmt.parseInt(usize, ctx.header("upload-offset") orelse "", 10) catch return ApiError.badRequest("Upload-Offset is required and must be an unsigned integer.").toResponse(ctx.allocator.a);
    store.append(clock(ctx), ctx.param("upload") orelse "", binding(who), offset, ctx.body) catch |err| return failure(ctx, err);
    return .{ .status = 204, .body = "" };
}
pub fn abort(ctx: *http.RequestCtx) !http.Response {
    const store = ctx.app.?.resumable_uploads orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    const who = (try identity(ctx)) orelse return ApiError.unauthorized().toResponse(ctx.allocator.a);
    store.abort(clock(ctx), ctx.param("upload") orelse "", binding(who)) catch |err| return failure(ctx, err);
    return .{ .status = 204, .body = "" };
}
pub fn commit(ctx: *http.RequestCtx) anyerror!http.Response {
    const store = ctx.app.?.resumable_uploads orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    const who = (try identity(ctx)) orelse return ApiError.unauthorized().toResponse(ctx.allocator.a);
    const session = (store.commit(clock(ctx), ctx.param("upload") orelse "", binding(who)) catch |err| return failure(ctx, err)) orelse return .{ .status = 204, .body = "" };
    var committed = false;
    defer store.finish(session, committed);
    const target = session.target;
    {
        var reader = try ctx.app.?.pool.acquireReader();
        defer ctx.app.?.pool.releaseReader(&reader);
        const current = (try collections.get(ctx.allocator.a, &reader, target.collection)) orelse return ApiError.conflict("Upload collection no longer exists.").toResponse(ctx.allocator.a);
        if (!std.mem.eql(u8, current.id, target.collection_id)) return ApiError.conflict("Upload collection no longer exists.").toResponse(ctx.allocator.a);
        const field = schema.fieldByName(current, target.field) orelse return ApiError.conflict("Upload file field no longer exists.").toResponse(ctx.allocator.a);
        if (field.options != .file) return ApiError.conflict("Upload file field no longer exists.").toResponse(ctx.allocator.a);
    }
    const file = http.UploadedFile{ .field = target.field, .filename = target.filename, .mimetype = target.mimetype, .bytes = session.bytes };
    var adapted = ctx.*;
    adapted.method = .PATCH;
    adapted.path = try std.fmt.allocPrint(ctx.allocator.a, "/api/collections/{s}/records/{s}", .{ target.collection, target.record });
    adapted.params = &.{ .{ .key = "col", .value = target.collection }, .{ .key = "id", .value = target.record } };
    adapted.body = "";
    adapted.query = "";
    adapted.form_fields = .{ .object = .empty };
    adapted.files = &.{file};
    adapted.content_type = "multipart/form-data";
    const response = try @import("records.zig").updateResumable(&adapted, .{ .collection = who.collection, .principal = binding(who).principal, .target_collection_id = target.collection_id, .committed = &committed });
    if (committed) return .{ .status = 204, .body = "" };
    return response;
}
