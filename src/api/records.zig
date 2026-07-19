const std = @import("std");
const http = @import("../http.zig");
const app_mod = @import("../app.zig");
const db = @import("../db.zig");
const migrations = @import("../migrations.zig");
const collections = @import("../collections.zig");
const colcache = @import("../colcache.zig");
const schema = @import("../schema.zig");
const records = @import("../records.zig");
const ApiError = @import("error.zig").ApiError;
const FieldError = @import("error.zig").FieldError;
const params_mod = @import("../query/params.zig");
const expand_mod = @import("../query/expand.zig");
const fields_mod = @import("../query/fields.zig");
const policy = @import("../policy.zig");
const tenancy = @import("../tenancy/tenancy.zig");
const request = @import("../request.zig");
const Ctx = @import("../ctx.zig").Ctx;
const auth = @import("../auth.zig");
const api_auth = @import("auth.zig");
const realtime_ws = @import("../realtime/ws.zig");
const file_plan = @import("../files/plan.zig");
const events = @import("../events.zig");
const crypto = @import("../crypto.zig");
const jwt = @import("../jwt.zig");
const ratelimit = @import("../ratelimit.zig");

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
        .rctx = rctx,
        .arena = arena,
        .collection = col_name,
        .record = value,
        .phase = phase,
    };
    // The hook's capabilities (`ctx.records()`) ride on a Ctx bound to the triggering
    // write's IN-TRANSACTION connection (A2): a before-hook side-write reuses the txn and
    // commits/rolls back atomically with the primary write — never re-acquiring the pool
    // writer (which would deadlock, since the handler already holds it).
    var ctx = Ctx{ .app = app, .arena = arena, .rctx = rctx.*, .bound_conn = conn };
    defer ctx.deinit();
    if (is_before) {
        try handler(&ctx, &ev);
    } else {
        handler(&ctx, &ev) catch |e| {
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
    // `records.last_errors` holds slices allocated from THIS request's arena, which is freed when
    // the request ends. Null it once consumed so the worker thread's threadlocal never outlives the
    // arena it points into — otherwise a later reader on the same thread would dereference freed
    // memory (NO_SLOP §3, "spooky action"). The field/code/message copied into `fes` are the
    // arena-owned strings, still live for the toResponse render below (same request scope).
    defer records.last_errors = null;
    const verrs = records.last_errors orelse &[_]schema.ValidationError{};
    const fes = try ctx.allocator.alloc(FieldError, verrs.len);
    for (verrs, 0..) |e, i| fes[i] = .{ .field = e.field, .code = e.code, .message = e.message };
    return ApiError.validation(fes).toResponse(ctx.allocator);
}

/// Resolve the `:col` route param to its parsed collection via the app's metadata cache
/// (colcache) — direct DB load when no cache is installed. The returned Lease's `col`
/// memory is CACHE-OWNED and read-only; callers MUST `defer lease.release()` and must not
/// retain `col` past the request.
fn resolveCollection(ctx: *http.RequestCtx, conn: *db.Db) !colcache.Lease {
    const name = ctx.param("col") orelse return colcache.Lease{ .col = null };
    const cache = if (ctx.app) |a| a.col_cache else null;
    return colcache.lease(cache, conn, ctx.allocator, name);
}

fn jsonResponse(ctx: *http.RequestCtx, status: u16, v: std.json.Value) !http.Response {
    return .{ .status = status, .body = try std.json.Stringify.valueAlloc(ctx.allocator, v, .{}) };
}

/// Fills auth/superuser from the verified bearer/cookie token (anonymous if absent/invalid), then
/// — when tenancy is enabled — resolves the active account scope (`account_id`/`account_role`/
/// `memberships`) from a verified `_memberships` row. Resolution is cached on the returned context
/// (one indexed SELECT per request) and fails closed: any error leaves the scope empty.
fn buildContext(ctx: *http.RequestCtx, conn: *db.Db, data: ?std.json.Value) request.RequestContext {
    var rctx = request.RequestContext{ .auth = null, .is_superuser = false, .collection = "", .data = data, .method = @tagName(ctx.method) };
    const app = ctx.app orelse return rctx;
    rctx.tenancy_enabled = app.tenancy.enabled;
    rctx.role_ranking = app.role_ranking; // ability `.min_role` comparisons (#155)
    const a = (auth.authenticate(app.io, ctx.allocator, app, ctx, conn) catch null) orelse return rctx;
    rctx.auth = a.record;
    rctx.is_superuser = a.is_superuser;
    rctx.collection = a.collection;
    // Superusers bypass tenancy (consistent with rules.decide); resolution is skipped for them and
    // the fail-closed empty scope is kept on any resolution error — see `tenancy.resolveRequest`.
    tenancy.resolveRequest(ctx, conn, app, a, &rctx);
    return rctx;
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

/// Peek the request body for the auth-collection password-change control fields WITHOUT
/// running the full prepare pipeline (this runs on a READER, before the writer is taken).
/// Multipart form fields are verbatim strings; JSON bodies are parsed fresh (the later
/// prepareRecordData parse is unaffected — double-parsing only happens on auth PATCHes).
const PwFields = struct { password: ?[]const u8 = null, old: ?[]const u8 = null };

fn peekPasswordFields(ctx: *http.RequestCtx) ?PwFields {
    const raw = if (ctx.form_fields) |ff| ff else (std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.body, .{}) catch return null).value;
    if (raw != .object) return .{};
    var out = PwFields{};
    if (raw.object.get("password")) |v| if (v == .string) {
        out.password = v.string;
    };
    if (raw.object.get("oldPassword")) |v| if (v == .string and v.string.len > 0) {
        out.old = v.string;
    };
    return out;
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
            deleteWrites(app, col.name, record_id, writes[0..written]);
            return error.StorageFailed;
        };
        written += 1;
    }
    for (deletes) |d| storage.delete(app.io, col.name, record_id, d) catch |e|
        std.log.warn("replaced-file cleanup failed for {s}/{s}/{s}: {s}", .{ col.name, record_id, d, @errorName(e) });
}

/// Best-effort removal of just-written upload bytes when a create/update did NOT commit, so a
/// rolled-back row never leaves orphaned files in storage. The request already failed, so a delete
/// error here is logged, never propagated — silently swallowing it would leak files unboundedly
/// with no signal for an operator (NO_SLOP §2.3).
fn deleteWrites(app: *app_mod.App, col_name: []const u8, record_id: []const u8, writes: []const file_plan.FieldWrite) void {
    const storage = app.storage orelse return;
    for (writes) |wr| storage.delete(app.io, col_name, record_id, wr.filename) catch |e|
        std.log.warn("orphaned upload cleanup failed for {s}/{s}/{s}: {s}", .{ col_name, record_id, wr.filename, @errorName(e) });
}

