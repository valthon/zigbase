const std = @import("std");
const http = @import("../http.zig");
const app_mod = @import("../app.zig");
const db = @import("../db.zig");
const migrations = @import("../migrations.zig");
const collections = @import("../collections.zig");
const schema = @import("../schema.zig");
const records = @import("../records.zig");
const ApiError = @import("error.zig").ApiError;
const FieldError = @import("error.zig").FieldError;
const params_mod = @import("../query/params.zig");
const expand_mod = @import("../query/expand.zig");
const rules = @import("../rules.zig");
const request = @import("../request.zig");
const auth = @import("../auth.zig");
const realtime_ws = @import("../realtime/ws.zig");
const file_plan = @import("../files/plan.zig");
const events = @import("../events.zig");

/// Fire a record lifecycle event. `before_*` errors propagate (caller rolls back via the
/// normal records path); `after_*` errors route to the error backstop and are swallowed.
pub fn emitRecord(
    app: *app_mod.App,
    rctx: *const request.RequestContext,
    arena: std.mem.Allocator,
    conn: *db.Db,
    col_name: []const u8,
    value: *std.json.Value,
    phase: events.RecordPhase,
) !void {
    const d = app.dispatch orelse return;
    const handler = d.record orelse return;
    const is_before = switch (phase) {
        .before_create, .before_update, .before_delete => true,
        else => false,
    };
    // before-hooks observe the raw request body; skip non-object bodies so a hook's
    // `ev.record.object` access can't panic. records.* will reject non-objects with NotObject (400).
    if (is_before and value.* != .object) return;
    var ev = events.RecordEvent{
        .app = app,
        .ctx = rctx,
        .data = .{ .app = app, .conn = conn, .io = app.io },
        .arena = arena,
        .collection = col_name,
        .record = value,
        .phase = phase,
    };
    if (is_before) {
        try handler(&ev);
    } else {
        handler(&ev) catch |e| {
            var err_ev = events.ErrorEvent{ .app = app, .ctx = rctx, .err = e, .phase = .after_hook, .message = @errorName(e) };
            events.dispatchError(app, app.dispatch, &err_ev);
        };
    }
}

/// Fire file.afterUpload once per written file. After-style: never propagates.
fn emitFileUploads(app: *app_mod.App, rctx: *const request.RequestContext, col_name: []const u8, record_id: []const u8, writes: []const file_plan.FieldWrite) void {
    const d = app.dispatch orelse return;
    const h = d.on_file_upload orelse return;
    for (writes) |wr| {
        var ev = events.FileEvent{ .app = app, .ctx = rctx, .collection = col_name, .record_id = record_id, .filename = wr.filename };
        h(&ev);
    }
}

fn validationResponse(ctx: *http.RequestCtx) !http.Response {
    const verrs = records.last_errors orelse &[_]schema.ValidationError{};
    const fes = try ctx.allocator.alloc(FieldError, verrs.len);
    for (verrs, 0..) |e, i| fes[i] = .{ .field = e.field, .code = e.code, .message = e.message };
    return ApiError.validation(fes).toResponse(ctx.allocator);
}

fn resolveCollection(ctx: *http.RequestCtx, conn: *db.Db) !?schema.Collection {
    const name = ctx.param("col") orelse return null;
    return collections.get(ctx.allocator, conn, name);
}

fn jsonResponse(ctx: *http.RequestCtx, status: u16, v: std.json.Value) !http.Response {
    return .{ .status = status, .body = try std.json.Stringify.valueAlloc(ctx.allocator, v, .{}) };
}

/// Fills auth/superuser from the verified bearer/cookie token (anonymous if absent/invalid).
fn buildContext(ctx: *http.RequestCtx, conn: *db.Db, data: ?std.json.Value) request.RequestContext {
    if (ctx.app) |app| {
        if (auth.authenticate(app.io, ctx.allocator, app, ctx, conn) catch null) |a| {
            return .{ .auth = a.record, .is_superuser = a.is_superuser, .data = data, .method = @tagName(ctx.method) };
        }
    }
    return .{ .auth = null, .is_superuser = false, .data = data, .method = @tagName(ctx.method) };
}

fn forbidden(ctx: *http.RequestCtx) !http.Response {
    return (ApiError{ .status = 403, .message = "Forbidden." }).toResponse(ctx.allocator);
}

fn hookRejected(ctx: *http.RequestCtx) anyerror!http.Response {
    return ApiError.badRequest("Request rejected by a hook.").toResponse(ctx.allocator);
}

/// For auth collections, transform request data through auth.applyCreate/applyUpdate
/// (hash password, gen/rotate tokenKey, strip plaintext, force verified=false on create).
/// For non-auth collections, returns `data` unchanged. Maps a bad/short/missing password to BadPassword.
const AuthPrepError = error{BadPassword} || std.mem.Allocator.Error;

fn prepAuthData(ctx: *http.RequestCtx, col: schema.Collection, data: std.json.Value, comptime is_create: bool) AuthPrepError!std.json.Value {
    if (col.type != .auth) return data;
    const app = ctx.app.?;
    const min_len = col.options.auth.minPasswordLength;
    const out = if (is_create)
        auth.applyCreate(app.io, ctx.allocator, data, min_len)
    else
        auth.applyUpdate(app.io, ctx.allocator, data, min_len);
    return out catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadPassword, // PasswordTooShort and rare hashing/token failures -> bad request
    };
}

/// Write the planned uploads for `record_id` via Storage, then delete replaced/removed files.
/// On a write failure, deletes the files written so far and returns error.StorageFailed (caller
/// rolls back the record). No-op when no storage is configured (unit tests).
fn writeUploads(ctx: *http.RequestCtx, col: schema.Collection, record_id: []const u8, writes: []const file_plan.FieldWrite, deletes: []const []const u8) !void {
    const app = ctx.app.?;
    const storage = app.storage orelse return;
    var written: usize = 0;
    for (writes) |wr| {
        storage.put(app.io, col.name, record_id, wr.filename, wr.bytes) catch {
            for (writes[0..written]) |dw| storage.delete(app.io, col.name, record_id, dw.filename) catch {};
            return error.StorageFailed;
        };
        written += 1;
    }
    for (deletes) |d| storage.delete(app.io, col.name, record_id, d) catch {};
}

