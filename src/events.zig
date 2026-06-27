const std = @import("std");

const App = @import("app.zig").App;
const request = @import("request.zig");
const Ctx = @import("ctx.zig").Ctx;
const Data = @import("data.zig").Data;
const db = @import("db.zig");
const sentry = @import("sentry.zig");
const http = @import("http.zig");
const migrations = @import("migrations.zig");
const collections = @import("collections.zig");
const schema = @import("schema.zig");
const route_types = @import("route_types.zig");

// ---------------------------------------------------------------------------
// RAII DB-access handles for `RouteEvent` (the one app-only event that still
// exposes raw writer()/reader()). JobEvent/LifecycleEvent get DB access through
// the `*Ctx` parameter their handlers now receive (`ctx.records()`), which
// lazily checks out a pooled connection and releases it on `ctx.deinit()`.
// Unlike RecordEvent — whose ctx is bound to the in-transaction writer for the
// triggering write — RouteEvent has no ambient connection, so a handler that
// wants raw DB access must check one out of the pool and (crucially) hand it
// back. These handles make that lifetime explicit and leak-safe:
//
//   var w = ev.writer();         // acquires the shared pool writer (mutex-guarded)
//   defer w.deinit();            // releases it back to the pool — no leak
//   _ = try w.data().create(...);
//
//   var r = try ev.reader();     // checks out a pooled read-only connection
//   defer r.deinit();            // returns it to the warm pool — no leak
//   const rec = try r.data().findById(...);
//
// Asymmetry by design (mirrors db.Pool): the WRITER is a single shared,
// mutex-guarded connection, so deinit *unlocks* it (does not close). The READER
// is checked out of the pool's warm reader set, so deinit *returns* it to the
// pool (releaseReader) rather than closing.
// ---------------------------------------------------------------------------

/// RAII handle around the pool's shared writer connection. `data()` yields a
/// `Data` bound to it; `deinit()` releases the writer mutex. Hold it no longer
/// than necessary — only one writer exists pool-wide.
pub const WriterData = struct {
    app: *App,
    pool: *db.Pool,
    conn: *db.Db,

    /// A `Data` bound to the acquired writer connection. Valid until `deinit()`.
    pub fn data(self: *WriterData) Data {
        return .{ .app = self.app, .conn = self.conn, .io = self.app.io, .alloc = self.app.allocator };
    }

    /// Release the writer back to the pool. Call exactly once (use `defer`).
    pub fn deinit(self: *WriterData) void {
        self.pool.releaseWriter();
    }
};

/// RAII handle around a pooled, read-only connection checked out via
/// `acquireReader()`. `data()` yields a `Data` bound to it; `deinit()` returns
/// the connection to the pool's warm reader set.
pub const ReaderData = struct {
    app: *App,
    pool: *db.Pool,
    conn: db.Db,

    /// A `Data` bound to this reader connection. Takes `*ReaderData` so the
    /// returned `Data.conn` points at this handle's own (stable) `conn` field
    /// rather than a dangling stack copy; the handle must outlive the `Data`.
    pub fn data(self: *ReaderData) Data {
        return .{ .app = self.app, .conn = &self.conn, .io = self.app.io, .alloc = self.app.allocator };
    }

    /// Return the connection to the pool's warm reader set. Call exactly once
    /// (use `defer`). Passes `&self.conn` to match `Pool.releaseReader`.
    pub fn deinit(self: *ReaderData) void {
        self.pool.releaseReader(&self.conn);
    }
};

/// Acquire the pool's writer for create/update/delete. Caller MUST `deinit()`
/// the returned handle (use `defer`) to release the writer.
fn acquireWriter(app: *App) WriterData {
    const conn = app.pool.acquireWriter();
    return .{ .app = app, .pool = app.pool, .conn = conn };
}

/// Check out a pooled read-only connection for reads. Caller MUST `deinit()` the
/// returned handle (use `defer`) to return it to the pool.
fn acquireReader(app: *App) db.DbError!ReaderData {
    const conn = try app.pool.acquireReader();
    return .{ .app = app, .pool = app.pool, .conn = conn };
}

// NOTE: adding a variant requires updating phaseFieldName() and the consumer-facing camelCase field name.
pub const RecordPhase = enum {
    before_create,
    after_create,
    before_update,
    after_update,
    before_delete,
    after_delete,
};

pub const RecordEvent = struct {
    app: *App,
    ctx: *const request.RequestContext,
    /// Request-scoped allocator that owns `record`'s JSON storage. Hooks MUST use
    /// this (not `app.allocator`) for any allocation that becomes part of `record`,
    /// so growth is consistent with the map's backing and is freed with the request.
    arena: std.mem.Allocator,
    collection: []const u8,
    record: *std.json.Value, // mutable in before_*; the persisted record in after_*
    phase: RecordPhase,
    // DB capabilities are delivered to a record hook via its `*Ctx` parameter
    // (`ctx.records()`), whose `bound_conn` is the triggering write's in-transaction
    // connection — so a before-hook's side-write commits/rolls back atomically with it.
};

pub const ErrorPhase = enum { request, before_hook, after_hook, cron, job, file_serve };

pub const ErrorEvent = struct {
    app: *App,
    ctx: ?*const request.RequestContext,
    err: anyerror,
    phase: ErrorPhase,
    message: []const u8,
};

pub const RecordHandler = *const fn (ctx: *Ctx, ev: *RecordEvent) anyerror!void;
pub const ErrorHandler = *const fn (ev: *ErrorEvent) void;

pub const AuthLevel = enum { public, authed, superuser };

