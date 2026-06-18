# ZigBase SP2.2a — Framework Typed-Routes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace raw custom-route handlers with a typed-only contract whose `Input`/`Output` are reflected from the handler signature at comptime, validated against a bounded Zig→TS subset at app-build time, and dispatched via a generated thunk — and expose per-route metadata for the SP2.2b generator.

**Architecture:** A new framework-side `src/route_types.zig` defines `Req(Input)` + `RouteError` + the handler-type reflection + the bounded-subset comptime check + the per-handler dispatch thunk. `events.buildRoutes` is rewritten to validate each typed handler's I/O, wrap it in a thunk (reusing today's `RouteEvent` dispatch), and record comptime route metadata exposed on the `App` type. golfsim's four routes are migrated as the worked example.

**Tech Stack:** Zig 0.16.0 (`mise exec zig@0.16.0 -- zig …`), comptime metaprogramming (`@typeInfo`/`@TypeOf`), `std.json`.

## Global Constraints

- Build/test ONLY via `mise exec zig@0.16.0 -- zig …` (plain `zig` is 0.15.2 and fails). Run from the repo/worktree root.
- `zig build test` prints a `failed command: …/test …` line + provision warnings even on SUCCESS (exit 0) — judge by exit code 0 + absence of real `error:`/`panic`/assertion-failure lines, not that line. Prefer `mise exec zig@0.16.0 -- zig test <file>` for fast focused unit runs of a single file where possible; otherwise `zig build test`.
- **Typed-only, hard break:** the public route handler form becomes `fn(req: *Req(Input)) RouteError!Output`. The old `fn(*RouteEvent) !http.Response` form is no longer user-facing (it survives only as the internal thunk type `RuntimeRoute.handler`).
- **Single source of truth:** `Input`/`Output` are reflected from the handler; there is NO `.input`/`.output` on the route spec.
- **Break at app-build comptime:** unrepresentable `Input`/`Output` → `@compileError` naming route + field path + Zig type, raised from `buildRoutes` (so `zig build <app>` fails).
- **Bounded Zig→TS subset (pragmatic core):** struct of — ints/floats→`number`, `bool`→`boolean`, `[]const u8`→`string`, `?T`→nullable, `[]T`→`T[]` (`[]const u8`→`string`), nested structs (recursive), Zig enums (string union), `std.json.Value`→`unknown`. Everything else rejected.
- **Do NOT break the collection generator or existing tests.** `zig build`, `zig build test`, `zig build gen-dating-client-check`, `zig build gen-test`, golfsim `gen-client-check`, and the TS suites must stay green.
- SP2.2b (the generator's `zb.rpc.*` emission) is OUT OF SCOPE — 2.2a only EXPOSES the metadata the generator will read.
- Comptime-metaprogramming note for implementers: the comptime bodies below are the intended shape; verify each against the compiler as you TDD (Zig 0.16 `@typeInfo` tags are lowercase: `.@"struct"`, `.@"fn"`, `.error_union`, `.optional`, `.pointer`, `.int`, `.float`, `.bool`, `.@"enum"`). The TESTS are the binding spec.

---

## File Structure

- `src/route_types.zig` — **Create.** `Req(Input)`, `RouteError`, `req.fail`/error state, `req.param`/auth accessors; reflection (`HandlerInput`/`HandlerOutput`); bounded-subset `isRepresentable`/`assertRepresentable`; the `makeThunk` dispatch wrapper. One focused file: "everything a typed route needs at comptime + runtime."
- `src/events.zig` — **Modify.** `buildRoutes` rewrite (validate + thunk + metadata); add `RouteMeta` + `routeMeta(specs)`; keep `RuntimeRoute` (its `.handler` is now a thunk). Re-export `route_types` items consumers need (`Req`, `RouteError`).
- `src/zigbase.zig` (root module) — **Modify.** Re-export `Req`, `RouteError` at the top level (handlers reference `zigbase.Req(...)` / `zigbase.RouteError`).
- `src/codegen/identifiers.zig` — **Modify.** Add `routeMethodName(alloc, path, api_prefix)`.
- `src/framework.zig` — **Modify.** Expose `pub const routes` (comptime route metadata) on the `App` type, alongside `collections`.
- `examples/golfsim/src/main.zig` — **Modify.** Migrate the four handlers to typed form + their `Input`/`Output` structs.

---

## Task 1: `route_types.zig` — `Req(Input)`, `RouteError`, `req.fail`

**Files:**
- Create: `src/route_types.zig`
- Test: a `test {…}` block at the bottom of `src/route_types.zig`

**Interfaces:**
- Produces:
  - `pub const RouteError = error{ BadRequest, Unauthorized, Forbidden, NotFound, Conflict, RouteFailed };`
  - `pub fn Req(comptime InputT: type) type` returning a struct with `pub const Input = InputT;` and fields/methods below.
  - `pub fn statusForError(e: RouteError) u16` (default status mapping).

- [ ] **Step 1: Write the failing test** (append to `src/route_types.zig`):

```zig
const std = @import("std");
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
```

- [ ] **Step 2: Run it to verify it fails.** Run: `mise exec zig@0.16.0 -- zig test src/route_types.zig`. Expected: FAIL (Req/RouteError/Param undefined).

- [ ] **Step 3: Implement** (top of `src/route_types.zig`, above the tests):

```zig
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
```

- [ ] **Step 4: Run tests to verify they pass.** Run: `mise exec zig@0.16.0 -- zig test src/route_types.zig`. Expected: PASS (3 tests).

- [ ] **Step 5: Commit.**
```bash
git add src/route_types.zig
git commit -m "feat(routes): Req(Input) + RouteError + req.fail (typed-route building blocks)"
```

---

## Task 2: Handler-type reflection (`HandlerInput`/`HandlerOutput`)

**Files:**
- Modify: `src/route_types.zig`

**Interfaces:**
- Produces:
  - `pub fn HandlerInput(comptime H: type) type` — given a handler type `fn(*Req(I)) RouteError!O`, returns `I`.
  - `pub fn HandlerOutput(comptime H: type) type` — returns `O`.

- [ ] **Step 1: Write the failing test** (append to the test block):

```zig
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
```

- [ ] **Step 2: Run it to verify it fails.** Run: `mise exec zig@0.16.0 -- zig test src/route_types.zig`. Expected: FAIL (HandlerInput undefined).

- [ ] **Step 3: Implement** (add to `route_types.zig`):

```zig
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
```

- [ ] **Step 4: Run tests to verify they pass.** Run: `mise exec zig@0.16.0 -- zig test src/route_types.zig`. Expected: PASS.

- [ ] **Step 5: Commit.**
```bash
git add src/route_types.zig
git commit -m "feat(routes): reflect Input/Output from typed handler signatures"
```

---

## Task 3: Bounded Zig→TS subset check (`isRepresentable`/`assertRepresentable`)

**Files:**
- Modify: `src/route_types.zig`

**Interfaces:**
- Produces:
  - `pub fn isRepresentable(comptime T: type) bool` — comptime predicate for the bounded subset (returns bool, testable).
  - `pub fn assertRepresentable(comptime T: type, comptime route_name: []const u8) void` — `@compileError` (naming the route + field path + type) when not representable.

- [ ] **Step 1: Write the failing test** (append; tests the BOOL predicate — the `@compileError` path is verified manually in Step 6):

```zig
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
```

- [ ] **Step 2: Run it to verify it fails.** Run: `mise exec zig@0.16.0 -- zig test src/route_types.zig`. Expected: FAIL (isRepresentable undefined).

- [ ] **Step 3: Implement** (add to `route_types.zig`). `std.json.Value` is detected by identity so the recursive walk treats it as the `unknown` escape hatch:

```zig
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
```

- [ ] **Step 4: Run tests to verify they pass.** Run: `mise exec zig@0.16.0 -- zig test src/route_types.zig`. Expected: PASS.

- [ ] **Step 5: Verify the `@compileError` path manually.** Temporarily append a throwaway to `src/route_types.zig`:
```zig
comptime { assertRepresentable(struct { bad: *u8 }, "tmpRoute"); }
```
Run: `mise exec zig@0.16.0 -- zig test src/route_types.zig`. Expected: a COMPILE ERROR containing `route 'tmpRoute' field 'bad': type *u8 is not representable`. Then **remove** the throwaway block (use Edit, not `git checkout`) and re-run Step 4 to confirm green.

- [ ] **Step 6: Commit.**
```bash
git add src/route_types.zig
git commit -m "feat(routes): bounded Zig→TS subset check (isRepresentable + assertRepresentable @compileError)"
```

---

## Task 4: The dispatch thunk (`makeThunk`)

**Files:**
- Modify: `src/route_types.zig`
- Test: in `src/route_types.zig` (thunk invoked with a fabricated `RouteEvent`-shaped input)

**Interfaces:**
- Consumes: `Req`, `HandlerInput`/`HandlerOutput`, `RouteError`, `statusForError` (Tasks 1-3); `http.RequestCtx`/`http.Response`, `events.RouteEvent` (existing).
- Produces: `pub fn makeThunk(comptime handler: anytype) events.RouteHandler` — a `fn(*RouteEvent) anyerror!http.Response` that parses `Input`, builds `Req`, calls `handler`, serializes `Output`→200 (or 204 for void), and maps `RouteError`/`req.failure`→status+message.

**Note on imports:** `route_types.zig` must now import `http`/`events`. To avoid a cycle (events imports route_types for `Req`/`RouteError`, route_types imports events for `RouteEvent`/`RouteHandler`), keep `Req`/`RouteError`/reflection/`isRepresentable` in `route_types.zig` (no events import) and place `makeThunk` ALSO in `route_types.zig` but importing `events`/`http` lazily inside the function body via `@import` (Zig allows `const events = @import("events.zig");` at function scope). Verify no import cycle compile error; if one arises, move ONLY `makeThunk` into `events.zig` (it already imports http) and have it call `route_types` for reflection — note this fallback in your report.

- [ ] **Step 1: Write the failing test** (append). The thunk takes a `*RouteEvent`; build a minimal one with a `RequestCtx` carrying `body`/`params`:

```zig
test "makeThunk: parses input, serializes output (200)" {
    const http = @import("http.zig");
    const events = @import("events.zig");
    const In = struct { guests: u32 };
    const Out = struct { id: []const u8, confirmed: bool };
    const H = struct {
        fn h(req: *Req(In)) RouteError!Out {
            try testing.expectEqual(@as(u32, 2), req.input.guests);
            try testing.expectEqualStrings("bk1", req.param("id").?);
            return .{ .id = req.param("id").?, .confirmed = true };
        }
    }.h;
    const thunk = makeThunk(H);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var params = [_]http.Param{.{ .key = "id", .value = "bk1" }};
    var ctx = http.RequestCtx{
        .method = .POST, .path = "/api/bookings/bk1/confirm",
        .body = "{\"guests\":2}", .allocator = arena.allocator(), .params = &params,
    };
    var rctx = @import("request.zig").RequestContext{ .auth = null, .is_superuser = false, .method = "POST" };
    var ev = events.RouteEvent{ .app = undefined, .ctx = &ctx, .rctx = rctx };
    const resp = try thunk(&ev);
    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"confirmed\":true") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"id\":\"bk1\"") != null);
}

test "makeThunk: RouteError -> status; req.fail -> custom status+message" {
    const http = @import("http.zig");
    const events = @import("events.zig");
    const H = struct {
        fn h(req: *Req(void)) RouteError!void {
            return req.fail(404, "Booking not found");
        }
    }.h;
    const thunk = makeThunk(H);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = http.RequestCtx{ .method = .POST, .path = "/x", .allocator = arena.allocator() };
    var rctx = @import("request.zig").RequestContext{ .auth = null, .is_superuser = false, .method = "POST" };
    var ev = events.RouteEvent{ .app = undefined, .ctx = &ctx, .rctx = rctx };
    const resp = try thunk(&ev);
    try testing.expectEqual(@as(u16, 404), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "Booking not found") != null);
}
```

- [ ] **Step 2: Run it to verify it fails.** Run: `mise exec zig@0.16.0 -- zig test src/route_types.zig`. Expected: FAIL (makeThunk undefined).

- [ ] **Step 3: Implement** (add to `route_types.zig`). Input parsing: `void`→skip; for GET/DELETE parse from `ctx.query` (form-decoded into the struct — for 2.2a, parse query as JSON-less key=value into the Input struct's string/number fields; if that's heavy, GET routes in golfsim use only path params + `void` input, so a minimal query parser covering golfsim suffices — see Task 8), otherwise parse `ctx.body` as JSON via `std.json.parseFromSlice`:

```zig
/// Wrap a typed handler `fn(*Req(I)) RouteError!O` into a RouteHandler thunk
/// (`fn(*RouteEvent) anyerror!http.Response`). Comptime-specialized per handler.
pub fn makeThunk(comptime handler: anytype) @import("events.zig").RouteHandler {
    const H = @TypeOf(handler);
    const In = HandlerInput(H);
    const Out = HandlerOutput(H);
    const events = @import("events.zig");
    const http = @import("http.zig");

    const Thunk = struct {
        fn run(ev: *events.RouteEvent) anyerror!http.Response {
            const a = ev.ctx.allocator;
            // 1. Parse input.
            const input: In = if (In == void) {} else blk: {
                if (ev.ctx.method == .GET or ev.ctx.method == .DELETE) {
                    break :blk parseQuery(In, a, ev.ctx.query) catch
                        return badRequest(a, "Invalid query parameters.");
                }
                if (ev.ctx.body.len == 0) return badRequest(a, "Missing request body.");
                break :blk (std.json.parseFromSlice(In, a, ev.ctx.body, .{ .ignore_unknown_fields = true }) catch
                    return badRequest(a, "Invalid JSON body.")).value;
            };
            // 2. Build Req. Map RouteEvent's params (http.Param) onto route_types.Param.
            var params = try a.alloc(Param, ev.ctx.params.len);
            for (ev.ctx.params, 0..) |p, i| params[i] = .{ .key = p.key, .value = p.value };
            const auth_id = ev.rctx.resolveMacro("@request.auth.id") orelse "";
            var req = Req(In){ .input = input, .params = params, .auth_id = auth_id, .app = ev.app, .arena = a };
            // 3. Call handler; map errors.
            const out: Out = handler(&req) catch |e| {
                if (req.failure) |f|
                    return jsonError(a, f.status, f.message);
                const re: RouteError = @errorCast(e);
                return jsonError(a, statusForError(re), @errorName(re));
            };
            // 4. Serialize output (204 for void).
            if (Out == void) return .{ .status = 204, .body = "" };
            const body = try std.json.Stringify.valueAlloc(a, out, .{});
            return .{ .status = 200, .body = body };
        }
    };
    return Thunk.run;
}

fn badRequest(a: std.mem.Allocator, msg: []const u8) @import("http.zig").Response {
    return jsonError(a, 400, msg) catch .{ .status = 400, .body = "{\"message\":\"Bad request.\"}" };
}

fn jsonError(a: std.mem.Allocator, status: u16, message: []const u8) !@import("http.zig").Response {
    const body = try std.fmt.allocPrint(a, "{{\"message\":{}}}", .{std.json.fmt(message, .{})});
    return .{ .status = status, .body = body };
}

/// Minimal x-www-form / query parser into a struct of string/number/bool fields.
/// Covers GET routes whose Input is flat (golfsim's GET routes use void input today).
fn parseQuery(comptime T: type, a: std.mem.Allocator, query: []const u8) !T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const raw = findQueryValue(query, f.name);
        @field(result, f.name) = try coerceQueryField(f.type, a, raw);
    }
    return result;
}
// coerceQueryField / findQueryValue: implement per the field types you actually need
// (string -> the raw slice; int -> std.fmt.parseInt; bool -> "true"/"1"). Keep minimal:
// 2.2a's golfsim GET routes declare `Req(void)`, so this path is only exercised by the
// dedicated parseQuery unit test you add if/when a GET route gains a typed Input.
```

Note: `std.json.fmt` / `std.json.Stringify` exact spelling — verify against the codebase's existing usage (see `src/api/records.zig` for `std.json.Stringify.valueAlloc`); if `std.json.fmt` for escaping a bare string isn't available in this Zig, build the message object via a small `std.json.ObjectMap` and `Stringify.valueAlloc` instead (the pattern `confirmBooking` uses).

- [ ] **Step 4: Run tests to verify they pass.** Run: `mise exec zig@0.16.0 -- zig test src/route_types.zig`. Expected: PASS (both thunk tests).

- [ ] **Step 5: Commit.**
```bash
git add src/route_types.zig
git commit -m "feat(routes): makeThunk — typed handler -> RouteEvent dispatch (parse/serialize/error-map)"
```

---

## Task 5: `routeMethodName` (name-from-path)

**Files:**
- Modify: `src/codegen/identifiers.zig`
- Test: in `src/codegen/identifiers.zig` test block

**Interfaces:**
- Consumes: `pascal` (existing).
- Produces: `pub fn routeMethodName(alloc: std.mem.Allocator, path: []const u8, api_prefix: []const u8) ![]const u8` — strip `api_prefix`, drop `:param` segments, camel-join the rest.

- [ ] **Step 1: Write the failing test** (append to identifiers.zig tests):

```zig
test "routeMethodName camel-joins non-param segments" {
    const a = std.testing.allocator;
    const cases = [_]struct { path: []const u8, want: []const u8 }{
        .{ .path = "/api/bookings/:id/confirm", .want = "bookingsConfirm" },
        .{ .path = "/api/listings/:id/availability", .want = "listingsAvailability" },
        .{ .path = "/api/golfsim/health", .want = "golfsimHealth" },
        .{ .path = "/api/ping", .want = "ping" },
    };
    inline for (cases) |c| {
        const got = try routeMethodName(a, c.path, "/api");
        defer a.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}
```

- [ ] **Step 2: Run it to verify it fails.** Run: `mise exec zig@0.16.0 -- zig test src/codegen/identifiers.zig`. Expected: FAIL.

- [ ] **Step 3: Implement** (add to identifiers.zig):

```zig
/// Derive a camelCase RPC method name from a route path: strip the api-prefix, drop
/// `:param` segments, and camel-join the remaining segments. First segment lowercase,
/// subsequent segments PascalCased: "/api/bookings/:id/confirm" -> "bookingsConfirm".
pub fn routeMethodName(alloc: std.mem.Allocator, path: []const u8, api_prefix: []const u8) ![]const u8 {
    var rest = path;
    if (std.mem.startsWith(u8, rest, api_prefix)) rest = rest[api_prefix.len..];
    var out: std.ArrayList(u8) = .empty;
    var first = true;
    var it = std.mem.tokenizeScalar(u8, rest, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or seg[0] == ':') continue; // skip path params
        if (first) {
            // first segment: lowercase as-is (camelCase start).
            try out.appendSlice(alloc, seg);
            first = false;
        } else {
            const p = try pascal(alloc, seg);
            defer alloc.free(p);
            try out.appendSlice(alloc, p);
        }
    }
    return out.toOwnedSlice(alloc);
}
```

- [ ] **Step 4: Run tests to verify they pass.** Run: `mise exec zig@0.16.0 -- zig test src/codegen/identifiers.zig`. Expected: PASS.

- [ ] **Step 5: Commit.**
```bash
git add src/codegen/identifiers.zig
git commit -m "feat(codegen): routeMethodName — camel-join non-param path segments"
```

---

## Task 6: `buildRoutes` rewrite — validate + thunk + metadata + collision

**Files:**
- Modify: `src/events.zig` (`buildRoutes`, `RuntimeRoute`, add `RouteMeta` + `routeMeta`; update `validateRouteSpecs`)
- Test: in `src/events.zig` test block

**Interfaces:**
- Consumes: `route_types.makeThunk` / `assertRepresentable` / `HandlerInput` / `HandlerOutput` (Tasks 2-4); `identifiers.routeMethodName` is codegen-side, so name derivation for the COMPTIME-error collision check uses a comptime path→name helper added here (codegen reuses its own at emit time). For 2.2a, add a comptime `comptimeRouteName(comptime path, comptime name_override)` in events.zig that mirrors `routeMethodName` (comptime-friendly, no allocator).
- Produces:
  - `RuntimeRoute` unchanged in shape (`.handler` is now the thunk).
  - `pub const RouteMeta = struct { method: http.Method, path: []const u8, name: []const u8, auth: AuthLevel, Input: type, Output: type };`
  - `pub fn routeMeta(comptime specs: anytype) []const RouteMeta` — comptime metadata (consumed by the generator in 2.2b).
  - `buildRoutes(comptime specs)` now: per spec, `assertRepresentable(HandlerInput(...))` + `assertRepresentable(HandlerOutput(...))`, derive name (override or `comptimeRouteName`), `@compileError` on duplicate names, and store `makeThunk(spec.handler)` as the RuntimeRoute handler.

- [ ] **Step 1: Write the failing test** (append to events.zig tests). Use a typed handler in the spec:

```zig
test "buildRoutes builds thunks + metadata with derived names" {
    const route_types = @import("route_types.zig");
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
```

- [ ] **Step 2: Run it to verify it fails.** Run: `mise exec zig@0.16.0 -- zig test src/events.zig` (or `zig build test`). Expected: FAIL.

- [ ] **Step 3: Implement.** Add the imports + `RouteMeta`/`comptimeRouteName`/`routeMeta`, and rewrite `buildRoutes`:

```zig
const route_types = @import("route_types.zig");

pub const RouteMeta = struct {
    method: http.Method,
    path: []const u8,
    name: []const u8,
    auth: AuthLevel,
    Input: type,
    Output: type,
};

/// Comptime path→method-name (mirrors codegen identifiers.routeMethodName) with an
/// optional `.name` override. Strips "/api" prefix + ":param" segments, camel-joins.
fn comptimeRouteName(comptime path: []const u8, comptime override: ?[]const u8) []const u8 {
    if (override) |n| return n;
    comptime {
        var rest: []const u8 = path;
        const prefix = "/api";
        if (std.mem.startsWith(u8, rest, prefix)) rest = rest[prefix.len..];
        var name: []const u8 = "";
        var first = true;
        var it = std.mem.tokenizeScalar(u8, rest, '/');
        while (it.next()) |seg| {
            if (seg.len == 0 or seg[0] == ':') continue;
            if (first) { name = seg; first = false; }
            else {
                var s: []const u8 = &[_]u8{std.ascii.toUpper(seg[0])};
                s = s ++ seg[1..];
                name = name ++ s;
            }
        }
        return name;
    }
}

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

pub fn buildRoutes(comptime specs: anytype) []const RuntimeRoute {
    comptime validateRouteSpecs(specs);
    const fields = std.meta.fields(@TypeOf(specs));
    const meta = comptime routeMeta(specs);
    // Collision check + representability validation at comptime.
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
    const Holder = struct {
        const table: [fields.len]RuntimeRoute = blk: {
            var t: [fields.len]RuntimeRoute = undefined;
            for (fields, 0..) |f, i| {
                const s = @field(specs, f.name);
                t[i] = .{
                    .method = s.method,
                    .pattern = s.path,
                    .handler = route_types.makeThunk(s.handler),
                    .auth = if (@hasField(@TypeOf(s), "auth")) s.auth else .superuser,
                };
            }
            break :blk t;
        };
    };
    return &Holder.table;
}
```
Also update `validateRouteSpecs` (events.zig:214-224): it must now accept `.name` as an allowed optional field and no longer require/permit a raw-Response handler shape (the handler is the typed form — its shape is validated by `HandlerInput`/`HandlerOutput` `@compileError`s). Keep requiring `.method`/`.path`/`.handler`.

- [ ] **Step 4: Run tests to verify they pass.** Run: `mise exec zig@0.16.0 -- zig test src/events.zig`. Expected: PASS.

- [ ] **Step 5: Verify collision @compileError manually.** Temporarily add two specs deriving the same name (e.g. two `/api/items/:id/confirm` with different methods) in a throwaway `comptime { _ = buildRoutes(.{...}); }`; `zig test src/events.zig` must error with `duplicate route method name 'itemsConfirm'`. Remove the throwaway (Edit, not checkout); re-run Step 4.

- [ ] **Step 6: Commit.**
```bash
git add src/events.zig
git commit -m "feat(routes): buildRoutes — typed handlers -> thunks + comptime route metadata + collision guard"
```

---

## Task 7: Re-export `Req`/`RouteError` + expose `App.routes`

**Files:**
- Modify: `src/zigbase.zig` (root module re-exports)
- Modify: `src/framework.zig` (App type: `pub const routes`)
- Test: in `src/framework.zig` test block (read `App.routes` at comptime)

**Interfaces:**
- Produces:
  - `zigbase.Req` / `zigbase.RouteError` (top-level re-exports for handler authors).
  - `App.routes: []const events.RouteMeta` — the comptime route metadata (mirrors `App.collections`), consumed by the SP2.2b generator.

- [ ] **Step 1: Write the failing test** (append to framework.zig tests):

```zig
test "App exposes route metadata for codegen" {
    const route_types = @import("route_types.zig");
    const In = struct { n: u32 };
    const TestApp = App(.{
        .routes = .{
            .{
                .method = http.Method.POST, .path = "/api/widgets/:id/poke",
                .auth = AuthLevel.authed,
                .handler = struct {
                    fn h(req: *route_types.Req(In)) route_types.RouteError!void { _ = req; }
                }.h,
            },
        },
    });
    try std.testing.expectEqual(@as(usize, 1), TestApp.routes.len);
    try std.testing.expectEqualStrings("widgetsPoke", TestApp.routes[0].name);
    try std.testing.expect(TestApp.routes[0].Input == In);
}
```

- [ ] **Step 2: Run it to verify it fails.** Run: `mise exec zig@0.16.0 -- zig test src/framework.zig` (or `zig build test`). Expected: FAIL (`App.routes` undefined).

- [ ] **Step 3: Implement.**
In `src/framework.zig`'s `App(comptime cfg: anytype)`, beside `pub const collections` (lines ~230-233), add:
```zig
pub const routes: []const events.RouteMeta = if (@hasField(@TypeOf(cfg), "routes"))
    events.routeMeta(cfg.routes)
else
    &.{};
```
In `src/zigbase.zig`, add top-level re-exports next to the existing `RouteEvent`/`http` exports:
```zig
pub const Req = @import("route_types.zig").Req;
pub const RouteError = @import("route_types.zig").RouteError;
```
(Confirm the exact export style by matching how `RouteEvent` is currently re-exported in `src/zigbase.zig`.)

- [ ] **Step 4: Run tests to verify they pass.** Run: `mise exec zig@0.16.0 -- zig test src/framework.zig`. Expected: PASS.

- [ ] **Step 5: Full build + test (no regressions to collections).** Run: `mise exec zig@0.16.0 -- zig build` then `mise exec zig@0.16.0 -- zig build test`. Expected: exit 0 (ignore the `failed command:` quirk line). Also `mise exec zig@0.16.0 -- zig build gen-dating-client-check` + `zig build gen-test` exit 0 (the collection generator is untouched).

- [ ] **Step 6: Commit.**
```bash
git add src/zigbase.zig src/framework.zig
git commit -m "feat(routes): re-export Req/RouteError + expose App.routes metadata for codegen"
```

---

## Task 8: Migrate golfsim's four routes to typed handlers

**Files:**
- Modify: `examples/golfsim/src/main.zig`

**Interfaces:**
- Consumes: `zigbase.Req`, `zigbase.RouteError` (Task 7).

Migrate each handler to `fn(req: *zigbase.Req(Input)) zigbase.RouteError!Output`, declaring `Input`/`Output` structs. The routes' wire behavior must stay identical (paths unchanged, same JSON responses) so the existing golfsim e2e (SP2.1b) still passes via the untyped `zb.send`.

- [ ] **Step 1: Define Input/Output structs + migrate `confirmBooking`/`cancelBooking`.** These take only the path param `:id` (no body) and return the updated booking. Model `Output` as `std.json.Value` (the booking is a dynamic record — `unknown` on the client) for now; `Input` is `void` (the `:id` is a path param, read via `req.param`):

```zig
fn confirmBooking(req: *zigbase.Req(void)) zigbase.RouteError!std.json.Value {
    const id = req.param("id") orelse return req.fail(400, "Missing booking id.");
    if (!isSafeId(id)) return req.fail(400, "Invalid booking id.");
    const caller_id = req.auth_id;
    const app: *zigbase.App = @ptrCast(@alignCast(req.app.?));
    const conn = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const data = zigbase.Data{ .app = app, .conn = conn, .io = app.io };
    const existing = (data.findById("bookings", id) catch return error.RouteFailed) orelse return error.NotFound;
    if (existing != .object) return error.NotFound;
    // ... same multi-hop owner check as the original, returning error.NotFound / error.Forbidden ...
    if (!owner_ok) return error.Forbidden;
    var patch: std.json.ObjectMap = .empty;
    try patch.put(req.arena.?, "status", .{ .string = "confirmed" });
    const updated = (data.update("bookings", id, .{ .object = patch }) catch return error.RouteFailed) orelse return error.NotFound;
    return updated; // thunk serializes -> 200 JSON
}
```
(Apply the same transform to `cancelBooking`: `Req(void)` → `std.json.Value`, path-param `:id`, guest-ownership check → `error.Forbidden`, status→"cancelled". Reuse the original's logic verbatim, swapping raw `Response` returns for `RouteError` / `req.fail`, and `ev.ctx.allocator`→`req.arena.?`, `ev.rctx.resolveMacro("@request.auth.id")`→`req.auth_id`, `ev.app`→the `@ptrCast` app, `ev.writer()`→`app.pool.acquireWriter()` pattern shown.) Errors map: 404→`error.NotFound`, 403→`error.Forbidden`, 400→`req.fail(400, …)`.

- [ ] **Step 2: Migrate `listingAvailability` (GET, returns an items wrapper).** Output is a wrapper struct; keep it `std.json.Value` to preserve the exact `{"items":[...]}` body, OR define `const AvailabilityOut = struct { items: []std.json.Value };` and build it. Simplest preserving behavior — return `std.json.Value`:
```zig
fn listingAvailability(req: *zigbase.Req(void)) zigbase.RouteError!std.json.Value {
    const id = req.param("id") orelse return req.fail(400, "Missing listing id.");
    if (!isSafeId(id)) return req.fail(400, "Invalid listing id.");
    const app: *zigbase.App = @ptrCast(@alignCast(req.app.?));
    var r = app.pool.acquireReader() catch return error.RouteFailed;
    defer app.pool.releaseReader(&r);
    const data = ... ; // reader-bound Data facade (mirror original ev.reader().data())
    const filter = try std.fmt.allocPrint(req.arena.?, "listing = \"{s}\" && status != \"cancelled\"", .{id});
    const result = data.list("bookings", .{ .filter = filter, .perPage = 200 }) catch return error.RouteFailed;
    var arr: std.json.Array = .empty;
    for (result.items) |item| try arr.append(req.arena.?, item);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(req.arena.?, "items", .{ .array = arr });
    return .{ .object = obj };
}
```
(Confirm the reader-bound `Data` construction against the original `ev.reader()`/`r.data()` shape; the original used `var r = try ev.reader(); defer r.deinit(); r.data().list(...)`.)

- [ ] **Step 3: Migrate `health` (no input, no DB).** A typed struct output (so the client gets a typed health shape):
```zig
const HealthOut = struct { status: []const u8, app: []const u8 };
fn health(req: *zigbase.Req(void)) zigbase.RouteError!HealthOut {
    _ = req;
    return .{ .status = "ok", .app = "golfsim" };
}
```

- [ ] **Step 4: Routes declarations unchanged in shape** (the spec still `.{ .method, .path, .handler, .auth }`; `.handler` now points at the typed fns). Leave `examples/golfsim/src/main.zig`'s `.routes` block as-is (paths/methods/auth unchanged).

- [ ] **Step 5: Build golfsim.** Run: `cd examples/golfsim && mise exec zig@0.16.0 -- zig build`. Expected: exit 0 (golfsim compiles with typed handlers; `App.routes` metadata builds; representability check passes — all Inputs are `void`, Outputs are `std.json.Value`/`HealthOut`, all representable).

- [ ] **Step 6: Run golfsim's e2e (behavior unchanged).** Run: `cd examples/golfsim && mise exec node@24 -- npm run test:e2e` (build `@zigbase/client` first if needed per the SP2.1b harness). Expected: the e2e passes — the routes respond identically (the e2e calls them via `zb.send`, which is unaffected). If a response body differs (e.g. confirm/cancel now 204 vs 200), adjust the handler to return the record (200) as the original did — do NOT change the e2e's expectations unless the original behavior genuinely changed.

- [ ] **Step 7: Commit.**
```bash
git add examples/golfsim/src/main.zig
git commit -m "feat(golfsim): migrate the four custom routes to typed handlers (Req/RouteError)"
```

---

## Task 9: Whole-build green + metadata sanity

**Files:** none (verification + a small sanity test).

- [ ] **Step 1: Full Zig build + test.** Run: `mise exec zig@0.16.0 -- zig build` then `mise exec zig@0.16.0 -- zig build test`. Expected: exit 0 (ignore the `failed command:` quirk).
- [ ] **Step 2: Collection generator unaffected.** Run: `mise exec zig@0.16.0 -- zig build gen-dating-client-check` + `zig build gen-test` + `( cd examples/golfsim && mise exec zig@0.16.0 -- zig build gen-client-check )`. Expected: all exit 0 (routes don't touch collection codegen; golfsim's collection client is unchanged).
- [ ] **Step 3: TS suites unaffected.** Run from `clients/typescript`: `mise exec node@24 -- npm run typecheck && npm test && npm run test:integration`. Expected: exit 0 (no client-side change in 2.2a).
- [ ] **Step 4: Commit any final fixups** (if Steps 1-3 surfaced anything), else nothing to commit.

---

## Self-review notes (for the executor)

- **Spec coverage:** route spec (Task 6/8), typed handler `Req`/`RouteError`/`req.fail` (Tasks 1,8), `route_types.zig` reflection + bounded-subset comptime check (Tasks 2,3), dispatch thunk (Task 4), per-route metadata on `App` (Tasks 6,7), name-from-path + collision (Tasks 5,6), golfsim migration (Task 8). SP2.2b (generator `zb.rpc.*`) intentionally absent.
- **Import-cycle risk (Task 4):** `events ↔ route_types`. Mitigation: `makeThunk` imports `events` lazily at function scope; if the compiler still cycles, move `makeThunk` into `events.zig`. Flag whichever you did.
- **Comptime fragility:** the `@typeInfo` tag spellings and the `Holder`-const-for-static-lifetime pattern (copied from the existing `buildRoutes`) are the load-bearing idioms; lean on the per-task `zig test <file>` runs to catch comptime errors early.
- **golfsim behavior parity** is the integration guard — the existing e2e must pass unchanged (Task 8 Step 6).
