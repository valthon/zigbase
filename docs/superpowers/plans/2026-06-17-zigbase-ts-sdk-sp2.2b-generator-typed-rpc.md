# ZigBase TS SDK — SP2.2b: Generator Typed RPC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the pure-Zig TypeScript client generator to read the typed-route metadata `App.routes` (exposed by SP2.2a) and emit a typed `zb.rpc.*` surface — `<Name>Input`/`<Name>Output` interfaces plus thin `send`-wrapping methods — on the generated client.

**Architecture:** A new comptime Zig-type→TS emitter (`rpc_ts.zig`) walks each route's `Input`/`Output` `type` and produces TS interface text; a renderer (`rpc.zig`) assembles the full RPC section (interfaces + the `rpc` member of the client interface + the `rpc: {…}` factory object); `gen_client.zig`/`gen_main.zig` splice that section into the existing generated client. Route names come from `RouteMeta.name` (the single source of truth computed by the framework's `comptimeRouteName`) — never recomputed in codegen — so framework metadata and generated method names cannot diverge. RPC methods are thin wrappers over the base client's existing `send` (no new runtime).

**Tech Stack:** Zig 0.16 (comptime metaprogramming + `std.ArrayList(u8)` text emission), TypeScript (the generated client + `vitest`/`tsd`-style type tests), the existing `@zigbase/client` base SDK.

## Global Constraints

- **Zig toolchain is 0.16.0 ONLY.** Always invoke as `mise exec zig@0.16.0 -- zig …`. Plain `zig` is 0.15.2 and WILL fail. `zig build test` prints a benign trailing `failed command:` line even on success — judge by exit code 0 and the absence of real `error:`/`panic:`/assertion lines.
- **Do NOT break the SP2.1b collection generator or its tests.** The `db.*`/`realtime.*`/`files` surface, the dating golden snapshot's existing sections, and all `gen-*-check` staleness gates must still pass. RPC is purely additive (a new `rpc` member + new interfaces).
- **`zb.rpc.*` is a NEW namespace** alongside `db`/`realtime`/`files`; RPC method names must not collide with each other (reuse the `@compileError`-on-collision discipline from SP2.1b/SP2.2a).
- **Route names are derived once, in the framework.** The generator consumes `RouteMeta.name`; it must NOT call `identifiers.routeMethodName` for emission. Keep `routeMethodName` only as a tested cross-check helper.
- **The bounded Zig→TS subset** (from the spec "What it emits & mapping rules"): `i*/u*/f32/f64`→`number`, `bool`→`boolean`, `[]const u8`→`string`, `?T`→`T | null`, `[]T` (T≠u8)→`T[]`, nested `struct`→named `interface` (recursive), `enum`→string-literal union, `std.json.Value`→`unknown`, **anything else → `@compileError` naming route + field + type**. `void` Output → `Promise<void>`; `void` Input → method takes no `input` argument.
- **Call shape (from spec B1):** `rpc.<name>(params: { <:seg>: string }, input: <Name>Input, opts?: SendOptions): Promise<<Name>Output>` — the `params` object is present **iff** the route has `:param` path segments (omitted otherwise); the `input` argument is present **iff** `Input` is not `void`; `opts?` is always last. GET/DELETE encode `input` as the query string; POST/PUT/PATCH send it as the JSON body. Path params interpolate into `route.path` (which already includes the `/api` prefix).
- **`--api-prefix` is finally consumed:** the generator validates that every `route.path` starts with the supplied `--api-prefix` (default `/api`), erroring with a clear message if the framework's route prefix and the generator's flag disagree.
- **Per repo convention:** every PR keeps published docs/examples in sync — update `clients/typescript/README.md`, the `examples/golfsim` README if present, and any `docs/*.md` mirror that documents the generated client surface. (Do NOT edit historic plan/spec docs.)

---

## File Structure

**New files:**
- `src/codegen/rpc_ts.zig` — comptime Zig-`type`→TS-text emitter. `tsForType(comptime T) []const u8` for inline (anonymous) TS types, `collectNamedTypes(comptime T)` to gather nested structs/enums that need named `interface`/union declarations, `isRepresentable(comptime T) bool` predicate (mirrors `route_types.assertRepresentable`'s walk but for the codegen's own guard messages). One responsibility: turn a single Zig type into TS.
- `src/codegen/rpc.zig` — comptime RPC-section renderer. `renderInterfaces(comptime routes) []const u8`, `renderClientInterfaceMember(comptime routes) []const u8`, `renderFactoryMember(comptime routes) []const u8`, and a top-level `render(comptime routes) Section` bundling the three. Uses `rpc_ts.zig`. One responsibility: assemble the route list into TS.

