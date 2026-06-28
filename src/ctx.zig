const std = @import("std");
const App = @import("app.zig").App;
const db = @import("db.zig");
const request = @import("request.zig");
const events = @import("events.zig");
const Data = @import("data.zig").Data;
const records_engine = @import("records.zig");
const migrations = @import("migrations.zig");
const collections = @import("collections.zig");
const schema = @import("schema.zig");
const expand_mod = @import("query/expand.zig");
const http_client = @import("http_client.zig");
const error_mod = @import("api/error.zig");
const http_mod = @import("http.zig");
const auth_helpers = @import("auth_helpers.zig");
const api_auth = @import("api/auth.zig");
const session = @import("session.zig");
const features = @import("features.zig");
const features_resolver = @import("features_resolver.zig");
const realtime_ws = @import("realtime/ws.zig");

pub const Ctx = struct {
    app: *App,
    arena: std.mem.Allocator,
    rctx: request.RequestContext = .{},
    /// Non-null inside a record hook: the hook's in-transaction connection. When set,
    /// ALL reads and writes use it (acquiring the pool writer here would deadlock).
    bound_conn: ?*db.Db = null,
    /// Lazily checked-out reader, cached for the Ctx lifetime (route/job context only).
    reader: ?events.ReaderData = null,
    /// Stashed error from ctx.fail/ctx.invalid; consumed by errorResponse(error.Handled).
    handled: ?error_mod.ApiError = null,
    /// The raw HTTP request context. Non-null for route handlers; null for job/hook contexts
    /// where there is no HTTP request. Required by `issueSession`.
    request: ?*http_mod.RequestCtx = null,

    /// The resolved identity of the authenticated principal for this request.
    /// `id` is an empty string when no auth record is present (e.g. a superuser-only
    /// token with no associated record).
    /// `collection` is the auth collection name (e.g. "users"); empty string when
    /// anonymous or when the token carries no collection claim.
    pub const User = struct {
        id: []const u8,
        is_superuser: bool,
        collection: []const u8,
    };

    /// Derive the authenticated identity from the request context.
    /// Returns null for anonymous contexts (no auth record and not a superuser).
    pub fn user(self: *Ctx) ?User {
        if (!self.rctx.is_superuser and self.rctx.auth == null) return null;
        const id: []const u8 = blk: {
            const auth_val = self.rctx.auth orelse break :blk "";
            if (auth_val != .object) break :blk "";
            const id_field = auth_val.object.get("id") orelse break :blk "";
            break :blk switch (id_field) {
                .string => |s| s,
                else => "",
            };
        };
        return .{
            .id = id,
            .is_superuser = self.rctx.is_superuser,
            .collection = self.rctx.collection,
        };
    }

    /// Mint a session for a known record via the audited seam (`.custom` method tag).
    /// Acquires the DB writer, calls `auth_helpers.issueSession`, releases the writer,
    /// and returns the signed JWT + 2 cookies.
    ///
    /// Only valid inside a route handler — panics if `request` is null (job/hook context).
    ///
    /// WARNING: this function acquires the pool writer internally. Do NOT call it while
    /// already holding the writer (e.g. inside `ctx.tx`, from a before-hook, or with a
    /// bound_conn set) — it would deadlock permanently. In those cases, call
    /// `zigbase.auth.issueSession(self.request.?, bound_conn, collection, record_id)`
    /// directly with the connection you already hold.
    ///
    /// NOTE: for full session management (clearSession, revokeAllSessions, refresh,
    /// rotate, listActiveSessions, revoke), use `ctx.auth()` — all shipped.
    pub fn issueSession(self: *Ctx, collection: []const u8, record_id: []const u8) !auth_helpers.Issued {
        const conn = self.app.pool.acquireWriter();
        defer self.app.pool.releaseWriter();
        return auth_helpers.issueSession(self.request.?, conn, collection, record_id);
    }

    /// A connection suitable for reads. Bound conn wins; else lazily check out + cache a reader.
    pub fn connForRead(self: *Ctx) !*db.Db {
        if (self.bound_conn) |c| return c;
        if (self.reader == null) {
            self.reader = .{ .app = self.app, .pool = self.app.pool, .conn = try self.app.pool.acquireReader() };
        }
        return &self.reader.?.conn;
    }

    /// Release any cached reader. Call once (the accessor/handler frame owns this via defer).
    pub fn deinit(self: *Ctx) void {
        if (self.reader) |*r| {
            r.deinit();
            self.reader = null;
        }
    }

    /// Returns a Records namespace bound to this Ctx for read operations.
    pub fn records(self: *Ctx) Records {
        return .{ .ctx = self };
    }

    /// Returns the session-management namespace (`ctx.auth()`): `clearSession` (#86),
    /// plus the #99 session verbs — `revokeAllSessions`/`refresh`/`rotate` (epoch model,
    /// always available) and the Variant B per-device `listActiveSessions`/`revoke`.
    pub fn auth(self: *Ctx) AuthApi {
        return .{ .ctx = self };
    }

    /// Returns the key→value/settings namespace (#87) bound to this Ctx.
    /// Reads use the read connection (bound conn wins); writes use the bound
    /// connection if set, else acquire/release the pool writer — deadlock-safe
    /// inside `ctx.tx`/before-hooks and self-managing on the route/job path.
    /// KV/settings are superuser-managed: they are NOT exposed publicly by
    /// default. To publish a value, write a custom route that calls these.
    pub fn kv(self: *Ctx) KeyValue {
        return .{ .ctx = self };
    }

    // -----------------------------------------------------------------------
    // Feature flags + experiments (#128/#129/#130).
    //
    // Flags are DECLARED in the `App(.{ .flags = … })` literal. The typed,
    // compile-checked accessors live on the App type (`App.flag(ctx, .name)`,
    // `App.setFlag(ctx, .name, on)`, `App.experiment(ctx, .name, subject)`) — a
    // typo'd `.name` is a compile error. The runtime escape hatches below resolve
    // by string for dynamic names; both consult the registry threaded onto
    // `app.features`. (The old v0.7 `ctx.flag("arbitrary")` KV-or-false API is
    // removed — only declared flags resolve.)
    // -----------------------------------------------------------------------

    /// Resolve a DECLARED flag's effective value: the `flag:<name>` override from
    /// `_kv` if present, else the declared default. Swallows read errors (falls back
    /// to the default) so a kill-switch check never fails the request. Used by the
    /// typed `App.flag` accessor and by `flagByName`.
    pub fn resolveDeclaredFlag(self: *Ctx, def: features.FlagDef) bool {
        const conn = self.connForRead() catch return def.default;
        const data = Data{ .app = self.app, .conn = conn, .io = self.app.io, .alloc = self.arena };
        const key = std.fmt.allocPrint(self.arena, "flag:{s}", .{def.name}) catch return def.default;
        const ov = data.kvGet(key) catch return def.default;
        const value = features_resolver.resolveFlag(ov, def);
        // Notify-only exposure seam (zero-cost when no .onFeatureExposure handler).
        events.dispatchFlagExposure(self.app, self.app.dispatch, def.name, value);
        return value;
    }

    /// Resolve a DECLARED experiment to a variant for `subject`: applies the
    /// `exp:<name>:weights` JSON override from `_kv` when valid, else declared
    /// weights, then deterministic bucketing. Used by the typed `App.experiment`
    /// accessor.
    pub fn resolveDeclaredExperiment(self: *Ctx, def: features.ExperimentDef, subject: []const u8) ![]const u8 {
        const key = try std.fmt.allocPrint(self.arena, "exp:{s}:weights", .{def.name});
        // A sticky experiment with a non-empty subject persists its first assignment, so
        // the miss path INSERTs — it needs the writer. Non-sticky resolution (and an empty
        // subject, which is never persisted) stays read-only. Reuse the bound writer inside
        // a `ctx.tx`; otherwise acquire it just for this resolve.
        const sticky = def.sticky and subject.len > 0;
        const need_writer = sticky and self.bound_conn == null;
        const conn = if (sticky)
            (self.bound_conn orelse self.app.pool.acquireWriter())
        else
            try self.connForRead();
        defer if (need_writer) self.app.pool.releaseWriter();
        const data = Data{ .app = self.app, .conn = conn, .io = self.app.io, .alloc = self.arena };
        const ov = try data.kvGet(key);
        const variant = try features_resolver.resolveExperiment(self.arena, if (sticky) conn else null, ov, def, subject);
        // Notify-only exposure seam, fired on the RESOLVED variant (after the sticky
        // lookup). Zero-cost when no .onFeatureExposure handler is registered.
        events.dispatchExperimentExposure(self.app, self.app.dispatch, def.name, subject, variant);
        return variant;
    }

    /// Write a `flag:<name>` override (`"true"`/`"false"`) into `_kv`. Used by the
    /// typed `App.setFlag` accessor (the App-side enum guarantees `name` is declared).
    pub fn writeFlagOverride(self: *Ctx, name: []const u8, enabled: bool) !void {
        const key = try std.fmt.allocPrint(self.arena, "flag:{s}", .{name});
        try self.kv().set(key, if (enabled) "true" else "false");
        // Signal-only realtime push: tell subscribers to re-GET /api/state. No-op when
        // the reactor isn't running (tests/CLI).
        realtime_ws.broadcastFeaturesChanged();
    }

    /// Runtime escape hatch: resolve a flag by string name. Returns `null` when the
    /// name is not DECLARED (or no registry is wired), else its resolved value. Use
    /// the typed `App.flag(ctx, .name)` whenever the name is known at compile time.
    pub fn flagByName(self: *Ctx, name: []const u8) ?bool {
        const reg = self.app.features orelse return null;
        for (reg.flags) |def| {
            if (std.mem.eql(u8, def.name, name)) return self.resolveDeclaredFlag(def);
        }
        return null;
    }

    /// Runtime escape hatch: set a flag override by string name. Errors with
    /// `error.UndeclaredFlag` when the name is not declared (or no registry is
    /// wired). The typed `App.setFlag(ctx, .name, on)` is the compile-checked path.
    pub fn setFlag(self: *Ctx, name: []const u8, enabled: bool) !void {
        const reg = self.app.features orelse return error.UndeclaredFlag;
        for (reg.flags) |def| {
            if (std.mem.eql(u8, def.name, name)) return self.writeFlagOverride(name, enabled);
        }
        return error.UndeclaredFlag;
    }

    /// Returns the feature-resolution namespace (`ctx.flags()`): `resolveAll(subject)`
    /// resolves every declared flag + experiment in one batched `_kv` scan (the shape
    /// the public `/api/state` projection serves).
    pub fn flags(self: *Ctx) FlagsApi {
        return .{ .ctx = self };
    }

    /// Run `f` inside an IMMEDIATE transaction on the writer connection.
    /// All Records writes inside `f` reuse the bound connection — no deadlock.
    /// Returns error.NestedTransaction when called from an already-bound Ctx.
    pub fn tx(self: *Ctx, comptime T: type, f: *const fn (t: *Tx) anyerror!T) !T {
        if (self.bound_conn != null) return error.NestedTransaction;
        const conn = self.app.pool.acquireWriter();
        defer self.app.pool.releaseWriter();
        try conn.beginImmediate();
        var t = Tx{ .inner = .{ .app = self.app, .arena = self.arena, .rctx = self.rctx, .bound_conn = conn } };
        defer t.inner.deinit();
        const result = f(&t) catch |e| {
            conn.rollback() catch {};
            return e;
        };
        conn.commit() catch |e| {
            conn.rollback() catch {};
            return e;
        };
        return result;
    }

    /// Returns an outbound HTTP client bound to this Ctx's arena and the app's io.
    pub fn http(self: *Ctx) http_client.HttpClient {
        return .{ .alloc = self.arena, .io = self.app.io };
    }

    /// Sentinel error type returned by fail/invalid so callers can propagate.
    pub const FailError = error{Handled};

    /// Stash a custom status+message error and return error.Handled for propagation.
    pub fn fail(self: *Ctx, status: u16, message: []const u8) FailError {
        self.handled = .{ .status = status, .message = message };
        return error.Handled;
    }

    /// Stash a validation error (400 with field details) and return error.Handled.
    pub fn invalid(self: *Ctx, fields: []const error_mod.FieldError) FailError {
        self.handled = error_mod.ApiError.validation(fields);
        return error.Handled;
    }

    /// Map any error to an http.Response. error.Handled renders the stashed ApiError;
    /// known errors map to canonical status codes; anything else → 500 (no detail leaked).
    pub fn errorResponse(self: *Ctx, err: anyerror) http_mod.Response {
        const ae: error_mod.ApiError = switch (err) {
            error.Handled => self.handled orelse error_mod.ApiError.internal(),
            error.NotFound => error_mod.ApiError.notFound(),
            error.BadRequest => error_mod.ApiError.badRequest("Bad request."),
            error.Conflict => error_mod.ApiError.conflict("Conflict."),
            error.Forbidden => error_mod.ApiError.forbidden(),
            error.Unauthorized => error_mod.ApiError.unauthorized(),
            else => error_mod.ApiError.internal(),
        };
        return ae.toResponse(self.arena) catch
            error_mod.ApiError.internal().toResponse(self.arena) catch unreachable;
    }
};

