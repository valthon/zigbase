//! Typed-route building blocks (SP2.2a): the handler-facing `Req(Input)` + `RouteError`,
//! the comptime handler-type reflection, the bounded Zig→TS representability check, and
//! the per-handler dispatch thunk. Framework-side (the generator imports this for the TS
//! subset; the framework imports it at comptime to validate + build thunks).
const std = @import("std");

/// A captured path param (mirrors http.Param so route_types stays http-free for unit tests).
pub const Param = struct { key: []const u8, value: []const u8 };

/// A custom failure recorded by `req.fail` (status + message), surfaced by the thunk.
pub const Failure = struct { status: u16, message: []const u8 };

/// The route error set. Named members map to a default status via `statusForError`;
/// `RouteFailed` means "see req.failure for a custom status+message".
pub const RouteError = error{ BadRequest, Unauthorized, Forbidden, NotFound, Conflict, RouteFailed };

pub fn statusForError(e: RouteError) u16 {
    return switch (e) {
        error.BadRequest => 400,
        error.Unauthorized => 401,
        error.Forbidden => 403,
        error.NotFound => 404,
        error.Conflict => 409,
        error.RouteFailed => 500, // overridden by req.failure.status in the thunk
    };
}

/// Human-readable message for a `RouteError` when no custom `req.fail` message was recorded.
/// `RouteFailed` without a recorded failure means the handler returned it directly (no message);
/// surface a generic 500-style string — the status is already 500 via `statusForError`.
pub fn messageForError(e: RouteError) []const u8 {
    return switch (e) {
        error.BadRequest => "Bad request.",
        error.Unauthorized => "Not authenticated.",
        error.Forbidden => "Forbidden.",
        error.NotFound => "Not found.",
        error.Conflict => "Conflict.",
        error.RouteFailed => "Internal error.",
    };
}

/// The typed request handed to a route handler. `Input` is the parsed body/query;
/// `params` are path params; `auth_id` is the caller's id ("" when anonymous).
/// DB and other capabilities are reached via `req.ctx` (`req.ctx.records()`,
/// `req.ctx.http()`, `req.ctx.user()`, ...). `failure` is set by `fail`.
pub fn Req(comptime InputT: type) type {
    return struct {
        const Self = @This();
        pub const Input = InputT;
        // Lazy import: `ctx: *Ctx` is a pointer field, so Req's layout does not depend on
        // Ctx's layout — this avoids the route_types <- events <- ctx import cycle becoming
        // a comptime layout dependency.
        const Ctx = @import("ctx.zig").Ctx;

        input: InputT,
        params: []const Param,
        auth_id: []const u8,
        failure: ?Failure = null,
        /// The per-request capability object (DB/records, http client, auth identity, fail/tx).
        /// Set by `makeThunk`; typed handlers reach capabilities via `req.ctx.records()`,
        /// `req.ctx.http()`, `req.ctx.user()`, etc.
        ctx: *Ctx,
        // Legacy runtime handles, kept for the example apps (blog/golfsim) which still read
        // `req.app.?`/`req.arena.?`. Sourced from `ctx` by the thunk; new code uses `req.ctx`.
        // (Removal is deferred so this single-file task does not break the example builds.)
        app: ?*anyopaque = null,
        arena: ?std.mem.Allocator = null,

        pub fn param(self: *const Self, name: []const u8) ?[]const u8 {
            for (self.params) |p| if (std.mem.eql(u8, p.key, name)) return p.value;
            return null;
        }

        /// Record a custom status+message and return the sentinel error. Usage:
        /// `return req.fail(404, "Booking not found");`
        pub fn fail(self: *Self, status: u16, message: []const u8) RouteError {
            self.failure = .{ .status = status, .message = message };
            return RouteError.RouteFailed;
        }
    };
}