pub fn view(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    var r = try app.pool.acquireReader();
    defer app.pool.releaseReader(&r);
    var col_lease = try resolveCollection(ctx, &r);
    defer col_lease.release();
    const col = col_lease.col orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rid = ctx.param("id") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rctx = buildContext(ctx, &r, null);
    switch (policy.decide(col, .view, &rctx)) {
        .deny_locked => return ApiError.notFound().toResponse(ctx.allocator),
        .allow => {},
        .check => if (!try policy.authorizes(ctx.allocator, &r, col, .view, rid, &rctx)) return ApiError.notFound().toResponse(ctx.allocator),
    }
    var rec = (try records.get(ctx.allocator, &r, col, rid)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const qp = try params_mod.parse(ctx.allocator, ctx.query);
    if (qp.get("expand")) |exp| if (exp.len > 0) try expand_mod.expand(ctx.allocator, &r, col, &rec, exp, 0, &rctx);
    // `fields=` response projection: a PURE OUTPUT FILTER applied AFTER expand + authorization —
    // it can only narrow the record, never reveal a field it wouldn't otherwise return.
    if (qp.get("fields")) |f| if (f.len > 0) {
        // Attacker-controlled — cap length like filter/sort (records.max_filter_len) to bound
        // parse/projection cost before doing any work.
        if (f.len > records.max_filter_len) return ApiError.badRequest("`fields` is too long.").toResponse(ctx.allocator);
        try fields_mod.project(ctx.allocator, &rec, try fields_mod.parse(ctx.allocator, f));
    };
    return jsonResponse(ctx, 200, rec);
}

/// `GET /api/collections/:col/records/:id/abilities` (#155): the set of actions the current
/// principal may perform on THIS record, computed through the same `policy` decision the REST
/// chokepoints use. The endpoint itself is authorized — a principal who cannot VIEW the record
/// gets 404 (it must not reveal a record's existence or its ability set). Returns
/// `{ "view": bool, "update": bool, "delete": bool }`.
pub fn abilities(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    var r = try app.pool.acquireReader();
    defer app.pool.releaseReader(&r);
    var col_lease = try resolveCollection(ctx, &r);
    defer col_lease.release();
    const col = col_lease.col orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rid = ctx.param("id") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rctx = buildContext(ctx, &r, null);
    // The record must exist AND be viewable; otherwise 404 (never leak existence).
    if ((try records.get(ctx.allocator, &r, col, rid)) == null) return ApiError.notFound().toResponse(ctx.allocator);
    const can_view = try policy.authorizes(ctx.allocator, &r, col, .view, rid, &rctx);
    if (!can_view) return ApiError.notFound().toResponse(ctx.allocator);
    const can_update = try policy.authorizes(ctx.allocator, &r, col, .update, rid, &rctx);
    const can_delete = try policy.authorizes(ctx.allocator, &r, col, .delete, rid, &rctx);
    var obj: std.json.ObjectMap = .empty;
    // `view` is always `true` on a 200: we already returned 404 above unless the caller can view the
    // record, so the response's very existence IS the view grant. It is emitted for a uniform shape.
    try obj.put(ctx.allocator, "view", .{ .bool = can_view });
    try obj.put(ctx.allocator, "update", .{ .bool = can_update });
    try obj.put(ctx.allocator, "delete", .{ .bool = can_delete });
    return jsonResponse(ctx, 200, .{ .object = obj });
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
    // The collection lease must OUTLIVE the reader block below: `col` is borrowed from the
    // cache entry's arena and used through the whole handler, so it is released only on
    // return (function-scope defer), never at block exit.
    var col_lease: colcache.Lease = .{ .col = null };
    defer col_lease.release();
    // Resolve, plan files, and (for auth collections) hash the password BEFORE acquiring the
    // writer, so the expensive argon2 hash in prepAuthData does NOT run under the global writer
    // lock. The reader is closed before the writer is taken. M2 fix.
    const col, const all, const data2 = blk: {
        var r = try app.pool.acquireReader();
        defer app.pool.releaseReader(&r);
        col_lease = try resolveCollection(ctx, &r);
        const col = col_lease.col orelse return ApiError.notFound().toResponse(ctx.allocator);
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
    const decision = policy.decide(col, .create, &rctx);
    if (decision == .deny_locked) return forbidden(ctx);

    // Tenant write guard (#156): creating a row in a tenant-owned collection requires an ACTIVE
    // account context. A non-superuser with no resolved account is denied (fail closed) rather
    // than writing an un-owned row. Superuser / crossTenant tooling is exempt.
    if (app.tenancy.enabled and !rctx.is_superuser and !rctx.cross_tenant)
        if (col.options.tenant_field != null and rctx.account_id.len == 0) return forbidden(ctx);

    // A2 KEYSTONE: the handler owns ONE write transaction spanning the before-hook,
    // the row INSERT, and the access-rule guard. A hook side-write + the primary
    // write commit atomically; a before-hook error (or a denied guard, or a storage
    // failure) rolls the WHOLE thing back — fail closed. `errdefer` covers error
    // returns; the catch-and-return-an-error-RESPONSE paths return a value (not an
    // error), so each rolls back explicitly before returning.
    try w.beginImmediate();
    errdefer w.rollback() catch {};

    // A before-hook may `put` NEW keys, which reallocs the map header captured in this
    // local; downstream MUST read the `_mut` binding (here and for rec_mut/ur_mut/ex_mut
    // below), not the original const — the binding is the grow-capturing reference.
    var data_mut = data2;
    emitRecord(app, &rctx, ctx.allocator, w, col.name, &data_mut, .before_create) catch {
        w.rollback() catch {};
        return hookRejected(ctx);
    };
    // #98: auth-collection registration hook. Fires INSIDE the create transaction, after the
    // generic before_create hook and before the INSERT. An abort rolls back the whole create
    // (fail closed) and returns the Ctx-mapped response. `data_mut` is the writable record.
    if (col.type == .auth) {
        if (try api_auth.fireAuthLifecycleBefore(ctx, w, col.name, "", .before_register, &data_mut, null)) |resp| {
            w.rollback() catch {};
            return resp;
        }
    }
    // Stamp the owning account onto the new row so a client can never set/spoof `tenant_field`
    // (superuser / crossTenant tooling keeps the client-provided value). The in-txn create guard
    // below (decide() forces `.check` for tenant-owned collections) re-verifies tenant_field ==
    // account_id, so even a before-hook that mutated it cannot persist a cross-tenant row.
    if (app.tenancy.enabled and !rctx.is_superuser and !rctx.cross_tenant)
        if (col.options.tenant_field) |tf| if (data_mut == .object)
            try data_mut.object.put(ctx.allocator, tf, .{ .string = rctx.account_id });

    // KNOWN LIMITATION: a `.check` guard evaluates `@request.data.*` from rctx.data, which is
    // built pre-hook; a hook mutating a guard-referenced field is not seen by the WHERE clause.
    const rec = records.createInTxn(ctx.allocator, app.io, w, col, data_mut) catch |e| switch (e) {
        error.Validation => {
            w.rollback() catch {};
            return validationResponse(ctx);
        },
        error.NotObject => {
            w.rollback() catch {};
            return ApiError.badRequest("Body must be a JSON object.").toResponse(ctx.allocator);
        },
        // A UNIQUE/CHECK/NOT NULL/FK violation (e.g. a duplicate email on signup) is a client
        // error, not a server fault — 409, never 500. No files have been written yet on the
        // create path (writeUploads runs after the INSERT), so an explicit rollback is enough.
        error.Constraint => {
            w.rollback() catch {};
            return ApiError.conflict("A record with these values already exists.").toResponse(ctx.allocator);
        },
        else => return e, // errdefer rolls back
    };
    // Access-rule guard evaluated INSIDE the transaction:
    // a denial rolls the INSERT back so a forbidden write never persists.
    if (decision == .check) {
        const guard = (try policy.compilePredicate(ctx.allocator, w, col, .create, &rctx)).?;
        if (!try records.guardPasses(ctx.allocator, w, col, rec.object.get("id").?.string, guard)) {
            w.rollback() catch {};
            return forbidden(ctx);
        }
    }
    const rid = rec.object.get("id").?.string;
    // File bytes are written before commit so a storage failure rolls the row back
    // (via the explicit rollback below); on commit the files and the row are both durable.
    writeUploads(ctx, col, rid, all.writes, all.deletes) catch {
        w.rollback() catch {};
        return ApiError.internal().toResponse(ctx.allocator);
    };
    // The upload bytes are now durable but the row is not until COMMIT succeeds. A commit
    // failure (SQLITE_FULL/IOERR) rolls the INSERT back via the errdefer above, so without
    // this guard the files would be orphaned under a record id that never existed — and, with
    // no orphan-file GC, be permanently unreclaimable. Flip on success so kept files stay.
    var committed = false;
    errdefer if (!committed) deleteWrites(app, col.name, rid, all.writes);
    try w.commit();
    committed = true;

    // after-hooks and the realtime broadcast run AFTER commit (side effects).
    emitFileUploads(app, &rctx, col.name, rid, all.writes);
    var rec_mut = rec;
    emitRecord(app, &rctx, ctx.allocator, w, col.name, &rec_mut, .after_create) catch {};
    // #98: auth-collection registration after-hook (post-commit, notify-only). `rec_mut` is
    // the persisted account (id populated); it also seeds the hook's `ctx.user()` identity.
    if (col.type == .auth)
        api_auth.emitAuthLifecycle(ctx, w, col.name, rid, .after_register, &rec_mut, rec_mut);
    realtime_ws.broadcast(app, col, .create, rid, rec_mut, null);
    return jsonResponse(ctx, 201, rec_mut);
}

pub fn update(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    // F1 password-change gate (spec §F1). When an AUTH-collection PATCH carries a
    // `password`, authorize the change BEFORE the writer is acquired:
    //   1. deny_locked updateRule → 403 first (the normal rule gate, spec ladder step 1);
    //   2. rate-limit scope "pwchange" (global limiter budget, per client IP falling back
    //      to the target identity) BEFORE any argon2 work;
    //   3. non-superusers must present a verifying `oldPassword` (argon2 on the READER —
    //      never serialize writes behind argon2). Wrong/missing `oldPassword`, a missing
    //      target, or a passwordless target (no/empty passwordHash) are all the
    //      login-identical `400 "Invalid credentials."` with dummyVerify timing padding
    //      (non-oracle: none of the branches is distinguishable by body or time).
    // Superusers bypass `oldPassword` AND the pwchange limiter (admin reset).
    // Consequence (deliberate): only the record owner or a superuser can change a
    // password, regardless of how permissive updateRule is.
    var pw_change = false; // this PATCH changes an auth record's password
    var self_change = false; // ...and the caller IS the target record (keep-this-device)
    {
        var gate_r = try app.pool.acquireReader();
        defer app.pool.releaseReader(&gate_r);
        var gate_lease = try resolveCollection(ctx, &gate_r);
        defer gate_lease.release();
        const gcol = gate_lease.col orelse return ApiError.notFound().toResponse(ctx.allocator);
        if (gcol.type == .auth) {
            const grid = ctx.param("id") orelse return ApiError.notFound().toResponse(ctx.allocator);
            const pf = peekPasswordFields(ctx) orelse return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator);
            if (pf.password != null) {
                pw_change = true;
                const grctx = buildContext(ctx, &gate_r, null);
                if (policy.decide(gcol, .update, &grctx) == .deny_locked) return forbidden(ctx);
                if (grctx.auth) |au| {
                    const aid = if (au == .object) (if (au.object.get("id")) |v| (if (v == .string) v.string else "") else "") else "";
                    self_change = std.mem.eql(u8, grctx.collection, gcol.name) and std.mem.eql(u8, aid, grid);
                }
                if (!grctx.is_superuser) {
                    if (try api_auth.rateLimited(ctx, "pwchange", grid)) |resp| return resp;
                    const phc = try api_auth.passwordHashFor(ctx.allocator, &gate_r, gcol.name, grid);
                    const opw = pf.old;
                    if (phc == null or phc.?.len == 0 or opw == null) {
                        // Missing target / passwordless target / missing oldPassword: run the
                        // identity-independent argon2 padding so timing can't distinguish them.
                        crypto.dummyVerify(app.io, ctx.allocator);
                        return ApiError.badRequest("Invalid credentials.").toResponse(ctx.allocator);
                    }
                    if (!crypto.verifyPassword(app.io, ctx.allocator, phc.?, opw.?))
                        return ApiError.badRequest("Invalid credentials.").toResponse(ctx.allocator);
                }
            }
        }
    }
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    var col_lease = try resolveCollection(ctx, w);
    defer col_lease.release();
    const col = col_lease.col orelse return ApiError.notFound().toResponse(ctx.allocator);
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
    const decision = policy.decide(col, .update, &rctx);
    if (decision == .deny_locked) return forbidden(ctx);

    // Tenant pre-authorization (defense-in-depth, symmetric with delete's pre-hook authz): for a
    // tenant-owned collection, confirm the TARGET row belongs to the active account BEFORE opening
    // the txn / running the before_update hook, so a cross-tenant PUT never triggers hook side
    // effects against another account's record. The in-txn `.check` guard still independently
    // rejects a cross-tenant MOVE (changing tenant_field on a row you DO own).
    if (app.tenancy.enabled and !rctx.is_superuser and !rctx.cross_tenant) {
        if (col.options.tenant_field) |tf| {
            if (rctx.account_id.len == 0) return forbidden(ctx); // no active account (mirror create)
            const owner = if (existing == .object) existing.object.get(tf) else null;
            const owner_id = if (owner) |o| (if (o == .string) o.string else "") else "";
            if (!std.mem.eql(u8, owner_id, rctx.account_id))
                return ApiError.notFound().toResponse(ctx.allocator);
        }
    }

    // A2 KEYSTONE: one transaction spanning the before-hook, the UPDATE, and the
    // access-rule guard (see create() for the errdefer/explicit-rollback rationale).
    try w.beginImmediate();
    errdefer w.rollback() catch {};

    var data_mut = data2;
    emitRecord(app, &rctx, ctx.allocator, w, col.name, &data_mut, .before_update) catch {
        w.rollback() catch {};
        return hookRejected(ctx);
    };

    // #98 on the PATCH path (spec §F1): `beforePasswordChange` fires ONLY when the prepared
    // data contains a password change, INSIDE the update transaction, with a READ-ONLY
    // pre-change snapshot. Abort ⇒ rollback ⇒ password unchanged (fail closed), mapped via
    // the Ctx error model — identical contract to confirm-password-reset.
    if (col.type == .auth and pw_change) {
        var snap = existing;
        if (try api_auth.fireAuthLifecycleBefore(ctx, w, col.name, rid, .before_password_change, &snap, existing)) |resp| {
            w.rollback() catch {};
            return resp;
        }
    }

    // Write new file bytes BEFORE the DB update so a storage failure can't leave dangling refs.
    if (ctx.app.?.storage) |storage| {
        var written: usize = 0;
        for (all.writes) |wr| {
            storage.put(app.io, col.name, rid, wr.filename, wr.bytes) catch {
                deleteWrites(app, col.name, rid, all.writes[0..written]);
                w.rollback() catch {};
                return ApiError.internal().toResponse(ctx.allocator);
            };
            written += 1;
        }
    }
    // The upload bytes are durable but the row is not until COMMIT. Every exit before commit —
    // whether it returns an error (via `try` on the guard/session paths or a failing commit,
    // which the errdefer above rolls back) or an error RESPONSE value (validation/not-found/
    // guard-miss below) — must remove the just-written files, or a rolled-back UPDATE leaks
    // them in storage. One guard replaces the cleanup that was copy-pasted into each branch.
    var committed = false;
    defer if (!committed) deleteWrites(app, col.name, rid, all.writes);

    // KNOWN LIMITATION: a `.check` guard evaluates `@request.data.*` from rctx.data, which is
    // built pre-hook; a hook mutating a guard-referenced field is not seen by the WHERE clause.
    const updated = records.updateInTxn(ctx.allocator, w, col, rid, data_mut) catch |e| switch (e) {
        // The `committed`-guarded defer above deletes the written files on each of these
        // pre-commit exits, so no branch repeats the storage cleanup.
        error.Validation => {
            w.rollback() catch {};
            return validationResponse(ctx);
        },
        error.NotObject => {
            w.rollback() catch {};
            return ApiError.badRequest("Body must be a JSON object.").toResponse(ctx.allocator);
        },
        // A UNIQUE/CHECK/NOT NULL/FK violation is a client error → 409, not 500. This is a
        // value-return, so the `committed`-guarded defer above deletes the just-written files.
        error.Constraint => {
            w.rollback() catch {};
            return ApiError.conflict("A record with these values already exists.").toResponse(ctx.allocator);
        },
        else => return e, // errdefer rolls back
    };
    const ur = updated orelse {
        w.rollback() catch {};
        return ApiError.notFound().toResponse(ctx.allocator);
    };
    // Access-rule guard evaluated INSIDE the transaction on the UPDATED row:
    // a denial rolls the UPDATE back. A guard miss maps to 404.
    if (decision == .check) {
        const guard = (try policy.compilePredicate(ctx.allocator, w, col, .update, &rctx)).?;
        if (!try records.guardPasses(ctx.allocator, w, col, rid, guard)) {
            w.rollback() catch {};
            return ApiError.notFound().toResponse(ctx.allocator);
        }
    }
    // Password changed ⇒ applyUpdate rotated `tokenKey` (every outstanding token dies in
    // BOTH session modes). Table mode additionally purges the target's `_sessions` rows
    // INSIDE the txn so no zombie rows outlive the rotation until GC.
    if (col.type == .auth and pw_change and app.session_store == .table)
        try api_auth.deleteSessionsForPrincipal(w, col.name, rid);
    try w.commit();
    committed = true; // row is durable — the write-cleanup defer must NOT fire past here

    // Side effects AFTER commit: drop replaced files, fire file/after-update hooks, broadcast.
    if (ctx.app.?.storage) |storage| for (all.deletes) |d| storage.delete(app.io, col.name, rid, d) catch |e|
        std.log.warn("replaced-file cleanup failed for {s}/{s}/{s}: {s}", .{ col.name, rid, d, @errorName(e) });
    emitFileUploads(app, &rctx, col.name, rid, all.writes);
    // Self-service password change: "keep this device, log out everywhere else". The old
    // token (incl. the caller's) died with the tokenKey rotation; re-issue ONE fresh session
    // for the authenticated owner under the NEW key (the writer is still held — table mode
    // inserts the single fresh `_sessions` row). Travels ONLY via Set-Cookie: the JSON body
    // stays the plain updated record (stable SDK update() return type). NO onAuth — this is
    // not a login. Bearer-token clients re-authenticate (the SDK helper does so). Admin
    // change (non-self): no re-issue; every target session stays dead.
    var pw_cookies: []const http.Cookie = &.{};
    if (col.type == .auth and pw_change and self_change) {
        if (api_auth.issueSessionNoEmit(ctx, w, col.name, rid)) |issued| {
            pw_cookies = try ctx.allocator.dupe(http.Cookie, &issued.cookies);
        } else |e| {
            // Degraded, not fatal: the password IS changed; the caller just has to log in again.
            std.log.warn("password-change re-issue failed ({s}); caller must re-authenticate", .{@errorName(e)});
        }
    }
    // Capture id BEFORE the after-hook so a hook that mutates/removes "id" can't panic the broadcast.
    const broadcast_id = ur.object.get("id").?.string;
    var ur_mut = ur;
    emitRecord(app, &rctx, ctx.allocator, w, col.name, &ur_mut, .after_update) catch {};
    // #98: afterPasswordChange AFTER the record after-hooks (notify-only, post-commit).
    if (col.type == .auth and pw_change) {
        var snap2 = ur_mut;
        api_auth.emitAuthLifecycle(ctx, w, col.name, rid, .after_password_change, &snap2, ur_mut);
    }
    realtime_ws.broadcast(app, col, .update, broadcast_id, ur_mut, null);
    if (pw_cookies.len > 0) {
        const body = try std.json.Stringify.valueAlloc(ctx.allocator, ur_mut, .{});
        return .{ .status = 200, .content_type = "application/json", .body = body, .cookies = pw_cookies };
    }
    return jsonResponse(ctx, 200, ur_mut);
}

pub fn delete(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    var col_lease = try resolveCollection(ctx, w);
    defer col_lease.release();
    const col = col_lease.col orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rid = ctx.param("id") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const existing = (try records.get(ctx.allocator, w, col, rid)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rctx = buildContext(ctx, w, null);
    // Gate FIRST (pre-delete authorization): the deleteRule is checked against the live
    // row before the transaction opens — unchanged semantics.
    switch (policy.decide(col, .delete, &rctx)) {
        .deny_locked => return forbidden(ctx),
        .allow => {},
        .check => if (!try policy.authorizes(ctx.allocator, w, col, .delete, rid, &rctx)) return ApiError.notFound().toResponse(ctx.allocator),
    }

    // A2 KEYSTONE: one transaction spanning the before-hook, the DELETE, and the auth
    // _externalAuths cleanup, so a before-hook side-write + the delete commit atomically
    // and a hook error rolls the whole thing back (see create() for the rollback rationale).
    try w.beginImmediate();
    errdefer w.rollback() catch {};

    var ex_mut = existing;
    emitRecord(app, &rctx, ctx.allocator, w, col.name, &ex_mut, .before_delete) catch {
        w.rollback() catch {};
        return hookRejected(ctx);
    };
    // Realtime delete prep (#159, PR-6/PR-6b), INSIDE this transaction so a Postgres side-table
    // snapshot commits atomically with the delete. Returns the AT-REST (ciphertext) snapshot used
    // for delete authz — so LOCAL authz matches the cross-instance REMOTE path and the live
    // create/update path (all compare ciphertext) — plus the cross-instance NOTIFY token (Postgres
    // only; the wire carries only the token, never the row data). On SQLite with no encrypted
    // fields this reuses `ex_mut` with no extra read (byte-identical).
    const rt = realtime_ws.prepareDelete(ctx.allocator, app, w, col, rid, ex_mut);
    if (!try records.deleteInTxn(ctx.allocator, w, col, rid)) {
        w.rollback() catch {};
        return ApiError.notFound().toResponse(ctx.allocator);
    }
    if (col.type == .auth) {
        var st = try w.prepare("DELETE FROM \"_externalAuths\" WHERE \"collectionRef\"=?1 AND \"recordRef\"=?2;");
        defer st.finalize();
        try st.bindText(1, col.name);
        try st.bindText(2, rid);
        _ = try st.step();
    }
    try w.commit();

    // Side effects AFTER commit. Best-effort file removal: the row is already gone and the
    // request must succeed, but a silent failure (e.g. transient S3 error) would orphan the
    // record's files with no signal — log so orphan accumulation is diagnosable (NO_SLOP §2.3).
    if (app.storage) |storage| storage.deleteRecord(app.io, col.name, rid) catch |e|
        std.log.warn("orphaned file cleanup failed for deleted record {s}/{s}: {s}", .{ col.name, rid, @errorName(e) });
    emitRecord(app, &rctx, ctx.allocator, w, col.name, &ex_mut, .after_delete) catch {};
    // F4: pass the deleted row's snapshot so subscribers to an owner/expression-scoped collection
    // can re-authorize the delete event (the live row is gone). The snapshot rides in the published
    // frame under a private key and is stripped before any client receives the id-only delete frame.
    realtime_ws.broadcast(app, col, .delete, rid, rt.snapshot, rt.token);
    return .{ .status = 204, .body = "" };
}

pub fn list(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    var r = try app.pool.acquireReader();
    defer app.pool.releaseReader(&r);
    var col_lease = try resolveCollection(ctx, &r);
    defer col_lease.release();
    const col = col_lease.col orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rctx = buildContext(ctx, &r, null);
    var rule_expr: ?[]const u8 = null;
    switch (policy.decide(col, .list, &rctx)) {
        .deny_locked => return forbidden(ctx),
        .allow => {},
        // Pass the list rule to `records.list` as a filter ONLY when the rule ITSELF is a
        // check-state expression (`policy.listRuleFilter`). `decide` can force `.check` purely from
        // an ability or the tenant scope (e.g. an `@public` list rule + a view ability); feeding
        // "@public" — an allow sentinel, not a boolean filter — to the filter compiler would 400.
        // The ability/tenant predicates are composed inside `records.list` regardless, so dropping
        // the rule clause here keeps the row-narrowing while avoiding the bogus filter. (#155)
        .check => rule_expr = policy.listRuleFilter(col, &rctx),
    }
    const qp = try params_mod.parse(ctx.allocator, ctx.query);
    const pg = app.pagination;

    // Mode selection + enable/disable gating (comptime-configured via App(.{ .pagination = ... })).
    // The PRESENCE of a `cursor` param (even empty = "first page") or a `limit` param signals
    // cursor-mode intent — this is what the SDK's getPage() sends. A non-empty cursor TOKEN is
    // tracked separately so the first page (empty token) skips the keyset predicate.
    const cursor_present = qp.get("cursor") != null or qp.get("limit") != null;
    const has_token = if (qp.get("cursor")) |c| c.len > 0 else false;
    const has_page_param = qp.get("page") != null or qp.get("perPage") != null;
    if (cursor_present and !pg.cursor_enabled)
        return ApiError.badRequest("Cursor pagination is disabled.").toResponse(ctx.allocator);
    if (has_page_param and !pg.offset_enabled)
        return ApiError.badRequest("Offset pagination is disabled; use `cursor`.").toResponse(ctx.allocator);
    // Cursor mode when the client opted in (cursor/limit param) OR offset is disabled. A cursor
    // param was already rejected above when cursor is disabled, so we never reach cursor mode then.
    const cursor_mode = (cursor_present or !pg.offset_enabled) and pg.cursor_enabled;

    const page = parseU32(qp.get("page"), 1);
    const perPage = parseU32(qp.get("perPage"), 30);
    const limit: ?u32 = if (qp.get("limit")) |l| (std.fmt.parseInt(u32, l, 10) catch null) else null;
    // skipTotal default: true in cursor mode (cheap), false in offset mode (unchanged behavior).
    const skip_total = parseBool(qp.get("skipTotal"), cursor_mode);

    // The STATEFUL token format mints/looks up cursor rows in `_cursorStates`, so it needs the
    // writer connection — but ONLY for the records.list call. We acquire it just around that call
    // and release it immediately after (a `errdefer` covers the error returns), so the writer lock
    // is never held across `expand`/serialize. Other modes run entirely on the pooled reader `r`.
    const need_writer = pg.cursor_token == .stateful and cursor_mode;
    const writer: ?*db.Db = if (need_writer) app.pool.acquireWriter() else null;
    var writer_held = need_writer;
    defer if (writer_held) app.pool.releaseWriter();

    const conn = writer orelse &r;

    const result = records.list(ctx.allocator, conn, col, .{
        .filter = qp.get("filter"),
        .sort = qp.get("sort"),
        // Full-text search (#157): `?search=` (alias `?q=`) composes a bound FTS5 MATCH into the
        // SAME scoped query. `?vector=` is the opt-in (-Dvector) KNN spec.
        .search = qp.get("search") orelse qp.get("q"),
        .vectorSpec = qp.get("vector"),
        .page = page,
        .perPage = perPage,
        .rule = rule_expr,
        .rctx = &rctx,
        .cursor = if (cursor_mode and has_token) qp.get("cursor") else null,
        .cursorMode = cursor_mode,
        .limit = limit,
        .skipTotal = skip_total,
        .cursorToken = pg.cursor_token,
        .signingSecret = app.jwt_secret,
        .io = app.io,
        .writer = writer,
    }) catch |e| {
        if (writer_held) {
            app.pool.releaseWriter();
            writer_held = false;
        }
        switch (e) {
            error.CursorState => return ApiError.gone("Cursor expired; re-fetch from the start.").toResponse(ctx.allocator),
            error.BadCursorSort => return ApiError.badRequest("Cursor pagination requires a sortable, visible, non-relation sort field.").toResponse(ctx.allocator),
            error.CursorSig => return ApiError.badRequest("Invalid cursor signature.").toResponse(ctx.allocator),
            error.CursorSort => return ApiError.badRequest("Cursor does not match the requested sort.").toResponse(ctx.allocator),
            error.CursorFilter => return ApiError.badRequest("Cursor does not match the requested filter.").toResponse(ctx.allocator),
            error.BadCursor => return ApiError.badRequest("Invalid cursor.").toResponse(ctx.allocator),
            error.EncryptedField => return ApiError.badRequest("Cannot filter or sort by an encrypted field.").toResponse(ctx.allocator),
            error.HiddenField => return ApiError.badRequest("Cannot filter or sort by a hidden field.").toResponse(ctx.allocator),
            error.NotSearchable => return ApiError.badRequest("This collection has no searchable fields; `search` is not supported here.").toResponse(ctx.allocator),
            error.SearchDisabled => return ApiError.badRequest("Full-text search is not enabled in this build.").toResponse(ctx.allocator),
            error.VectorDisabled => return ApiError.badRequest("Vector search is not enabled in this build.").toResponse(ctx.allocator),
            error.VectorCursorUnsupported => return ApiError.badRequest("Vector search does not support cursor pagination; use offset paging.").toResponse(ctx.allocator),
            error.BadVector => return ApiError.badRequest("Invalid vector search query.").toResponse(ctx.allocator),
            // A vector query that fails at execution surfaces as a backend runtime error (StepFailed) —
            // only knowable at query time (dims aren't in the field schema). Map it to a clean 400 ONLY
            // when a vector query was requested, so non-vector DB failures keep their 500. (The embedding
            // JSON itself is already validated up front in `vector.build`.) The SAME StepFailed covers
            // distinct operator conditions, so inspect the captured backend error (`conn.errMsg()`) to
            // avoid MISDIRECTING the operator: a MISSING pgvector extension (`type "vector" does not
            // exist`) gets an install hint, whereas a real dimension mismatch / malformed stored
            // embedding gets the softened query-error message.
            error.StepFailed => {
                if (qp.get("vector") == null) return e;
                const emsg = conn.errMsg();
                if (std.mem.indexOf(u8, emsg, "does not exist") != null and std.mem.indexOf(u8, emsg, "vector") != null)
                    return ApiError.badRequest("Vector search is unavailable: the pgvector extension is not installed on this database (run `CREATE EXTENSION vector`).").toResponse(ctx.allocator);
                return ApiError.badRequest("Invalid vector search query: the query embedding's dimension may not match the stored embeddings (or a stored embedding is malformed).").toResponse(ctx.allocator);
            },
            // Overflow/BadNumber/TooPrecise are `values.ValueError`s raised when a numeric literal
            // is malformed or out of i64 range. They reach here from two client-controlled inputs:
            // a filter/sort literal (compiler.zig binds `price=99999999999999999999` via
            // decimalToScaledInt) and a cursor boundary value (keyset.jsonToParam, same path). Both
            // are bad input, not a server fault — a 400, never a 500. (A source-level split that
            // returns the sharper "Invalid cursor." for the cursor case belongs in keyset.zig.)
            error.UnknownField, error.NotARelation, error.MultiRelationTraversal, error.BadFilter, error.BadSort, error.BadValue, error.Overflow, error.BadNumber, error.TooPrecise, error.UnexpectedToken, error.BadOperand, error.Empty, error.UnexpectedChar, error.UnterminatedString, error.TooDeep => return ApiError.badRequest("Invalid filter or sort.").toResponse(ctx.allocator),
            else => return e,
        }
    };
    // Release the writer lock immediately on success — expand/serialize below run on the reader.
    if (writer_held) {
        app.pool.releaseWriter();
        writer_held = false;
    }

    if (qp.get("expand")) |exp| if (exp.len > 0) {
        // Batch the whole page through one PageCache: the target-collection schema is parsed once
        // (not per row) and each (target,id) view decision is memoized (not re-authorized per row).
        try expand_mod.expandItems(ctx.allocator, &r, col, result.items, exp, 0, &rctx);
    };

    // `fields=` response projection: parse ONCE, apply to EACH record (never the envelope). It is a
    // pure output filter applied after expand — it can only narrow each record, never widen access.
    if (qp.get("fields")) |f| if (f.len > 0) {
        // Attacker-controlled — cap length like filter/sort (records.max_filter_len). A list can
        // return many records, so an unbounded spec amplifies parse/projection cost per item.
        if (f.len > records.max_filter_len) return ApiError.badRequest("`fields` is too long.").toResponse(ctx.allocator);
        const spec = try fields_mod.parse(ctx.allocator, f);
        for (result.items) |*item| try fields_mod.project(ctx.allocator, item, spec);
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
                .id = "",
                .name = "posts",
                .fields = &[_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }},
                // Open fixture: "@public" is the allow-all sentinel (empty "" is now LOCKED).
                .listRule = "@public",
                .viewRule = "@public",
                .createRule = "@public",
                .updateRule = "@public",
                .deleteRule = "@public",
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

test "fields= projection on view narrows a record to the listed keys" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col_param = [_]http.Param{.{ .key = "col", .value = "posts" }};
    var cctx = ctxFor(env, a, .POST, "{\"title\":\"hi\"}", &col_param);
    const cres = try create(&cctx);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, cres.body, .{});
    const rid = parsed.value.object.get("id").?.string;

    const view_params = [_]http.Param{ .{ .key = "col", .value = "posts" }, .{ .key = "id", .value = rid } };
    var vctx = http.RequestCtx{ .method = .GET, .path = "/", .query = "fields=id", .allocator = a, .app = &env.app, .params = &view_params };
    const vres = try view(&vctx);
    try std.testing.expectEqual(@as(u16, 200), vres.status);
    const pv = (try std.json.parseFromSlice(std.json.Value, a, vres.body, .{})).value;
    try std.testing.expect(pv.object.get("id") != null);
    try std.testing.expect(pv.object.get("title") == null); // narrowed away
}

test "fields= over the length cap is rejected 400 (DoS guard)" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col_param = [_]http.Param{.{ .key = "col", .value = "posts" }};
    var cctx = ctxFor(env, a, .POST, "{\"title\":\"hi\"}", &col_param);
    const cres = try create(&cctx);
    const rid = (try std.json.parseFromSlice(std.json.Value, a, cres.body, .{})).value.object.get("id").?.string;

    // A spec longer than records.max_filter_len must 400 before any parse/projection work.
    const big = try a.alloc(u8, records.max_filter_len + 1);
    @memset(big, 'a');
    const query = try std.fmt.allocPrint(a, "fields={s}", .{big});
    const view_params = [_]http.Param{ .{ .key = "col", .value = "posts" }, .{ .key = "id", .value = rid } };
    var vctx = http.RequestCtx{ .method = .GET, .path = "/", .query = query, .allocator = a, .app = &env.app, .params = &view_params };
    const vres = try view(&vctx);
    try std.testing.expectEqual(@as(u16, 400), vres.status);
}