**Modified files:**
- `src/events.zig` — harden `comptimeRouteName` to strip `-`/`_` within a segment (match codegen's `pascal`), so the two name algorithms are provably identical.
- `src/codegen/identifiers.zig` — add a unit test asserting `routeMethodName(path) == comptimeRouteName(path)` for representative paths (drift guard).
- `src/codegen/gen_client.zig` — `generate(...)` and `emitClientFactory(...)` gain a `routes`-derived RPC section: emit the `<Name>Input`/`<Name>Output` interfaces, add the `rpc: { … }` member to the `ZbClient` interface, and add the `rpc: { … }` object to the `createClient` return. Plus the `--api-prefix` startsWith validation.
- `src/codegen/gen_main.zig` — pass `@import("app").App.routes` (comptime) into the generator alongside `App.collections`.
- `fixtures/dating/schema.zig` — add typed routes with pure (non-DB) handlers covering every Input/Output shape, so the golden snapshot and the live dating-server exercise the RPC surface.
- `clients/typescript/test/codegen/dating/zbase.gen.ts` — regenerated golden (gains the `rpc` surface).
- `examples/golfsim/clients/typescript/zbase.gen.ts` — regenerated golfsim snapshot (gains the `rpc` surface).
- `clients/typescript/README.md` (+ any `docs/*.md` that documents the client surface) — document `zb.rpc.*`.

**New tests:**
- `clients/typescript/test/codegen/dating/zbase.rpc.test-d.ts` — type-level assertions over the generated `rpc` surface.
- `clients/typescript/test/integration/rpc.integration.test.ts` — live, against the dating-server binary, exercising query-input + a `RouteError`→throw.
- `examples/golfsim/test/golfsim.e2e.test.ts` — migrated from `zb.send` to `zb.rpc.*`.

---

## Reference: shapes this plan builds on (read once)

`RouteMeta` (`src/events.zig`):
```zig
pub const RouteMeta = struct {
    method: http.Method,   // .GET/.POST/.PUT/.PATCH/.DELETE
    path: []const u8,      // full path incl. prefix, e.g. "/api/bookings/:id/confirm"
    name: []const u8,      // camelJoined method name, e.g. "bookingsConfirm"
    auth: AuthLevel,
    Input: type,           // comptime-only
    Output: type,          // comptime-only (error-union payload)
};
```
`App.routes: []const events.RouteMeta` is exposed on every `App(cfg)` type (and is `&.{}` when a config has no `.routes`).

Base client (`clients/typescript/src/client.ts`):
```ts
export interface SendOptions {
  query?: Record<string, string | number | boolean | undefined>;
  body?: unknown;
  headers?: Record<string, string>;
  signal?: AbortSignal;
  requestKey?: string;
}
// on the client object:
send<T>(method: string, path: string, opts?: SendOptions): Promise<T>;  // throws on non-2xx (SP1)
```

Generator text emission (`src/codegen/gen_client.zig`) uses `const W = std.ArrayList(u8);` with `w.appendSlice(alloc, …)` and `std.fmt.allocPrint(alloc, …)`. `identifiers.zig` provides `pascal(alloc, s)` (PascalCase, strips `_`/`-`).

---

### Task 1: Unify route-name derivation (the precondition)

The generator will consume `RouteMeta.name` directly, so the only risk is the framework's `comptimeRouteName` and codegen's `routeMethodName` drifting. They already share the algorithm except `routeMethodName` runs segments through `pascal()` (which strips `_`/`-`) while `comptimeRouteName` inlines a naive first-char uppercase. Harden `comptimeRouteName` to strip `_`/`-` too, then add a drift-guard test.

**Files:**
- Modify: `src/events.zig` (the `comptimeRouteName` fn, ~lines 244–266)
- Test: `src/codegen/identifiers.zig` (append a test) — and a comptime test in `src/events.zig`

**Interfaces:**
- Consumes: nothing new.
- Produces: `comptimeRouteName` and `identifiers.routeMethodName` are guaranteed to produce identical output for any path; `RouteMeta.name` is the canonical name the generator reads.

- [ ] **Step 1: Write the failing drift-guard test** in `src/codegen/identifiers.zig` (append after the existing `routeMethodName` test). It imports the framework name fn and asserts equality including a separator case:

```zig
test "routeMethodName matches the framework's comptimeRouteName" {
    const events = @import("../events.zig");
    const a = std.testing.allocator;
    const cases = [_][]const u8{
        "/api/bookings/:id/confirm",
        "/api/listings/:id/availability",
        "/api/golfsim/health",
        "/api/ping",
        "/api/user-profile/list-items", // separator case: both must strip '-'
        "/health",
    };
    inline for (cases) |path| {
        const got = try routeMethodName(a, path, "/api");
        defer a.free(got);
        try std.testing.expectEqualStrings(events.comptimeRouteName(path, null), got);
    }
}
```

- [ ] **Step 2: Run it to confirm it fails** on the separator case (and that `comptimeRouteName` is importable):

Run: `mise exec zig@0.16.0 -- zig build test 2>&1 | grep -iE 'expected|error:|comptimeRouteName' | head`
Expected: a mismatch on `/api/user-profile/list-items` (framework keeps the dash, codegen strips it), e.g. `expected "userProfileListItems", found "user-profileList-items"` — OR a compile error that `comptimeRouteName` is private. If `comptimeRouteName` is `fn` (not `pub`), make it `pub` in `src/events.zig` in the next step.

- [ ] **Step 3: Harden `comptimeRouteName`** in `src/events.zig` so each non-first segment is PascalCased with separators stripped, and the first segment also strips separators (camelCase). Replace the segment-joining loop body so it mirrors `pascal` semantics. Make the fn `pub`:

```zig
pub fn comptimeRouteName(comptime path: []const u8, comptime override: ?[]const u8) []const u8 {
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
            // PascalCase the segment, stripping '_'/'-' separators (matches
            // codegen identifiers.pascal); first segment keeps its leading
            // char lowercase to yield camelCase overall.
            var piece: []const u8 = "";
            var upper_next = false;
            for (seg, 0..) |ch, i| {
                if (ch == '_' or ch == '-') { upper_next = true; continue; }
                const is_first_overall = first and i == 0;
                const c = if (upper_next or (!first and piece.len == 0)) std.ascii.toUpper(ch)
                          else if (is_first_overall) ch else ch;
                piece = piece ++ &[_]u8{c};
                upper_next = false;
            }
            name = name ++ piece;
            first = false;
        }
        return name;
    }
}
```

Note: `pascal` uppercases the FIRST char of each segment too; for the very first segment we want it lowercase (camelCase). The `(!first and piece.len == 0)` clause uppercases the first emitted char of non-first segments; the first segment's leading char is left as-is.

- [ ] **Step 4: Run the test to confirm it passes**:

Run: `mise exec zig@0.16.0 -- zig build test 2>&1 | tail -5; echo "exit=$?"`
Expected: exit 0, no `error:`/`expected` lines. `/api/user-profile/list-items` now yields `userProfileListItems` from both functions.

- [ ] **Step 5: Commit**

```bash
git add src/events.zig src/codegen/identifiers.zig
git commit -m "fix(routes): unify comptimeRouteName with codegen pascal (strip separators) + drift-guard test"
```

---

### Task 2: Comptime Zig-`type`→TS emitter (`rpc_ts.zig`)

The core: turn a single Zig `type` into TS text at comptime. Anonymous types render inline (`number`, `string`, `T | null`, `T[]`, `unknown`); named types (structs/enums) render as named `interface`/union declarations and are referenced by name. This task builds and unit-tests the emitter in isolation (no routes yet).

**Files:**
- Create: `src/codegen/rpc_ts.zig`
- Test: in-file `test` blocks in `src/codegen/rpc_ts.zig`; wire the file into the test aggregation (see Step 6).

**Interfaces:**
- Produces:
  - `pub fn tsName(comptime T: type) []const u8` — the TS identifier for a named struct/enum (its short Zig type name, e.g. `ConfirmInput`); for nested anonymous structs, a deterministic generated name.
  - `pub fn tsForType(comptime T: type) []const u8` — the **inline** TS type expression for `T` (e.g. `"number"`, `"string"`, `"string | null"`, `"Foo[]"`, `"unknown"`; for a named struct/enum returns its `tsName`).
  - `pub fn isRepresentable(comptime T: type) bool` — true iff `T` is in the bounded subset.
  - `pub fn renderNamedDecls(comptime T: type, w: *std.ArrayList(u8), alloc: std.mem.Allocator) !void` — appends `export interface <Name> { … }` / `export type <Name> = …` declarations for every named struct/enum reachable from `T` (deduplicated, dependencies first). For scalars/void this appends nothing.
- Consumes: `std.json.Value` (the escape hatch type), `identifiers.pascal`.

- [ ] **Step 1: Write failing tests** in `src/codegen/rpc_ts.zig` covering the inline mapping for each subset type:

```zig
const std = @import("std");
const json = std.json;

test "tsForType scalars" {
    try std.testing.expectEqualStrings("number", tsForType(i64));
    try std.testing.expectEqualStrings("number", tsForType(u32));
    try std.testing.expectEqualStrings("number", tsForType(f64));
    try std.testing.expectEqualStrings("boolean", tsForType(bool));
    try std.testing.expectEqualStrings("string", tsForType([]const u8));
    try std.testing.expectEqualStrings("unknown", tsForType(json.Value));
    try std.testing.expectEqualStrings("void", tsForType(void));
}

test "tsForType optional and slice" {
    try std.testing.expectEqualStrings("string | null", tsForType(?[]const u8));
    try std.testing.expectEqualStrings("number | null", tsForType(?i32));
    try std.testing.expectEqualStrings("number[]", tsForType([]const i32));
}

const Color = enum { red, green, blue };
const Inner = struct { tag: []const u8, n: i32 };
const Outer = struct { name: []const u8, color: Color, inner: Inner, maybe: ?bool, nums: []const i64 };

test "tsForType named struct/enum returns the name" {
    try std.testing.expectEqualStrings("Color", tsForType(Color));
    try std.testing.expectEqualStrings("Outer", tsForType(Outer));
}

test "renderNamedDecls emits interfaces and unions, deps first, deduped" {
    const a = std.testing.allocator;
    var w: std.ArrayList(u8) = .empty;
    defer w.deinit(a);
    try renderNamedDecls(Outer, &w, a);
    const out = w.items;
    // enum → string-literal union
    try std.testing.expect(std.mem.indexOf(u8, out, "export type Color = \"red\" | \"green\" | \"blue\";") != null);
    // nested struct interface present
    try std.testing.expect(std.mem.indexOf(u8, out, "export interface Inner {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "tag: string;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "n: number;") != null);
    // outer interface references named members and renders optional/array/null
    try std.testing.expect(std.mem.indexOf(u8, out, "export interface Outer {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "color: Color;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "inner: Inner;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "maybe: boolean | null;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "nums: number[];") != null);
    // dependency ordering: Inner before Outer
    try std.testing.expect(std.mem.indexOf(u8, out, "interface Inner").? < std.mem.indexOf(u8, out, "interface Outer").?);
}

test "isRepresentable rejects unsupported" {
    try std.testing.expect(isRepresentable(Outer));
    try std.testing.expect(!isRepresentable(union(enum) { a: i32, b: bool }));
    try std.testing.expect(!isRepresentable(*i32)); // bare single-item pointer (non-slice)
}
```

- [ ] **Step 2: Run to confirm failure** (functions undefined):

Run: `mise exec zig@0.16.0 -- zig test src/codegen/rpc_ts.zig 2>&1 | head`
Expected: compile errors — `error: use of undeclared identifier 'tsForType'` etc.

- [ ] **Step 3: Implement the emitter.** Add above the tests:

```zig
const ident = @import("identifiers.zig");

/// The TS identifier for a named struct/enum: its short (last-segment) Zig type name.
pub fn tsName(comptime T: type) []const u8 {
    const full = @typeName(T);
    // @typeName is fully qualified (e.g. "module.Outer"); take the last '.'-segment.
    comptime {
        var last: []const u8 = full;
        var it = std.mem.splitScalar(u8, full, '.');
        while (it.next()) |seg| last = seg;
        return last;
    }
}

/// Bounded Zig→TS subset predicate (mirrors route_types.assertRepresentable's walk).
pub fn isRepresentable(comptime T: type) bool {
    if (T == void or T == std.json.Value) return true;
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .@"enum" => true,
        .optional => |o| isRepresentable(o.child),
        .pointer => |p| p.size == .slice and (p.child == u8 or isRepresentable(p.child)),
        .@"struct" => |s| blk: {
            inline for (s.fields) |f| {
                if (!isRepresentable(f.type)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

/// Inline TS type expression for T. Named structs/enums return their tsName.
pub fn tsForType(comptime T: type) []const u8 {
    if (T == void) return "void";
    if (T == std.json.Value) return "unknown";
    if (T == []const u8) return "string";
    return switch (@typeInfo(T)) {
        .int, .float => "number",
        .bool => "boolean",
        .@"enum" => tsName(T),
        .@"struct" => tsName(T),
        .optional => |o| tsForType(o.child) ++ " | null",
        .pointer => |p| blk: {
            if (p.size != .slice) @compileError("rpc: unsupported pointer type " ++ @typeName(T));
            if (p.child == u8) break :blk "string";
            break :blk tsForType(p.child) ++ "[]";
        },
        else => @compileError("rpc: unsupported type " ++ @typeName(T)),
    };
}

/// Append `export interface`/`export type` declarations for every named struct/enum
/// reachable from T, dependencies first, deduplicated by tsName.
pub fn renderNamedDecls(comptime T: type, w: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();
    try renderNamedDeclsInner(T, w, alloc, &seen);
}

fn renderNamedDeclsInner(comptime T: type, w: *std.ArrayList(u8), alloc: std.mem.Allocator, seen: *std.StringHashMap(void)) !void {
    switch (@typeInfo(T)) {
        .optional => |o| try renderNamedDeclsInner(o.child, w, alloc, seen),
        .pointer => |p| if (p.size == .slice and p.child != u8) try renderNamedDeclsInner(p.child, w, alloc, seen),
        .@"enum" => |e| {
            const nm = tsName(T);
            if (seen.contains(nm)) return;
            try seen.put(nm, {});
            try w.appendSlice(alloc, try std.fmt.allocPrint(alloc, "export type {s} = ", .{nm}));
            inline for (e.fields, 0..) |f, i| {
                if (i != 0) try w.appendSlice(alloc, " | ");
                try w.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\"{s}\"", .{f.name}));
            }
            try w.appendSlice(alloc, ";\n");
        },
        .@"struct" => |s| {
            const nm = tsName(T);
            if (seen.contains(nm)) return;
            try seen.put(nm, {}); // mark before recursing so cycles terminate
            // emit dependencies first
            inline for (s.fields) |f| try renderNamedDeclsInner(f.type, w, alloc, seen);
            try w.appendSlice(alloc, try std.fmt.allocPrint(alloc, "export interface {s} {{\n", .{nm}));
            inline for (s.fields) |f| {
                try w.appendSlice(alloc, try std.fmt.allocPrint(alloc, "  {s}: {s};\n", .{ f.name, tsForType(f.type) }));
            }
            try w.appendSlice(alloc, "}\n");
        },
        else => {}, // scalars/void/json.Value contribute no named decls
    }
}
```

- [ ] **Step 4: Run the tests to confirm they pass**:

Run: `mise exec zig@0.16.0 -- zig test src/codegen/rpc_ts.zig 2>&1 | tail -5; echo "exit=$?"`
Expected: all tests pass, exit 0.

- [ ] **Step 5: Wire `rpc_ts.zig` into the aggregated `zig build test`.** Find where codegen test files are aggregated (search the codegen test root):

Run: `grep -rn '_ = @import' src/codegen/*root*.zig src/root.zig | grep -iE 'identifier|ts_type|emit'`

Add `_ = @import("rpc_ts.zig");` next to the existing codegen imports in that root (e.g. `src/codegen/gen_test_root.zig` or wherever `identifiers.zig`/`ts_type.zig` are referenced for tests). Then:

Run: `mise exec zig@0.16.0 -- zig build test 2>&1 | tail -5; echo "exit=$?"`
Expected: exit 0; the new tests run as part of the suite.

- [ ] **Step 6: Commit**

```bash
git add src/codegen/rpc_ts.zig src/codegen/gen_test_root.zig src/root.zig
git commit -m "feat(codegen): comptime Zig-type to TS emitter for route I/O (rpc_ts.zig)"
```

---

### Task 3: RPC section renderer (`rpc.zig`)

Assemble a route list into the three TS fragments: the `<Name>Input`/`<Name>Output` named decls, the `rpc` member for the `ZbClient` interface, and the `rpc: {…}` object for the `createClient` factory. Path params come from scanning `route.path` for `:segments`.

**Files:**
- Create: `src/codegen/rpc.zig`
- Test: in-file `test` blocks; wire into the test aggregation (alongside Task 2's import).

**Interfaces:**
- Consumes: `rpc_ts.tsForType`, `rpc_ts.tsName`, `rpc_ts.renderNamedDecls`; `events.RouteMeta`.
- Produces:
  - `pub const Section = struct { decls: []const u8, iface_member: []const u8, factory_member: []const u8 };`
  - `pub fn render(comptime routes: []const RouteMeta, alloc: std.mem.Allocator) !Section`
  - `pub fn pathParams(comptime path: []const u8) []const []const u8` — the ordered `:segment` names (without the colon).

- [ ] **Step 1: Write failing tests** in `src/codegen/rpc.zig`. Build a small synthetic `routes` array (RouteMeta literals) and assert substrings:

```zig
const std = @import("std");
const events = @import("../events.zig");
const http = @import("../http.zig");

const ConfirmOut = struct { id: []const u8, status: []const u8 };
const SearchIn = struct { q: []const u8, limit: i32 };

const test_routes = [_]events.RouteMeta{
    .{ .method = .POST, .path = "/api/bookings/:id/confirm", .name = "bookingsConfirm", .auth = .authed, .Input = void, .Output = ConfirmOut },
    .{ .method = .GET, .path = "/api/search", .name = "search", .auth = .public, .Input = SearchIn, .Output = std.json.Value },
};

test "pathParams extracts colon segments in order" {
    const ps = comptime pathParams("/api/bookings/:id/confirm");
    try std.testing.expectEqual(@as(usize, 1), ps.len);
    try std.testing.expectEqualStrings("id", ps[0]);
    try std.testing.expectEqual(@as(usize, 0), comptime pathParams("/api/search").len);
}

test "render emits interface member, factory method, and named decls" {
    const a = std.testing.allocator;
    const sec = try render(&test_routes, a);
    defer a.free(sec.decls); defer a.free(sec.iface_member); defer a.free(sec.factory_member);

    // Output interface emitted
    try std.testing.expect(std.mem.indexOf(u8, sec.decls, "export interface ConfirmOut {") != null);
    try std.testing.expect(std.mem.indexOf(u8, sec.decls, "export interface SearchIn {") != null);

    // Interface member: void input → no input arg; params object present; query route has input
    try std.testing.expect(std.mem.indexOf(u8, sec.iface_member,
        "bookingsConfirm(params: { id: string }, opts?: SendOptions): Promise<ConfirmOut>;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sec.iface_member,
        "search(input: SearchIn, opts?: SendOptions): Promise<unknown>;") != null);

    // Factory: POST interpolates :id and sends body absent (void input); GET sends query
    try std.testing.expect(std.mem.indexOf(u8, sec.factory_member, "bookingsConfirm(params, opts) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, sec.factory_member, "`/api/bookings/${encodeURIComponent(String(params.id))}/confirm`") != null);
    try std.testing.expect(std.mem.indexOf(u8, sec.factory_member, "return base.send(\"POST\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, sec.factory_member, "query: input as Record<string, string | number | boolean | undefined>") != null);
}
```

- [ ] **Step 2: Run to confirm failure**:

Run: `mise exec zig@0.16.0 -- zig test src/codegen/rpc.zig 2>&1 | head`
Expected: undeclared `render`/`pathParams`.

- [ ] **Step 3: Implement `rpc.zig`:**

```zig
const std = @import("std");
const events = @import("../events.zig");
const http = @import("../http.zig");
const rpc_ts = @import("rpc_ts.zig");

const RouteMeta = events.RouteMeta;
const W = std.ArrayList(u8);

pub const Section = struct {
    decls: []const u8,         // <Name>Input/<Name>Output interfaces + named nested decls
    iface_member: []const u8,  // body of `rpc: { … }` in the ZbClient interface
    factory_member: []const u8,// body of `rpc: { … }` in createClient
};

/// Ordered ":segment" names (colon stripped) from a path.
pub fn pathParams(comptime path: []const u8) []const []const u8 {
    comptime {
        var out: []const []const u8 = &.{};
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |seg| {
            if (seg.len > 0 and seg[0] == ':') out = out ++ &[_][]const u8{seg[1..]};
        }
        return out;
    }
}

fn methodStr(comptime m: http.Method) []const u8 {
    return switch (m) {
        .GET => "GET", .POST => "POST", .PUT => "PUT", .PATCH => "PATCH", .DELETE => "DELETE",
        else => @compileError("rpc: unsupported HTTP method for a typed route"),
    };
}

fn isBodyMethod(comptime m: http.Method) bool {
    return m == .POST or m == .PUT or m == .PATCH;
}

/// `params: { id: string; ... }` type literal, or "" if no params.
fn paramsTypeLiteral(comptime path: []const u8) []const u8 {
    const ps = pathParams(path);
    if (ps.len == 0) return "";
    comptime {
        var s: []const u8 = "params: { ";
        for (ps, 0..) |p, i| {
            if (i != 0) s = s ++ "; ";
            s = s ++ p ++ ": string";
        }
        return s ++ " }";
    }
}

/// The interpolated URL template literal for the route's path.
fn urlTemplate(comptime path: []const u8) []const u8 {
    comptime {
        var s: []const u8 = "`";
        var it = std.mem.splitScalar(u8, path, '/');
        var first = true;
        while (it.next()) |seg| {
            if (first) { first = false; } else { s = s ++ "/"; }
            if (seg.len > 0 and seg[0] == ':') {
                s = s ++ "${encodeURIComponent(String(params." ++ seg[1..] ++ "))}";
            } else {
                s = s ++ seg;
            }
        }
        return s ++ "`";
    }
}