pub const GetOptions = struct { expand: ?[]const u8 = null };
pub const ListOptions = struct {
    filter: ?[]const u8 = null,
    sort: ?[]const u8 = null,
    page: u32 = 1,
    perPage: u32 = 30,
    limit: ?u32 = null,
    cursor: ?[]const u8 = null,
    expand: ?[]const u8 = null,
};

pub const Records = struct {
    ctx: *Ctx,

    fn dataRead(self: Records) !Data {
        return .{ .app = self.ctx.app, .conn = try self.ctx.connForRead(), .io = self.ctx.app.io, .alloc = self.ctx.arena };
    }

    pub fn get(self: Records, collection: []const u8, id: []const u8, opts: GetOptions) !?std.json.Value {
        const data = try self.dataRead();
        var rec = (try data.findById(collection, id)) orelse return null;
        try self.applyExpand(collection, &rec, opts.expand);
        return rec;
    }

    pub fn list(self: Records, collection: []const u8, opts: ListOptions) !records_engine.ListResult {
        const q = records_engine.ListQuery{
            .filter = opts.filter,
            .sort = opts.sort,
            .page = opts.page,
            .perPage = opts.perPage,
            .limit = opts.limit,
            .cursor = opts.cursor,
            .rctx = &self.ctx.rctx,
            .io = self.ctx.app.io,
        };
        const result = try (try self.dataRead()).list(collection, q);
        if (opts.expand) |spec| if (spec.len > 0) {
            const conn = try self.ctx.connForRead();
            if (try collections.get(self.ctx.arena, conn, collection)) |col| {
                for (result.items) |*item| {
                    try expand_mod.expand(self.ctx.arena, conn, col, item, spec, 0, &self.ctx.rctx);
                }
            }
        };
        return result;
    }

    pub fn create(self: Records, collection: []const u8, value: std.json.Value) !std.json.Value {
        if (self.ctx.bound_conn) |c|
            return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena }).create(collection, value);
        const c = self.ctx.app.pool.acquireWriter();
        defer self.ctx.app.pool.releaseWriter();
        return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena }).create(collection, value);
    }

    pub fn update(self: Records, collection: []const u8, id: []const u8, value: std.json.Value) !?std.json.Value {
        if (self.ctx.bound_conn) |c|
            return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena }).update(collection, id, value);
        const c = self.ctx.app.pool.acquireWriter();
        defer self.ctx.app.pool.releaseWriter();
        return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena }).update(collection, id, value);
    }

    pub fn delete(self: Records, collection: []const u8, id: []const u8) !bool {
        if (self.ctx.bound_conn) |c|
            return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena }).delete(collection, id);
        const c = self.ctx.app.pool.acquireWriter();
        defer self.ctx.app.pool.releaseWriter();
        return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena }).delete(collection, id);
    }

    /// Resolve the collection and run expand on `rec` in-place.
    /// CRUD operations in Records bypass collection rules (matching Data behaviour);
    /// expand applies the *target* collection's viewRule under the Ctx identity.
    /// A job ctx with rctx = .{} gets the anonymous view.
    fn applyExpand(self: Records, collection: []const u8, rec: *std.json.Value, spec: ?[]const u8) !void {
        const s = spec orelse return;
        if (s.len == 0) return;
        const conn = try self.ctx.connForRead();
        const col = (try collections.get(self.ctx.arena, conn, collection)) orelse return;
        try expand_mod.expand(self.ctx.arena, conn, col, rec, s, 0, &self.ctx.rctx);
    }
};