test "fields= projection cannot widen access to an absent field" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col_param = [_]http.Param{.{ .key = "col", .value = "posts" }};
    var cctx = ctxFor(env, a, .POST, "{\"title\":\"hi\"}", &col_param);
    const cres = try create(&cctx);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, cres.body, .{});
    const rid = parsed.value.object.get("id").?.string;

    // `secret` is not a field on `posts`, so the built record never contained it. Requesting it
    // via `fields=` must NOT conjure it — projection can only remove keys, never add one.
    const view_params = [_]http.Param{ .{ .key = "col", .value = "posts" }, .{ .key = "id", .value = rid } };
    var vctx = http.RequestCtx{ .method = .GET, .path = "/", .query = "fields=id,secret", .allocator = a, .app = &env.app, .params = &view_params };
    const vres = try view(&vctx);
    try std.testing.expectEqual(@as(u16, 200), vres.status);
    const pv = (try std.json.parseFromSlice(std.json.Value, a, vres.body, .{})).value;
    try std.testing.expect(pv.object.get("id") != null);
    try std.testing.expect(pv.object.get("secret") == null); // never revealed
    try std.testing.expect(std.mem.indexOf(u8, vres.body, "secret") == null);
}

test "fields= projection on list narrows each item but keeps the envelope" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col_param = [_]http.Param{.{ .key = "col", .value = "posts" }};
    var c1 = ctxFor(env, a, .POST, "{\"title\":\"a\"}", &col_param);
    _ = try create(&c1);

    var lctx = http.RequestCtx{ .method = .GET, .path = "/", .query = "fields=title", .allocator = a, .app = &env.app, .params = &col_param };
    const res = try list(&lctx);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    const root = (try std.json.parseFromSlice(std.json.Value, a, res.body, .{})).value;
    // Envelope keys are untouched by projection.
    try std.testing.expect(root.object.get("page") != null);
    try std.testing.expect(root.object.get("perPage") != null);
    const items = root.object.get("items").?.array;
    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    const item = items.items[0];
    try std.testing.expect(item.object.get("title") != null);
    try std.testing.expect(item.object.get("id") == null); // narrowed
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
        .id = "",
        .name = name,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }},
        .listRule = listR,
        .viewRule = viewR,
        .createRule = createR,
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
        .id = "",
        .name = name,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }},
        // create/view permissive so a row can be seeded over the handler ("@public" = allow-all).
        .listRule = "@public",
        .viewRule = "@public",
        .createRule = "@public",
        .updateRule = updateR,
        .deleteRule = deleteR,
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
        .id = "",
        .name = name,
        .type = .auth,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }},
        // Open fixture for list/view ("@public"); createR is supplied per test.
        .listRule = "@public",
        .viewRule = "@public",
        .createRule = createR,
        .updateRule = "@public",
        .deleteRule = "@public",
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
// #98 — register lifecycle hooks (beforeRegister / afterRegister)
// ---------------------------------------------------------------------------