pub fn view(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    var r = try app.pool.acquireReader();
    defer app.pool.releaseReader(&r);
    const col = (try resolveCollection(ctx, &r)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rid = ctx.param("id") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rctx = buildContext(ctx, &r, null);
    switch (rules.decide(col.viewRule, &rctx)) {
        .deny_locked => return ApiError.notFound().toResponse(ctx.allocator),
        .allow => {},
        .check => if (!try rules.matches(ctx.allocator, &r, col, rid, col.viewRule.?, &rctx)) return ApiError.notFound().toResponse(ctx.allocator),
    }
    var rec = (try records.get(ctx.allocator, &r, col, rid)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const qp = try params_mod.parse(ctx.allocator, ctx.query);
    if (qp.get("expand")) |exp| if (exp.len > 0) try expand_mod.expand(ctx.allocator, &r, col, &rec, exp, 0, &rctx);
    return jsonResponse(ctx, 200, rec);
}

/// The one body-ingestion path for record create/update: parse the body
/// (multipart form fields or JSON), apply the multipart schema coercion, and
/// plan file fields. Centralized so no entry point can skip the coercion.
/// Returns `.resp` with the mapped 400/413 client error when the body or file
/// plan is invalid; OutOfMemory propagates.
const Prepared = union(enum) { plan: file_plan.AllPlan, resp: http.Response };

fn prepareRecordData(ctx: *http.RequestCtx, col: schema.Collection, existing: ?std.json.Value) anyerror!Prepared {
    const app = ctx.app.?;
    const raw = if (ctx.form_fields) |ff| ff else (std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.body, .{}) catch
        return .{ .resp = try ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator) }).value;
    // Multipart values are verbatim strings; make them behave like a JSON client.
    // JSON bodies (form_fields == null) are never coerced.
    const coerced = if (ctx.form_fields != null) try records.coerceFormFields(ctx.allocator, col, raw) else raw;
    const all = file_plan.planAllFileFields(app.io, ctx.allocator, col, coerced, ctx.files, existing) catch |e| switch (e) {
        error.TooLarge => return .{ .resp = try (ApiError{ .status = 413, .message = "File too large." }).toResponse(ctx.allocator) },
        error.TooMany => return .{ .resp = try ApiError.badRequest("Too many files for the field.").toResponse(ctx.allocator) },
        error.BadMimeType => return .{ .resp = try ApiError.badRequest("File type not allowed.").toResponse(ctx.allocator) },
        error.OutOfMemory => return e,
    };
    return .{ .plan = all };
}

pub fn create(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    // Resolve, plan files, and (for auth collections) hash the password BEFORE acquiring the
    // writer, so the expensive argon2 hash in prepAuthData does NOT run under the global writer
    // lock. The reader is closed before the writer is taken. M2 fix.
    const col, const all, const data2 = blk: {
        var r = try app.pool.acquireReader();
        defer app.pool.releaseReader(&r);
        const col = (try resolveCollection(ctx, &r)) orelse return ApiError.notFound().toResponse(ctx.allocator);
        const all = switch (try prepareRecordData(ctx, col, null)) {
            .plan => |p| p,
            .resp => |resp| return resp,
        };
        const data2 = prepAuthData(ctx, col, all.data, true) catch |e| switch (e) {
            error.BadPassword => return ApiError.badRequest("A password of the required length is required.").toResponse(ctx.allocator),
            error.OutOfMemory => return e,
        };
        break :blk .{ col, all, data2 };
    };
    const data = all.data;

    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const rctx = buildContext(ctx, w, data);
    // Gate FIRST: before-hooks must run only on already-authorized ops (matching delete).
    // decide() is pure (src/rules.zig) so computing it once and reusing is equivalent to inline.
    const decision = rules.decide(col.createRule, &rctx);
    if (decision == .deny_locked) return forbidden(ctx);
    // A before-hook may `put` NEW keys, which reallocs the map header captured in this
    // local; downstream MUST read the `_mut` binding (here and for rec_mut/ur_mut/ex_mut
    // below), not the original const — the binding is the grow-capturing reference.
    var data_mut = data2;
    emitRecord(app, &rctx, ctx.allocator, w, col.name, &data_mut, .before_create) catch return hookRejected(ctx);
    // KNOWN LIMITATION: a `.check` guard evaluates `@request.data.*` from rctx.data, which is
    // built pre-hook; a hook mutating a guard-referenced field is not seen by the WHERE clause.
    const rec = (switch (decision) {
        .deny_locked => unreachable,
        .allow => records.create(ctx.allocator, app.io, w, col, data_mut),
        .check => records.createGuarded(ctx.allocator, app.io, w, col, data_mut, try rules.compileGuard(ctx.allocator, w, col, col.createRule.?, &rctx)),
    }) catch |e| switch (e) {
        error.Validation => return validationResponse(ctx),
        error.NotObject => return ApiError.badRequest("Body must be a JSON object.").toResponse(ctx.allocator),
        error.Forbidden => return forbidden(ctx),
        else => return e,
    };
    const rid = rec.object.get("id").?.string;
    writeUploads(ctx, col, rid, all.writes, all.deletes) catch {
        _ = records.delete(ctx.allocator, w, col, rid) catch {};
        return ApiError.internal().toResponse(ctx.allocator);
    };
    emitFileUploads(app, &rctx, col.name, rid, all.writes);
    var rec_mut = rec;
    emitRecord(app, &rctx, ctx.allocator, w, col.name, &rec_mut, .after_create) catch {};
    realtime_ws.broadcast(app, col, .create, rid, rec_mut);
    return jsonResponse(ctx, 201, rec_mut);
}