pub const RouteEvent = struct {
    app: *App,
    ctx: *http.RequestCtx,
    /// Resolved request/auth context (auth identity, is_superuser, method). Built by
    /// the framework before the handler runs; `.public` routes still get it (anonymous).
    rctx: request.RequestContext,

    /// Acquire the pool writer for create/update/delete:
    /// `var w = ev.writer(); defer w.deinit(); _ = try w.data().create(...);`.
    pub fn writer(ev: *RouteEvent) WriterData {
        return acquireWriter(ev.app);
    }
    /// Check out a pooled read-only connection for reads:
    /// `var r = try ev.reader(); defer r.deinit(); _ = try r.data().findById(...);`.
    pub fn reader(ev: *RouteEvent) db.DbError!ReaderData {
        return acquireReader(ev.app);
    }
    /// Mint a session for a known record via the audited seam (`.custom` method tag).
    /// Acquires the DB writer, calls `auth_helpers.issueSession`, releases the writer,
    /// and returns the signed JWT + 2 cookies. Fires `onAuth` exactly once.
    ///
    /// WARNING: this function acquires the pool writer internally. If the calling
    /// handler already holds the writer (`var w = ev.writer()`), do NOT call this —
    /// it would attempt to acquire the single non-reentrant writer a second time and
    /// deadlock permanently. Instead call `zigbase.auth.issueSession(ev.ctx, w.conn,
    /// collection, record_id)` with the connection you already hold.
    pub fn issueSession(ev: *RouteEvent, collection: []const u8, record_id: []const u8) !@import("auth_helpers.zig").Issued {
        var w = ev.writer();
        defer w.deinit();
        return @import("auth_helpers.zig").issueSession(ev.ctx, w.conn, collection, record_id);
    }

};
pub const RouteHandler = *const fn (ctx: *Ctx) anyerror!http.Response;

/// Re-exported for config code that needs to name the rate-limit callback type.
pub const RateLimitFn = @import("auth_helpers.zig").RateLimitFn;

/// A custom route after comptime assembly. The framework matches method+pattern
/// (reusing router.matchPath), enforces `auth`, then calls `handler`.
pub const RuntimeRoute = struct {
    method: http.Method,
    pattern: []const u8,
    handler: RouteHandler,
    auth: AuthLevel,
};

pub const AuthMethod = enum { password, oauth2, magic_link, otp, webauthn, custom };
pub const AuthEvent = struct {
    app: *App,
    ctx: *const request.RequestContext,
    collection: []const u8,
    record: ?std.json.Value,
    method: AuthMethod,
};
/// Notify-only, post-issuance auth notification. Fires AFTER a session is minted; cannot
/// abort or transactionally write. For a writable, abortable seam use `beforeAuthSuccess`.
pub const AuthHandler = *const fn (ev: *AuthEvent) void;

/// Event for the writable, abortable, in-transaction `beforeAuthSuccess` hook (#80).
/// Fires after credentials/token are verified (and, for magic-link, the link token is
/// consumed) and the verification gate has passed, but BEFORE the session JWT is issued.
/// The hook's `ctx` is bound to the login's in-transaction writer, so its
/// `ctx.records()` writes commit atomically with the login — and roll back, with the
/// session blocked, if the hook returns an error (fail closed).
pub const AuthSuccessEvent = struct {
    app: *App,
    /// The auth collection name.
    collection: []const u8,
    /// The authenticated record's id.
    record_id: []const u8,
    /// Which method completed (`.password`/`.magic_link`/`.otp`/`.webauthn`/`.oauth2`/`.custom`).
    method: AuthMethod,
    /// The authenticated record (always provided). The hook may also read fresh state
    /// via `ctx.records().get(collection, record_id, .{})` on the bound connection.
    record: std.json.Value,
};
/// `beforeAuthSuccess` handler: writable + abortable. Returning an error ROLLS BACK the
/// login transaction (no session issued); use `ctx.fail(status, msg)` for a chosen status,
/// `error.Forbidden`/`error.Unauthorized` for 403/401, else the response is a generic 500.
///
/// WARNING — the hook runs with a request-bound `*Ctx` whose writer connection is ALREADY
/// HELD inside the login transaction. It MUST NOT call anything that re-acquires the pool
/// writer or opens a new transaction: `ctx.issueSession()`, `ctx.tx()`, or any helper that
/// grabs the writer would attempt to take the single non-reentrant writer a second time and
/// **deadlock permanently** (`ctx.tx` is guarded and returns `error.NestedTransaction`, but
/// the writer-acquiring helpers are not). For side-writes use `ctx.records()` directly — it
/// reuses the bound transaction connection, so the writes commit atomically with the login.
pub const AuthSuccessHandler = *const fn (ctx: *Ctx, ev: *AuthSuccessEvent) anyerror!void;

// ---------------------------------------------------------------------------
// Auth lifecycle hooks (#98) — uniform before/after pairs for register, logout,
// refresh, and password-change, built on the `beforeAuthSuccess` discipline:
// before-hooks are writable + (where a write txn exists) transactional + abortable
// (fail closed); after-hooks are notify-only (errors routed to the backstop).
// ---------------------------------------------------------------------------

// NOTE: adding a variant requires updating authLifecyclePhaseFieldName() and the
// consumer-facing camelCase field name guard.
pub const AuthLifecyclePhase = enum {
    before_register,
    after_register,
    before_logout,
    after_logout,
    before_refresh,
    after_refresh,
    before_password_change,
    after_password_change,
};

/// Event for the auth lifecycle hooks (#98). One type for all eight phases; `phase`
/// discriminates. Before-phase handlers run with a `*Ctx` bound to the endpoint's
/// in-transaction writer where one exists (register/refresh/password-change), so their
/// `ctx.records()` writes commit atomically with the action and roll back on abort.
pub const AuthLifecycleEvent = struct {
    app: *App,
    /// The auth collection name (e.g. "users").
    collection: []const u8,
    /// The principal's record id. "" for `before_register` (no id yet) and for an
    /// unauthenticated logout.
    record_id: []const u8,
    phase: AuthLifecyclePhase,
    /// `before_register`: the writable to-be-created record data — mutate via the hook's
    ///   `ctx.arena` (same contract as a `before_create` RecordEvent).
    /// `after_register`: the persisted record (id populated).
    /// refresh / password-change: the existing record snapshot (read).
    /// logout: null (no record is loaded).
    record: ?*std.json.Value,
};
/// Auth lifecycle handler. Before-phase: writable + abortable (returning any error fails
/// the action closed — where a write txn exists it ROLLS BACK; the response is mapped via
/// the `Ctx` error model: `ctx.fail(status,msg)`, `error.Forbidden`→403, else 500).
/// After-phase: notify-only (errors are routed to the framework error backstop).
pub const AuthLifecycleHandler = *const fn (ctx: *Ctx, ev: *AuthLifecycleEvent) anyerror!void;

