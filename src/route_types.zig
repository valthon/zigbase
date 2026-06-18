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

/// The typed request handed to a route handler. `Input` is the parsed body/query;
/// `params` are path params; `auth_id` is the caller's id ("" when anonymous).
/// `app`/`io` give DB access (same handles as RouteEvent today). `failure` is set by `fail`.
pub fn Req(comptime InputT: type) type {
    return struct {
        const Self = @This();
        pub const Input = InputT;

        input: InputT,
        params: []const Param,
        auth_id: []const u8,
        failure: ?Failure = null,
        // Runtime handles wired by the thunk (opaque here to keep route_types import-light;
        // the thunk sets these from the RouteEvent). Untyped pointers avoid a framework import cycle.
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
    const ReqT = ptr_info.pointer.child;
    if (!@hasDecl(ReqT, "Input")) @compileError("route handler parameter must be *Req(Input) (missing Req.Input)");
    return ReqT.Input;
}

/// Extract `Output` from a handler type `fn(...) RouteError!Output` (the error-union payload).
pub fn HandlerOutput(comptime H: type) type {
    const info = @typeInfo(H);
    const ret = info.@"fn".return_type orelse @compileError("route handler return type is unknown");
    const ret_info = @typeInfo(ret);
    if (ret_info != .error_union) @compileError("route handler must return RouteError!Output");
    return ret_info.error_union.payload;
}

const testing = std.testing;

test "Req carries typed input + records a custom failure" {
    const In = struct { note: []const u8 };
    var ctx_params = [_]Param{.{ .key = "id", .value = "abc" }};
    var req = Req(In){
        .input = .{ .note = "hi" },
        .params = &ctx_params,
        .auth_id = "user1",
        .failure = null,
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