pub fn render(comptime routes: []const RouteMeta, alloc: std.mem.Allocator) !Section {
    var decls: W = .empty;
    var iface: W = .empty;
    var factory: W = .empty;
    errdefer { decls.deinit(alloc); iface.deinit(alloc); factory.deinit(alloc); }

    inline for (routes) |r| {
        const has_params = comptime pathParams(r.path).len > 0;
        const has_input = r.Input != void;
        const out_ts = comptime rpc_ts.tsForType(r.Output);

        // 1) named decls for Input (if struct/enum) and Output (if struct/enum)
        try rpc_ts.renderNamedDecls(r.Input, &decls, alloc);
        try rpc_ts.renderNamedDecls(r.Output, &decls, alloc);

        // 2) interface member: name(<params,><input,> opts?): Promise<Out>;
        try iface.appendSlice(alloc, "    ");
        try iface.appendSlice(alloc, r.name);
        try iface.appendSlice(alloc, "(");
        var wrote_arg = false;
        if (has_params) { try iface.appendSlice(alloc, comptime paramsTypeLiteral(r.path)); wrote_arg = true; }
        if (has_input) {
            if (wrote_arg) try iface.appendSlice(alloc, ", ");
            try iface.appendSlice(alloc, "input: ");
            try iface.appendSlice(alloc, comptime rpc_ts.tsForType(r.Input));
            wrote_arg = true;
        }
        if (wrote_arg) try iface.appendSlice(alloc, ", ");
        try iface.appendSlice(alloc, "opts?: SendOptions): Promise<");
        try iface.appendSlice(alloc, if (r.Output == void) "void" else out_ts);
        try iface.appendSlice(alloc, ">;\n");

        // 3) factory method
        try factory.appendSlice(alloc, "      ");
        try factory.appendSlice(alloc, r.name);
        try factory.appendSlice(alloc, "(");
        var wrote_p = false;
        if (has_params) { try factory.appendSlice(alloc, "params"); wrote_p = true; }
        if (has_input) { if (wrote_p) try factory.appendSlice(alloc, ", "); try factory.appendSlice(alloc, "input"); wrote_p = true; }
        if (wrote_p) try factory.appendSlice(alloc, ", ");
        try factory.appendSlice(alloc, "opts) {\n");
        try factory.appendSlice(alloc, try std.fmt.allocPrint(alloc,
            "        return base.send({s}{s}, ", .{ "\"" ++ comptime methodStr(r.method) ++ "\", ", comptime urlTemplate(r.path) }));
        // options object
        if (has_input and comptime isBodyMethod(r.method)) {
            try factory.appendSlice(alloc, "{ body: input, ...opts });\n");
        } else if (has_input) {
            try factory.appendSlice(alloc, "{ query: input as Record<string, string | number | boolean | undefined>, ...opts });\n");
        } else {
            try factory.appendSlice(alloc, "opts);\n");
        }
        try factory.appendSlice(alloc, "      },\n");
    }

    return .{
        .decls = try decls.toOwnedSlice(alloc),
        .iface_member = try iface.toOwnedSlice(alloc),
        .factory_member = try factory.toOwnedSlice(alloc),
    };
}
```

Note on `base.send(...)` typing: the factory methods are emitted inside `createClient` where `base` is the underlying `Client`. `base.send<T>` is generic but the generated `.js` is plain JS (the `.gen.ts` is type-checked, then consumers import the `.js`); the return type is carried by the `ZbClient` interface, so the untyped `base.send(...)` call body is fine. (Matches how `db`/`realtime` factory bodies are emitted.)

- [ ] **Step 4: Run tests to confirm they pass**:

Run: `mise exec zig@0.16.0 -- zig test src/codegen/rpc.zig 2>&1 | tail -5; echo "exit=$?"`
Expected: exit 0, all asserts pass.

- [ ] **Step 5: Wire into aggregated test** — add `_ = @import("rpc.zig");` next to the Task 2 import. Run:

Run: `mise exec zig@0.16.0 -- zig build test 2>&1 | tail -5; echo "exit=$?"`
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add src/codegen/rpc.zig src/codegen/gen_test_root.zig src/root.zig
git commit -m "feat(codegen): RPC section renderer (interfaces + client member + factory)"
```