pub const FileEvent = struct {
    app: *App,
    ctx: *const request.RequestContext,
    collection: []const u8,
    record_id: []const u8,
    filename: []const u8,
};
/// beforeServe may return error to deny (framework -> 404); afterUpload errors -> backstop.
pub const FileServeHandler = *const fn (ev: *FileEvent) anyerror!void;
pub const FileUploadHandler = *const fn (ev: *FileEvent) void;

pub const LifecycleEvent = struct {
    app: *App,
};
/// Lifecycle handlers (onBootstrap/onBeforeServe/onBeforeTerminate) receive a
/// `*Ctx` (built by the framework from `app`, anonymous rctx, no request) plus
/// the event. DB access goes through `ctx.records()`.
pub const LifecycleHandler = *const fn (ctx: *Ctx, ev: *LifecycleEvent) void;

pub const JobEvent = struct {
    app: *App,
    name: []const u8,
};
/// Cron/interval/reactive jobs and `app.submit` tasks receive a `*Ctx` (built by
/// the scheduler per invocation from `app`, anonymous rctx, no request) plus the
/// event. DB access goes through `ctx.records()`; the ctx lazily checks out a
/// pooled connection and releases it on `ctx.deinit()`.
pub const JobTask = *const fn (ctx: *Ctx, ev: *JobEvent) anyerror!void;

/// `@compileError` on any route spec missing a required field (`.method`/`.path`/
/// `.handler`), mirroring `validateHooks`. `.auth` and `.name` are optional (auth
/// defaults to `.superuser`; name defaults to the path-derived name) so they are
/// intentionally not required here. The handler is the TYPED form
/// (`fn(*route_types.Req(In)) route_types.RouteError!Out`); its shape is validated by
/// `route_types.HandlerInput`/`HandlerOutput`'s own `@compileError`s when `routeMeta`
/// reflects it — so no raw-Response coercion check is performed here.
fn validateRouteSpecs(comptime specs: anytype) void {
    inline for (std.meta.fields(@TypeOf(specs))) |f| {
        const s = @field(specs, f.name);
        if (!@hasField(@TypeOf(s), "method")) @compileError("route spec is missing '.method' (expected .{ .method = .GET, .path = \"/...\", .handler = fn })");
        if (!@hasField(@TypeOf(s), "path")) @compileError("route spec is missing '.path' (expected .{ .method = .GET, .path = \"/...\", .handler = fn })");
        if (!@hasField(@TypeOf(s), "handler")) @compileError("route spec is missing '.handler' (expected .{ .method = .GET, .path = \"/...\", .handler = fn })");
    }
}

/// True iff `H` is the UNTYPED route handler form `fn(*Ctx) anyerror!http.Response`.
/// Untyped handlers own the full response (status, cookies, content-type, redirect, raw
/// body), so they are stored directly instead of being wrapped in a typed thunk. Anything
/// else is treated as the typed form `fn(*Req(In)) RouteError!Out`.
pub fn isUntypedHandler(comptime H: type) bool {
    // Accept either a bare `fn(...)` or a single-item function pointer `*const fn(...)`
    // — a handler written as `&myHandler` reflects as `.pointer`, not `.@"fn"`.
    comptime var T = H;
    if (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .one) {
        T = @typeInfo(T).pointer.child;
    }
    const info = @typeInfo(T);
    if (info != .@"fn") return false;
    const f = info.@"fn";
    if (f.params.len != 1) return false;
    const p = f.params[0].type orelse return false;
    const pi = @typeInfo(p);
    if (pi != .pointer or pi.pointer.size != .one) return false;
    return pi.pointer.child == Ctx;
}

/// Comptime route metadata for a typed route spec: the derived method name plus the
/// reflected Input/Output types (the bounded Zig→TS subset surfaces). Consumed by the
/// framework's comptime route assembly (collision + representability checks) and by the
/// codegen generator (SP2.2b) to emit the TS RPC surface.
pub const RouteMeta = struct {
    method: http.Method,
    path: []const u8,
    name: []const u8,
    auth: AuthLevel,
    Input: type,
    Output: type,
    /// True for untyped `fn(*Ctx) anyerror!http.Response` handlers, which own the
    /// raw response and contribute no typed RPC surface. The TS codegen skips these so it
    /// doesn't emit a client method that would mis-handle their non-JSON responses.
    untyped: bool = false,
};

/// Comptime path→method-name (mirrors codegen `identifiers.routeMethodName`) with an
/// optional `.name` override. Strips the "/api" prefix + ":param" segments, camel-joins
/// the rest. Comptime-friendly (no allocator) for the framework-side collision check.
/// Separators ('_', '-') within a segment are stripped and the following char is
/// uppercased, matching codegen `pascal()` semantics (drift-guard test enforces parity).
pub fn comptimeRouteName(comptime path: []const u8, comptime override: ?[]const u8) []const u8 {
    if (override) |n| return n;
    return comptime blk: {
        var rest: []const u8 = path;
        const prefix = "/api";
        if (std.mem.startsWith(u8, rest, prefix)) rest = rest[prefix.len..];
        var name: []const u8 = "";
        var first = true;
        var it = std.mem.tokenizeScalar(u8, rest, '/');
        while (it.next()) |seg| {
            if (seg.len == 0 or seg[0] == ':') continue;
            // PascalCase the segment, stripping '_'/'-' separators (matches
            // codegen identifiers.pascal); first segment keeps its leading
            // char lowercase to yield camelCase overall.
            var piece: []const u8 = "";
            var upper_next = false;
            var seg_first = true;
            for (seg) |ch| {
                if (ch == '_' or ch == '-') { upper_next = true; continue; }
                // Lowercase the first emitted char to match routeMethodName's camelCase (first char always lowercase).
                const c = if (first and seg_first) std.ascii.toLower(ch)
                          else if (upper_next or (!first and seg_first)) std.ascii.toUpper(ch)
                          else ch;
                piece = piece ++ &[_]u8{c};
                upper_next = false;
                seg_first = false;
            }
            name = name ++ piece;
            first = false;
        }
        break :blk name;
    };
}