/// Extract `Input` from a handler type `fn(*Req(Input)) RouteError!Output`.
/// Reflects the first parameter (`*Req(Input)`) and reads its `pub const Input`.
/// `@compileError` if the handler doesn't take a single `*Req(...)`.
pub fn HandlerInput(comptime H: type) type {
    const info = @typeInfo(H);
    if (info != .@"fn") @compileError("route handler must be a function");
    const fn_info = info.@"fn";
    if (fn_info.params.len != 1) @compileError("route handler must take exactly one *Req(Input) parameter");
    const ptr_t = fn_info.params[0].type orelse @compileError("route handler parameter type is unknown");
    const ptr_info = @typeInfo(ptr_t);
    if (ptr_info != .pointer) @compileError("route handler parameter must be *Req(Input)");
    if (ptr_info.pointer.size != .one) @compileError("route handler parameter must be a single-item pointer *Req(Input)");
    const ReqT = ptr_info.pointer.child;
    if (!@hasDecl(ReqT, "Input")) @compileError("route handler parameter must be *Req(Input) (missing Req.Input)");
    return ReqT.Input;
}

/// Extract `Output` from a handler type `fn(...) RouteError!Output` (the error-union payload).
pub fn HandlerOutput(comptime H: type) type {
    if (@typeInfo(H) != .@"fn") @compileError("route handler must be a function");
    const info = @typeInfo(H);
    const ret = info.@"fn".return_type orelse @compileError("route handler return type is unknown");
    const ret_info = @typeInfo(ret);
    if (ret_info != .error_union) @compileError("route handler must return RouteError!Output");
    return ret_info.error_union.payload;
}

/// Extract the error set from a handler type `fn(...) E!Output`.
/// Used by `makeThunk` to enforce that the error set is exactly `RouteError`.
pub fn HandlerErrorSet(comptime H: type) type {
    if (@typeInfo(H) != .@"fn") @compileError("route handler must be a function");
    const info = @typeInfo(H);
    const ret = info.@"fn".return_type orelse @compileError("route handler return type is unknown");
    if (@typeInfo(ret) != .error_union) @compileError("route handler must return RouteError!Output");
    return @typeInfo(ret).error_union.error_set;
}

/// True iff `T` maps into the pragmatic Zig→TS subset (recursive over struct fields,
/// optionals, and slices). `std.json.Value` is the `unknown` escape hatch.
pub fn isRepresentable(comptime T: type) bool {
    if (T == void) return true;
    if (T == std.json.Value) return true;
    const info = @typeInfo(T);
    return switch (info) {
        .int, .float, .bool => true,
        .@"enum" => true, // string-literal union of the tag names
        .optional => |o| isRepresentable(o.child),
        .pointer => |p| blk: {
            // Only slices are allowed: `[]const u8` is string, `[]T` is T[].
            if (p.size != .slice) break :blk false;
            if (p.child == u8) break :blk true; // string
            break :blk isRepresentable(p.child);
        },
        .@"struct" => |s| blk: {
            inline for (s.fields) |f| {
                if (!isRepresentable(f.type)) break :blk false;
            }
            break :blk true;
        },
        else => false, // unions, fn, opaque, comptime-only, etc.
    };
}

/// Comptime guard: `@compileError` (naming the route + the field path) when `T` (a route's
/// Input or Output) isn't representable. Walks to report the FIRST offending field path.
pub fn assertRepresentable(comptime T: type, comptime route_name: []const u8) void {
    assertRepresentableField(T, route_name, "");
}

fn assertRepresentableField(comptime T: type, comptime route_name: []const u8, comptime path: []const u8) void {
    if (T == void or T == std.json.Value) return;
    const info = @typeInfo(T);
    switch (info) {
        .int, .float, .bool, .@"enum" => {},
        .optional => |o| assertRepresentableField(o.child, route_name, path),
        .pointer => |p| {
            if (p.size != .slice)
                @compileError("route '" ++ route_name ++ "' field '" ++ path ++ "': type " ++ @typeName(T) ++ " is not representable (only slices/strings allowed, not bare pointers)");
            if (p.child != u8) assertRepresentableField(p.child, route_name, path ++ "[]");
        },
        .@"struct" => |s| {
            inline for (s.fields) |f| {
                assertRepresentableField(f.type, route_name, if (path.len == 0) f.name else path ++ "." ++ f.name);
            }
        },
        else => @compileError("route '" ++ route_name ++ "' field '" ++ path ++ "': type " ++ @typeName(T) ++ " is not representable in the bounded Zig→TS subset"),
    }
}