test "#98 register: beforeRegister mutates the account; afterRegister sees it persisted" {
    var env = try TestEnv.init();
    defer env.deinit();
    try seedAuth(env, "regusers", "@public");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Hook = struct {
        var before_seen: usize = 0;
        var after_seen: usize = 0;
        var after_rid: []const u8 = "";
        var after_col: []const u8 = "";
        var before_id_empty = false;
        fn before(ctx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
            before_seen += 1;
            before_id_empty = ev.record_id.len == 0; // no id yet at before_register
            if (ev.record) |r| try r.object.put(ctx.arena, "bio", .{ .string = "seeded" });
        }
        fn after(ctx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
            _ = ctx;
            after_seen += 1;
            after_rid = ev.record_id;
            after_col = ev.collection;
        }
    };
    Hook.before_seen = 0;
    Hook.after_seen = 0;
    var disp = events.Dispatch{ .auth_lifecycle = events.buildAuthLifecycleDispatcher(.{
        .beforeRegister = Hook.before,
        .afterRegister = Hook.after,
    }) };
    env.app.dispatch = &disp;
    defer env.app.dispatch = null;

    const p = [_]http.Param{.{ .key = "col", .value = "regusers" }};
    var cctx = ctxFor(env, a, .POST, "{\"email\":\"r@x.io\",\"password\":\"longenough\"}", &p);
    const res = try create(&cctx);
    try std.testing.expectEqual(@as(u16, 201), res.status);
    try std.testing.expectEqual(@as(usize, 1), Hook.before_seen);
    try std.testing.expectEqual(@as(usize, 1), Hook.after_seen);
    try std.testing.expect(Hook.before_id_empty);
    try std.testing.expect(Hook.after_rid.len > 0);
    try std.testing.expectEqualStrings("regusers", Hook.after_col);
    // The beforeRegister mutation persisted (the INSERT used the mutated data).
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"bio\":\"seeded\"") != null);
    try std.testing.expectEqual(@as(i64, 1), try countRows(env, "regusers"));
}