/// Reflect a comptime tuple of typed route specs into `[]const RouteMeta`. Per spec,
/// reads `.method`/`.path`/`.auth` (auth defaults to `.superuser`), derives the method
/// name (`.name` override or `comptimeRouteName`), and reflects the handler's Input/Output
/// via `route_types.HandlerInput`/`HandlerOutput` (which `@compileError` on a wrong-shaped
/// handler). The `Holder`-const pattern gives the table static lifetime so the `[]const`
/// slice is returnable.
pub fn routeMeta(comptime specs: anytype) []const RouteMeta {
    const fields = std.meta.fields(@TypeOf(specs));
    const Holder = struct {
        const table: [fields.len]RouteMeta = blk: {
            @setEvalBranchQuota(10_000 + fields.len * 5_000); // scale with route count
            var t: [fields.len]RouteMeta = undefined;
            for (fields, 0..) |f, i| {
                const s = @field(specs, f.name);
                const H = @TypeOf(s.handler);
                const untyped = isUntypedHandler(H);
                const override: ?[]const u8 = if (@hasField(@TypeOf(s), "name")) s.name else null;
                t[i] = .{
                    .method = s.method,
                    .path = s.path,
                    .name = comptimeRouteName(s.path, override),
                    .auth = if (@hasField(@TypeOf(s), "auth")) s.auth else .superuser,
                    // Untyped handlers own the raw response; they contribute no typed RPC
                    // surface, so Input/Output are void (representable + query-parseable)
                    // and `untyped` flags them out of TS RPC codegen.
                    .Input = if (untyped) void else route_types.HandlerInput(H),
                    .Output = if (untyped) void else route_types.HandlerOutput(H),
                    .untyped = untyped,
                };
            }
            break :blk t;
        };
    };
    return &Holder.table;
}

/// Assemble a comptime tuple of TYPED route specs into a runtime route table. Each spec is
/// `.{ .method, .path, .handler, .auth = .public|.authed|.superuser, .name = "..." }`;
/// `.auth` defaults to `.superuser` (safe default) and `.name` defaults to the path-derived
/// name when omitted. The handler is `fn(*route_types.Req(In)) route_types.RouteError!Out`;
/// it is wrapped in `route_types.makeThunk` so the stored `.handler` is a RouteHandler.
/// Comptime-validates each route's Input/Output representability and `@compileError`s on a
/// duplicate derived method name.
pub fn buildRoutes(comptime specs: anytype) []const RuntimeRoute {
    comptime validateRouteSpecs(specs);
    const fields = std.meta.fields(@TypeOf(specs));
    const meta = comptime routeMeta(specs);
    // Representability + duplicate-name guards, all at comptime.
    comptime {
        @setEvalBranchQuota(10_000 + meta.len * 5_000); // scale with route count
        for (meta, 0..) |m, i| {
            if (m.name.len == 0)
                @compileError("route '" ++ m.path ++ "' derives an empty method name; add an explicit .name to the route spec");
            route_types.assertRepresentable(m.Input, m.name);
            route_types.assertRepresentable(m.Output, m.name);
            // GET/DELETE routes communicate their Input via a query string.
            // If the Input is representable but not query-parseable (e.g. contains a
            // non-string slice or a nested struct), the server's `parseQuery` cannot
            // decode it and every call would get a misleading 400 at runtime. Catch it
            // at build time instead.
            if (m.method == .GET or m.method == .DELETE) {
                if (!route_types.isQueryParseable(m.Input))
                    @compileError("route '" ++ m.name ++ "': GET/DELETE Input must be encodable as a query string (scalars/enums/strings/optionals only); got a type with a non-query field. Use POST/PUT/PATCH for a JSON body, or simplify the Input.");
            }
            for (meta[0..i]) |prev| {
                if (std.mem.eql(u8, prev.name, m.name))
                    @compileError("duplicate route method name '" ++ m.name ++ "' (paths '" ++ prev.path ++ "' and '" ++ m.path ++ "') — add a distinct .name");
            }
        }
    }
    // A struct-namespace const has static lifetime, so &Holder.table is a valid []const returnable at runtime (a plain comptime local is not).
    const Holder = struct {
        const table: [fields.len]RuntimeRoute = blk: {
            @setEvalBranchQuota(10_000 + fields.len * 5_000); // scale with route count
            var t: [fields.len]RuntimeRoute = undefined;
            for (fields, 0..) |f, i| {
                const s = @field(specs, f.name);
                const auth: AuthLevel = if (@hasField(@TypeOf(s), "auth")) s.auth else .superuser;
                // Untyped handlers already match RouteHandler — store directly so they keep
                // full control of the response (cookies/redirect/content-type). Typed handlers
                // are wrapped in a thunk that parses Input and serializes Output as JSON.
                const handler = if (isUntypedHandler(@TypeOf(s.handler))) s.handler else route_types.makeThunk(s.handler);
                t[i] = .{ .method = s.method, .pattern = s.path, .handler = handler, .auth = auth };
            }
            break :blk t;
        };
    };
    return &Holder.table;
}

/// Runtime, type-erased dispatch surface stored on `App`. The comptime App(cfg)
/// builder (a later task) fills these with generated functions; null = no subscribers.
pub const Dispatch = struct {
    record: ?RecordHandler = null,
    on_error: ?ErrorHandler = null,
    routes: []const RuntimeRoute = &.{},
    on_auth: ?AuthHandler = null,
    before_auth_success: ?AuthSuccessHandler = null,
    /// Generated by `buildAuthLifecycleDispatcher(cfg.auth)`; routes by phase to the
    /// registered register/logout/refresh/password-change before/after handler.
    auth_lifecycle: ?AuthLifecycleHandler = null,
    on_file_serve: ?FileServeHandler = null,
    on_file_upload: ?FileUploadHandler = null,
    on_bootstrap: ?LifecycleHandler = null,
    on_before_serve: ?LifecycleHandler = null,
    on_before_terminate: ?LifecycleHandler = null,
};