---

### Task 4: Splice the RPC section into the generated client + consume `--api-prefix`

Thread `App.routes` from `gen_main.zig` into the generator, splice the three RPC fragments into the right places in `gen_client.zig`, and validate `--api-prefix` against each route path.

**Files:**
- Modify: `src/codegen/gen_main.zig` (forward `App.routes`)
- Modify: `src/codegen/gen_client.zig` (`generate`, `emitClientFactory`, `mainWithCollections`, args/validation)

**Interfaces:**
- Consumes: `rpc.render`, `rpc.Section`, `App.routes` (`[]const events.RouteMeta`).
- Produces: generated client contains `export interface <Name>Input/Output`, a `rpc: { … };` member on the client interface, and a `rpc: { … },` object in `createClient`.

- [ ] **Step 1: Add a regen-driven failing expectation.** First, see the current generator signature and the createClient tail so the splice points are exact:

Run: `grep -n 'pub fn generate\|fn emitClientFactory\|mainWithCollections\|files: base.files\|authStore: base.authStore' src/codegen/gen_client.zig`

(You will splice: the `decls` just before the `createClient` function/`ZbClient` interface emission; the `iface_member` into the `ZbClient` interface after the `realtime`/`files` members; the `factory_member` into the return object after `files: base.files,`.)