test "#98 register: an aborting beforeRegister blocks the account (fail closed)" {
    var env = try TestEnv.init();
    defer env.deinit();
    try seedAuth(env, "regblock", "@public");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Hook = struct {
        fn abort(ctx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
            _ = ev;
            return ctx.fail(403, "registration closed");
        }
    };
    var disp = events.Dispatch{ .auth_lifecycle = events.buildAuthLifecycleDispatcher(.{ .beforeRegister = Hook.abort }) };
    env.app.dispatch = &disp;
    defer env.app.dispatch = null;

    const p = [_]http.Param{.{ .key = "col", .value = "regblock" }};
    var cctx = ctxFor(env, a, .POST, "{\"email\":\"blocked@x.io\",\"password\":\"longenough\"}", &p);
    const res = try create(&cctx);
    try std.testing.expectEqual(@as(u16, 403), res.status);
    // Fail closed: no account row was created.
    try std.testing.expectEqual(@as(i64, 0), try countRows(env, "regblock"));
}

test "#98 register: lifecycle hook does NOT fire for a non-auth collection create" {
    var env = try TestEnv.init();
    defer env.deinit();
    // TestEnv.init seeds a base "posts" collection (createRule @public).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Hook = struct {
        var seen: usize = 0;
        fn before(ctx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
            _ = ctx;
            _ = ev;
            seen += 1;
        }
    };
    Hook.seen = 0;
    var disp = events.Dispatch{ .auth_lifecycle = events.buildAuthLifecycleDispatcher(.{ .beforeRegister = Hook.before }) };
    env.app.dispatch = &disp;
    defer env.app.dispatch = null;

    const p = [_]http.Param{.{ .key = "col", .value = "posts" }};
    var cctx = ctxFor(env, a, .POST, "{\"title\":\"hi\"}", &p);
    const res = try create(&cctx);
    try std.testing.expectEqual(@as(u16, 201), res.status);
    try std.testing.expectEqual(@as(usize, 0), Hook.seen);
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
        .id = "",
        .name = name,
        .fields = &[_]schema.Field{
            .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
            .{ .id = "f2", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } },
            .{ .id = "f3", .name = "ratio", .options = .{ .number = .{ .mode = .float } } },
            .{ .id = "f4", .name = "flag", .options = .{ .bool = .{} } },
            .{ .id = "f5", .name = "tags", .options = .{ .select = .{ .values = &.{ "x", "y" }, .maxSelect = 3 } } },
            .{ .id = "f6", .name = "photos", .options = .{ .file = .{ .maxSelect = 3 } } },
        },
        // Open fixture ("@public" allow-all; empty "" is now LOCKED).
        .listRule = "@public",
        .viewRule = "@public",
        .createRule = "@public",
        .updateRule = "@public",
        .deleteRule = "@public",
    });
}