/// Map a comptime RecordPhase to its hook-config field name.
fn phaseFieldName(comptime p: RecordPhase) []const u8 {
    return switch (p) {
        .before_create => "beforeCreate",
        .after_create => "afterCreate",
        .before_update => "beforeUpdate",
        .after_update => "afterUpdate",
        .before_delete => "beforeDelete",
        .after_delete => "afterDelete",
    };
}

/// True iff `name` is one of the six canonical camelCase phase field names.
/// Kept DRY with `phaseFieldName` by deriving the set from `RecordPhase`.
fn isPhaseFieldName(comptime name: []const u8) bool {
    inline for (std.meta.fields(RecordPhase)) |p| {
        if (std.mem.eql(u8, name, phaseFieldName(@field(RecordPhase, p.name)))) return true;
    }
    return false;
}

/// `@compileError` on any hook-group field whose name is not a canonical phase
/// name, so a typo (e.g. `.beforeCreat`) fails loudly instead of silently
/// never firing. Runs over every group, including the `any` wildcard.
fn validateHooks(comptime hooks: anytype) void {
    inline for (std.meta.fields(@TypeOf(hooks))) |group| {
        const g = @field(hooks, group.name);
        switch (@typeInfo(@TypeOf(g))) {
            .@"struct" => {},
            else => @compileError("record hook group '" ++ group.name ++ "' must be a struct like .{ .beforeCreate = fn }"),
        }
        inline for (std.meta.fields(@TypeOf(g))) |f| {
            if (!isPhaseFieldName(f.name)) {
                @compileError("unknown record hook '" ++ group.name ++ "." ++ f.name ++
                    "'; expected one of beforeCreate/afterCreate/beforeUpdate/afterUpdate/beforeDelete/afterDelete");
            }
            // Assert the value coerces to RecordHandler so a wrong-typed hook fails loudly too.
            const _coerce: RecordHandler = @field(g, f.name);
            _ = _coerce;
        }
    }
}

/// Generate a record dispatcher from a comptime hook config of the shape:
///   .{ .any = .{ .beforeCreate = fn, ... }, .<collection> = .{ .afterUpdate = fn, ... } }
/// `any` (wildcard) handlers fire first, then the collection-specific group whose
/// field name equals ev.collection. Within a group, only the field matching ev.phase
/// runs. Handlers run in declaration order; errors propagate.
pub fn buildRecordDispatcher(comptime hooks: anytype) RecordHandler {
    comptime validateHooks(hooks);
    const Gen = struct {
        fn dispatch(ctx: *Ctx, ev: *RecordEvent) anyerror!void {
            // Pass 1: wildcard ("any") groups. Pass 2: collection-specific groups.
            inline for (.{ true, false }) |wildcard_pass| {
                inline for (std.meta.fields(@TypeOf(hooks))) |group| {
                    const is_wildcard = comptime std.mem.eql(u8, group.name, "any");
                    // Only the groups belonging to the current pass participate.
                    if (comptime is_wildcard == wildcard_pass) {
                        // Non-wildcard groups gate on the runtime collection name.
                        const collection_matches = is_wildcard or std.mem.eql(u8, ev.collection, group.name);
                        if (collection_matches) {
                            const g = @field(hooks, group.name);
                            switch (ev.phase) {
                                inline else => |p| {
                                    const fname = comptime phaseFieldName(p);
                                    if (@hasField(@TypeOf(g), fname)) {
                                        try @field(g, fname)(ctx, ev);
                                    }
                                },
                            }
                        }
                    }
                }
            }
        }
    };
    return Gen.dispatch;
}

/// Map a comptime AuthLifecyclePhase to its `.auth` config-group field name.
fn authLifecyclePhaseFieldName(comptime p: AuthLifecyclePhase) []const u8 {
    return switch (p) {
        .before_register => "beforeRegister",
        .after_register => "afterRegister",
        .before_logout => "beforeLogout",
        .after_logout => "afterLogout",
        .before_refresh => "beforeRefresh",
        .after_refresh => "afterRefresh",
        .before_password_change => "beforePasswordChange",
        .after_password_change => "afterPasswordChange",
    };
}

/// True iff `name` is one of the eight canonical camelCase lifecycle field names.
fn isAuthLifecycleFieldName(comptime name: []const u8) bool {
    inline for (std.meta.fields(AuthLifecyclePhase)) |p| {
        if (std.mem.eql(u8, name, authLifecyclePhaseFieldName(@field(AuthLifecyclePhase, p.name)))) return true;
    }
    return false;
}

/// `@compileError` on any `.auth` group field whose name is not a canonical phase
/// name, so a typo (e.g. `.beforeRegsiter`) fails loudly instead of silently never
/// firing. Mirrors `validateHooks`.
fn validateAuthLifecycleHooks(comptime auth_cfg: anytype) void {
    switch (@typeInfo(@TypeOf(auth_cfg))) {
        .@"struct" => {},
        else => @compileError("App cfg '.auth' must be a struct like .{ .beforeRegister = fn }"),
    }
    inline for (std.meta.fields(@TypeOf(auth_cfg))) |f| {
        if (!isAuthLifecycleFieldName(f.name)) {
            @compileError("unknown auth lifecycle hook 'auth." ++ f.name ++
                "'; expected one of beforeRegister/afterRegister/beforeLogout/afterLogout/beforeRefresh/afterRefresh/beforePasswordChange/afterPasswordChange");
        }
        // Assert the value coerces to AuthLifecycleHandler so a wrong-typed hook fails loudly too.
        const _coerce: AuthLifecycleHandler = @field(auth_cfg, f.name);
        _ = _coerce;
    }
}