pub fn update(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col = (try resolveCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rid = ctx.param("id") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const existing = (try records.get(ctx.allocator, w, col, rid)) orelse return ApiError.notFound().toResponse(ctx.allocator);

    const all = switch (try prepareRecordData(ctx, col, existing)) {
        .plan => |p| p,
        .resp => |resp| return resp,
    };
    const data = all.data;

    const data2 = prepAuthData(ctx, col, data, false) catch |e| switch (e) {
        error.BadPassword => return ApiError.badRequest("A password of the required length is required.").toResponse(ctx.allocator),
        error.OutOfMemory => return e,
    };
    const rctx = buildContext(ctx, w, data);
    // Gate FIRST: before-hooks must run only on already-authorized ops (matching delete).
    // decide() is pure (src/rules.zig) so computing it once and reusing is equivalent to inline.
    const decision = rules.decide(col.updateRule, &rctx);
    if (decision == .deny_locked) return forbidden(ctx);
    var data_mut = data2;
    emitRecord(app, &rctx, ctx.allocator, w, col.name, &data_mut, .before_update) catch return hookRejected(ctx);

    // Write new file bytes BEFORE the DB update so a storage failure can't leave dangling refs.
    if (ctx.app.?.storage) |storage| {
        var written: usize = 0;
        for (all.writes) |wr| {
            storage.put(app.io, col.name, rid, wr.filename, wr.bytes) catch {
                for (all.writes[0..written]) |dw| storage.delete(app.io, col.name, rid, dw.filename) catch {};
                return ApiError.internal().toResponse(ctx.allocator);
            };
            written += 1;
        }
    }

    // KNOWN LIMITATION: a `.check` guard evaluates `@request.data.*` from rctx.data, which is
    // built pre-hook; a hook mutating a guard-referenced field is not seen by the WHERE clause.
    const updated = (switch (decision) {
        .deny_locked => unreachable,
        .allow => records.update(ctx.allocator, w, col, rid, data_mut),
        .check => records.updateGuarded(ctx.allocator, w, col, rid, data_mut, try rules.compileGuard(ctx.allocator, w, col, col.updateRule.?, &rctx)),
    }) catch |e| switch (e) {
        error.Validation => return validationResponse(ctx),
        error.NotObject => return ApiError.badRequest("Body must be a JSON object.").toResponse(ctx.allocator),
        error.Forbidden => return ApiError.notFound().toResponse(ctx.allocator),
        else => return e,
    };
    const ur = updated orelse {
        if (ctx.app.?.storage) |storage| for (all.writes) |wr| storage.delete(app.io, col.name, rid, wr.filename) catch {};
        return ApiError.notFound().toResponse(ctx.allocator);
    };
    if (ctx.app.?.storage) |storage| for (all.deletes) |d| storage.delete(app.io, col.name, rid, d) catch {};
    emitFileUploads(app, &rctx, col.name, rid, all.writes);
    // Capture id BEFORE the after-hook so a hook that mutates/removes "id" can't panic the broadcast.
    const broadcast_id = ur.object.get("id").?.string;
    var ur_mut = ur;
    emitRecord(app, &rctx, ctx.allocator, w, col.name, &ur_mut, .after_update) catch {};
    realtime_ws.broadcast(app, col, .update, broadcast_id, ur_mut);
    return jsonResponse(ctx, 200, ur_mut);
}

pub fn delete(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col = (try resolveCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rid = ctx.param("id") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const existing = (try records.get(ctx.allocator, w, col, rid)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rctx = buildContext(ctx, w, null);
    switch (rules.decide(col.deleteRule, &rctx)) {
        .deny_locked => return forbidden(ctx),
        .allow => {},
        .check => if (!try rules.matches(ctx.allocator, w, col, rid, col.deleteRule.?, &rctx)) return ApiError.notFound().toResponse(ctx.allocator),
    }
    var ex_mut = existing;
    emitRecord(app, &rctx, ctx.allocator, w, col.name, &ex_mut, .before_delete) catch return hookRejected(ctx);
    if (!try records.delete(ctx.allocator, w, col, rid)) return ApiError.notFound().toResponse(ctx.allocator);
    if (col.type == .auth) {
        var st = try w.prepare("DELETE FROM \"_externalAuths\" WHERE \"collectionRef\"=?1 AND \"recordRef\"=?2;");
        defer st.finalize();
        try st.bindText(1, col.name);
        try st.bindText(2, rid);
        _ = try st.step();
    }
    if (app.storage) |storage| storage.deleteRecord(app.io, col.name, rid) catch {};
    emitRecord(app, &rctx, ctx.allocator, w, col.name, &ex_mut, .after_delete) catch {};
    // F4: pass the deleted row's snapshot so subscribers to an owner/expression-scoped collection
    // can re-authorize the delete event (the live row is gone). The snapshot rides in the published
    // frame under a private key and is stripped before any client receives the id-only delete frame.
    realtime_ws.broadcast(app, col, .delete, rid, ex_mut);
    return .{ .status = 204, .body = "" };
}

pub fn list(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    var r = try app.pool.acquireReader();
    defer app.pool.releaseReader(&r);
    const col = (try resolveCollection(ctx, &r)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rctx = buildContext(ctx, &r, null);
    var rule_expr: ?[]const u8 = null;
    switch (rules.decide(col.listRule, &rctx)) {
        .deny_locked => return forbidden(ctx),
        .allow => {},
        .check => rule_expr = col.listRule,
    }
    const qp = try params_mod.parse(ctx.allocator, ctx.query);
    const pg = app.pagination;

    // Mode selection + enable/disable gating (comptime-configured via App(.{ .pagination = ... })).
    const has_cursor = if (qp.get("cursor")) |c| c.len > 0 else false;
    const has_page_param = qp.get("page") != null or qp.get("perPage") != null;
    if (has_cursor and !pg.cursor_enabled)
        return ApiError.badRequest("Cursor pagination is disabled.").toResponse(ctx.allocator);
    if (has_page_param and !pg.offset_enabled)
        return ApiError.badRequest("Offset pagination is disabled; use `cursor`.").toResponse(ctx.allocator);
    // When offset is disabled and no cursor was supplied, the FIRST page still runs in cursor mode
    // (cursor==null) so clients get a nextCursor to walk forward. When cursor is disabled, a cursor
    // param was already rejected above, so offset mode runs.
    const cursor_mode = has_cursor or !pg.offset_enabled;

    const page = parseU32(qp.get("page"), 1);
    const perPage = parseU32(qp.get("perPage"), 30);
    const limit: ?u32 = if (qp.get("limit")) |l| (std.fmt.parseInt(u32, l, 10) catch null) else null;
    // skipTotal default: true in cursor mode (cheap), false in offset mode (unchanged behavior).
    const skip_total = parseBool(qp.get("skipTotal"), cursor_mode);

    const writer = if (pg.cursor_token == .stateful and cursor_mode) blk: {
        // Stateful mint/lookup writes/reads `_cursorStates`; needs a writer connection.
        break :blk app.pool.acquireWriter();
    } else null;
    defer if (writer != null) app.pool.releaseWriter();

    const conn = writer orelse &r;

    const result = records.list(ctx.allocator, conn, col, .{
        .filter = qp.get("filter"),
        .sort = qp.get("sort"),
        .page = page,
        .perPage = perPage,
        .rule = rule_expr,
        .rctx = &rctx,
        .cursor = if (cursor_mode) qp.get("cursor") else null,
        .cursorMode = cursor_mode,
        .limit = limit,
        .skipTotal = skip_total,
        .cursorToken = pg.cursor_token,
        .signingSecret = app.jwt_secret,
        .io = app.io,
        .writer = writer,
    }) catch |e| switch (e) {
        error.CursorState => return ApiError.gone("Cursor expired; re-fetch from the start.").toResponse(ctx.allocator),
        error.CursorSig => return ApiError.badRequest("Invalid cursor signature.").toResponse(ctx.allocator),
        error.CursorSort => return ApiError.badRequest("Cursor does not match the requested sort.").toResponse(ctx.allocator),
        error.CursorFilter => return ApiError.badRequest("Cursor does not match the requested filter.").toResponse(ctx.allocator),
        error.BadCursor => return ApiError.badRequest("Invalid cursor.").toResponse(ctx.allocator),
        error.UnknownField, error.NotARelation, error.MultiRelationTraversal, error.BadFilter, error.BadSort, error.BadValue, error.UnexpectedToken, error.BadOperand, error.Empty, error.UnexpectedChar, error.UnterminatedString, error.TooDeep =>
            return ApiError.badRequest("Invalid filter or sort.").toResponse(ctx.allocator),
        else => return e,
    };

    if (qp.get("expand")) |exp| if (exp.len > 0) {
        for (result.items) |*item| try expand_mod.expand(ctx.allocator, &r, col, item, exp, 0, &rctx);
    };

    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator, "page", .{ .integer = @intCast(result.page) });
    try root.put(ctx.allocator, "perPage", .{ .integer = @intCast(result.perPage) });
    if (result.totalItems) |total| {
        const total_pages: i64 = if (result.perPage == 0) 0 else @divTrunc(total + @as(i64, result.perPage) - 1, @as(i64, result.perPage));
        try root.put(ctx.allocator, "totalItems", .{ .integer = total });
        try root.put(ctx.allocator, "totalPages", .{ .integer = total_pages });
    }
    if (result.mode == .cursor) {
        try root.put(ctx.allocator, "nextCursor", if (result.nextCursor) |c| .{ .string = c } else .null);
        try root.put(ctx.allocator, "prevCursor", if (result.prevCursor) |c| .{ .string = c } else .null);
        try root.put(ctx.allocator, "hasNext", .{ .bool = result.hasNext });
        try root.put(ctx.allocator, "hasPrev", .{ .bool = result.hasPrev });
    }
    var arr = std.json.Array.init(ctx.allocator);
    for (result.items) |it| try arr.append(it);
    try root.put(ctx.allocator, "items", .{ .array = arr });
    return jsonResponse(ctx, 200, .{ .object = root });
}

fn parseU32(s: ?[]const u8, default: u32) u32 {
    const v = s orelse return default;
    return std.fmt.parseInt(u32, v, 10) catch default;
}

/// Parse a query-param boolean ("true"/"1" => true, "false"/"0" => false), else `default`.
fn parseBool(s: ?[]const u8, default: bool) bool {
    const v = s orelse return default;
    if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")) return true;
    if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0")) return false;
    return default;
}

const TestEnv = struct {
    tmp: std.testing.TmpDir,
    pool: db.Pool,
    app: app_mod.App,

    fn init() !*TestEnv {
        const env = try std.testing.allocator.create(TestEnv);
        env.tmp = std.testing.tmpDir(.{});
        const dir = try env.tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(dir);
        const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/test.db", .{dir}, 0);
        defer std.testing.allocator.free(path);
        env.pool = try db.Pool.init(std.testing.allocator, std.testing.io, path);
        {
            const w = env.pool.acquireWriter();
            defer env.pool.releaseWriter();
            try migrations.run(w);
            var setup_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer setup_arena.deinit();
            const sa = setup_arena.allocator();
            _ = try collections.create(sa, std.testing.io, w, .{
                .id = "", .name = "posts",
                .fields = &[_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }},
                // Open fixture: "@public" is the allow-all sentinel (empty "" is now LOCKED).
                .listRule = "@public", .viewRule = "@public", .createRule = "@public", .updateRule = "@public", .deleteRule = "@public",
            });
        }
        env.app = .{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = &env.pool };
        return env;
    }

    fn deinit(env: *TestEnv) void {
        env.pool.deinit();
        env.tmp.cleanup();
        std.testing.allocator.destroy(env);
    }
};

fn ctxFor(env: *TestEnv, a: std.mem.Allocator, m: http.Method, body: []const u8, params: []const http.Param) http.RequestCtx {
    return .{ .method = m, .path = "/", .body = body, .allocator = a, .app = &env.app, .params = params };
}

test "create then view a record over handlers" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col_param = [_]http.Param{.{ .key = "col", .value = "posts" }};

    var cctx = ctxFor(env, a, .POST, "{\"title\":\"hi\"}", &col_param);
    const cres = try create(&cctx);
    try std.testing.expectEqual(@as(u16, 201), cres.status);
    try std.testing.expect(std.mem.indexOf(u8, cres.body, "\"title\":\"hi\"") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, cres.body, .{});
    const rid = parsed.value.object.get("id").?.string;
    const view_params = [_]http.Param{ .{ .key = "col", .value = "posts" }, .{ .key = "id", .value = rid } };
    var vctx = ctxFor(env, a, .GET, "", &view_params);
    const vres = try view(&vctx);
    try std.testing.expectEqual(@as(u16, 200), vres.status);
}

test "view nonexistent collection -> 404" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const params = [_]http.Param{ .{ .key = "col", .value = "ghosts" }, .{ .key = "id", .value = "x" } };
    var ctx = ctxFor(env, arena.allocator(), .GET, "", &params);
    const res = try view(&ctx);
    try std.testing.expectEqual(@as(u16, 404), res.status);
}