/// Session-management namespace (`ctx.auth()`). Full shipped surface (PRs #111/#112):
///
/// - `clearSession`       — return the cleared `zb_auth`+`zb_csrf` cookies; a logout
///                          handler is a single `return .{ .cookies = try ctx.auth().clearSession() }`.
/// - `revokeAllSessions`  — bump the principal's `token_epoch` so every outstanding
///                          token stops verifying immediately; in table mode also wipes
///                          the principal's `_sessions` rows ("log out everywhere").
/// - `refresh`            — re-mint a session token (new `exp`, same epoch, sliding
///                          window); in table mode rotates the current device's row.
///                          Route context only (requires `ctx.request`).
/// - `rotate`             — bump epoch + mint a fresh token in one step ("rotate
///                          credentials, keep this device, kill all others"); table mode
///                          atomically replaces the device row. Route context only.
/// - `listActiveSessions` — list the principal's active (unexpired) sessions, newest
///                          first, with `is_current` marked. Requires
///                          `session_store = .table`; returns `error.SessionStoreNotEnabled`
///                          in the default `.epoch` mode.
/// - `revoke(id)`         — revoke ONE session by id ("log out this device"); owner-or-
///                          superuser only, collapsing non-owner and absent-id into
///                          `error.NotFound`. Requires `session_store = .table`.
pub const AuthApi = struct {
    ctx: *Ctx,

    /// One active session row (Variant B), as returned by `listActiveSessions`. `is_current`
    /// marks the session this request is authenticated with.
    pub const Session = struct {
        id: []const u8,
        created: []const u8,
        last_seen: []const u8,
        user_agent: []const u8,
        ip: []const u8,
        is_current: bool,
    };

    /// Clear the `zb_auth` + `zb_csrf` session cookies (logout). Returns arena-owned
    /// cookies that slot straight into a handler's `Response.cookies`:
    ///   return .{ .status = 204, .body = "", .cookies = try ctx.auth().clearSession() };
    pub fn clearSession(self: AuthApi) ![]const http_mod.Cookie {
        const cleared = session.clearedCookies(self.ctx.app.cookie_secure);
        return self.ctx.arena.dupe(http_mod.Cookie, &cleared);
    }

    /// The current authenticated principal (collection + id), or error.Unauthorized.
    fn principal(self: AuthApi) !Ctx.User {
        const u = self.ctx.user() orelse return error.Unauthorized;
        if (u.collection.len == 0 or u.id.len == 0) return error.Unauthorized;
        return u;
    }

    /// "Log out everywhere" (#99): bump the principal's `token_epoch` so EVERY outstanding
    /// `.auth` token immediately stops verifying. Works in BOTH session-store modes. In table
    /// mode it ALSO clears the principal's `_sessions` rows (so the per-device list empties).
    /// Uses the bound connection inside a tx/before-hook, else acquires the pool writer.
    pub fn revokeAllSessions(self: AuthApi) !void {
        const u = try self.principal();
        const table = self.ctx.app.session_store == .table;
        if (self.ctx.bound_conn) |c| {
            _ = try api_auth.bumpTokenEpoch(self.ctx.arena, c, u.collection, u.id);
            if (table) try api_auth.deleteSessionsForPrincipal(c, u.collection, u.id);
            return;
        }
        const w = self.ctx.app.pool.acquireWriter();
        defer self.ctx.app.pool.releaseWriter();
        _ = try api_auth.bumpTokenEpoch(self.ctx.arena, w, u.collection, u.id);
        if (table) try api_auth.deleteSessionsForPrincipal(w, u.collection, u.id);
    }

    /// Re-mint a session token for the current principal (new `exp`, SAME epoch) — a sliding
    /// refresh that leaves the principal's other sessions valid. In table mode this ROTATES
    /// the current device's `_sessions` row (the old `sid` row is dropped; issuing inserts the
    /// replacement) so a device keeps exactly one row. Route context only (needs `ctx.request`).
    pub fn refresh(self: AuthApi) !auth_helpers.Issued {
        const u = try self.principal();
        const req = self.ctx.request orelse return error.NoRequestContext;
        const table = self.ctx.app.session_store == .table;
        const cur = self.ctx.rctx.session_id;
        if (self.ctx.bound_conn) |c| {
            // Carry the old row's `created` forward (session-start time) onto the new row,
            // whose `lastSeen` is set to now by issue() — see carrySessionCreated.
            const old_created = if (table and cur.len > 0) try api_auth.deleteSessionReturningCreated(self.ctx.arena, c, cur) else null;
            const issued = try auth_helpers.issueSession(req, c, u.collection, u.id);
            if (table) try api_auth.carrySessionCreated(self.ctx.arena, c, issued.token, old_created);
            return issued;
        }
        const w = self.ctx.app.pool.acquireWriter();
        defer self.ctx.app.pool.releaseWriter();
        // Epoch mode does no pre-issue write, so no transaction is needed (issue() just
        // reads + signs). Table mode performs delete-old + insert-new (in issue) — wrap them
        // in ONE transaction so a mid-way failure never silently logs the device out.
        if (!table) return auth_helpers.issueSession(req, w, u.collection, u.id);
        try w.beginImmediate();
        errdefer w.rollback() catch {};
        const old_created = if (cur.len > 0) try api_auth.deleteSessionReturningCreated(self.ctx.arena, w, cur) else null;
        const issued = try auth_helpers.issueSession(req, w, u.collection, u.id);
        try api_auth.carrySessionCreated(self.ctx.arena, w, issued.token, old_created);
        w.commit() catch |e| {
            w.rollback() catch {};
            return e;
        };
        return issued;
    }

    /// Rotate: bump the epoch (invalidating ALL prior tokens, including the one on THIS
    /// request) then mint a fresh token carrying the new epoch — "rotate my credentials,
    /// keep me signed in here, kill every other session". In table mode it also drops this
    /// device's old `_sessions` row and (via issue) inserts the replacement. Route context only.
    pub fn rotate(self: AuthApi) !auth_helpers.Issued {
        const u = try self.principal();
        const req = self.ctx.request orelse return error.NoRequestContext;
        const table = self.ctx.app.session_store == .table;
        const cur = self.ctx.rctx.session_id;
        if (self.ctx.bound_conn) |c| {
            _ = try api_auth.bumpTokenEpoch(self.ctx.arena, c, u.collection, u.id);
            const old_created = if (table and cur.len > 0) try api_auth.deleteSessionReturningCreated(self.ctx.arena, c, cur) else null;
            const issued = try auth_helpers.issueSession(req, c, u.collection, u.id);
            if (table) try api_auth.carrySessionCreated(self.ctx.arena, c, issued.token, old_created);
            return issued;
        }
        const w = self.ctx.app.pool.acquireWriter();
        defer self.ctx.app.pool.releaseWriter();
        // Epoch mode: a single epoch bump (UPDATE) then issue() (read + sign) — no multi-write
        // to make atomic; a failed issue returns an error the caller sees. Table mode bundles
        // bump + delete-old + insert-new (in issue) into ONE transaction so a mid-way failure
        // never leaves the device's row deleted without a replacement (silent logout).
        if (!table) {
            _ = try api_auth.bumpTokenEpoch(self.ctx.arena, w, u.collection, u.id);
            return auth_helpers.issueSession(req, w, u.collection, u.id);
        }
        try w.beginImmediate();
        errdefer w.rollback() catch {};
        _ = try api_auth.bumpTokenEpoch(self.ctx.arena, w, u.collection, u.id);
        const old_created = if (cur.len > 0) try api_auth.deleteSessionReturningCreated(self.ctx.arena, w, cur) else null;
        const issued = try auth_helpers.issueSession(req, w, u.collection, u.id);
        try api_auth.carrySessionCreated(self.ctx.arena, w, issued.token, old_created);
        w.commit() catch |e| {
            w.rollback() catch {};
            return e;
        };
        return issued;
    }

    /// Variant B (`App(.{ .session_store = .table })`): list the current principal's active
    /// (unexpired) sessions for a per-device UI, newest first, with `is_current` set on the
    /// session this request is using. Read-only (one indexed SELECT). Returns
    /// `error.SessionStoreNotEnabled` in the default `.epoch` mode (no per-session inventory).
    pub fn listActiveSessions(self: AuthApi) ![]const Session {
        if (self.ctx.app.session_store != .table) return error.SessionStoreNotEnabled;
        const u = try self.principal();
        const conn = if (self.ctx.bound_conn) |c| c else try self.ctx.connForRead();
        const rows = try api_auth.listSessions(self.ctx.arena, conn, u.collection, u.id);
        const cur = self.ctx.rctx.session_id;
        const out = try self.ctx.arena.alloc(Session, rows.len);
        for (rows, 0..) |row, i| out[i] = .{
            .id = row.id,
            .created = row.created,
            .last_seen = row.last_seen,
            .user_agent = row.user_agent,
            .ip = row.ip,
            .is_current = cur.len > 0 and std.mem.eql(u8, row.id, cur),
        };
        return out;
    }

    /// Variant B: revoke ONE session by id ("log out this device"). AUTHORIZED — a
    /// non-superuser may revoke only a session they OWN. A non-owner gets `error.NotFound`
    /// whether or not the session id exists (indistinguishable — no existence oracle on other
    /// users' session ids); a genuinely absent id is also `error.NotFound`.
    /// `error.SessionStoreNotEnabled` in `.epoch` mode.
    pub fn revoke(self: AuthApi, session_id: []const u8) !void {
        if (self.ctx.app.session_store != .table) return error.SessionStoreNotEnabled;
        const u = try self.principal();
        if (self.ctx.bound_conn) |c| return self.revokeOn(c, u, session_id);
        const w = self.ctx.app.pool.acquireWriter();
        defer self.ctx.app.pool.releaseWriter();
        return self.revokeOn(w, u, session_id);
    }

    /// Authorize + delete one session row on `conn`. Owner-or-superuser only (fail closed).
    /// A non-owner is given the SAME `error.NotFound` as a missing row — collapsing the
    /// owner-mismatch and absent-row cases so revoke can't probe other users' session ids.
    fn revokeOn(self: AuthApi, conn: *db.Db, u: Ctx.User, session_id: []const u8) !void {
        const owner = (try api_auth.sessionOwner(self.ctx.arena, conn, session_id)) orelse return error.NotFound;
        const is_owner = std.mem.eql(u8, owner.collection, u.collection) and std.mem.eql(u8, owner.record, u.id);
        if (!u.is_superuser and !is_owner) return error.NotFound; // indistinguishable from absent
        _ = try api_auth.deleteSession(conn, session_id);
    }
};