- [ ] **Step 2: Thread routes into `mainWithCollections` and `generate`.** Change the generator entry to accept routes. In `gen_main.zig`:

```zig
pub fn main(init: std.process.Init) !void {
    const app = @import("app");
    return zigbase.codegen.gen_client.mainWithCollections(init, app.App.collections, app.App.routes);
}
```

In `gen_client.zig`, update `mainWithCollections` signature and the internal `generate(...)` call to take `routes: []const events.RouteMeta`. Add `const events = @import("../events.zig");` import if absent. Where `generate(...)` is defined, add the `routes` parameter and compute the section near the top:

```zig
pub fn generate(
    alloc: std.mem.Allocator,
    cols: []const schema.Collection,
    routes: []const events.RouteMeta,
    // ... existing params (client_name, auth_collection, api_prefix, …) unchanged
) ![]const u8 {
    // ... existing setup ...
    const rpc_section = try @import("rpc.zig").render(routes, alloc);
    // (existing emission continues; see Steps 3–5 for where each fragment goes)
```

If `generate` does not currently receive `api_prefix`, thread it from the parsed `Args` (it is parsed already).

- [ ] **Step 3: Validate `--api-prefix`** — after parsing args and before emission, loop routes (use a comptime-built runtime list of paths, since `path` is a normal `[]const u8` field):