test "list handler returns the page envelope" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col_param = [_]http.Param{.{ .key = "col", .value = "posts" }};
    var c1 = ctxFor(env, a, .POST, "{\"title\":\"a\"}", &col_param);
    _ = try create(&c1);
    var c2 = ctxFor(env, a, .POST, "{\"title\":\"b\"}", &col_param);
    _ = try create(&c2);

    var lctx = http.RequestCtx{ .method = .GET, .path = "/", .query = "perPage=1", .allocator = a, .app = &env.app, .params = &col_param };
    const res = try list(&lctx);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"totalItems\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"page\":1") != null);
}

test "list handler clamps an oversized perPage to the 500 cap (F9 DoS)" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col_param = [_]http.Param{.{ .key = "col", .value = "posts" }};
    // A client asking for a huge page cannot force a huge SQL LIMIT / allocation:
    // the response echoes the clamped perPage (500), not the requested 100000.
    var lctx = http.RequestCtx{ .method = .GET, .path = "/", .query = "perPage=100000", .allocator = a, .app = &env.app, .params = &col_param };
    const res = try list(&lctx);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"perPage\":500") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"perPage\":100000") == null);
}

fn extractStr(body: []const u8, key: []const u8) ?[]const u8 {
    const k = std.fmt.allocPrint(std.testing.allocator, "\"{s}\":\"", .{key}) catch return null;
    defer std.testing.allocator.free(k);
    const start = (std.mem.indexOf(u8, body, k) orelse return null) + k.len;
    const end = std.mem.indexOfScalarPos(u8, body, start, '"') orelse return null;
    return body[start..end];
}