/// Key→value/settings namespace (#87) bound to a Ctx. A thin ergonomic layer over
/// `Data.kvGet/kvSet/kvDelete`: reads run on the read connection, writes use the
/// bound connection if present else the pool writer (mirroring `Records.create`).
pub const KeyValue = struct {
    ctx: *Ctx,

    /// Fetch `key`'s value, or null if absent. Result lives on the ctx arena.
    pub fn get(self: KeyValue, key: []const u8) !?[]const u8 {
        const data = Data{ .app = self.ctx.app, .conn = try self.ctx.connForRead(), .io = self.ctx.app.io, .alloc = self.ctx.arena };
        return data.kvGet(key);
    }

    /// Upsert `key`→`value` (preserves `created`).
    pub fn set(self: KeyValue, key: []const u8, value: []const u8) !void {
        if (self.ctx.bound_conn) |c|
            return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena }).kvSet(key, value);
        const c = self.ctx.app.pool.acquireWriter();
        defer self.ctx.app.pool.releaseWriter();
        return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena }).kvSet(key, value);
    }

    /// Delete `key`. Returns whether a row existed.
    pub fn delete(self: KeyValue, key: []const u8) !bool {
        if (self.ctx.bound_conn) |c|
            return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena }).kvDelete(key);
        const c = self.ctx.app.pool.acquireWriter();
        defer self.ctx.app.pool.releaseWriter();
        return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io, .alloc = self.ctx.arena }).kvDelete(key);
    }
};