fn formCtx(env: *TestEnv, a: std.mem.Allocator, m: http.Method, fields: std.json.ObjectMap, files: []const http.UploadedFile, params: []const http.Param) http.RequestCtx {
    return .{
        .method = m,
        .path = "/",
        .body = "",
        .allocator = a,
        .app = &env.app,
        .params = params,
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

// ---------------------------------------------------------------------------
// A2 Task 5 (KEYSTONE): a `before_create` hook runs INSIDE the triggering
// write's transaction. A hook that issues a side-write and then returns an
// error must roll BOTH writes back — neither the primary row nor the hook's
// side-write may survive. Under the pre-Task-5 ordering the before-hook ran
// before the handler opened a transaction, so the side-write autocommitted and
// the `audit` row survived (this test FAILS there) — proof the abort is atomic.
// ---------------------------------------------------------------------------

fn auditThenRejectHook(ctx: *Ctx, ev: *events.RecordEvent) anyerror!void {
    if (ev.phase != .before_create) return;
    if (!std.mem.eql(u8, ev.collection, "posts")) return; // act only on the primary write
    // Side-write into `audit` on the hook's IN-TRANSACTION connection (ctx.bound_conn).
    // We call records.create directly with ev.arena rather than ctx.records().create — the
    // latter would allocate the throwaway record on app.allocator and trip the test's
    // leak detector; the connection (and thus the shared transaction) is identical.
    const conn = ctx.bound_conn.?;
    const acol = (try collections.get(ev.arena, conn, "audit")) orelse return error.AuditMissing;
    var obj: std.json.ObjectMap = .empty;
    try obj.put(ev.arena, "title", .{ .string = "audit-side-write" });
    _ = try records.create(ev.arena, ctx.app.io, conn, acol, .{ .object = obj });
    return error.HookRejected;
}

fn countRows(env: *TestEnv, table: []const u8) !i64 {
    var r = try env.pool.acquireReader();
    defer env.pool.releaseReader(&r);
    const sql = try std.fmt.allocPrintSentinel(std.testing.allocator, "SELECT COUNT(*) FROM \"{s}\";", .{table}, 0);
    defer std.testing.allocator.free(sql);
    var st = try r.prepare(sql);
    defer st.finalize();
    _ = try st.step();
    return st.columnInt(0);
}

test "before-hook side-write rolls back with the triggering write on hook error" {
    var env = try TestEnv.init();
    defer env.deinit();
    // A second collection the hook writes into.
    try seedRuled(env, "audit", "@public", "@public", "@public");

    const disp = events.Dispatch{ .record = auditThenRejectHook };
    env.app.dispatch = &disp;
    defer env.app.dispatch = null;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col_param = [_]http.Param{.{ .key = "col", .value = "posts" }};
    var cctx = ctxFor(env, a, .POST, "{\"title\":\"hi\"}", &col_param);
    const res = try create(&cctx);

    // The hook rejected the write -> 400, and BOTH writes rolled back atomically.
    try std.testing.expectEqual(@as(u16, 400), res.status);
    try std.testing.expectEqual(@as(i64, 0), try countRows(env, "posts"));
    try std.testing.expectEqual(@as(i64, 0), try countRows(env, "audit"));
}

// ---- Tenancy: update pre-authorization (reviewer MINOR 1, #156) -------------

const TenantHooks = struct {
    var before_update_calls: usize = 0;
    fn countBeforeUpdate(ctx: *Ctx, ev: *events.RecordEvent) anyerror!void {
        _ = ctx;
        if (ev.phase == .before_update) before_update_calls += 1;
    }
};

test "update pre-authorizes tenant ownership BEFORE the before_update hook fires (#156)" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(dir);
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}/t.db", .{dir}, 0);
    defer gpa.free(path);
    var pool = try db.Pool.init(gpa, std.testing.io, path);
    defer pool.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Schema + seed data.
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try migrations.run(w);
        _ = try collections.create(a, std.testing.io, w, .{ .id = "", .name = "users", .type = .auth, .fields = &.{} });
        const users_col = (try collections.get(a, w, "users")).?;
        var ud: std.json.ObjectMap = .empty;
        try ud.put(a, "email", .{ .string = "u1@x.io" });
        try ud.put(a, "password", .{ .string = "longenough" });
        const prepared = try auth.applyCreate(std.testing.io, a, .{ .object = ud }, users_col.options.auth.minPasswordLength);
        _ = try records.create(a, std.testing.io, w, users_col, prepared);
        _ = try collections.create(a, std.testing.io, w, .{
            .id = "",
            .name = "projects",
            .fields = &[_]schema.Field{
                .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
                .{ .id = "f2", .name = "account", .options = .{ .text = .{} } },
            },
            .createRule = "@public",
            .updateRule = "@public",
            .viewRule = "@public",
            .options = .{ .tenant_field = "account" },
        });
        try w.exec("INSERT INTO projects (id,created,updated,title,account) VALUES ('rA','t','t','a','accA'),('rB','t','t','b','accB');");
    }

    // The user's id + tokenKey, then an active membership of u1 in accA.
    var u_id: []const u8 = "";
    var u_tk: []const u8 = "";
    {
        var r = try pool.acquireReader();
        defer pool.releaseReader(&r);
        var st = try r.prepare("SELECT id, tokenKey FROM users WHERE email='u1@x.io';");
        defer st.finalize();
        _ = try st.step();
        u_id = try a.dupe(u8, st.columnText(0));
        u_tk = try a.dupe(u8, st.columnText(1));
    }
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        var ins = try w.prepare("INSERT INTO _memberships (id,created,updated,account,user_collection,user,role,status) VALUES ('m1','','','accA','users',?1,'owner','active');");
        defer ins.finalize();
        try ins.bindText(1, u_id);
        _ = try ins.step();
    }

    TenantHooks.before_update_calls = 0;
    const dispatch = events.Dispatch{ .record = events.buildRecordDispatcher(.{ .projects = .{ .beforeUpdate = TenantHooks.countBeforeUpdate } }) };
    var app = app_mod.App{
        .allocator = gpa,
        .io = std.testing.io,
        .pool = &pool,
        .dispatch = &dispatch,
        .tenancy = .{ .enabled = true, .resolver = .header, .auth_collection = "users" },
    };

    // Mint a session token for u1.
    var mintctx = http.RequestCtx{ .method = .POST, .path = "/", .allocator = a, .app = &app };
    const tok = blk: {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        break :blk try api_auth.mintToken(&mintctx, w, "users", u_id, u_tk, .auth, 100000, "");
    };
    const bearer = try std.fmt.allocPrint(a, "Bearer {s}", .{tok});
    const hdrs = [_]http.Param{.{ .key = "x-account-id", .value = "accA" }};

    // Cross-tenant PATCH (accB's row) -> 404, and the before_update hook MUST NOT have fired.
    {
        const params = [_]http.Param{ .{ .key = "col", .value = "projects" }, .{ .key = "id", .value = "rB" } };
        var uctx = http.RequestCtx{ .method = .PATCH, .path = "/", .body = "{\"title\":\"hax\"}", .allocator = a, .app = &app, .params = &params, .authorization = bearer, .headers = &hdrs };
        const res = try update(&uctx);
        try std.testing.expectEqual(@as(u16, 404), res.status);
        try std.testing.expectEqual(@as(usize, 0), TenantHooks.before_update_calls);
    }
    // In-tenant PATCH (accA's row) -> 200, and the hook DID fire (proves the probe permits legit updates).
    {
        const params = [_]http.Param{ .{ .key = "col", .value = "projects" }, .{ .key = "id", .value = "rA" } };
        var uctx = http.RequestCtx{ .method = .PATCH, .path = "/", .body = "{\"title\":\"ok\"}", .allocator = a, .app = &app, .params = &params, .authorization = bearer, .headers = &hdrs };
        const res = try update(&uctx);
        try std.testing.expectEqual(@as(u16, 200), res.status);
        try std.testing.expectEqual(@as(usize, 1), TenantHooks.before_update_calls);
    }
}

