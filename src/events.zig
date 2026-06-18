const std = @import("std");

const App = @import("app.zig").App;
const request = @import("request.zig");
const Data = @import("data.zig").Data;
const db = @import("db.zig");
const sentry = @import("sentry.zig");
const http = @import("http.zig");
const migrations = @import("migrations.zig");
const collections = @import("collections.zig");
const schema = @import("schema.zig");
const route_types = @import("route_types.zig");

// ---------------------------------------------------------------------------
// RAII DB-access handles for the events that carry only `app` (RouteEvent,
// JobEvent, LifecycleEvent). Unlike RecordEvent — whose `.data` is already bound
// to the in-transaction writer for the triggering write — these events have no
// ambient connection, so a handler that wants DB access must check one out of
// the pool and (crucially) hand it back. These handles make that lifetime
// explicit and leak-safe:
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
        return .{ .app = self.app, .conn = self.conn, .io = self.app.io };
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
        return .{ .app = self.app, .conn = &self.conn, .io = self.app.io };
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
    data: Data,
    /// Request-scoped allocator that owns `record`'s JSON storage. Hooks MUST use
    /// this (not `app.allocator`) for any allocation that becomes part of `record`,
    /// so growth is consistent with the map's backing and is freed with the request.
    arena: std.mem.Allocator,
    collection: []const u8,
    record: *std.json.Value, // mutable in before_*; the persisted record in after_*
    phase: RecordPhase,
};

pub const ErrorPhase = enum { request, before_hook, after_hook, cron, job, file_serve };

pub const ErrorEvent = struct {
    app: *App,
    ctx: ?*const request.RequestContext,
    err: anyerror,
    phase: ErrorPhase,
    message: []const u8,
};

pub const RecordHandler = *const fn (ev: *RecordEvent) anyerror!void;
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
};
pub const RouteHandler = *const fn (ev: *RouteEvent) anyerror!http.Response;

/// A custom route after comptime assembly. The framework matches method+pattern
/// (reusing router.matchPath), enforces `auth`, then calls `handler`.
pub const RuntimeRoute = struct {
    method: http.Method,
    pattern: []const u8,
    handler: RouteHandler,
    auth: AuthLevel,
};

pub const AuthMethod = enum { password, oauth2 };
pub const AuthEvent = struct {
    app: *App,
    ctx: *const request.RequestContext,
    collection: []const u8,
    record: ?std.json.Value,
    method: AuthMethod,
};
pub const AuthHandler = *const fn (ev: *AuthEvent) void;

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

    /// Acquire the pool writer for create/update/delete:
    /// `var w = ev.writer(); defer w.deinit(); _ = try w.data().create(...);`.
    pub fn writer(ev: *LifecycleEvent) WriterData {
        return acquireWriter(ev.app);
    }
    /// Check out a pooled read-only connection for reads:
    /// `var r = try ev.reader(); defer r.deinit(); _ = try r.data().findById(...);`.
    pub fn reader(ev: *LifecycleEvent) db.DbError!ReaderData {
        return acquireReader(ev.app);
    }
};
pub const LifecycleHandler = *const fn (ev: *LifecycleEvent) void;