/// Feature-resolution namespace (`ctx.flags()`) bound to a Ctx (#128/#129/#130).
pub const FlagsApi = struct {
    ctx: *Ctx,

    /// Resolve every DECLARED flag + experiment for `subject` in a SINGLE batched
    /// `_kv` scan (`flag:*` / `exp:*`). Returns empty when no registry is wired.
    /// Allocates on the ctx arena. This is the exact shape the public `/api/state`
    /// projection (a later PR) serves.
    pub fn resolveAll(self: FlagsApi, subject: []const u8) !features_resolver.Resolved {
        const reg = self.ctx.app.features orelse return .{};
        const conn = try self.ctx.connForRead();
        const data = Data{ .app = self.ctx.app, .conn = conn, .io = self.ctx.app.io, .alloc = self.ctx.arena };
        const entries = try data.kvScanPrefix(&.{ "flag:", "exp:" });
        const pairs = try self.ctx.arena.alloc(features_resolver.KvPair, entries.len);
        for (entries, 0..) |e, i| pairs[i] = .{ .key = e.key, .value = e.value };
        return features_resolver.resolveAll(self.ctx.arena, reg.*, pairs, subject);
    }
};

/// A transaction scope: wraps an inner Ctx whose bound_conn is set so that
/// all Records writes inside the callback reuse the in-progress transaction.
pub const Tx = struct {
    inner: Ctx,

    pub fn records(self: *Tx) Records {
        return .{ .ctx = &self.inner };
    }

    /// The transaction's request/invocation arena — use this to allocate values you
    /// put into records inside the callback.
    pub fn arena(self: *Tx) std.mem.Allocator {
        return self.inner.arena;
    }
};

// ---------------------------------------------------------------------------
// Test harness (file-backed pool, posts collection) — matches TestEnv pattern
// from events.zig.
// ---------------------------------------------------------------------------

const CtxTestEnv = struct {
    tmp: std.testing.TmpDir,
    db_path: [:0]u8,
    pool: db.Pool,
    arena: std.heap.ArenaAllocator,
    app: App,

    fn init() !*CtxTestEnv {
        const ga = std.testing.allocator;
        const env = try ga.create(CtxTestEnv);
        errdefer ga.destroy(env);

        env.tmp = std.testing.tmpDir(.{});
        errdefer env.tmp.cleanup();

        const dir_path = try env.tmp.dir.realPathFileAlloc(std.testing.io, ".", ga);
        defer ga.free(dir_path);
        env.db_path = try std.fmt.allocPrintSentinel(ga, "{s}/test.db", .{dir_path}, 0);
        errdefer ga.free(env.db_path);

        env.pool = try db.Pool.init(ga, std.testing.io, env.db_path);
        errdefer env.pool.deinit();

        env.arena = std.heap.ArenaAllocator.init(ga);
        errdefer env.arena.deinit();
        const a = env.arena.allocator();
        const io = std.testing.io;

        // Migrate + create a collection on the writer so create/findById work.
        {
            const w = env.pool.acquireWriter();
            defer env.pool.releaseWriter();
            try w.exec("PRAGMA foreign_keys=ON;");
            try migrations.run(w);
            const fields = [_]schema.Field{
                .{ .id = "f1", .name = "title", .required = true, .options = .{ .text = .{} } },
            };
            _ = try collections.create(a, io, w, .{ .id = "", .name = "posts", .fields = &fields });
        }

        env.app = App{ .allocator = a, .io = io, .pool = &env.pool };
        return env;
    }

    /// Like init(), but also provisions an `authors` collection and a `posts.author`
    /// single-relation field so expand tests have something to resolve.
    fn initWithRelation() !*CtxTestEnv {
        const ga = std.testing.allocator;
        const env = try ga.create(CtxTestEnv);
        errdefer ga.destroy(env);

        env.tmp = std.testing.tmpDir(.{});
        errdefer env.tmp.cleanup();

        const dir_path = try env.tmp.dir.realPathFileAlloc(std.testing.io, ".", ga);
        defer ga.free(dir_path);
        env.db_path = try std.fmt.allocPrintSentinel(ga, "{s}/test.db", .{dir_path}, 0);
        errdefer ga.free(env.db_path);

        env.pool = try db.Pool.init(ga, std.testing.io, env.db_path);
        errdefer env.pool.deinit();

        env.arena = std.heap.ArenaAllocator.init(ga);
        errdefer env.arena.deinit();
        const a = env.arena.allocator();
        const io = std.testing.io;

        {
            const w = env.pool.acquireWriter();
            defer env.pool.releaseWriter();
            try w.exec("PRAGMA foreign_keys=ON;");
            try migrations.run(w);
            const author_fields = [_]schema.Field{
                .{ .id = "a1", .name = "name", .options = .{ .text = .{} } },
            };
            const authors = try collections.create(a, io, w, .{ .id = "", .name = "authors", .fields = &author_fields, .viewRule = "@public" });
            const post_fields = [_]schema.Field{
                .{ .id = "p1", .name = "title", .required = true, .options = .{ .text = .{} } },
                .{ .id = "p2", .name = "author", .options = .{ .relation = .{ .targetCollectionId = authors.id, .maxSelect = 1 } } },
            };
            _ = try collections.create(a, io, w, .{ .id = "", .name = "posts", .fields = &post_fields });
        }

        env.app = App{ .allocator = a, .io = io, .pool = &env.pool };
        return env;
    }

    fn deinit(env: *CtxTestEnv) void {
        const ga = std.testing.allocator;
        env.arena.deinit();
        env.pool.deinit();
        ga.free(env.db_path);
        env.tmp.cleanup();
        ga.destroy(env);
    }
};

test "ctx.user() reflects the resolved auth identity; anonymous is null" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var anon = Ctx{ .app = &env.app, .arena = env.arena.allocator(), .rctx = .{} };
    defer anon.deinit();
    try std.testing.expect(anon.user() == null);
    // A superuser rctx yields a User with is_superuser=true.
    var su = Ctx{ .app = &env.app, .arena = env.arena.allocator(), .rctx = .{ .is_superuser = true } };
    defer su.deinit();
    try std.testing.expect(su.user().?.is_superuser);
    // An authed rctx with a collection forwards the collection name.
    var auth_obj: std.json.ObjectMap = .empty;
    try auth_obj.put(std.testing.allocator, "id", .{ .string = "abc123" });
    defer auth_obj.deinit(std.testing.allocator);
    var authed = Ctx{
        .app = &env.app,
        .arena = env.arena.allocator(),
        .rctx = .{ .auth = .{ .object = auth_obj }, .is_superuser = false, .collection = "users" },
    };
    defer authed.deinit();
    const u = authed.user().?;
    try std.testing.expectEqualStrings("abc123", u.id);
    try std.testing.expectEqualStrings("users", u.collection);
    try std.testing.expect(!u.is_superuser);
}