test "cursor handler: forward mode returns hasNext/nextCursor and omits totalItems by default" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col_param = [_]http.Param{.{ .key = "col", .value = "posts" }};
    inline for (.{ "a", "b", "c" }) |t| {
        var c = ctxFor(env, a, .POST, "{\"title\":\"" ++ t ++ "\"}", &col_param);
        _ = try create(&c);
    }
    // Disable offset so the first page (no cursor token) runs in cursor mode.
    env.app.pagination = .{ .offset_enabled = false, .cursor_enabled = true, .cursor_token = .stateless };
    var lctx = http.RequestCtx{ .method = .GET, .path = "/", .query = "limit=2", .allocator = a, .app = &env.app, .params = &col_param };
    const res = try list(&lctx);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"hasNext\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"nextCursor\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"totalItems\"") == null); // skipTotal default
    env.app.pagination = .{}; // restore
}

test "cursor handler: skipTotal=false includes totalItems" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col_param = [_]http.Param{.{ .key = "col", .value = "posts" }};
    var c1 = ctxFor(env, a, .POST, "{\"title\":\"a\"}", &col_param);
    _ = try create(&c1);
    env.app.pagination = .{ .offset_enabled = false, .cursor_enabled = true };
    var lctx = http.RequestCtx{ .method = .GET, .path = "/", .query = "limit=2&skipTotal=false", .allocator = a, .app = &env.app, .params = &col_param };
    const res = try list(&lctx);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"totalItems\":1") != null);
    env.app.pagination = .{};
}

test "cursor handler: garbage cursor -> 400; changed sort -> 400" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col_param = [_]http.Param{.{ .key = "col", .value = "posts" }};
    inline for (.{ "a", "b", "c" }) |t| {
        var c = ctxFor(env, a, .POST, "{\"title\":\"" ++ t ++ "\"}", &col_param);
        _ = try create(&c);
    }
    // Garbage cursor.
    var g = http.RequestCtx{ .method = .GET, .path = "/", .query = "cursor=%21%21garbage", .allocator = a, .app = &env.app, .params = &col_param };
    try std.testing.expectEqual(@as(u16, 400), (try list(&g)).status);
    // Get a valid cursor first, then replay it under a different sort -> 400.
    var first = http.RequestCtx{ .method = .GET, .path = "/", .query = "sort=created&limit=1", .allocator = a, .app = &env.app, .params = &col_param };
    env.app.pagination = .{ .offset_enabled = false, .cursor_enabled = true };
    const fres = try list(&first);
    const tok = extractStr(fres.body, "nextCursor").?;
    const q2 = try std.fmt.allocPrint(a, "sort=-created&limit=1&cursor={s}", .{tok});
    var second = http.RequestCtx{ .method = .GET, .path = "/", .query = q2, .allocator = a, .app = &env.app, .params = &col_param };
    try std.testing.expectEqual(@as(u16, 400), (try list(&second)).status);
    env.app.pagination = .{};
}