pub const JobEvent = struct {
    app: *App,
    name: []const u8,

    /// Acquire the pool writer for create/update/delete:
    /// `var w = ev.writer(); defer w.deinit(); _ = try w.data().create(...);`.
    pub fn writer(ev: *JobEvent) WriterData {
        return acquireWriter(ev.app);
    }
    /// Check out a pooled read-only connection for reads:
    /// `var r = try ev.reader(); defer r.deinit(); _ = try r.data().findById(...);`.
    pub fn reader(ev: *JobEvent) db.DbError!ReaderData {
        return acquireReader(ev.app);
    }
};
pub const JobTask = *const fn (ev: *JobEvent) anyerror!void;

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
                const c = if (upper_next or (!first and seg_first)) std.ascii.toUpper(ch)
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
            var t: [fields.len]RouteMeta = undefined;
            for (fields, 0..) |f, i| {
                const s = @field(specs, f.name);
                const H = @TypeOf(s.handler);
                const override: ?[]const u8 = if (@hasField(@TypeOf(s), "name")) s.name else null;
                t[i] = .{
                    .method = s.method,
                    .path = s.path,
                    .name = comptimeRouteName(s.path, override),
                    .auth = if (@hasField(@TypeOf(s), "auth")) s.auth else .superuser,
                    .Input = route_types.HandlerInput(H),
                    .Output = route_types.HandlerOutput(H),
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
        for (meta, 0..) |m, i| {
            route_types.assertRepresentable(m.Input, m.name);
            route_types.assertRepresentable(m.Output, m.name);
            for (meta[0..i]) |prev| {
                if (std.mem.eql(u8, prev.name, m.name))
                    @compileError("duplicate route method name '" ++ m.name ++ "' (paths '" ++ prev.path ++ "' and '" ++ m.path ++ "') — add a distinct .name");
            }
        }
    }
    // A struct-namespace const has static lifetime, so &Holder.table is a valid []const returnable at runtime (a plain comptime local is not).
    const Holder = struct {
        const table: [fields.len]RuntimeRoute = blk: {
            var t: [fields.len]RuntimeRoute = undefined;
            for (fields, 0..) |f, i| {
                const s = @field(specs, f.name);
                const auth: AuthLevel = if (@hasField(@TypeOf(s), "auth")) s.auth else .superuser;
                t[i] = .{ .method = s.method, .pattern = s.path, .handler = route_types.makeThunk(s.handler), .auth = auth };
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
        fn dispatch(ev: *RecordEvent) anyerror!void {
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
                                        try @field(g, fname)(ev);
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

test "record dispatcher fires wildcard then specific, in order, and mutations stick" {
    const Trace = struct {
        var seq: std.ArrayListUnmanaged([]const u8) = .empty;
        fn wild(ev: *RecordEvent) anyerror!void {
            try seq.append(std.testing.allocator, "wild");
            try ev.record.object.put(std.testing.allocator, "touched", .{ .bool = true });
        }
        fn specific(ev: *RecordEvent) anyerror!void {
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
    var ev = RecordEvent{ .app = undefined, .ctx = undefined, .data = undefined, .arena = std.testing.allocator, .collection = "posts", .record = &rec, .phase = .before_create };

    try dispatch(&ev);
    try std.testing.expectEqual(@as(usize, 2), Trace.seq.items.len);
    try std.testing.expectEqualStrings("wild", Trace.seq.items[0]);
    try std.testing.expectEqualStrings("specific", Trace.seq.items[1]);
    try std.testing.expect(rec.object.get("touched").?.bool == true);
}

test "before hook error aborts (propagates) and unrelated collection is skipped" {
    const H = struct {
        fn boom(ev: *RecordEvent) anyerror!void {
            _ = ev;
            return error.HookRejected;
        }
    };
    const dispatch = buildRecordDispatcher(.{ .posts = .{ .beforeCreate = H.boom } });

    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    var rec: std.json.Value = .{ .object = obj };
    var ev = RecordEvent{ .app = undefined, .ctx = undefined, .data = undefined, .arena = std.testing.allocator, .collection = "comments", .record = &rec, .phase = .before_create };
    try dispatch(&ev); // "comments" not registered -> no-op, no error

    ev.collection = "posts";
    try std.testing.expectError(error.HookRejected, dispatch(&ev));
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
        fn onAfter(ev: *RecordEvent) anyerror!void {
            _ = ev;
            after_calls += 1;
        }
    };
    H.after_calls = 0;
    const dispatch = buildRecordDispatcher(.{ .posts = .{ .afterCreate = H.onAfter } });
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    var rec: std.json.Value = .{ .object = obj };
    var ev = RecordEvent{ .app = undefined, .ctx = undefined, .data = undefined, .arena = std.testing.allocator, .collection = "posts", .record = &rec, .phase = .before_create };
    try dispatch(&ev); // before_create fired, but only afterCreate is registered -> no call
    try std.testing.expectEqual(@as(usize, 0), H.after_calls);
    ev.phase = .after_create;
    try dispatch(&ev);
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

test "JobEvent.reader() sees a committed write and returns the conn to the pool (no leak)" {
    const env = try TestEnv.init();
    defer env.deinit();
    const a = env.arena.allocator();

    var job = JobEvent{ .app = &env.app, .name = "nightly" };

    // Write a record via the writer handle first.
    var id_buf: [64]u8 = undefined;
    var id_len: usize = 0;
    {
        var w = job.writer();
        defer w.deinit();
        var obj: std.json.ObjectMap = .empty;
        try obj.put(a, "title", .{ .string = "world" });
        const created = try w.data().create("posts", .{ .object = obj });
        const id = created.object.get("id").?.string;
        @memcpy(id_buf[0..id.len], id);
        id_len = id.len;
    }
    const id = id_buf[0..id_len];

    // The warm pool starts cold; after a reader handle deinit it must hold the
    // returned connection.
    try std.testing.expectEqual(@as(usize, 0), env.pool.reader_count);
    {
        var r = try job.reader();
        defer r.deinit();
        const found = (try r.data().findById("posts", id)).?;
        try std.testing.expectEqualStrings("world", found.object.get("title").?.string);
    }
    // Prove deinit returned the connection to the warm pool (no leak/close).
    try std.testing.expectEqual(@as(usize, 1), env.pool.reader_count);

    // And re-acquiring reuses that exact warm connection.
    var r2 = try env.pool.acquireReader();
    defer env.pool.releaseReader(&r2);
    try std.testing.expectEqual(@as(usize, 0), env.pool.reader_count);
}