/// Wrap a typed handler `fn(*Req(I)) RouteError!O` into a RouteHandler thunk
/// (`fn(*Ctx) anyerror!http.Response`). Comptime-specialized per handler.
/// `events`/`http`/`Ctx` are imported lazily inside the function so the rest of
/// route_types.zig (Req/RouteError/reflection) stays free of the framework import
/// cycle (events.zig imports route_types for Req/RouteError).
pub fn makeThunk(comptime handler: anytype) @import("events.zig").RouteHandler {
    const H = @TypeOf(handler);
    if (HandlerErrorSet(H) != RouteError)
        @compileError("route handler must return RouteError!Output, found a different error set: " ++ @typeName(HandlerErrorSet(H)));
    const In = HandlerInput(H);
    const Out = HandlerOutput(H);
    const http = @import("http.zig");
    const Ctx = @import("ctx.zig").Ctx;

    const Thunk = struct {
        fn run(cx: *Ctx) anyerror!http.Response {
            const a = cx.arena;
            const rc = cx.request.?; // typed routes always run with an HTTP request
            // 1. Parse input (void -> skip; GET/DELETE -> query; else JSON body).
            // The GET query branch is gated behind a comptime `isQueryParseable(In)`
            // so that complex POST-body types (with nested slices, enums, optional
            // structs) don't instantiate `parseQuery` and hit its @compileError paths.
            const input: In = if (In == void) {} else blk: {
                if (comptime isQueryParseable(In)) {
                    if (rc.method == .GET or rc.method == .DELETE) {
                        break :blk parseQuery(In, a, rc.query) catch
                            return badRequest(a, "Invalid query parameters.");
                    }
                }
                if (rc.body.len == 0) return badRequest(a, "Missing request body.");
                break :blk (std.json.parseFromSlice(In, a, rc.body, .{ .ignore_unknown_fields = true }) catch
                    return badRequest(a, "Invalid JSON body.")).value;
            };
            // 2. Build Req. Map request params (http.Param) onto route_types.Param.
            var params = try a.alloc(Param, rc.params.len);
            for (rc.params, 0..) |p, i| params[i] = .{ .key = p.key, .value = p.value };
            const auth_id = cx.rctx.resolveMacro("@request.auth.id") orelse "";
            var req = Req(In){ .input = input, .params = params, .auth_id = auth_id, .ctx = cx, .app = cx.app, .arena = a };
            // 3. Call handler; map errors -> status+message.
            const out: Out = handler(&req) catch |e| {
                if (req.failure) |f|
                    return jsonError(a, f.status, f.message);
                const re: RouteError = @errorCast(e);
                return jsonError(a, statusForError(re), messageForError(re));
            };
            // 4. Serialize output (204 for void, else 200 JSON).
            if (Out == void) return .{ .status = 204, .body = "" };
            const body = try std.json.Stringify.valueAlloc(a, out, .{});
            return .{ .status = 200, .body = body };
        }
    };
    return Thunk.run;
}

/// 400 with a JSON `{"message": ...}` body; falls back to a static body if alloc fails.
fn badRequest(a: std.mem.Allocator, msg: []const u8) @import("http.zig").Response {
    return jsonError(a, 400, msg) catch .{ .status = 400, .body = "{\"message\":\"Bad request.\"}" };
}

/// Build `{"message": <json-escaped message>}` at `status`. Uses `std.json.fmt` with the
/// `{f}` format spec (Zig 0.16: `std.json.fmt` returns a value with a `format` method;
/// `{f}` invokes that method to emit properly JSON-escaped output).
fn jsonError(a: std.mem.Allocator, status: u16, message: []const u8) !@import("http.zig").Response {
    const body = try std.fmt.allocPrint(a, "{{\"message\":{f}}}", .{std.json.fmt(message, .{})});
    return .{ .status = status, .body = body };
}