test "#86 ctx.auth().clearSession returns arena cookies matching the framework's logout policy" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const a = env.arena.allocator();
    var ctx = Ctx{ .app = &env.app, .arena = a, .rctx = .{} };
    defer ctx.deinit();

    const cookies = try ctx.auth().clearSession();
    try std.testing.expectEqual(@as(usize, 2), cookies.len);

    // Identical to the shared session policy that the built-in authLogout uses — so the
    // one-line consumer logout can never drift from the framework's own clear.
    const expected = session.clearedCookies(env.app.cookie_secure);
    for (cookies, 0..) |c, i| {
        try std.testing.expectEqualStrings(expected[i].name, c.name);
        try std.testing.expectEqualStrings("", c.value);
        try std.testing.expect(c.max_age_s < 0);
        try std.testing.expectEqual(expected[i].http_only, c.http_only);
        try std.testing.expectEqual(expected[i].secure, c.secure);
        try std.testing.expect(c.same_site == .strict);
        try std.testing.expectEqualStrings("/", c.path);
    }
    // zb_auth is HttpOnly; zb_csrf is readable by JS (double-submit).
    try std.testing.expect(cookies[0].http_only and !cookies[1].http_only);

    // The zigbase.auth.clearSession(ctx) re-export delegates to the same policy.
    const via_helper = try @import("auth_helpers.zig").clearSession(&ctx);
    try std.testing.expectEqualStrings(cookies[0].name, via_helper[0].name);
    try std.testing.expectEqualStrings(cookies[1].name, via_helper[1].name);
}

test "ctx.records.list returns created rows; get fetches one by id" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const a = env.arena.allocator();

    // Seed two rows directly on the writer.
    const id = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const d = Data{ .app = &env.app, .conn = w, .io = env.app.io, .alloc = a };
        var o1: std.json.ObjectMap = .empty;
        try o1.put(a, "title", .{ .string = "alpha" });
        const c1 = try d.create("posts", .{ .object = o1 });
        var o2: std.json.ObjectMap = .empty;
        try o2.put(a, "title", .{ .string = "beta" });
        _ = try d.create("posts", .{ .object = o2 });
        break :blk try a.dupe(u8, c1.object.get("id").?.string);
    };

    var ctx = Ctx{ .app = &env.app, .arena = a, .rctx = .{} };
    defer ctx.deinit();

    const page = try ctx.records().list("posts", .{ .sort = "title" });
    try std.testing.expectEqual(@as(usize, 2), page.items.len);

    const one = (try ctx.records().get("posts", id, .{})).?;
    try std.testing.expectEqualStrings("alpha", one.object.get("title").?.string);
}

test "ctx.records() allocates results on the ctx arena, not app.allocator (no GPA leak)" {
    // Regression: ctx.records() used to allocate results on app.allocator (the GPA),
    // leaking them on the job/route path. Prove results now land on the per-invocation
    // ctx arena: point app.allocator at the leak-checked testing allocator, run records
    // ops through a job-style ctx whose arena is a SEPARATE arena, then deinit ONLY that
    // arena. If any result allocated on app.allocator, std.testing.allocator would flag a
    // leak at test end; the clean exit proves nothing escaped to the GPA.
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const seed_a = env.arena.allocator();

    const id = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const d = Data{ .app = &env.app, .conn = w, .io = env.app.io, .alloc = seed_a };
        var o1: std.json.ObjectMap = .empty;
        try o1.put(seed_a, "title", .{ .string = "alpha" });
        const c1 = try d.create("posts", .{ .object = o1 });
        break :blk try seed_a.dupe(u8, c1.object.get("id").?.string);
    };

    // From here, app.allocator is the raw leak-checked testing allocator: any result that
    // leaks to it (instead of the ctx arena) is caught.
    env.app.allocator = std.testing.allocator;

    var job_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var ctx = Ctx{ .app = &env.app, .arena = job_arena.allocator(), .rctx = .{}, .request = null, .bound_conn = null };
    {
        defer ctx.deinit(); // releases the pooled reader first
        const page = try ctx.records().list("posts", .{ .sort = "title" });
        try std.testing.expectEqual(@as(usize, 1), page.items.len);
        try std.testing.expectEqualStrings("alpha", page.items[0].object.get("title").?.string);
        const one = (try ctx.records().get("posts", id, .{})).?;
        try std.testing.expectEqualStrings("alpha", one.object.get("title").?.string);
    }
    job_arena.deinit(); // frees all result memory; nothing should remain on app.allocator
}

test "Ctx(bound) uses the bound connection and never acquires from the pool" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();

    var ctx = Ctx{
        .app = &env.app,
        .arena = env.arena.allocator(),
        .rctx = .{},
        .bound_conn = w,
        .reader = null,
    };
    defer ctx.deinit();

    // No reader is cached because bound_conn short-circuits acquisition.
    const conn = try ctx.connForRead();
    try std.testing.expect(conn == w);
    try std.testing.expect(ctx.reader == null);
}

test "ctx.records create/update/delete round-trips and releases the writer" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const a = env.arena.allocator();

    var ctx = Ctx{ .app = &env.app, .arena = a, .rctx = .{} };
    defer ctx.deinit();

    var o: std.json.ObjectMap = .empty;
    try o.put(a, "title", .{ .string = "draft" });
    const created = try ctx.records().create("posts", .{ .object = o });
    const id = created.object.get("id").?.string;

    var u: std.json.ObjectMap = .empty;
    try u.put(a, "title", .{ .string = "published" });
    const updated = (try ctx.records().update("posts", id, .{ .object = u })).?;
    try std.testing.expectEqualStrings("published", updated.object.get("title").?.string);

    try std.testing.expect(try ctx.records().delete("posts", id));

    // Writer was released each time: re-acquiring directly must not deadlock.
    const w2 = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    _ = w2;
}

test "ctx.kv set/get round-trips; delete removes" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var ctx = Ctx{ .app = &env.app, .arena = env.arena.allocator(), .rctx = .{} };
    defer ctx.deinit();

    try std.testing.expect((try ctx.kv().get("k")) == null);
    try ctx.kv().set("k", "v");
    try std.testing.expectEqualStrings("v", (try ctx.kv().get("k")).?);
    try ctx.kv().set("k", "v2");
    try std.testing.expectEqualStrings("v2", (try ctx.kv().get("k")).?);
    try std.testing.expect(try ctx.kv().delete("k"));
    try std.testing.expect((try ctx.kv().get("k")) == null);
}

// A small declared registry for the ctx feature-flag tests below: `beta` (default
// off, the override case), `default_on` (the #128 kill-switch case), `intx` (the
// in-transaction write case).
const flag_test_registry = features.Registry{
    .flags = &.{
        .{ .name = "beta", .default = false },
        .{ .name = "default_on", .default = true },
        .{ .name = "intx", .default = false },
    },
    .experiments = &.{
        .{ .name = "layout", .variants = &.{ "control", "compact" }, .weights = &.{ 50, 50 } },
    },
};