```zig
for (routes) |r| {
    if (!std.mem.startsWith(u8, r.path, args.api_prefix)) {
        std.log.err("gen_client: route '{s}' does not start with --api-prefix '{s}'; the framework route prefix and the generator prefix disagree.", .{ r.path, args.api_prefix });
        return error.RoutePrefixMismatch;
    }
}
```

- [ ] **Step 4: Emit the named decls** just before the client interface/factory section. Find the line emitting `export interface {client_name}` (in `emitClientFactory`) and append `rpc_section.decls` immediately before it:

```zig
try w.appendSlice(alloc, rpc_section.decls);
try w.appendSlice(alloc, try std.fmt.allocPrint(alloc, "export interface {s} {{\n  db: {{\n", .{client_name}));
```

(Pass `rpc_section` into `emitClientFactory` by adding a parameter, or inline the factory emission in `generate` where `rpc_section` is in scope — choose whichever keeps the existing call sites smallest; the reviewer will check the splice is additive.)

- [ ] **Step 5: Emit the interface member and the factory object.** In the `ZbClient` interface body, after the `realtime: { … };` and `files: FilesService;` members, add:

```zig
try w.appendSlice(alloc, "  rpc: {\n");
try w.appendSlice(alloc, rpc_section.iface_member);
try w.appendSlice(alloc, "  };\n");
```

In the `createClient` return object, right after `files: base.files,`, add:

```zig
try w.appendSlice(alloc, "    rpc: {\n");
try w.appendSlice(alloc, rpc_section.factory_member);
try w.appendSlice(alloc, "    },\n");
```

(When `routes.len == 0`, all three fragments are empty strings — the generated client is byte-identical to today except for an empty `rpc: {\n  };\n` / `rpc: {\n    },\n`. To keep zero-route clients byte-identical, guard: only emit the `rpc` member/object when `routes.len > 0`.)

- [ ] **Step 6: Build the generator and regenerate the dating client** (no dating routes yet → `rpc` absent; proves additive-when-empty):

Run: `mise exec zig@0.16.0 -- zig build gen-dating-client && mise exec zig@0.16.0 -- zig build gen-test 2>&1 | tail -5; echo "exit=$?"`
Expected: exit 0 — the golden is unchanged (dating has no routes yet), proving the empty-routes path is byte-identical.

- [ ] **Step 7: Commit**

```bash
git add src/codegen/gen_main.zig src/codegen/gen_client.zig
git commit -m "feat(codegen): splice zb.rpc surface into generated client + consume --api-prefix"
```

---

### Task 5: Add typed routes to the dating fixture (golden + live coverage)