/// Minimal query (`a=1&b=hi`) parser into a flat struct of string/int/bool fields.
/// Covers GET/DELETE routes whose Input is flat; golfsim's GET routes use `Req(void)`,
/// so today this is exercised only by its own unit test.
fn parseQuery(comptime T: type, a: std.mem.Allocator, query: []const u8) !T {
    if (@typeInfo(T) != .@"struct")
        @compileError("GET/DELETE route Input must be a struct (typed query input lands in SP2.2b): " ++ @typeName(T));
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const raw = findQueryValue(query, f.name);
        @field(result, f.name) = try coerceQueryField(f.type, a, raw);
    }
    return result;
}

/// Look up `name`'s value in an `&`-joined `key=value` query string; null if absent.
fn findQueryValue(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

/// True iff `T` is a query-string scalar: int, float, bool, enum, `[]const u8`,
/// or an optional wrapping one of those. Does NOT accept structs or non-string
/// slices — those are not coercible by `coerceQueryField`.
fn isQueryScalar(comptime F: type) bool {
    if (F == []const u8) return true;
    const info = @typeInfo(F);
    return switch (info) {
        .int, .float, .bool, .@"enum" => true,
        .optional => |o| isQueryScalar(o.child),
        else => false, // struct, non-string slice, pointer, union, etc.
    };
}

/// True iff `T` can be parsed from a flat query string by `coerceQueryField`.
/// Used by `makeThunk` as a comptime guard to avoid instantiating `parseQuery`
/// for complex struct types (e.g. POST-body inputs with nested slices/structs)
/// that will never appear on the GET code path at runtime. Also used by
/// `buildRoutes` (events.zig) to enforce the GET/DELETE contract at app-build time.
///
/// A top-level struct is accepted ONLY if every field is a query scalar (int,
/// float, bool, enum, `[]const u8`, or optional-of-those). Nested structs and
/// non-string slices are rejected — `parseQuery` only handles flat inputs.
/// Only `void` and flat structs of scalars are accepted; bare scalars, optionals,
/// and non-struct types are rejected so handlers must use a wrapping struct.
pub fn isQueryParseable(comptime T: type) bool {
    if (T == void) return true;
    return switch (@typeInfo(T)) {
        .@"struct" => |s| blk: {
            inline for (s.fields) |f| {
                if (!isQueryScalar(f.type)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

/// Coerce a raw query value into a field type: string -> the slice, int -> parseInt,
/// float -> parseFloat, bool -> "true"/"1", enum -> tag name match.
/// Missing required value -> error.BadRequest. Optionals: a missing value becomes null.
fn coerceQueryField(comptime F: type, a: std.mem.Allocator, raw: ?[]const u8) !F {
    const info = @typeInfo(F);
    if (info == .optional) {
        const r = raw orelse return null;
        return try coerceQueryField(info.optional.child, a, r);
    }
    const r = raw orelse return error.BadRequest;
    if (F == []const u8) return r;
    return switch (info) {
        .int => std.fmt.parseInt(F, r, 10) catch error.BadRequest,
        .float => std.fmt.parseFloat(F, r) catch error.BadRequest,
        .bool => std.mem.eql(u8, r, "true") or std.mem.eql(u8, r, "1"),
        .@"enum" => std.meta.stringToEnum(F, r) orelse error.BadRequest,
        else => @compileError("GET/DELETE query field type not yet supported: " ++ @typeName(F)),
    };
}

const testing = std.testing;

test "Req carries typed input + records a custom failure" {
    const Ctx = @import("ctx.zig").Ctx;
    const In = struct { note: []const u8 };
    var ctx_params = [_]Param{.{ .key = "id", .value = "abc" }};
    var cx = Ctx{ .app = undefined, .arena = undefined, .rctx = .{} };
    var req = Req(In){
        .input = .{ .note = "hi" },
        .params = &ctx_params,
        .auth_id = "user1",
        .failure = null,
        .ctx = &cx,
    };
    try testing.expectEqualStrings("hi", req.input.note);
    try testing.expectEqualStrings("abc", req.param("id").?);
    try testing.expect(req.param("missing") == null);

    const e = req.fail(404, "Booking not found");
    try testing.expectEqual(RouteError.RouteFailed, e);
    try testing.expectEqual(@as(u16, 404), req.failure.?.status);
    try testing.expectEqualStrings("Booking not found", req.failure.?.message);
}

test "statusForError maps named errors" {
    try testing.expectEqual(@as(u16, 403), statusForError(RouteError.Forbidden));
    try testing.expectEqual(@as(u16, 404), statusForError(RouteError.NotFound));
    try testing.expectEqual(@as(u16, 400), statusForError(RouteError.BadRequest));
}

test "reflect Input/Output from a handler type" {
    const In = struct { a: u32 };
    const Out = struct { ok: bool };
    const H = struct {
        fn h(req: *Req(In)) RouteError!Out {
            _ = req;
            return .{ .ok = true };
        }
    }.h;
    try testing.expect(HandlerInput(@TypeOf(H)) == In);
    try testing.expect(HandlerOutput(@TypeOf(H)) == Out);

    // void input/output handler.
    const HV = struct {
        fn h(req: *Req(void)) RouteError!void {
            _ = req;
        }
    }.h;
    try testing.expect(HandlerInput(@TypeOf(HV)) == void);
    try testing.expect(HandlerOutput(@TypeOf(HV)) == void);
}

test "HandlerErrorSet returns RouteError for a normal handler" {
    const h = struct {
        fn run(req: *Req(void)) RouteError!void {
            _ = req;
        }
    }.run;
    try testing.expect(HandlerErrorSet(@TypeOf(h)) == RouteError);
}

test "isRepresentable accepts the bounded subset" {
    try testing.expect(isRepresentable(void));
    try testing.expect(isRepresentable(u32));
    try testing.expect(isRepresentable(f64));
    try testing.expect(isRepresentable(bool));
    try testing.expect(isRepresentable([]const u8)); // string
    try testing.expect(isRepresentable(?[]const u8)); // nullable string
    try testing.expect(isRepresentable([]const u32)); // number[]
    try testing.expect(isRepresentable(std.json.Value)); // unknown escape hatch
    const En = enum { a, b };
    try testing.expect(isRepresentable(En));
    const Nested = struct { x: u8, tags: []const []const u8, label: ?[]const u8, kind: En };
    try testing.expect(isRepresentable(Nested));
}

test "isRepresentable rejects unsupported types" {
    try testing.expect(!isRepresentable(*u8)); // bare pointer (non-slice)
    const U = union(enum) { a: u8, b: u16 };
    try testing.expect(!isRepresentable(U)); // tagged union (rich tier; not in pragmatic core)
    const WithFn = struct { f: *const fn () void };
    try testing.expect(!isRepresentable(WithFn));
}

test "makeThunk: parses input, serializes output (200)" {
    const http = @import("http.zig");
    const Ctx = @import("ctx.zig").Ctx;
    const In = struct { guests: u32 };
    const Out = struct { id: []const u8, guests: u32, confirmed: bool };
    const H = struct {
        // Handlers may only fail with RouteError, so assert by reflecting parsed
        // input/params into the Output and asserting on the serialized body below.
        fn h(req: *Req(In)) RouteError!Out {
            const id = req.param("id") orelse return req.fail(400, "missing id param");
            return .{ .id = id, .guests = req.input.guests, .confirmed = true };
        }
    }.h;
    const thunk = makeThunk(H);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var params = [_]http.Param{.{ .key = "id", .value = "bk1" }};
    var ctx = http.RequestCtx{
        .method = .POST,
        .path = "/api/bookings/bk1/confirm",
        .body = "{\"guests\":2}",
        .allocator = arena.allocator(),
        .params = &params,
    };
    const rctx = @import("request.zig").RequestContext{ .auth = null, .is_superuser = false, .method = "POST" };
    var cx = Ctx{ .app = undefined, .arena = arena.allocator(), .rctx = rctx, .request = &ctx };
    defer cx.deinit();
    const resp = try thunk(&cx);
    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"confirmed\":true") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"id\":\"bk1\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"guests\":2") != null);
}

test "coerceQueryField: enum field parses valid variant, rejects unknown, optional works" {
    const SortEnum = enum { newest, oldest };
    const QueryWithEnum = struct { sort: SortEnum, maybe: ?SortEnum };

    const a = testing.allocator;

    // Valid variant: "newest" -> .newest
    const q1 = try parseQuery(QueryWithEnum, a, "sort=newest&maybe=oldest");
    try testing.expectEqual(SortEnum.newest, q1.sort);
    try testing.expectEqual(SortEnum.oldest, q1.maybe.?);

    // Optional absent -> null
    const q2 = try parseQuery(QueryWithEnum, a, "sort=oldest");
    try testing.expectEqual(SortEnum.oldest, q2.sort);
    try testing.expect(q2.maybe == null);

    // Unknown variant -> error.BadRequest
    try testing.expectError(error.BadRequest, parseQuery(QueryWithEnum, a, "sort=unknown_variant"));
}

test "isQueryParseable: struct with non-string slice returns false" {
    const Bad = struct { tags: []const []const u8 };
    try testing.expect(!isQueryParseable(Bad));

    const AlsoBad = struct { ids: []const u32 };
    try testing.expect(!isQueryParseable(AlsoBad));

    const Good = struct { q: []const u8, limit: i32, kind: enum { a, b }, flag: ?bool };
    try testing.expect(isQueryParseable(Good));
}

test "isQueryParseable: nested struct returns false; mixed flat struct returns true" {
    // Nested struct field: must be rejected even if the inner struct is all scalars.
    try testing.expect(!isQueryParseable(struct { inner: struct { a: i32 } }));

    // Non-string slice: must be rejected.
    try testing.expect(!isQueryParseable(struct { tags: []const []const u8 }));

    // All query-scalar fields: must be accepted.
    const K = enum { a, b };
    try testing.expect(isQueryParseable(struct { q: []const u8, n: i32, k: K, opt: ?i32 }));

    // Bare scalars and optionals are NOT parseable (only void and flat structs are).
    try testing.expect(!isQueryParseable(i32));
    try testing.expect(!isQueryParseable(?i32));

    // void is still parseable.
    try testing.expect(isQueryParseable(void));
}

test "makeThunk wires req.ctx with app + arena" {
    const http = @import("http.zig");
    const Ctx = @import("ctx.zig").Ctx;
    // Container-level statics capture what the handler observed via req.ctx.
    const Observed = struct {
        var ctx_ptr: ?*Ctx = null;
        var arena_ptr: ?*anyopaque = null;
    };
    Observed.ctx_ptr = null;
    Observed.arena_ptr = null;
    const H = struct {
        fn h(req: *Req(void)) RouteError!void {
            Observed.ctx_ptr = req.ctx;
            Observed.arena_ptr = req.ctx.arena.ptr;
        }
    }.h;
    const thunk = makeThunk(H);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = http.RequestCtx{ .method = .POST, .path = "/x", .allocator = arena.allocator() };
    const rctx = @import("request.zig").RequestContext{ .auth = null, .is_superuser = false, .method = "POST" };
    var cx = Ctx{ .app = undefined, .arena = arena.allocator(), .rctx = rctx, .request = &ctx };
    defer cx.deinit();
    _ = try thunk(&cx);
    // req.ctx points exactly at the Ctx the thunk received...
    try testing.expect(Observed.ctx_ptr == &cx);
    // ...and that Ctx's arena is the request arena.
    try testing.expect(Observed.arena_ptr == arena.allocator().ptr);
}

test "makeThunk: RouteError -> status; req.fail -> custom status+message" {
    const http = @import("http.zig");
    const Ctx = @import("ctx.zig").Ctx;
    const H = struct {
        fn h(req: *Req(void)) RouteError!void {
            return req.fail(404, "Booking not found");
        }
    }.h;
    const thunk = makeThunk(H);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = http.RequestCtx{ .method = .POST, .path = "/x", .allocator = arena.allocator() };
    const rctx = @import("request.zig").RequestContext{ .auth = null, .is_superuser = false, .method = "POST" };
    var cx = Ctx{ .app = undefined, .arena = arena.allocator(), .rctx = rctx, .request = &ctx };
    defer cx.deinit();
    const resp = try thunk(&cx);
    try testing.expectEqual(@as(u16, 404), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "Booking not found") != null);
}