test "gating: cursor disabled -> cursor param 400; offset disabled -> page param 400" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col_param = [_]http.Param{.{ .key = "col", .value = "posts" }};
    // cursor disabled: a cursor param is rejected.
    env.app.pagination = .{ .offset_enabled = true, .cursor_enabled = false };
    var c = http.RequestCtx{ .method = .GET, .path = "/", .query = "cursor=abc", .allocator = a, .app = &env.app, .params = &col_param };
    const cres = try list(&c);
    try std.testing.expectEqual(@as(u16, 400), cres.status);
    try std.testing.expect(std.mem.indexOf(u8, cres.body, "Cursor pagination is disabled") != null);
    // offset disabled: a page/perPage param is rejected.
    env.app.pagination = .{ .offset_enabled = false, .cursor_enabled = true };
    var p = http.RequestCtx{ .method = .GET, .path = "/", .query = "page=2", .allocator = a, .app = &env.app, .params = &col_param };
    const pres = try list(&p);
    try std.testing.expectEqual(@as(u16, 400), pres.status);
    try std.testing.expect(std.mem.indexOf(u8, pres.body, "Offset pagination is disabled") != null);
    env.app.pagination = .{};
}

test "offset mode response shape is unchanged (regression guard)" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col_param = [_]http.Param{.{ .key = "col", .value = "posts" }};
    var c1 = ctxFor(env, a, .POST, "{\"title\":\"a\"}", &col_param);
    _ = try create(&c1);
    var lctx = http.RequestCtx{ .method = .GET, .path = "/", .query = "perPage=10", .allocator = a, .app = &env.app, .params = &col_param };
    const res = try list(&lctx);
    // Offset envelope: page/perPage/totalItems/totalPages/items; no cursor fields.
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"totalItems\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"totalPages\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"nextCursor\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"hasNext\"") == null);
}

fn seedRuled(env: *TestEnv, name: []const u8, listR: ?[]const u8, viewR: ?[]const u8, createR: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    _ = try collections.create(a, std.testing.io, w, .{
        .id = "", .name = name,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }},
        .listRule = listR, .viewRule = viewR, .createRule = createR,
    });
}

test "locked (null) collection: list 403, create 403" {
    var env = try TestEnv.init();
    defer env.deinit();
    try seedRuled(env, "locked", null, null, null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = [_]http.Param{.{ .key = "col", .value = "locked" }};
    var lctx = http.RequestCtx{ .method = .GET, .path = "/", .query = "", .allocator = a, .app = &env.app, .params = &p };
    try std.testing.expectEqual(@as(u16, 403), (try list(&lctx)).status);
    var cctx = ctxFor(env, a, .POST, "{\"title\":\"x\"}", &p);
    try std.testing.expectEqual(@as(u16, 403), (try create(&cctx)).status);
}

test "createRule on request data: empty title -> 403, nonempty -> 201" {
    var env = try TestEnv.init();
    defer env.deinit();
    try seedRuled(env, "guarded", "", "", "@request.data.title != \"\"");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = [_]http.Param{.{ .key = "col", .value = "guarded" }};
    var bad = ctxFor(env, a, .POST, "{\"title\":\"\"}", &p);
    try std.testing.expectEqual(@as(u16, 403), (try create(&bad)).status);
    var ok = ctxFor(env, a, .POST, "{\"title\":\"hello\"}", &p);
    try std.testing.expectEqual(@as(u16, 201), (try create(&ok)).status);
}

fn seedUpDelRuled(env: *TestEnv, name: []const u8, updateR: ?[]const u8, deleteR: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    _ = try collections.create(a, std.testing.io, w, .{
        .id = "", .name = name,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }},
        // create/view permissive so a row can be seeded over the handler ("@public" = allow-all).
        .listRule = "@public", .viewRule = "@public", .createRule = "@public", .updateRule = updateR, .deleteRule = deleteR,
    });
}

test "update handler: rule denial -> 403, missing id -> 404" {
    var env = try TestEnv.init();
    defer env.deinit();
    // null update rule -> locked (deny) for non-superusers.
    try seedUpDelRuled(env, "ud_upd", null, "");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col_param = [_]http.Param{.{ .key = "col", .value = "ud_upd" }};

    // Seed a row via the create handler.
    var cctx = ctxFor(env, a, .POST, "{\"title\":\"hi\"}", &col_param);
    const cres = try create(&cctx);
    try std.testing.expectEqual(@as(u16, 201), cres.status);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, cres.body, .{});
    const rid = parsed.value.object.get("id").?.string;

    // Existing row, but the locked updateRule denies -> 403.
    const p_exist = [_]http.Param{ .{ .key = "col", .value = "ud_upd" }, .{ .key = "id", .value = rid } };
    var uctx = ctxFor(env, a, .PATCH, "{\"title\":\"new\"}", &p_exist);
    try std.testing.expectEqual(@as(u16, 403), (try update(&uctx)).status);

    // Nonexistent id -> 404 (the not-found check precedes the rule gate).
    const p_missing = [_]http.Param{ .{ .key = "col", .value = "ud_upd" }, .{ .key = "id", .value = "nope" } };
    var mctx = ctxFor(env, a, .PATCH, "{\"title\":\"new\"}", &p_missing);
    try std.testing.expectEqual(@as(u16, 404), (try update(&mctx)).status);
}