test "ctx flags: declared default returned when unset; override wins; flagByName null for undeclared" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    env.app.features = &flag_test_registry;
    var ctx = Ctx{ .app = &env.app, .arena = env.arena.allocator(), .rctx = .{} };
    defer ctx.deinit();

    // Unset declared flag → declared default.
    try std.testing.expect(!(ctx.flagByName("beta").?));
    // A default-ON flag stays on when unset (#128 kill-switch).
    try std.testing.expect(ctx.flagByName("default_on").?);

    // setFlag writes the flag:<name> override; override wins.
    try ctx.setFlag("beta", true);
    try std.testing.expect(ctx.flagByName("beta").?);
    try std.testing.expectEqualStrings("true", (try ctx.kv().get("flag:beta")).?);
    // Flip the kill switch off.
    try ctx.setFlag("default_on", false);
    try std.testing.expect(!(ctx.flagByName("default_on").?));

    // An undeclared name resolves to null (escape hatch), and setFlag errors.
    try std.testing.expect(ctx.flagByName("never_declared") == null);
    try std.testing.expectError(error.UndeclaredFlag, ctx.setFlag("never_declared", true));
}

test "ctx.flags().resolveAll returns all declared flags + experiments via the batched scan" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    env.app.features = &flag_test_registry;
    var ctx = Ctx{ .app = &env.app, .arena = env.arena.allocator(), .rctx = .{} };
    defer ctx.deinit();

    // One flag override in _kv; everything else falls back to declared defaults.
    try ctx.setFlag("beta", true);

    const resolved = try ctx.flags().resolveAll("user-7");
    try std.testing.expectEqual(@as(usize, 3), resolved.flags.len);
    try std.testing.expectEqual(@as(usize, 1), resolved.experiments.len);
    // beta overridden on, default_on default on, intx default off.
    for (resolved.flags) |rf| {
        if (std.mem.eql(u8, rf.name, "beta")) try std.testing.expect(rf.value);
        if (std.mem.eql(u8, rf.name, "default_on")) try std.testing.expect(rf.value);
        if (std.mem.eql(u8, rf.name, "intx")) try std.testing.expect(!rf.value);
    }
    // The experiment resolves to one of its declared variants, deterministically.
    const v = resolved.experiments[0].variant;
    try std.testing.expect(std.mem.eql(u8, v, "control") or std.mem.eql(u8, v, "compact"));
    const again = try ctx.flags().resolveAll("user-7");
    try std.testing.expectEqualStrings(v, again.experiments[0].variant);
}

test "feature exposure hook fires on flag read + experiment resolve; zero-cost when unset" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    env.app.features = &flag_test_registry;

    const H = struct {
        var flag_calls: usize = 0;
        var exp_calls: usize = 0;
        var last_flag_name: []const u8 = "";
        var last_flag_value: bool = false;
        var last_exp_name: []const u8 = "";
        var last_exp_subject: []const u8 = "";
        var last_exp_variant: []const u8 = "";
        fn onExposure(ev: *events.ExposureEvent) void {
            switch (ev.kind) {
                .flag => {
                    flag_calls += 1;
                    last_flag_name = ev.name;
                    last_flag_value = ev.value;
                },
                .experiment => {
                    exp_calls += 1;
                    last_exp_name = ev.name;
                    last_exp_subject = ev.subject;
                    last_exp_variant = ev.variant;
                },
            }
        }
    };
    H.flag_calls = 0;
    H.exp_calls = 0;

    var ctx = Ctx{ .app = &env.app, .arena = env.arena.allocator(), .rctx = .{} };
    defer ctx.deinit();

    // Zero-cost path: no dispatch wired -> resolving must NOT invoke any handler.
    try std.testing.expect(env.app.dispatch == null);
    _ = ctx.flagByName("default_on").?;
    _ = try ctx.resolveDeclaredExperiment(flag_test_registry.experiments[0], "user-7");
    try std.testing.expectEqual(@as(usize, 0), H.flag_calls);
    try std.testing.expectEqual(@as(usize, 0), H.exp_calls);

    // Wire a handler -> resolving fires exposure with the right kind/name/subject/value|variant.
    var dispatch = events.Dispatch{ .on_feature_exposure = H.onExposure };
    env.app.dispatch = &dispatch;

    const on = ctx.flagByName("default_on").?;
    try std.testing.expectEqual(@as(usize, 1), H.flag_calls);
    try std.testing.expectEqualStrings("default_on", H.last_flag_name);
    try std.testing.expectEqual(on, H.last_flag_value);
    try std.testing.expect(H.last_flag_value);

    const variant = try ctx.resolveDeclaredExperiment(flag_test_registry.experiments[0], "user-7");
    try std.testing.expectEqual(@as(usize, 1), H.exp_calls);
    try std.testing.expectEqualStrings("layout", H.last_exp_name);
    try std.testing.expectEqualStrings("user-7", H.last_exp_subject);
    try std.testing.expectEqualStrings(variant, H.last_exp_variant);

    // A STICKY experiment (persists its assignment) still fires exposure on the
    // RESOLVED variant — including on the second resolve, which reads the stored
    // assignment rather than re-bucketing.
    const sticky_def = features.ExperimentDef{
        .name = "sticky_layout",
        .variants = &.{ "control", "compact" },
        .weights = &.{ 50, 50 },
        .sticky = true,
    };
    const sv1 = try ctx.resolveDeclaredExperiment(sticky_def, "user-9");
    try std.testing.expectEqual(@as(usize, 2), H.exp_calls);
    try std.testing.expectEqualStrings("sticky_layout", H.last_exp_name);
    try std.testing.expectEqualStrings("user-9", H.last_exp_subject);
    try std.testing.expectEqualStrings(sv1, H.last_exp_variant);
    // Second resolve hits the stored assignment; exposure still fires with the same variant.
    const sv2 = try ctx.resolveDeclaredExperiment(sticky_def, "user-9");
    try std.testing.expectEqual(@as(usize, 3), H.exp_calls);
    try std.testing.expectEqualStrings(sv1, sv2);
    try std.testing.expectEqualStrings(sv1, H.last_exp_variant);
}

fn txnSetFlag(t: *Tx) anyerror!void {
    try t.inner.setFlag("intx", true);
    try std.testing.expectEqualStrings("true", (try t.inner.kv().get("flag:intx")).?);
}

test "ctx.setFlag works inside ctx.tx (bound_conn path)" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    env.app.features = &flag_test_registry;
    var ctx = Ctx{ .app = &env.app, .arena = env.arena.allocator(), .rctx = .{} };
    defer ctx.deinit();

    try ctx.tx(void, txnSetFlag);
    // committed and visible after the transaction.
    try std.testing.expect(ctx.flagByName("intx").?);
}