/// Generate an auth-lifecycle dispatcher from a comptime `.auth` config group of the shape:
///   .{ .beforeRegister = fn, .afterRegister = fn, .beforeLogout = fn, ... }
/// Only the field matching `ev.phase` runs; an unregistered phase is a no-op. Errors
/// propagate (the firing site decides abort-vs-backstop, like `emitRecord`).
pub fn buildAuthLifecycleDispatcher(comptime auth_cfg: anytype) AuthLifecycleHandler {
    comptime validateAuthLifecycleHooks(auth_cfg);
    const Gen = struct {
        fn dispatch(ctx: *Ctx, ev: *AuthLifecycleEvent) anyerror!void {
            switch (ev.phase) {
                inline else => |p| {
                    const fname = comptime authLifecyclePhaseFieldName(p);
                    if (@hasField(@TypeOf(auth_cfg), fname)) {
                        try @field(auth_cfg, fname)(ctx, ev);
                    }
                },
            }
        }
    };
    return Gen.dispatch;
}

test "auth lifecycle dispatcher fires only the matching phase; mutation sticks" {
    const H = struct {
        var before_register_calls: usize = 0;
        var after_register_calls: usize = 0;
        fn onBeforeRegister(ctx: *Ctx, ev: *AuthLifecycleEvent) anyerror!void {
            _ = ctx;
            before_register_calls += 1;
            if (ev.record) |r| try r.object.put(std.testing.allocator, "seeded", .{ .bool = true });
        }
        fn onAfterRegister(ctx: *Ctx, ev: *AuthLifecycleEvent) anyerror!void {
            _ = ctx;
            _ = ev;
            after_register_calls += 1;
        }
    };
    H.before_register_calls = 0;
    H.after_register_calls = 0;
    const dispatch = buildAuthLifecycleDispatcher(.{
        .beforeRegister = H.onBeforeRegister,
        .afterRegister = H.onAfterRegister,
    });

    var rec: std.json.Value = .{ .object = .empty };
    defer rec.object.deinit(std.testing.allocator);
    var ctx = Ctx{ .app = undefined, .arena = std.testing.allocator, .rctx = .{}, .bound_conn = null };
    defer ctx.deinit();

    var ev = AuthLifecycleEvent{ .app = undefined, .collection = "users", .record_id = "", .phase = .before_register, .record = &rec };
    try dispatch(&ctx, &ev);
    try std.testing.expectEqual(@as(usize, 1), H.before_register_calls);
    try std.testing.expectEqual(@as(usize, 0), H.after_register_calls);
    try std.testing.expect(rec.object.get("seeded").?.bool == true);

    // An unregistered phase is a no-op (no handler for logout here).
    ev.phase = .before_logout;
    try dispatch(&ctx, &ev);
    try std.testing.expectEqual(@as(usize, 1), H.before_register_calls);

    ev.phase = .after_register;
    try dispatch(&ctx, &ev);
    try std.testing.expectEqual(@as(usize, 1), H.after_register_calls);
}

test "auth lifecycle before-hook error propagates (abort signal)" {
    const H = struct {
        fn boom(ctx: *Ctx, ev: *AuthLifecycleEvent) anyerror!void {
            _ = ctx;
            _ = ev;
            return error.RegisterRejected;
        }
    };
    const dispatch = buildAuthLifecycleDispatcher(.{ .beforeRegister = H.boom });
    var ctx = Ctx{ .app = undefined, .arena = std.testing.allocator, .rctx = .{}, .bound_conn = null };
    defer ctx.deinit();
    var ev = AuthLifecycleEvent{ .app = undefined, .collection = "users", .record_id = "", .phase = .before_register, .record = null };
    try std.testing.expectError(error.RegisterRejected, dispatch(&ctx, &ev));
    // A phase with no registered handler is a clean no-op even when others would error.
    ev.phase = .after_logout;
    try dispatch(&ctx, &ev);
}

// NOTE: a typo'd lifecycle hook name is rejected at COMPILE time by
// `validateAuthLifecycleHooks` — e.g. `buildAuthLifecycleDispatcher(.{ .beforeRegsiter = fn })`
// is a `@compileError`. It cannot be asserted at runtime (it would fail the build), so it is
// covered by the same mechanism the record-hook typo guard uses (`validateHooks`).

test "record dispatcher fires wildcard then specific, in order, and mutations stick" {
    const Trace = struct {
        var seq: std.ArrayListUnmanaged([]const u8) = .empty;
        fn wild(ctx: *Ctx, ev: *RecordEvent) anyerror!void {
            _ = ctx;
            try seq.append(std.testing.allocator, "wild");
            try ev.record.object.put(std.testing.allocator, "touched", .{ .bool = true });
        }
        fn specific(ctx: *Ctx, ev: *RecordEvent) anyerror!void {
            _ = ctx;
            try seq.append(std.testing.allocator, "specific");
            _ = ev;
        }
    };
    defer Trace.seq.deinit(std.testing.allocator);

    const hooks = .{
        .any = .{ .beforeCreate = Trace.wild },
        .posts = .{ .beforeCreate = Trace.specific },
    };
    const dispatch = buildRecordDispatcher(hooks);

    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "touched", .{ .bool = false });
    var rec: std.json.Value = .{ .object = obj };
    var ev = RecordEvent{ .app = undefined, .ctx = undefined, .arena = std.testing.allocator, .collection = "posts", .record = &rec, .phase = .before_create };
    var ctx = Ctx{ .app = undefined, .arena = std.testing.allocator, .rctx = .{}, .bound_conn = null };
    defer ctx.deinit();

    try dispatch(&ctx, &ev);
    try std.testing.expectEqual(@as(usize, 2), Trace.seq.items.len);
    try std.testing.expectEqualStrings("wild", Trace.seq.items[0]);
    try std.testing.expectEqualStrings("specific", Trace.seq.items[1]);
    try std.testing.expect(rec.object.get("touched").?.bool == true);
}