test "delete handler: rule denial -> 403, missing id -> 404" {
    var env = try TestEnv.init();
    defer env.deinit();
    // null delete rule -> locked (deny) for non-superusers.
    try seedUpDelRuled(env, "ud_del", "", null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col_param = [_]http.Param{.{ .key = "col", .value = "ud_del" }};

    var cctx = ctxFor(env, a, .POST, "{\"title\":\"hi\"}", &col_param);
    const cres = try create(&cctx);
    try std.testing.expectEqual(@as(u16, 201), cres.status);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, cres.body, .{});
    const rid = parsed.value.object.get("id").?.string;

    // Existing row, but the locked deleteRule denies -> 403.
    const p_exist = [_]http.Param{ .{ .key = "col", .value = "ud_del" }, .{ .key = "id", .value = rid } };
    var dctx = ctxFor(env, a, .DELETE, "", &p_exist);
    try std.testing.expectEqual(@as(u16, 403), (try delete(&dctx)).status);

    // Nonexistent id -> 404.
    const p_missing = [_]http.Param{ .{ .key = "col", .value = "ud_del" }, .{ .key = "id", .value = "nope" } };
    var mctx = ctxFor(env, a, .DELETE, "", &p_missing);
    try std.testing.expectEqual(@as(u16, 404), (try delete(&mctx)).status);
}

fn seedAuth(env: *TestEnv, name: []const u8, createR: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    _ = try collections.create(a, std.testing.io, w, .{
        .id = "", .name = name, .type = .auth,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
        // Open fixture for list/view ("@public"); createR is supplied per test.
        .listRule = "@public", .viewRule = "@public", .createRule = createR, .updateRule = "@public", .deleteRule = "@public",
    });
}

test "creating an auth record hashes the password, hides secrets, forces verified=false" {
    var env = try TestEnv.init();
    defer env.deinit();
    try seedAuth(env, "users", "@public");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = [_]http.Param{.{ .key = "col", .value = "users" }};
    var cctx = ctxFor(env, a, .POST, "{\"email\":\"u@x.io\",\"password\":\"longenough\",\"verified\":true}", &p);
    const res = try create(&cctx);
    try std.testing.expectEqual(@as(u16, 201), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "passwordHash") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "tokenKey") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "password") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"verified\":false") != null);
}

// ---------------------------------------------------------------------------
// Multipart-input handler tests (TDD). ctx.form_fields non-null == multipart;
// the handlers must coerce those string values by schema BEFORE validation,
// and must NEVER coerce JSON bodies.
// ---------------------------------------------------------------------------

fn seedTyped(env: *TestEnv, name: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    _ = try collections.create(a, std.testing.io, w, .{
        .id = "", .name = name,
        .fields = &[_]schema.Field{
            .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
            .{ .id = "f2", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } },
            .{ .id = "f3", .name = "ratio", .options = .{ .number = .{ .mode = .float } } },
            .{ .id = "f4", .name = "flag", .options = .{ .@"bool" = .{} } },
            .{ .id = "f5", .name = "tags", .options = .{ .select = .{ .values = &.{ "x", "y" }, .maxSelect = 3 } } },
            .{ .id = "f6", .name = "photos", .options = .{ .file = .{ .maxSelect = 3 } } },
        },
        // Open fixture ("@public" allow-all; empty "" is now LOCKED).
        .listRule = "@public", .viewRule = "@public", .createRule = "@public", .updateRule = "@public", .deleteRule = "@public",
    });
}

fn formCtx(env: *TestEnv, a: std.mem.Allocator, m: http.Method, fields: std.json.ObjectMap, files: []const http.UploadedFile, params: []const http.Param) http.RequestCtx {
    return .{
        .method = m, .path = "/", .body = "", .allocator = a, .app = &env.app, .params = params,
        .content_type = "multipart/form-data; boundary=x",
        .form_fields = .{ .object = fields },
        .files = files,
    };
}

test "multipart create: schema coercion (bool/float/multi-select) + verbatim text/fixed" {
    var env = try TestEnv.init();
    defer env.deinit();
    try seedTyped(env, "mp_things");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = [_]http.Param{.{ .key = "col", .value = "mp_things" }};
    var ff: std.json.ObjectMap = .empty;
    try ff.put(a, "title", .{ .string = "true" }); // scalar-looking text stays text
    try ff.put(a, "price", .{ .string = "45.00" });
    try ff.put(a, "ratio", .{ .string = "2.50" });
    try ff.put(a, "flag", .{ .string = "true" });
    try ff.put(a, "tags", .{ .string = "[\"x\",\"y\"]" });
    var ctx = formCtx(env, a, .POST, ff, &.{}, &p);
    const res = try create(&ctx);
    try std.testing.expectEqual(@as(u16, 201), res.status);
    const rec = (try std.json.parseFromSlice(std.json.Value, a, res.body, .{})).value.object;
    try std.testing.expectEqualStrings("true", rec.get("title").?.string);
    try std.testing.expectEqualStrings("45.00", rec.get("price").?.string);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), rec.get("ratio").?.float, 0.0001);
    try std.testing.expectEqual(true, rec.get("flag").?.bool);
    try std.testing.expectEqual(@as(usize, 2), rec.get("tags").?.array.items.len);
}

test "multipart create: file part + fixed-mode decimal in the same request (original repro)" {
    var env = try TestEnv.init();
    defer env.deinit();
    try seedTyped(env, "mp_files");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = [_]http.Param{.{ .key = "col", .value = "mp_files" }};
    var ff: std.json.ObjectMap = .empty;
    try ff.put(a, "title", .{ .string = "b" });
    try ff.put(a, "price", .{ .string = "45.00" });
    const ups = [_]http.UploadedFile{.{ .field = "photos", .filename = "x.jpg", .mimetype = "image/jpeg", .bytes = "\xff\xd8\xff\xe0data" }};
    var ctx = formCtx(env, a, .POST, ff, &ups, &p);
    const res = try create(&ctx);
    try std.testing.expectEqual(@as(u16, 201), res.status);
    const rec = (try std.json.parseFromSlice(std.json.Value, a, res.body, .{})).value.object;
    try std.testing.expectEqualStrings("b", rec.get("title").?.string);
    try std.testing.expectEqualStrings("45.00", rec.get("price").?.string);
    const photos = rec.get("photos").?.array;
    try std.testing.expectEqual(@as(usize, 1), photos.items.len);
    try std.testing.expect(std.mem.endsWith(u8, photos.items[0].string, ".jpg"));
}