test "#129 ctx sticky experiment persists + survives a weight change (writer path)" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    env.app.features = &flag_test_registry;
    var ctx = Ctx{ .app = &env.app, .arena = env.arena.allocator(), .rctx = .{} };
    defer ctx.deinit();

    const sticky_def = features.ExperimentDef{
        .name = "checkout_layout",
        .variants = &.{ "control", "compact" },
        .weights = &.{ 50, 50 },
        .sticky = true,
    };

    // First resolve persists the assignment (acquires the writer internally).
    const first = try ctx.resolveDeclaredExperiment(sticky_def, "user-42");

    // A weight override that would force the OTHER variant must not move the subject.
    const opposite = if (std.mem.eql(u8, first, "control")) "[0,100]" else "[100,0]";
    try ctx.kv().set("exp:checkout_layout:weights", opposite);
    const after = try ctx.resolveDeclaredExperiment(sticky_def, "user-42");
    try std.testing.expectEqualStrings(first, after);

    // An empty subject still resolves (variant 0) and is never persisted.
    try std.testing.expectEqualStrings("control", try ctx.resolveDeclaredExperiment(sticky_def, ""));
    const conn = try ctx.connForRead();
    var st = try conn.prepare("SELECT COUNT(*) FROM \"_experiment_assignments\";");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 1), st.columnInt(0));
}

test "ctx.http() returns a client bound to the ctx arena and io" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var ctx = Ctx{ .app = &env.app, .arena = env.arena.allocator(), .rctx = .{} };
    defer ctx.deinit();
    const client = ctx.http();
    // Assert the client is bound to the app's io (same userdata pointer).
    try std.testing.expect(client.io.userdata == env.app.io.userdata);
    // Assert two successive calls return clients with the same arena allocator pointer.
    const client2 = ctx.http();
    try std.testing.expect(client.alloc.ptr == client2.alloc.ptr);
    // Assert the allocator pointer matches the ctx's arena allocator.
    try std.testing.expect(client.alloc.ptr == ctx.arena.ptr);
}

test "errorResponse maps known errors to status codes, unknown to 500" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var ctx = Ctx{ .app = &env.app, .arena = env.arena.allocator(), .rctx = .{} };
    defer ctx.deinit();

    try std.testing.expectEqual(@as(u16, 404), ctx.errorResponse(error.NotFound).status);
    try std.testing.expectEqual(@as(u16, 403), ctx.errorResponse(error.Forbidden).status);
    try std.testing.expectEqual(@as(u16, 400), ctx.errorResponse(error.BadRequest).status);
    try std.testing.expectEqual(@as(u16, 409), ctx.errorResponse(error.Conflict).status);
    try std.testing.expectEqual(@as(u16, 401), ctx.errorResponse(error.Unauthorized).status);
    try std.testing.expectEqual(@as(u16, 500), ctx.errorResponse(error.SomethingWeird).status);

    // ctx.fail stashes a custom message that errorResponse(error.Handled) renders.
    const e = ctx.fail(422, "nope");
    try std.testing.expectError(error.Handled, @as(error{Handled}!void, e));
    const r = ctx.errorResponse(error.Handled);
    try std.testing.expectEqual(@as(u16, 422), r.status);
}

test "ctx.records expand nests the related record under \"expand\"" {
    const env = try CtxTestEnv.initWithRelation();
    defer env.deinit();
    const a = env.arena.allocator();

    const post_id = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const d = Data{ .app = &env.app, .conn = w, .io = env.app.io, .alloc = a };
        var ao: std.json.ObjectMap = .empty;
        try ao.put(a, "name", .{ .string = "Ada" });
        const author = try d.create("authors", .{ .object = ao });
        const aid = try a.dupe(u8, author.object.get("id").?.string);
        var po: std.json.ObjectMap = .empty;
        try po.put(a, "title", .{ .string = "p" });
        try po.put(a, "author", .{ .string = aid });
        const post = try d.create("posts", .{ .object = po });
        break :blk try a.dupe(u8, post.object.get("id").?.string);
    };

    var ctx = Ctx{ .app = &env.app, .arena = a, .rctx = .{} };
    defer ctx.deinit();

    const post = (try ctx.records().get("posts", post_id, .{ .expand = "author" })).?;
    const exp = post.object.get("expand").?.object;
    try std.testing.expectEqualStrings("Ada", exp.get("author").?.object.get("name").?.string);
}

test "ctx.records list expand nests the related record under \"expand\" for each item" {
    const env = try CtxTestEnv.initWithRelation();
    defer env.deinit();
    const a = env.arena.allocator();

    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const d = Data{ .app = &env.app, .conn = w, .io = env.app.io, .alloc = a };
        var ao: std.json.ObjectMap = .empty;
        try ao.put(a, "name", .{ .string = "Grace" });
        const author = try d.create("authors", .{ .object = ao });
        const aid = try a.dupe(u8, author.object.get("id").?.string);
        inline for (.{ "Post One", "Post Two" }) |title| {
            var po: std.json.ObjectMap = .empty;
            try po.put(a, "title", .{ .string = title });
            try po.put(a, "author", .{ .string = aid });
            _ = try d.create("posts", .{ .object = po });
        }
    }

    var ctx = Ctx{ .app = &env.app, .arena = a, .rctx = .{} };
    defer ctx.deinit();

    const page = try ctx.records().list("posts", .{ .expand = "author" });
    try std.testing.expect(page.items.len >= 2);
    for (page.items) |item| {
        const exp = item.object.get("expand").?.object;
        try std.testing.expectEqualStrings("Grace", exp.get("author").?.object.get("name").?.string);
    }
}

fn txnTwoInserts(t: *Tx) anyerror!void {
    const a = t.arena();
    var o1: std.json.ObjectMap = .empty;
    try o1.put(a, "title", .{ .string = "one" });
    _ = try t.records().create("posts", .{ .object = o1 });
    var o2: std.json.ObjectMap = .empty;
    try o2.put(a, "title", .{ .string = "two" });
    _ = try t.records().create("posts", .{ .object = o2 });
}

test "ctx.tx commits all writes atomically" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const a = env.arena.allocator();
    var ctx = Ctx{ .app = &env.app, .arena = a, .rctx = .{} };
    defer ctx.deinit();

    try ctx.tx(void, txnTwoInserts);

    const page = try ctx.records().list("posts", .{});
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
}

fn txnInsertThenFail(t: *Tx) anyerror!void {
    const a = t.arena();
    var o: std.json.ObjectMap = .empty;
    try o.put(a, "title", .{ .string = "doomed" });
    _ = try t.records().create("posts", .{ .object = o });
    return error.Boom;
}

fn txnNested(t: *Tx) anyerror!void {
    // Attempting a tx inside a tx must be rejected.
    return t.inner.tx(void, txnInsertThenFail);
}

test "ctx.tx rolls back on error and rejects nesting" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var ctx = Ctx{ .app = &env.app, .arena = env.arena.allocator(), .rctx = .{} };
    defer ctx.deinit();

    try std.testing.expectError(error.Boom, ctx.tx(void, txnInsertThenFail));
    const page = try ctx.records().list("posts", .{});
    try std.testing.expectEqual(@as(usize, 0), page.items.len); // rolled back

    try std.testing.expectError(error.NestedTransaction, ctx.tx(void, txnNested));
}
