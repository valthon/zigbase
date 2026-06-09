const std = @import("std");

const App = @import("app.zig").App;
const request = @import("request.zig");
const Data = @import("data.zig").Data;
const sentry = @import("sentry.zig");
const http = @import("http.zig");

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

pub const AuthEvent = struct {
    app: *App,
    ctx: *const request.RequestContext,
    collection: []const u8,
    record: ?std.json.Value,
    method: enum { password, oauth2 },
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

pub const LifecycleEvent = struct { app: *App };
pub const LifecycleHandler = *const fn (ev: *LifecycleEvent) void;

/// `@compileError` on any route spec missing a required field (`.method`/`.path`/
/// `.handler`) or with a wrong-typed handler, mirroring `validateHooks`. `.auth` is
/// optional (defaults to `.superuser`) so it is intentionally not required here.
fn validateRouteSpecs(comptime specs: anytype) void {
    inline for (std.meta.fields(@TypeOf(specs))) |f| {
        const s = @field(specs, f.name);
        if (!@hasField(@TypeOf(s), "method")) @compileError("route spec is missing '.method' (expected .{ .method = .GET, .path = \"/...\", .handler = fn })");
        if (!@hasField(@TypeOf(s), "path")) @compileError("route spec is missing '.path' (expected .{ .method = .GET, .path = \"/...\", .handler = fn })");
        if (!@hasField(@TypeOf(s), "handler")) @compileError("route spec is missing '.handler' (expected .{ .method = .GET, .path = \"/...\", .handler = fn })");
        // Assert the handler coerces to RouteHandler so a wrong-typed handler fails loudly too.
        const _h: RouteHandler = s.handler;
        _ = _h;
    }
}

/// Assemble a comptime tuple of route specs into a runtime route table. Each spec is
/// `.{ .method, .path, .handler, .auth = .public|.authed|.superuser }`; `.auth` defaults
/// to `.superuser` (safe default) when omitted.
pub fn buildRoutes(comptime specs: anytype) []const RuntimeRoute {
    comptime validateRouteSpecs(specs);
    const fields = std.meta.fields(@TypeOf(specs));
    // A struct-namespace const has static lifetime, so &Holder.table is a valid []const returnable at runtime (a plain comptime local is not).
    const Holder = struct {
        const table: [fields.len]RuntimeRoute = blk: {
            var t: [fields.len]RuntimeRoute = undefined;
            for (fields, 0..) |f, i| {
                const s = @field(specs, f.name);
                const auth: AuthLevel = if (@hasField(@TypeOf(s), "auth")) s.auth else .superuser;
                t[i] = .{ .method = s.method, .pattern = s.path, .handler = s.handler, .auth = auth };
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
        fn a(ev: *RouteEvent) anyerror!http.Response {
            _ = ev;
            return .{ .status = 200, .body = "a" };
        }
        fn b(ev: *RouteEvent) anyerror!http.Response {
            _ = ev;
            return .{ .status = 200, .body = "b" };
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

test "buildRoutes defaults auth to .superuser when omitted" {
    const H = struct {
        fn a(ev: *RouteEvent) anyerror!http.Response {
            _ = ev;
            return .{ .status = 200, .body = "a" };
        }
    };
    const table = buildRoutes(.{
        .{ .method = .GET, .path = "/api/secret", .handler = H.a },
    });
    try std.testing.expect(table[0].auth == .superuser);
}