test "before hook error aborts (propagates) and unrelated collection is skipped" {
    const H = struct {
        fn boom(ctx: *Ctx, ev: *RecordEvent) anyerror!void {
            _ = ctx;
            _ = ev;
            return error.HookRejected;
        }
    };
    const dispatch = buildRecordDispatcher(.{ .posts = .{ .beforeCreate = H.boom } });

    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    var rec: std.json.Value = .{ .object = obj };
    var ev = RecordEvent{ .app = undefined, .ctx = undefined, .arena = std.testing.allocator, .collection = "comments", .record = &rec, .phase = .before_create };
    var ctx = Ctx{ .app = undefined, .arena = std.testing.allocator, .rctx = .{}, .bound_conn = null };
    defer ctx.deinit();
    try dispatch(&ctx, &ev); // "comments" not registered -> no-op, no error

    ev.collection = "posts";
    try std.testing.expectError(error.HookRejected, dispatch(&ctx, &ev));
}

/// Route a framework-caught error: run the consumer onError handler (if any),
/// then the built-in Sentry-or-log backstop. Never propagates.
pub fn dispatchError(app: *App, dispatch: ?*const Dispatch, ev: *ErrorEvent) void {
    if (dispatch) |d| {
        if (d.on_error) |h| h(ev);
    }
    sentry.backstop(app, ev.message);
}

test "dispatchError runs consumer handler before the backstop" {
    const H = struct {
        // Records the order in which the consumer handler and the backstop ran.
        var seq: std.ArrayListUnmanaged([]const u8) = .empty;
        fn onErr(ev: *ErrorEvent) void {
            _ = ev;
            seq.append(std.testing.allocator, "handler") catch {};
        }
        fn sink(_: []const u8) void {
            seq.append(std.testing.allocator, "backstop") catch {};
        }
    };
    H.seq = .empty;
    defer H.seq.deinit(std.testing.allocator);

    var app: App = undefined;
    app.allocator = std.testing.allocator;
    app.sentry_dsn = ""; // DSN-less -> backstop takes the log path
    // Route the log-mode backstop into our sink so it is observable and does not
    // emit a real std.log.err (which Zig's test runner would count as a failure).
    sentry.log_sink = H.sink;
    defer sentry.log_sink = null;

    var d = Dispatch{ .on_error = H.onErr };
    var ev = ErrorEvent{ .app = &app, .ctx = null, .err = error.Boom, .phase = .after_hook, .message = "x" };
    dispatchError(&app, &d, &ev);

    try std.testing.expectEqual(@as(usize, 2), H.seq.items.len);
    try std.testing.expectEqualStrings("handler", H.seq.items[0]);
    try std.testing.expectEqualStrings("backstop", H.seq.items[1]);
}

test "only the matching phase's handler runs" {
    const H = struct {
        var after_calls: usize = 0;
        fn onAfter(ctx: *Ctx, ev: *RecordEvent) anyerror!void {
            _ = ctx;
            _ = ev;
            after_calls += 1;
        }
    };
    H.after_calls = 0;
    const dispatch = buildRecordDispatcher(.{ .posts = .{ .afterCreate = H.onAfter } });
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    var rec: std.json.Value = .{ .object = obj };
    var ev = RecordEvent{ .app = undefined, .ctx = undefined, .arena = std.testing.allocator, .collection = "posts", .record = &rec, .phase = .before_create };
    var ctx = Ctx{ .app = undefined, .arena = std.testing.allocator, .rctx = .{}, .bound_conn = null };
    defer ctx.deinit();
    try dispatch(&ctx, &ev); // before_create fired, but only afterCreate is registered -> no call
    try std.testing.expectEqual(@as(usize, 0), H.after_calls);
    ev.phase = .after_create;
    try dispatch(&ctx, &ev);
    try std.testing.expectEqual(@as(usize, 1), H.after_calls);
}

test "buildRoutes assembles a runtime route table preserving order, method, pattern, auth" {
    const H = struct {
        fn a(req: *route_types.Req(void)) route_types.RouteError!void {
            _ = req;
        }
        fn b(req: *route_types.Req(void)) route_types.RouteError!void {
            _ = req;
        }
    };
    const table = buildRoutes(.{
        .{ .method = .GET, .path = "/api/x", .handler = H.a, .auth = .public },
        .{ .method = .POST, .path = "/api/y", .handler = H.b, .auth = .superuser },
    });
    try std.testing.expectEqual(@as(usize, 2), table.len);
    try std.testing.expect(table[0].method == .GET);
    try std.testing.expectEqualStrings("/api/x", table[0].pattern);
    try std.testing.expect(table[0].auth == .public);
    try std.testing.expect(table[1].method == .POST);
    try std.testing.expect(table[1].auth == .superuser);
}

test "buildRoutes builds thunks + metadata with derived names" {
    const In = struct { n: u32 };
    const Out = struct { doubled: u32 };
    const Specs = struct {
        fn confirm(req: *route_types.Req(In)) route_types.RouteError!Out {
            return .{ .doubled = req.input.n * 2 };
        }
        fn health(req: *route_types.Req(void)) route_types.RouteError!void {
            _ = req;
        }
    };
    const specs = .{
        .{ .method = http.Method.POST, .path = "/api/items/:id/confirm", .handler = Specs.confirm, .auth = AuthLevel.authed },
        .{ .method = http.Method.GET, .path = "/api/health", .handler = Specs.health },
    };
    const routes = buildRoutes(specs);
    try std.testing.expectEqual(@as(usize, 2), routes.len);
    try std.testing.expectEqual(http.Method.POST, routes[0].method);

    const meta = comptime routeMeta(specs);
    try std.testing.expectEqualStrings("itemsConfirm", meta[0].name);
    try std.testing.expectEqualStrings("health", meta[1].name);
    try std.testing.expectEqual(AuthLevel.authed, meta[0].auth);
    try std.testing.expect(meta[0].Input == In);
    try std.testing.expect(meta[0].Output == Out);
    try std.testing.expect(meta[1].Input == void);
}