Give the dating fixture (the generator's golden app, also built as the live `dating-server`) typed routes that cover every Input/Output shape with **pure** handlers (no DB access, so they compile and run trivially): void input + path param, POST body input (nested struct + enum + optional + array), GET query input (flat scalars), void output, struct output, `std.json.Value` output, and a `RouteError` throw.

**Files:**
- Modify: `fixtures/dating/schema.zig`

**Interfaces:**
- Consumes: `zigbase.Req`, `zigbase.RouteError`.
- Produces: `App.routes` is non-empty; method names (via `comptimeRouteName`): `echoPing`, `winksSend`, `messagesSearch`, `winksStatus` (see paths below).

- [ ] **Step 1: Add the route handler types + handlers** to `fixtures/dating/schema.zig` (above `pub const App`), using pure logic so no DB/runtime is needed:

```zig
const Color = enum { red, green, blue };
const SendWinkIn = struct {
    note: []const u8,
    color: Color,
    sticker: ?[]const u8,
    tags: []const []const u8,
};
const SendWinkOut = struct { ok: bool, note: []const u8 };
const SearchOut = struct { count: i64 };

// void input + path param + struct output (POST)
fn echoPing(req: *zigbase.Req(void)) zigbase.RouteError!SendWinkOut {
    return .{ .ok = true, .note = req.param("id") orelse "" };
}
// POST body input (nested enum/optional/array) + struct output
fn winksSend(req: *zigbase.Req(SendWinkIn)) zigbase.RouteError!SendWinkOut {
    if (req.input.note.len == 0) return req.fail(400, "note required");
    return .{ .ok = true, .note = req.input.note };
}
// GET query input (flat scalars) + struct output
const SearchIn = struct { q: []const u8, limit: i32 };
fn messagesSearch(req: *zigbase.Req(SearchIn)) zigbase.RouteError!SearchOut {
    return .{ .count = req.input.limit };
}
// void input + void output (GET) — exercises Promise<void>
fn winksStatus(req: *zigbase.Req(void)) zigbase.RouteError!void {
    _ = req;
    return;
}
```

- [ ] **Step 2: Register the routes** in the `App(.{ … })` config by adding a `.routes` tuple after `.collections`:

```zig
    .routes = .{
        .{ .method = .POST, .path = "/api/echo/:id/ping", .handler = echoPing },
        .{ .method = .POST, .path = "/api/winks/send", .handler = winksSend },
        .{ .method = .GET, .path = "/api/messages/search", .handler = messagesSearch },
        .{ .method = .GET, .path = "/api/winks/status", .handler = winksStatus },
    },
```

(Method names derived: `echoPing` ← `/api/echo/:id/ping`; `winksSend` ← `/api/winks/send`; `messagesSearch`; `winksStatus`. Confirm against `comptimeRouteName` — all segments are separator-free here.)

- [ ] **Step 3: Build the fixture as a server to confirm the routes compile + validate**:

Run: `mise exec zig@0.16.0 -- zig build dating-server -Dcpu=baseline 2>&1 | tail -5; echo "exit=$?"`
Expected: exit 0 — the typed routes pass `assertRepresentable` (all Input/Output are in the subset) and the dispatch thunks compile.

- [ ] **Step 4: Confirm the unit suite still passes** (route metadata + representability):

Run: `mise exec zig@0.16.0 -- zig build test 2>&1 | tail -5; echo "exit=$?"`
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add fixtures/dating/schema.zig
git commit -m "test(dating-fixture): typed routes covering all RPC input/output shapes"
```

---

### Task 6: Regenerate golden + golfsim snapshots; lock with `gen-test` + `--check`

Regenerate both clients now that the dating fixture has routes and the generator emits RPC. The dating golden gains the `rpc` surface (byte-exact snapshot test); golfsim's snapshot gains its 4 RPC methods.

**Files:**
- Modify: `clients/typescript/test/codegen/dating/zbase.gen.ts` (regenerated)
- Modify: `examples/golfsim/clients/typescript/zbase.gen.ts` (regenerated)

- [ ] **Step 1: Regenerate the dating golden**:

Run: `mise exec zig@0.16.0 -- zig build gen-dating-client`
Then inspect the new RPC surface:
Run: `grep -nE 'rpc:|SendWinkIn|SendWinkOut|SearchIn|SearchOut|echoPing|winksSend|messagesSearch|winksStatus|Color' clients/typescript/test/codegen/dating/zbase.gen.ts | head -40`
Expected: `export type Color = "red" | "green" | "blue";`, `export interface SendWinkIn {`, the four methods under a `rpc: {` member, and `winksStatus(opts?: SendOptions): Promise<void>;`.

- [ ] **Step 2: Verify the golden byte-exact test passes** against the freshly committed snapshot:

Run: `mise exec zig@0.16.0 -- zig build gen-test 2>&1 | tail -5; echo "exit=$?"`
Expected: exit 0 (the snapshot the test reads is the file you just regenerated).

- [ ] **Step 3: Regenerate the golfsim snapshot + verify staleness gate**:

```bash
cd examples/golfsim && mise exec zig@0.16.0 -- zig build gen-client && mise exec zig@0.16.0 -- zig build gen-client-check 2>&1 | tail -3; echo "exit=$?"; cd -
```
Expected: exit 0. Then confirm golfsim's 4 RPC methods are present:
Run: `grep -nE 'rpc:|bookingsConfirm|bookingsCancel|listingsAvailability|golfsimHealth|HealthOut' examples/golfsim/clients/typescript/zbase.gen.ts | head`
Expected: a `rpc: {` member with `bookingsConfirm(params: { id: string }, opts?: SendOptions): Promise<unknown>;` (void input, json.Value output → `unknown`), `golfsimHealth(opts?: SendOptions): Promise<HealthOut>;`, etc.

- [ ] **Step 4: Typecheck the generated dating client** (the `.gen.ts` must itself typecheck):

```bash
cd clients/typescript && mise exec node@24 -- npm run typecheck 2>&1 | tail -5; echo "exit=$?"; cd -
```
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/test/codegen/dating/zbase.gen.ts examples/golfsim/clients/typescript/zbase.gen.ts
git commit -m "test(codegen): regenerate dating golden + golfsim snapshot with zb.rpc surface"
```

---

### Task 7: Type-level tests for the generated RPC surface (`*.test-d.ts`)

Assert the generated `rpc` methods type correctly: params/input/output shapes, the `void` cases, and `@ts-expect-error` negatives.

**Files:**
- Create: `clients/typescript/test/codegen/dating/zbase.rpc.test-d.ts`

**Interfaces:**
- Consumes: the regenerated `clients/typescript/test/codegen/dating/zbase.gen.ts` (`createClient`, `SendWinkIn`, `SendWinkOut`, …).

- [ ] **Step 1: Confirm how `*.test-d.ts` is run** (the SP2.1b suite already has type-level tests):

Run: `grep -rn 'test-d\|tsd\|expectType\|test:types' clients/typescript/package.json clients/typescript/test 2>/dev/null | head`
Use the same runner/assert style the existing type tests use (e.g. `// @ts-expect-error` + a `typecheck`-of-tests script). If the repo uses bare `tsc --noEmit` over `test/**/*.test-d.ts`, follow that.

- [ ] **Step 2: Write the type-level test** mirroring the existing style:

```ts
import { createClient } from "./zbase.gen.js";

const zb = createClient("http://localhost");

// path param + void input + struct output
const p1: Promise<{ ok: boolean; note: string }> = zb.rpc.echoPing({ id: "abc" });
void p1;

// POST body input (nested enum/optional/array) + struct output
const p2: Promise<{ ok: boolean; note: string }> = zb.rpc.winksSend({
  note: "hi", color: "red", sticker: null, tags: ["a", "b"],
});
void p2;

// GET query input + struct output
const p3: Promise<{ count: number }> = zb.rpc.messagesSearch({ q: "x", limit: 5 });
void p3;

// void input + void output
const p4: Promise<void> = zb.rpc.winksStatus();
void p4;

// --- negatives ---
// @ts-expect-error wrong enum literal
zb.rpc.winksSend({ note: "x", color: "purple", sticker: null, tags: [] });
// @ts-expect-error missing required path param
zb.rpc.echoPing({});
// @ts-expect-error missing required input field (q)
zb.rpc.messagesSearch({ limit: 1 });
// @ts-expect-error winksStatus takes no input argument
zb.rpc.winksStatus({ foo: 1 });
```

- [ ] **Step 3: Run the type-level check** (the negatives must be caught by `@ts-expect-error`, the positives must compile):

Run: `cd clients/typescript && mise exec node@24 -- npm run typecheck 2>&1 | tail -10; echo "exit=$?"; cd -`
Expected: exit 0 (all `@ts-expect-error` lines have a real error to suppress; positives are well-typed). If the project has a dedicated `test:types` script, run that instead.

- [ ] **Step 4: Commit**

```bash
git add clients/typescript/test/codegen/dating/zbase.rpc.test-d.ts
git commit -m "test(codegen): type-level tests for the generated zb.rpc surface"
```

---

### Task 8: Live integration test against the dating-server (query input + RouteError)

Drive `zb.rpc.*` against the real `dating-server` binary, covering the two things golfsim's void-input routes cannot: a GET with **query input**, and a `RouteError`→client-throw.

**Files:**
- Create: `clients/typescript/test/integration/rpc.integration.test.ts`

**Interfaces:**
- Consumes: the dating integration harness (the one that spawns `dating-server` honoring `ZIGBASE_TEST_DATING_BINARY`); the generated dating client.

- [ ] **Step 1: Find the dating integration harness** the existing integration tests use to spawn the server:

Run: `grep -rln 'ZIGBASE_TEST_DATING_BINARY\|dating-server\|startDating\|spawnDating' clients/typescript/test | head`
Reuse that harness's start/stop exactly (don't write a new spawner).

- [ ] **Step 2: Write the live test** (adapt the import paths to the harness you found):

```ts
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { startDating } from "../<harness-path>.js"; // from Step 1
import { createClient } from "../codegen/dating/zbase.gen.js";

let srv: Awaited<ReturnType<typeof startDating>>;
beforeAll(async () => { srv = await startDating(); });
afterAll(() => srv?.stop());

describe("zb.rpc live (dating-server)", () => {
  it("GET with query input returns typed output", async () => {
    const zb = createClient(srv.url);
    // messagesSearch echoes limit back as count (pure handler)
    const res = await zb.rpc.messagesSearch({ q: "hello", limit: 7 });
    expect(res.count).toBe(7);
  });

  it("POST body input round-trips", async () => {
    const zb = createClient(srv.url);
    const res = await zb.rpc.winksSend({ note: "hey", color: "green", sticker: null, tags: ["x"] });
    expect(res).toEqual({ ok: true, note: "hey" });
  });

  it("RouteError (req.fail 400) rejects the promise", async () => {
    const zb = createClient(srv.url);
    await expect(zb.rpc.winksSend({ note: "", color: "red", sticker: null, tags: [] }))
      .rejects.toThrow();
  });
});
```

- [ ] **Step 3: Run the integration suite locally** (build the dating-server first if the harness doesn't):

```bash
mise exec zig@0.16.0 -- zig build dating-server -Dcpu=baseline
cd clients/typescript && mise exec node@24 -- npm run test:integration 2>&1 | tail -15; echo "exit=$?"; cd -
```
Expected: exit 0; the three RPC cases pass (the harness spawns the freshly built binary).

- [ ] **Step 4: Commit**

```bash
git add clients/typescript/test/integration/rpc.integration.test.ts
git commit -m "test(integration): live zb.rpc against dating-server (query input + RouteError)"
```

---

### Task 9: Migrate golfsim e2e to `zb.rpc.*` + docs sync

Replace golfsim's raw `zb.send("POST", \`/api/bookings/${id}/confirm\`)` with the generated typed `zb.rpc.bookingsConfirm({ id })`, proving the live end-to-end typed path on a real app. Then sync docs.

**Files:**
- Modify: `examples/golfsim/test/golfsim.e2e.test.ts`
- Modify: `clients/typescript/README.md` (+ any `docs/*.md` documenting the generated client)

**Interfaces:**
- Consumes: the regenerated `examples/golfsim/clients/typescript/zbase.gen.ts` (`zb.rpc.bookingsConfirm`).

- [ ] **Step 1: Replace the raw send call.** In `examples/golfsim/test/golfsim.e2e.test.ts`, change:

```ts
const confirmed = await zb.send<Booking>("POST", `/api/bookings/${booking.id}/confirm`);
expect(confirmed.status).toBe("confirmed");
```
to:
```ts
// bookingsConfirm has void input + an :id path param → params object only.
// Output is std.json.Value → unknown, so narrow to Booking for the assertion.
const confirmed = await zb.rpc.bookingsConfirm({ id: booking.id }) as Booking;
expect(confirmed.status).toBe("confirmed");
```

(The `Booking` import already exists in the test; the `unknown` output means the cast is explicit — that is the documented behavior for `std.json.Value` outputs.)

- [ ] **Step 2: Run golfsim's typecheck + e2e** (build `@zigbase/client` first, as CI does):

```bash
cd clients/typescript && mise exec node@24 -- npm run build && cd -
cd examples/golfsim && mise exec node@24 -- npm install && mise exec node@24 -- npm run typecheck && mise exec node@24 -- npm run test:e2e 2>&1 | tail -15; echo "exit=$?"; cd -
```
Expected: exit 0; the e2e test passes (1 test), now exercising `zb.rpc.bookingsConfirm` against the live golfsim binary.

- [ ] **Step 3: Document `zb.rpc.*`.** In `clients/typescript/README.md`, add a short "Typed RPC (`zb.rpc.*`)" subsection near the generated-client docs: show the call shape (`params` iff path params, `input` iff non-void, GET→query/POST→body, throws on `RouteError`), and a golfsim example. Mirror into any `docs/*.md` that documents the generated client surface (search: `grep -rln 'zb.db\|createClient\|generated client' docs site 2>/dev/null`). Do NOT edit historic plan/spec docs.

- [ ] **Step 4: Run the full local gate** (everything that CI runs that touches this work):

```bash
mise exec zig@0.16.0 -- zig build test 2>&1 | tail -3; echo "zig-test exit=$?"
mise exec zig@0.16.0 -- zig build gen-dating-client-check 2>&1 | tail -3; echo "dating-check exit=$?"
cd examples/golfsim && mise exec zig@0.16.0 -- zig build gen-client-check 2>&1 | tail -3; echo "golfsim-check exit=$?"; cd -
cd clients/typescript && mise exec node@24 -- npm run typecheck && mise exec node@24 -- npm test 2>&1 | tail -5; echo "ts exit=$?"; cd -
```
Expected: all exit 0 — staleness gates green (snapshots committed), unit + type tests pass.

- [ ] **Step 5: Commit**

```bash
git add examples/golfsim/test/golfsim.e2e.test.ts clients/typescript/README.md docs
git commit -m "feat(golfsim): drive bookingsConfirm through typed zb.rpc + document the RPC surface"
```

---

## Self-Review (completed during planning)

**Spec coverage (section B + mapping rules + validation):**
- B1 RPC surface / call shape (`params` iff path params, `input` iff non-void, opts last) → Tasks 3 (renderer) + 7 (type-level proof).
- B1 `<Name>Input`/`<Name>Output` from reflected types; `void` Output → `Promise<void>` → Tasks 2/3, proven in Task 7 (`winksStatus`).
- B1 GET/DELETE→query, POST/PUT/PATCH→body; path-param interpolation → Task 3 (`urlTemplate`, options object), proven live in Tasks 8/9.
- B1 thin wrapper over base `send` (no new runtime) → Task 3 factory bodies call `base.send`.
- B2 `rpc` on the client alongside `db`/`realtime`/`files`; `send`/`fetch` retained → Task 4 splice (additive).
- Mapping-rules table (every subset type + `@compileError` for unsupported) → Task 2 (`tsForType`/`isRepresentable` + tests).
- `:param`→`string` params object; name from path (camel-join) → Tasks 1 (name unification) + 3 (`pathParams`/`paramsTypeLiteral`).
- `--api-prefix` finally consumed → Task 4 (startsWith validation).
- Validation/testing: Zig unit tests (Tasks 2/3), typed-route fixture / golfsim migration (Tasks 5/9), type-level `*.test-d.ts` (Task 7), live e2e (Tasks 8/9), golden + `--check` (Task 6).
- Carry-forwards: reuse `identifiers` casing + collision discipline (Task 1), reuse base `send` + throw-on-non-2xx (Tasks 3/8), additive `rpc` surface (Task 4).

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every test step shows the assertions and the exact run command + expected result.

**Type consistency:** `RouteMeta{method,path,name,auth,Input,Output}` used consistently; `rpc_ts.tsForType`/`tsName`/`isRepresentable`/`renderNamedDecls` and `rpc.render`/`pathParams`/`Section{decls,iface_member,factory_member}` names match across Tasks 2→3→4; fixture method names (`echoPing`/`winksSend`/`messagesSearch`/`winksStatus`) match across Tasks 5→6→7→8; golfsim `bookingsConfirm` matches Task 6 snapshot → Task 9 usage.

**Known seams the reviewer/implementer must watch:**
- The exact splice points in `gen_client.zig` (Task 4) depend on the current `emitClientFactory` structure; Step 1 of Task 4 re-derives them with `grep` before editing. The guard "only emit `rpc` when `routes.len > 0`" keeps zero-route clients byte-identical (verified by Task 4 Step 6 before any fixture routes exist).
- `comptimeRouteName`'s rewritten loop (Task 1) is the one piece of fiddly comptime string logic; its drift-guard test (including the separator case) is the gate. If the exact char-casing logic is awkward, an equally valid implementation is to extract a shared `comptime pascalSegment([]const u8) []const u8` helper and call it from both `comptimeRouteName` and (a comptime mirror of) `routeMethodName` — the test asserts equality either way.