// ---- F1: self-service password change via PATCH /records (spec §F1) -------

/// Minimal fixture for the F1 tests: an auth collection `users` with
/// `updateRule = "@request.auth.id = id"` (owner-only, matching the brief), one seeded
/// user, and helpers to mint owner/superuser bearer tokens and read columns back directly.
const F1Env = struct {
    tmp: std.testing.TmpDir,
    pool: db.Pool,
    app: app_mod.App,
    arena: std.heap.ArenaAllocator,
    user_id: []const u8 = "",

    fn init(dispatch: ?*const events.Dispatch) !*F1Env {
        return F1Env.initWithMinLen(dispatch, 8);
    }

    /// Same as `init`, but lets a test override the `users` collection's
    /// `minPasswordLength` (e.g. 0, to exercise the min_len==0 password-change gate).
    fn initWithMinLen(dispatch: ?*const events.Dispatch, min_len: u8) !*F1Env {
        const env = try std.testing.allocator.create(F1Env);
        env.tmp = std.testing.tmpDir(.{});
        const dir = try env.tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(dir);
        const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/f1.db", .{dir}, 0);
        defer std.testing.allocator.free(path);
        env.pool = try db.Pool.init(std.testing.allocator, std.testing.io, path);
        env.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const a = env.arena.allocator();
        {
            const w = env.pool.acquireWriter();
            defer env.pool.releaseWriter();
            try migrations.run(w);
            _ = try collections.create(a, std.testing.io, w, .{
                .id = "",
                .name = "users",
                .type = .auth,
                .fields = &.{},
                .listRule = "@public",
                .viewRule = "@public",
                .createRule = "@public",
                .updateRule = "@request.auth.id = id",
                .deleteRule = "@public",
                .options = .{ .auth = .{ .minPasswordLength = min_len } },
            });
        }
        env.app = .{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = &env.pool, .dispatch = dispatch };
        env.user_id = "";
        return env;
    }

    fn deinit(env: *F1Env) void {
        env.arena.deinit();
        env.pool.deinit();
        env.tmp.cleanup();
        std.testing.allocator.destroy(env);
    }

    /// Create a user (password optional — pass "" for a passwordless target) and stash its id.
    fn createUser(env: *F1Env, email: []const u8, password: []const u8) ![]const u8 {
        const a = env.arena.allocator();
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const col = (try collections.get(a, w, "users")).?;
        var ud: std.json.ObjectMap = .empty;
        try ud.put(a, "email", .{ .string = email });
        if (password.len > 0) try ud.put(a, "password", .{ .string = password });
        const prepared = try auth.applyProvision(std.testing.io, a, .{ .object = ud }, col.options.auth.minPasswordLength);
        const rec = try records.create(a, std.testing.io, w, col, prepared);
        const rid = try a.dupe(u8, rec.object.get("id").?.string);
        env.user_id = rid;
        return rid;
    }

    /// Mint an owner (regular `.auth`) bearer for `rid`, reading its current tokenKey.
    fn mintOwnerBearer(env: *F1Env, rid: []const u8) ![]const u8 {
        const a = env.arena.allocator();
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const tk = (try api_auth.tokenKeyFor(a, w, "users", rid)).?;
        var mintctx = http.RequestCtx{ .method = .POST, .path = "/", .allocator = a, .app = &env.app };
        const tok = try api_auth.mintToken(&mintctx, w, "users", rid, tk, .auth, 100000, "");
        return try std.fmt.allocPrint(a, "Bearer {s}", .{tok});
    }

    /// Mint a `_superusers` bearer (raw INSERT + mintToken; no register/login endpoint needed).
    fn mintSuperuserBearer(env: *F1Env) ![]const u8 {
        const a = env.arena.allocator();
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try w.exec("INSERT INTO \"_superusers\" (\"id\",\"created\",\"updated\",\"email\",\"username\",\"passwordHash\",\"tokenKey\",\"verified\") VALUES ('su1','','','admin@x.io','','','sutk',1);");
        var mintctx = http.RequestCtx{ .method = .POST, .path = "/", .allocator = a, .app = &env.app };
        const tok = try api_auth.mintToken(&mintctx, w, "_superusers", "su1", "sutk", .auth, 100000, "");
        return try std.fmt.allocPrint(a, "Bearer {s}", .{tok});
    }

    fn passwordHash(env: *F1Env, rid: []const u8) ![]const u8 {
        const a = env.arena.allocator();
        var r = try env.pool.acquireReader();
        defer env.pool.releaseReader(&r);
        return (try api_auth.passwordHashFor(a, &r, "users", rid)) orelse "";
    }

    fn tokenKey(env: *F1Env, rid: []const u8) ![]const u8 {
        const a = env.arena.allocator();
        var r = try env.pool.acquireReader();
        defer env.pool.releaseReader(&r);
        return (try api_auth.tokenKeyFor(a, &r, "users", rid)).?;
    }

    fn sessionCountFor(env: *F1Env, rid: []const u8) !i64 {
        var r = try env.pool.acquireReader();
        defer env.pool.releaseReader(&r);
        var st = try r.prepare("SELECT COUNT(*) FROM \"_sessions\" WHERE \"collectionRef\" = 'users' AND \"recordRef\" = ?1;");
        defer st.finalize();
        try st.bindText(1, rid);
        _ = try st.step();
        return st.columnInt(0);
    }

    fn sessionIds(env: *F1Env, rid: []const u8) ![][]const u8 {
        const a = env.arena.allocator();
        var r = try env.pool.acquireReader();
        defer env.pool.releaseReader(&r);
        var st = try r.prepare("SELECT \"id\" FROM \"_sessions\" WHERE \"collectionRef\" = 'users' AND \"recordRef\" = ?1;");
        defer st.finalize();
        try st.bindText(1, rid);
        var out: std.ArrayList([]const u8) = .empty;
        while (try st.step()) try out.append(a, try a.dupe(u8, st.columnText(0)));
        return out.toOwnedSlice(a);
    }
};

fn patchCtx(env: *F1Env, a: std.mem.Allocator, rid: []const u8, bearer: []const u8, body: []const u8) http.RequestCtx {
    const params = [_]http.Param{ .{ .key = "col", .value = "users" }, .{ .key = "id", .value = rid } };
    const dup_params = a.dupe(http.Param, &params) catch unreachable;
    return .{ .method = .PATCH, .path = "/", .body = body, .allocator = a, .app = &env.app, .params = dup_params, .authorization = bearer };
}

test "F1 PATCH+password: owner with correct oldPassword -> 200, hash replaced, tokenKey rotated, fresh cookies" {
    var env = try F1Env.init(null);
    defer env.deinit();
    const a = env.arena.allocator();
    const rid = try env.createUser("owner@x.io", "oldpassword1");
    const bearer = try env.mintOwnerBearer(rid);
    const old_hash = try env.passwordHash(rid);
    const old_tk = try env.tokenKey(rid);

    var uctx = patchCtx(env, a, rid, bearer, "{\"password\":\"newpassword1\",\"oldPassword\":\"oldpassword1\"}");
    const res = try update(&uctx);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqual(@as(usize, 2), res.cookies.len);
    for (res.cookies) |c| try std.testing.expect(c.value.len > 0);

    const new_hash = try env.passwordHash(rid);
    const new_tk = try env.tokenKey(rid);
    try std.testing.expect(!std.mem.eql(u8, old_hash, new_hash));
    try std.testing.expect(!std.mem.eql(u8, old_tk, new_tk));

    try std.testing.expect(std.mem.indexOf(u8, res.body, "passwordHash") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "tokenKey") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "oldPassword") == null);

    // The OLD bearer no longer authenticates: tokenKey rotated invalidates the signature check.
    var r = try env.pool.acquireReader();
    defer env.pool.releaseReader(&r);
    const old_tok = uctx.bearerToken().?;
    try std.testing.expect(auth.verifyToken(a, &env.app, &r, old_tok) == null);
}

test "F1 PATCH+password: wrong and missing oldPassword -> login-identical 400, nothing changed" {
    var env = try F1Env.init(null);
    defer env.deinit();
    const a = env.arena.allocator();
    const rid = try env.createUser("owner2@x.io", "oldpassword1");
    const bearer = try env.mintOwnerBearer(rid);
    const before_hash = try env.passwordHash(rid);

    var wctx = patchCtx(env, a, rid, bearer, "{\"password\":\"newpassword1\",\"oldPassword\":\"wrongpassword\"}");
    const wres = try update(&wctx);
    try std.testing.expectEqual(@as(u16, 400), wres.status);
    try std.testing.expect(std.mem.indexOf(u8, wres.body, "Invalid credentials.") != null);
    try std.testing.expectEqual(@as(usize, 0), wres.cookies.len);

    var mctx = patchCtx(env, a, rid, bearer, "{\"password\":\"newpassword1\"}");
    const mres = try update(&mctx);
    try std.testing.expectEqual(@as(u16, 400), mres.status);
    try std.testing.expect(std.mem.indexOf(u8, mres.body, "Invalid credentials.") != null);
    try std.testing.expectEqual(@as(usize, 0), mres.cookies.len);

    try std.testing.expectEqualStrings(before_hash, try env.passwordHash(rid));
}