test "multipart update: coercion + removal-key passthrough removes the file" {
    var env = try TestEnv.init();
    defer env.deinit();
    try seedTyped(env, "mp_upd");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = [_]http.Param{.{ .key = "col", .value = "mp_upd" }};

    var cff: std.json.ObjectMap = .empty;
    try cff.put(a, "flag", .{ .string = "true" });
    const ups = [_]http.UploadedFile{.{ .field = "photos", .filename = "x.jpg", .mimetype = "image/jpeg", .bytes = "\xff\xd8\xff\xe0data" }};
    var cctx = formCtx(env, a, .POST, cff, &ups, &p);
    const cres = try create(&cctx);
    try std.testing.expectEqual(@as(u16, 201), cres.status);
    const crec = (try std.json.parseFromSlice(std.json.Value, a, cres.body, .{})).value.object;
    const rid = crec.get("id").?.string;
    const stored = crec.get("photos").?.array.items[0].string;

    var uff: std.json.ObjectMap = .empty;
    try uff.put(a, "flag", .{ .string = "false" });
    const minus = try std.fmt.allocPrint(a, "[\"{s}\"]", .{stored});
    try uff.put(a, "photos-", .{ .string = minus });
    const up = [_]http.Param{ .{ .key = "col", .value = "mp_upd" }, .{ .key = "id", .value = rid } };
    var uctx = formCtx(env, a, .PATCH, uff, &.{}, &up);
    const ures = try update(&uctx);
    try std.testing.expectEqual(@as(u16, 200), ures.status);
    const urec = (try std.json.parseFromSlice(std.json.Value, a, ures.body, .{})).value.object;
    try std.testing.expectEqual(false, urec.get("flag").?.bool);
    try std.testing.expectEqual(@as(usize, 0), urec.get("photos").?.array.items.len);
}

test "JSON bodies are NEVER coerced: a string for a bool/float field stays a 400" {
    var env = try TestEnv.init();
    defer env.deinit();
    try seedTyped(env, "mp_json");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = [_]http.Param{.{ .key = "col", .value = "mp_json" }};
    var c1 = ctxFor(env, a, .POST, "{\"flag\":\"true\"}", &p);
    const r1 = try create(&c1);
    try std.testing.expectEqual(@as(u16, 400), r1.status);
    try std.testing.expect(std.mem.indexOf(u8, r1.body, "\"flag\"") != null);
    var c2 = ctxFor(env, a, .POST, "{\"ratio\":\"2.50\"}", &p);
    try std.testing.expectEqual(@as(u16, 400), (try create(&c2)).status);
}

test "multipart auth signup still works (password keys pass through untouched)" {
    var env = try TestEnv.init();
    defer env.deinit();
    try seedAuth(env, "mp_users", "@public");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = [_]http.Param{.{ .key = "col", .value = "mp_users" }};
    var ff: std.json.ObjectMap = .empty;
    try ff.put(a, "email", .{ .string = "mp@x.io" });
    try ff.put(a, "password", .{ .string = "longenough" });
    try ff.put(a, "passwordConfirm", .{ .string = "longenough" });
    var ctx = formCtx(env, a, .POST, ff, &.{}, &p);
    const res = try create(&ctx);
    try std.testing.expectEqual(@as(u16, 201), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "mp@x.io") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "password") == null);
}

test "validation error is attributed to the offending field, not the first (Bug 2)" {
    var env = try TestEnv.init();
    defer env.deinit();
    try seedTyped(env, "mp_attr");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = [_]http.Param{.{ .key = "col", .value = "mp_attr" }};

    // multipart: title/ratio/flag valid, price invalid -> the error must name "price"
    var ff: std.json.ObjectMap = .empty;
    try ff.put(a, "title", .{ .string = "ok" });
    try ff.put(a, "ratio", .{ .string = "1.5" });
    try ff.put(a, "flag", .{ .string = "true" });
    try ff.put(a, "price", .{ .string = "abc" });
    var mctx = formCtx(env, a, .POST, ff, &.{}, &p);
    const mres = try create(&mctx);
    try std.testing.expectEqual(@as(u16, 400), mres.status);
    const mdata = (try std.json.parseFromSlice(std.json.Value, a, mres.body, .{})).value.object.get("data").?.object;
    try std.testing.expect(mdata.get("price") != null);
    try std.testing.expect(mdata.get("title") == null);
    try std.testing.expect(mdata.get("ratio") == null);
    try std.testing.expect(mdata.get("flag") == null);

    // JSON: same shape, same attribution
    var jctx = ctxFor(env, a, .POST, "{\"title\":\"ok\",\"ratio\":1.5,\"flag\":true,\"price\":\"abc\"}", &p);
    const jres = try create(&jctx);
    try std.testing.expectEqual(@as(u16, 400), jres.status);
    const jdata = (try std.json.parseFromSlice(std.json.Value, a, jres.body, .{})).value.object.get("data").?.object;
    try std.testing.expect(jdata.get("price") != null);
    try std.testing.expect(jdata.get("title") == null);
}

test "creating an auth record without a password is a 400" {
    var env = try TestEnv.init();
    defer env.deinit();
    try seedAuth(env, "users2", "@public");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = [_]http.Param{.{ .key = "col", .value = "users2" }};
    var cctx = ctxFor(env, a, .POST, "{\"email\":\"u@x.io\"}", &p);
    const res = try create(&cctx);
    try std.testing.expectEqual(@as(u16, 400), res.status);
}
