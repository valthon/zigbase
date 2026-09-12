//! Authenticated bounded upload sessions. Bearer credentials required;
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
    const ordinary = if (comptime @import("build_options").durable_resumable_uploads) switch (err) {
        error.PersistenceFailed => return ApiError.withCode(503, .internal, "Upload persistence unavailable; restart required.").toResponse(ctx.allocator.a),
        else => |other| other,
    } else err;
    return switch (ordinary) {
        error.NotFound => ApiError.notFound().toResponse(ctx.allocator.a),
        error.Conflict => ApiError.conflict("Upload state or offset conflicts; inspect status.").toResponse(ctx.allocator.a),
        error.LimitExceeded => ApiError.withCode(429, .too_many_requests, "Upload session or memory budget exhausted.").toResponse(ctx.allocator.a),
        error.InvalidLength => ApiError.badRequest("Upload metadata or length exceeds configured limits.").toResponse(ctx.allocator.a),
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Request-arena identity graph, freshly verified for EVERY operation. No
/// privilege, tenant role, or auth record is retained in the session store.
const Authenticated = struct { who: auth.Authed, binding: resumable.Binding };
fn identity(ctx: *http.RequestCtx) !?Authenticated {
    if (ctx.bearerToken() == null) return null;
    const app = ctx.app.?;
    var reader = try app.pool.acquireReader();
    const snapshot = if (comptime @import("build_options").durable_resumable_uploads) app.resumable_uploads.?.durable != null else false;
    defer release: {
        if (snapshot and reader.inTransaction()) reader.rollback() catch |err| {
            // Never return a stale authentication snapshot to the reader pool.
            std.log.warn("upload auth snapshot rollback failed: {s}; closing reader", .{@errorName(err)});
            reader.close();
            break :release;
        };
        app.pool.releaseReader(&reader);
    }
    if (snapshot) try reader.begin();
    const who = (try auth.authenticate(app.io, ctx.allocator.a, app, ctx, &reader)) orelse return null;
    var result = resumable.Binding{ .collection = who.collection, .principal = who.record.object.get("id").?.string };
    if (comptime @import("build_options").durable_resumable_uploads) if (snapshot) {
        // Same read snapshot as the credential verification above: a collection
        // replacement must not pair an old principal with a new collection ID.
        const col = (try collections.get(ctx.allocator.a, &reader, who.collection)) orelse return null;
        result.collection_id = col.id;
    };
    return .{ .who = who, .binding = result };
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
    const verified = (try identity(ctx)) orelse return ApiError.unauthorized().toResponse(ctx.allocator.a);
    const who = verified.who;
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
    const owner_binding = verified.binding;
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
    const value = store.begin(clock(ctx), owner_binding, .{ .collection = col.name, .collection_id = col.id, .record = rid, .field = input.field, .filename = input.filename, .mimetype = input.mimetype }, input.length) catch |err| return failure(ctx, err);
    return statusResponse(ctx, 201, value);
}

fn statusResponse(ctx: *http.RequestCtx, code: u16, value: resumable.Status) !http.Response {
    return .{ .status = code, .body = try std.json.Stringify.valueAlloc(ctx.allocator.a, .{ .id = @as([]const u8, &value.id), .offset = value.offset, .length = value.length, .expiresAt = value.expiresAt, .state = value.state, .durability = value.durability }, .{}) };
}

pub fn status(ctx: *http.RequestCtx) !http.Response {
    const store = ctx.app.?.resumable_uploads orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    const verified = (try identity(ctx)) orelse return ApiError.unauthorized().toResponse(ctx.allocator.a);
    const value = store.status(clock(ctx), ctx.param("upload") orelse "", verified.binding) catch |err| return failure(ctx, err);
    return statusResponse(ctx, 200, value);
}
pub fn append(ctx: *http.RequestCtx) !http.Response {
    const store = ctx.app.?.resumable_uploads orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    const verified = (try identity(ctx)) orelse return ApiError.unauthorized().toResponse(ctx.allocator.a);
    const offset = std.fmt.parseInt(usize, ctx.header("upload-offset") orelse "", 10) catch return ApiError.badRequest("Upload-Offset is required and must be an unsigned integer.").toResponse(ctx.allocator.a);
    store.append(clock(ctx), ctx.param("upload") orelse "", verified.binding, offset, ctx.body) catch |err| return failure(ctx, err);
    return .{ .status = 204, .body = "" };
}
pub fn abort(ctx: *http.RequestCtx) !http.Response {
    const store = ctx.app.?.resumable_uploads orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    const verified = (try identity(ctx)) orelse return ApiError.unauthorized().toResponse(ctx.allocator.a);
    store.abort(clock(ctx), ctx.param("upload") orelse "", verified.binding) catch |err| return failure(ctx, err);
    return .{ .status = 204, .body = "" };
}
pub fn commit(ctx: *http.RequestCtx) anyerror!http.Response {
    const store = ctx.app.?.resumable_uploads orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    const verified = (try identity(ctx)) orelse return ApiError.unauthorized().toResponse(ctx.allocator.a);
    const who = verified.who;
    const current_binding = verified.binding;
    const session = (store.commit(clock(ctx), ctx.param("upload") orelse "", current_binding) catch |err| return failure(ctx, err)) orelse return .{ .status = 204, .body = "" };
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
    const response = try @import("records.zig").updateResumable(&adapted, .{ .collection = who.collection, .principal = current_binding.principal, .target_collection_id = target.collection_id, .committed = &committed, .auth_collection_id = if (comptime @import("build_options").durable_resumable_uploads) current_binding.collection_id else {}, .durable_id = if (comptime @import("build_options").durable_resumable_uploads) (if (store.durable != null) &session.status.id else null) else {} });
    if (committed) return .{ .status = 204, .body = "" };
    return response;
}

test "durable auth binding uses the credential verification snapshot across collection replacement" {
    if (comptime !@import("build_options").durable_resumable_uploads) return error.SkipZigTest;
    const a = std.testing.allocator;
    const db = @import("../db.zig");
    const c = @import("../c.zig").c;
    const App = @import("../framework.zig").App(.{
        .files = .{ .resumable = .{ .durable = true } },
        .collections = .{ .users = .{ .type = .auth, .fields = .{} } },
    });
    var harness = try @import("../testing.zig").start(App, .{});
    defer harness.deinit();
    const user = try harness.createRecord("users", .{ .email = "snapshot@example.test", .password = "password123" });
    const rid = user.object.get("id").?.string;
    const bearer = try harness.mintSession("users", rid);
    var reader = try harness.app().pool.acquireReader();
    var reader_held = true;
    defer if (reader_held) harness.app().pool.releaseReader(&reader);
    const col = (try collections.get(a, &reader, "users")).?;
    defer col.deinit(a);
    const status_value = try harness.app().resumable_uploads.?.begin(@import("../clock.zig").nowUnix(std.testing.io), .{ .collection = "users", .principal = rid, .collection_id = col.id }, .{
        .collection = "posts",
        .collection_id = "postsidentity",
        .record = "record",
        .field = "file",
        .filename = "a.txt",
        .mimetype = "text/plain",
    }, 4);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/data.db", .{harness.data_dir}, 0);
    defer a.free(path);
    var other = try db.Db.open(path);
    defer other.close();
    const Probe = struct {
        other: *db.Db,
        fired: bool = false,
        failed: bool = false,
        fn callback(raw: ?*anyopaque, action: c_int, table: [*c]const u8, column: [*c]const u8, _: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (!self.fired and action == c.SQLITE_READ and table != null and column != null and std.mem.eql(u8, std.mem.span(table), "users") and std.mem.eql(u8, std.mem.span(column), "tokenKey")) {
                self.fired = true;
                // auth already read _collections; commit replacement before its
                // principal lookup and the later stable-binding lookup finish.
                self.other.exec("UPDATE _collections SET id='replacementauth' WHERE name='users';") catch {
                    self.failed = true;
                    return c.SQLITE_DENY;
                };
            }
            return c.SQLITE_OK;
        }
    };
    var probe = Probe{ .other = &other };
    const handle = db.sqliteHandle(&reader);
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_set_authorizer(handle, Probe.callback, &probe));
    defer std.debug.assert(c.sqlite3_set_authorizer(handle, null, null) == c.SQLITE_OK);
    harness.app().pool.releaseReader(&reader);
    reader_held = false;
    const url = try std.fmt.allocPrint(a, "/api/uploads/{s}", .{status_value.id});
    defer a.free(url);
    const first = try harness.request(.GET, url, .{ .auth = bearer });
    try std.testing.expect(probe.fired);
    try std.testing.expect(!probe.failed);
    // This request linearized before replacement. A mixed-incarnation binding
    // would instead return 404, or could authorize a new-incarnation session.
    try std.testing.expectEqual(@as(u16, 200), first.status);
    const second = try harness.request(.GET, url, .{ .auth = bearer });
    try std.testing.expectEqual(@as(u16, 404), second.status);
}