test "F1 PATCH+password: superuser bypasses oldPassword; target's sessions all die; NO re-issue cookies" {
    var env = try F1Env.init(null);
    defer env.deinit();
    const a = env.arena.allocator();
    const rid = try env.createUser("target@x.io", "originalpw1");
    const su_bearer = try env.mintSuperuserBearer();

    var uctx = patchCtx(env, a, rid, su_bearer, "{\"password\":\"adminreset1\"}");
    const res = try update(&uctx);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqual(@as(usize, 0), res.cookies.len);

    // The user's old tokenKey is gone (rotated); a fresh owner bearer minted with the NEW
    // tokenKey works, proving the new password/hash landed.
    const new_hash = try env.passwordHash(rid);
    try std.testing.expect(crypto.verifyPassword(std.testing.io, a, new_hash, "adminreset1"));
}

test "F1 PATCH+password: passwordless target -> 400 for non-superuser (no password bootstrap via PATCH)" {
    var env = try F1Env.init(null);
    defer env.deinit();
    const a = env.arena.allocator();
    const rid = try env.createUser("nopass@x.io", ""); // no password field at all
    // The target has no session/tokenKey-based bearer (never logged in); mint one anyway via the
    // stored (empty) tokenKey — required only to reach the update() handler as "self".
    const bearer = try env.mintOwnerBearer(rid);

    var uctx = patchCtx(env, a, rid, bearer, "{\"password\":\"newpassword1\",\"oldPassword\":\"anything12\"}");
    const res = try update(&uctx);
    try std.testing.expectEqual(@as(u16, 400), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "Invalid credentials.") != null);
}

const PwChangeHooks = struct {
    var before_calls: usize = 0;
    fn abortBeforePasswordChange(ctx: *Ctx, ev: *events.AuthLifecycleEvent) anyerror!void {
        _ = ev;
        before_calls += 1;
        return ctx.fail(403, "password change blocked by policy");
    }
};

test "F1 PATCH+password: aborting beforePasswordChange leaves password + tokenKey unchanged" {
    PwChangeHooks.before_calls = 0;
    const dispatch = events.Dispatch{ .auth_lifecycle = events.buildAuthLifecycleDispatcher(.{ .beforePasswordChange = PwChangeHooks.abortBeforePasswordChange }) };
    var env = try F1Env.init(&dispatch);
    defer env.deinit();
    const a = env.arena.allocator();
    const rid = try env.createUser("abort@x.io", "oldpassword1");
    const bearer = try env.mintOwnerBearer(rid);
    const before_hash = try env.passwordHash(rid);
    const before_tk = try env.tokenKey(rid);

    var uctx = patchCtx(env, a, rid, bearer, "{\"password\":\"newpassword1\",\"oldPassword\":\"oldpassword1\"}");
    const res = try update(&uctx);
    try std.testing.expectEqual(@as(u16, 403), res.status);
    try std.testing.expectEqual(@as(usize, 1), PwChangeHooks.before_calls);

    try std.testing.expectEqualStrings(before_hash, try env.passwordHash(rid));
    try std.testing.expectEqualStrings(before_tk, try env.tokenKey(rid));

    // Old bearer is still valid (tokenKey wasn't rotated — the txn rolled back).
    var r = try env.pool.acquireReader();
    defer env.pool.releaseReader(&r);
    const old_tok = uctx.bearerToken().?;
    try std.testing.expect(auth.verifyToken(a, &env.app, &r, old_tok) != null);
}

test "F1 PATCH+password: .table mode purges old rows in-txn and re-issues exactly one fresh row" {
    var env = try F1Env.init(null);
    defer env.deinit();
    env.app.session_store = .table;
    const a = env.arena.allocator();
    const rid = try env.createUser("tablemode@x.io", "oldpassword1");

    // Log in twice (two `_sessions` rows) via issueSession directly (owner tokenKey read fresh
    // each time — password unchanged between the two logins).
    var lctx1 = http.RequestCtx{ .method = .POST, .path = "/", .allocator = a, .app = &env.app };
    var lctx2 = http.RequestCtx{ .method = .POST, .path = "/", .allocator = a, .app = &env.app };
    const issued1 = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk try api_auth.issueSessionNoEmit(&lctx1, w, "users", rid);
    };
    const issued2 = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        break :blk try api_auth.issueSessionNoEmit(&lctx2, w, "users", rid);
    };
    _ = issued1;
    try std.testing.expectEqual(@as(i64, 2), try env.sessionCountFor(rid));

    const bearer = try std.fmt.allocPrint(a, "Bearer {s}", .{issued2.token});
    var uctx = patchCtx(env, a, rid, bearer, "{\"password\":\"newpassword1\",\"oldPassword\":\"oldpassword1\"}");
    const res = try update(&uctx);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqual(@as(usize, 2), res.cookies.len);

    try std.testing.expectEqual(@as(i64, 1), try env.sessionCountFor(rid));
    const ids = try env.sessionIds(rid);
    try std.testing.expectEqual(@as(usize, 1), ids.len);

    var new_token: []const u8 = "";
    for (res.cookies) |c| if (std.mem.eql(u8, c.name, "zb_auth")) {
        new_token = c.value;
    };
    try std.testing.expect(new_token.len > 0);
    const claims = try jwt.peekClaims(a, new_token);
    try std.testing.expectEqualStrings(ids[0], claims.sid.?);
}

test "F1 PATCH+password: 'pwchange' rate limit 429s BEFORE any argon2/verify work" {
    var env = try F1Env.init(null);
    defer env.deinit();
    var rl = ratelimit.RateLimiter.init(std.testing.allocator, 1, 3600);
    defer rl.deinit();
    env.app.rate_limiter = &rl;
    const a = env.arena.allocator();
    const rid = try env.createUser("limited@x.io", "oldpassword1");
    const bearer = try env.mintOwnerBearer(rid);

    // First PATCH (wrong oldPassword) consumes the single pwchange budget slot -> 400.
    var c1 = patchCtx(env, a, rid, bearer, "{\"password\":\"newpassword1\",\"oldPassword\":\"wrongpassword\"}");
    const r1 = try update(&c1);
    try std.testing.expectEqual(@as(u16, 400), r1.status);

    // Second PATCH (even with the CORRECT oldPassword) -> 429, proving the limiter fires
    // before argon2 verification runs (a correct password would otherwise succeed).
    var c2 = patchCtx(env, a, rid, bearer, "{\"password\":\"newpassword1\",\"oldPassword\":\"oldpassword1\"}");
    const r2 = try update(&c2);
    try std.testing.expectEqual(@as(u16, 429), r2.status);
    try std.testing.expect(std.mem.indexOf(u8, r2.body, "Too many requests") != null);

    // A non-password PATCH on the same collection/record is NOT limited (scope isolation:
    // "pwchange" is a distinct bucket from any other scope).
    var c3 = patchCtx(env, a, rid, bearer, "{\"email\":\"limited2@x.io\"}");
    const r3 = try update(&c3);
    try std.testing.expectEqual(@as(u16, 200), r3.status);
}

// Security fast-follow (Task 2 review, Low): with minPasswordLength == 0, applyUpdate
// accepts an empty-string password (`0 < 0` is false), so peekPasswordFields must still
// flag `pw_change` on ANY present string password — including "" — or a {"password":""}
// PATCH bypasses the whole gate (rate limit, oldPassword verify, hook, session purge)
// while still resetting the password and rotating tokenKey.
test "F1 PATCH+password: minPasswordLength=0 still gates an empty-string password change" {
    var env = try F1Env.initWithMinLen(null, 0);
    defer env.deinit();
    const a = env.arena.allocator();
    const rid = try env.createUser("zerolen@x.io", "oldpassword1");
    const bearer = try env.mintOwnerBearer(rid);
    const before_hash = try env.passwordHash(rid);
    const before_tk = try env.tokenKey(rid);

    // Without oldPassword: the gate must fire (pw_change=true) and reject with the
    // login-identical 400, leaving the password/tokenKey untouched.
    var uctx = patchCtx(env, a, rid, bearer, "{\"password\":\"\"}");
    const res = try update(&uctx);
    try std.testing.expectEqual(@as(u16, 400), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "Invalid credentials.") != null);
    try std.testing.expectEqual(@as(usize, 0), res.cookies.len);
    try std.testing.expectEqualStrings(before_hash, try env.passwordHash(rid));
    try std.testing.expectEqualStrings(before_tk, try env.tokenKey(rid));

    // With the correct oldPassword, the gate passes and applyUpdate's min_len==0 check
    // (harmlessly) accepts the empty password.
    var uctx2 = patchCtx(env, a, rid, bearer, "{\"password\":\"\",\"oldPassword\":\"oldpassword1\"}");
    const res2 = try update(&uctx2);
    try std.testing.expectEqual(@as(u16, 200), res2.status);
    try std.testing.expect(!std.mem.eql(u8, before_hash, try env.passwordHash(rid)));
    try std.testing.expect(!std.mem.eql(u8, before_tk, try env.tokenKey(rid)));
}
