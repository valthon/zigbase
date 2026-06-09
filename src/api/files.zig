const std = @import("std");
const http = @import("../http.zig");
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const collections = @import("../collections.zig");
const records = @import("../records.zig");
const rules = @import("../rules.zig");
const request = @import("../request.zig");
const auth = @import("../auth.zig");
const jwt = @import("../jwt.zig");
const crypto = @import("../crypto.zig");
const auth_api = @import("auth.zig");
const params_mod = @import("../query/params.zig");
const ApiError = @import("error.zig").ApiError;

fn recordReferencesFile(col: schema.Collection, rec: std.json.Value, name: []const u8) bool {
    if (rec != .object) return false;
    for (col.fields) |f| {
        if (f.fieldType() != .file) continue;
        const v = rec.object.get(f.name) orelse continue;
        switch (v) {
            .string => |s| if (std.mem.eql(u8, s, name)) return true,
            .array => |arr| for (arr.items) |it| {
                if (it == .string and std.mem.eql(u8, it.string, name)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn fileIdentity(ctx: *http.RequestCtx, conn: *db.Db) ?auth.Verified {
    const app = ctx.app.?;
    const qp = params_mod.parse(ctx.allocator, ctx.query) catch null;
    if (qp) |p| if (p.get("token")) |tok| {
        if (auth.verifyTokenOfTypes(ctx.allocator, app, conn, tok, &.{ .auth, .file })) |v| return v;
    };
    if (auth.authenticate(app.io, ctx.allocator, app, ctx, conn) catch null) |aa|
        return .{ .record = aa.record, .collection = aa.collection, .is_superuser = aa.is_superuser, .exp = 0 };
    return null;
}

/// GET /api/files/:col/:rec/:name
pub fn serve(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    var r = try app.pool.openReader();
    defer r.close();
    const col_name = ctx.param("col") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rid = ctx.param("rec") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const name = ctx.param("name") orelse return ApiError.notFound().toResponse(ctx.allocator);

    const col = (try collections.get(ctx.allocator, &r, col_name)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rec = (try records.get(ctx.allocator, &r, col, rid)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    if (!recordReferencesFile(col, rec, name)) return ApiError.notFound().toResponse(ctx.allocator);

    const ident = fileIdentity(ctx, &r);
    const rctx = request.RequestContext{
        .auth = if (ident) |i| i.record else null,
        .is_superuser = if (ident) |i| i.is_superuser else false,
        .method = "GET",
    };
    switch (rules.decide(col.viewRule, &rctx)) {
        .deny_locked => return ApiError.notFound().toResponse(ctx.allocator),
        .allow => {},
        .check => if (!try rules.matches(ctx.allocator, &r, col, rid, col.viewRule.?, &rctx)) return ApiError.notFound().toResponse(ctx.allocator),
    }

    const storage = app.storage orelse return ApiError.internal().toResponse(ctx.allocator);
    const path = (try storage.localPath(ctx.allocator, col.name, rid, name)) orelse return ApiError.internal().toResponse(ctx.allocator);

    const qp = params_mod.parse(ctx.allocator, ctx.query) catch null;
    const is_download = if (qp) |p| (p.get("download") != null) else false;
    const disposition = try std.fmt.allocPrint(ctx.allocator, "{s}; filename=\"{s}\"", .{ if (is_download) "attachment" else "inline", name });
    const cache: []const u8 = if (col.viewRule != null and col.viewRule.?.len == 0) "public, max-age=3600" else "private";
    const headers = try ctx.allocator.dupe(http.Header, &.{
        .{ .name = "Referrer-Policy", .value = "no-referrer" },
        .{ .name = "Cache-Control", .value = cache },
        .{ .name = "Content-Disposition", .value = disposition },
    });
    return .{ .status = 200, .body = "", .file_path = path, .extra_headers = headers };
}

/// POST /api/files/token — authenticated; mints a short-lived file-access token.
pub fn token(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const authed = (try auth.authenticate(app.io, ctx.allocator, app, ctx, w)) orelse
        return (ApiError{ .status = 401, .message = "Not authenticated." }).toResponse(ctx.allocator);
    const rid = authed.record.object.get("id").?.string;
    const table = if (authed.is_superuser) "_superusers" else authed.collection;
    const tk = (try auth_api.tokenKeyFor(ctx.allocator, w, table, rid)) orelse
        return (ApiError{ .status = 401, .message = "Not authenticated." }).toResponse(ctx.allocator);
    const now = try auth.nowUnixPub(w);
    const key = crypto.deriveKey(app.jwt_secret, tk);
    const claims = jwt.Claims{ .id = rid, .collection = authed.collection, .type = .file, .iat = now, .exp = now + app.file_token_ttl_s };
    const tok = try jwt.sign(ctx.allocator, claims, &key);
    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator, "token", .{ .string = tok });
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.allocator, std.json.Value{ .object = root }, .{}) };
}