test "buildRoutes defaults auth to .superuser when omitted" {
    const H = struct {
        fn a(req: *route_types.Req(void)) route_types.RouteError!void {
            _ = req;
        }
    };
    const table = buildRoutes(.{
        .{ .method = .GET, .path = "/api/secret", .handler = H.a },
    });
    try std.testing.expect(table[0].auth == .superuser);
}

test "AuthMethod enumerates all method tags" {
    try std.testing.expectEqualStrings("magic_link", @tagName(AuthMethod.magic_link));
    try std.testing.expectEqualStrings("custom", @tagName(AuthMethod.custom));
    try std.testing.expectEqualStrings("otp", @tagName(AuthMethod.otp));
    try std.testing.expectEqualStrings("webauthn", @tagName(AuthMethod.webauthn));
}

test "isUntypedHandler detects raw-response handlers and routeMeta flags them out of codegen" {
    const H = struct {
        // Untyped: owns the raw http.Response (cookies/redirect/non-JSON body).
        fn raw(ctx: *Ctx) anyerror!http.Response {
            _ = ctx;
            return error.Unexpected;
        }
        // Typed: reflected into the RPC surface.
        fn typed(req: *route_types.Req(void)) route_types.RouteError!void {
            _ = req;
        }
    };

    // Detection accepts both a bare `fn` and a single-item function pointer; a typed
    // `fn(*Req(...))` handler is not untyped.
    try std.testing.expect(isUntypedHandler(@TypeOf(H.raw)));
    try std.testing.expect(isUntypedHandler(*const @TypeOf(H.raw)));
    try std.testing.expect(!isUntypedHandler(@TypeOf(H.typed)));

    const specs = .{
        .{ .method = http.Method.GET, .path = "/api/raw", .handler = H.raw, .auth = AuthLevel.public },
        .{ .method = http.Method.GET, .path = "/api/health", .handler = H.typed },
    };
    const meta = comptime routeMeta(specs);
    // Untyped route: flagged out of codegen, contributes no typed Input/Output.
    try std.testing.expect(meta[0].untyped);
    try std.testing.expect(meta[0].Input == void);
    try std.testing.expect(meta[0].Output == void);
    // Typed route is unaffected.
    try std.testing.expect(!meta[1].untyped);
    try std.testing.expect(meta[1].Input == void); // its declared *Req(void)

    // buildRoutes still assembles a runnable table for both forms.
    const table = buildRoutes(specs);
    try std.testing.expectEqual(@as(usize, 2), table.len);
    try std.testing.expect(table[0].method == .GET);
}

// ---------------------------------------------------------------------------
// writer()/reader() data-accessor tests.
//
// A file-backed Pool (WAL) so a reader can see the writer's committed rows,
// mirroring the db.zig pool tests and the data.zig Data round-trip test. The
// no-leak assertions re-acquire the writer/reader *directly* off the pool after
// the handle's deinit: if deinit failed to release, acquireWriter would deadlock
// (spinlock) and acquireReader would not see the warm connection back in the
// pool.
// ---------------------------------------------------------------------------

const TestEnv = struct {
    tmp: std.testing.TmpDir,
    db_path: [:0]u8,
    pool: db.Pool,
    arena: std.heap.ArenaAllocator,
    app: App,

    fn init() !*TestEnv {
        const ga = std.testing.allocator;
        const env = try ga.create(TestEnv);
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

    fn deinit(env: *TestEnv) void {
        const ga = std.testing.allocator;
        env.arena.deinit();
        env.pool.deinit();
        ga.free(env.db_path);
        env.tmp.cleanup();
        ga.destroy(env);
    }
};

test "RouteEvent.writer() create round-trips and releases the writer (no leak)" {
    const env = try TestEnv.init();
    defer env.deinit();
    const a = env.arena.allocator();

    var ev = RouteEvent{ .app = &env.app, .ctx = undefined, .rctx = .{} };

    var id_buf: [64]u8 = undefined;
    var id_len: usize = 0;
    {
        var w = ev.writer();
        defer w.deinit();
        var obj: std.json.ObjectMap = .empty;
        try obj.put(a, "title", .{ .string = "hello" });
        const created = try w.data().create("posts", .{ .object = obj });
        const id = created.object.get("id").?.string;
        @memcpy(id_buf[0..id.len], id);
        id_len = id.len;

        const found = (try w.data().findById("posts", id)).?;
        try std.testing.expectEqualStrings("hello", found.object.get("title").?.string);
    }

    // Prove deinit released the writer: re-acquiring it directly must not
    // deadlock (the spinlock would hang forever if still held).
    {
        const w2 = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        _ = w2;
    }
}

test "job Ctx writes then reads a committed record and releases the conn on deinit (no leak)" {
    // Mirrors how the scheduler now hands a job its DB capabilities: a Ctx built
    // from app with anonymous rctx and no bound connection. Writes go through the
    // pool writer (released immediately); reads lazily check out a pooled reader
    // that ctx.deinit() returns to the warm pool.
    const env = try TestEnv.init();
    defer env.deinit();
    const a = env.arena.allocator();

    var cx = Ctx{ .app = &env.app, .arena = a, .rctx = .{}, .request = null, .bound_conn = null };
    defer cx.deinit();

    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "title", .{ .string = "world" });
    const created = try cx.records().create("posts", .{ .object = obj });
    const id = created.object.get("id").?.string;

    // No reader is checked out until the first read.
    try std.testing.expectEqual(@as(usize, 0), env.pool.reader_count);
    const found = (try cx.records().get("posts", id, .{})).?;
    try std.testing.expectEqualStrings("world", found.object.get("title").?.string);

    // ctx.deinit() (via defer) returns the cached reader to the warm pool — prove
    // it by deiniting explicitly here and checking the warm count, then null it so
    // the deferred deinit is a no-op.
    cx.deinit();
    try std.testing.expectEqual(@as(usize, 1), env.pool.reader_count);

    // Re-acquiring reuses that exact warm connection.
    var r2 = try env.pool.acquireReader();
    defer env.pool.releaseReader(&r2);
    try std.testing.expectEqual(@as(usize, 0), env.pool.reader_count);
}
