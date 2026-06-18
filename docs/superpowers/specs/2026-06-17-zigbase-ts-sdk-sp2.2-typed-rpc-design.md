# ZigBase TypeScript SDK — SP2.2: Typed RPC + Framework Typed-Routes

**Status:** Design approved, pending spec review
**Date:** 2026-06-17
**Scope:** Sub-project SP2.2 — give custom routes typed I/O end-to-end: a typed-only framework route
handler whose `Input`/`Output` types are reflected from its signature, and a generator that emits a
typed `zb.rpc.*` client surface from those routes. Builds on SP2.1b (the pure-Zig generator for
collections, merged). This is the last piece of the SP2 comptime flagship before SP3.

## Context & strategy

The SP2 comptime SDK generates a typed client from an app's comptime config. SP2.1b covered
**collections** fully (records, where, expand, services, realtime, files). **Custom routes** —
declared in `App(.{ .routes = .{ … } })` and today written as raw `fn(*RouteEvent) !http.Response`
handlers that hand-parse `ctx.body` and hand-serialize responses — carry **no typed I/O**, and the
client calls them via the untyped `send`/`fetch` escape hatch.

SP2.2 closes that. It is intentionally a **hard, typed-only break** to the route API: the only way to
declare a custom route is a typed handler. The headline: *write a Zig handler with typed input and
output; the typed TypeScript RPC method is a build artifact of `zig build` — no schema duplication,
no drift.*

Per the standing ordering rule: design this comptime/typed-route tier standalone and unconstrained;
do not let runtime-introspection (SP3) limits leak in.

## Design principles

1. **The handler signature is the single source of truth.** `Input` and `Output` are reflected from
   the handler's type at comptime (`Input` from its `*Req(Input)` parameter, `Output` from its
   `RouteError!Output` return). There is no separate `.input`/`.output` declaration to write or to
   drift from.
2. **Typed-only.** The typed handler is the *only* public route-handler form; the raw
   `fn(*RouteEvent) !http.Response` form is removed from the public API (it survives only as the
   internal dispatch thunk target). A hard break — existing raw routes are migrated.
3. **Break at app-build time.** The bounded Zig→TS type check runs at **comptime in the framework's
   route assembly**, so `zig build` of the *app* fails immediately (`@compileError` naming
   route+field+type) if a handler's `Input`/`Output` isn't representable — earlier than `gen-client`.
4. **One subset, two consumers.** A single bounded Zig→TS type-subset definition is enforced at
   app-build (the comptime check) and consumed by the generator (to emit the TS interfaces).
5. **Thin output over a tested core.** The generator emits concrete RPC method signatures + a thin
   wiring over the base client's existing `send`; no new runtime machinery in the typed core.

## Architecture & components

One feature, two coordinated layers with an internal phase boundary (B depends on A):

### A. Framework typed-routes

**A1. Route spec (shrunk).** A custom route declares only:
```zig
.{ .method = .POST, .path = "/api/bookings/:id/confirm",
   .handler = confirmBooking, .auth = .authed, .name = "confirmBooking" }   // .name optional
```
No `.input`/`.output`. `.method`/`.path`/`.handler` required; `.auth` as today (`public`/`authed`/
`superuser`); `.name` optional override for the generated method name.

**A2. Typed handler contract.** The only route-handler form:
```zig
fn confirmBooking(req: *Req(ConfirmInput)) RouteError!Booking {
    const id = req.param("id").?;          // path param (string; the path guarantees presence)
    const who = req.auth.id;               // auth identity (as today's rctx)
    const note = req.input.note;           // parsed + validated Input
    // ... db access via req.app / req.data ...
    if (!allowed) return error.Forbidden;  // -> 403
    return updated;                        // -> 200 JSON (Output)
}
```
- `Req(Input)` is `pub fn Req(comptime Input: type) type` returning a struct that carries
  `pub const Input = Input;` (for clean reflection), `input: Input`, the request context (`auth`,
  `app`, data handles), and path-param access (`param(name) ?[]const u8`).
- The framework parses the request into `Input`: from the JSON **body** for POST/PUT/PATCH, from the
  **query string** for GET/DELETE. A parse failure → 400 before the handler runs.
- The handler returns `Output` (framework JSON-serializes → 200; `void` → 204) or returns a
  `RouteError` (below).
- `Req(void)` means "no input" (no body/query parsed; the client method takes no input arg).

**A3. `RouteError` contract.** `RouteError` is a named error set mapped to status with default
messages: `error.BadRequest`→400, `Unauthorized`→401, `Forbidden`→403, `NotFound`→404,
`Conflict`→409; any other/unmapped error → 500. Returning a named error (`return error.Forbidden;`)
yields that status with a default JSON message. Because Zig error values can't carry a payload, a
**custom** status+message goes through `req.fail(status, msg)`: it records the status+message on
`req` and returns a sentinel `error.RouteFailed` (a member of `RouteError`); the dispatch thunk, on
catching the error, checks `req`'s recorded state first, else maps the named error, else 500. So the
handler writes either `return error.NotFound;` or `return req.fail(404, "Booking not found");`,
keeping the clean `RouteError!Output` signature. The TS client throws on any non-2xx (SP1's existing
transport behavior), so either form surfaces as a client-side throw carrying the status + message.

**A4. Comptime type reflection + validation (the heart).** A new **framework-side** module
(`src/route_types.zig`, part of the `zigbase` module) holds the reflection + the bounded-subset
definition + the comptime representability check. Dependency direction stays correct: the framework
uses it directly at comptime, and the generator (which already imports `zigbase`) imports it to emit
TS — the framework never depends on `src/codegen/`. Responsibilities:
- **Reflect** a handler's `Input`/`Output` from `@typeInfo(@TypeOf(handler))` — parameter `*Req(I)`
  → `I` (via the struct's `pub const Input`), return `RouteError!O` → `O` (error-union payload).
- **Validate (comptime)** that `I`/`O` are within the bounded subset; `@compileError` otherwise,
  naming the route, field path, and offending Zig type. Invoked from the framework's `buildRoutes`
  comptime assembly so `zig build <app>` fails early.
- The generator's emitter (in `src/codegen/`) imports this module's subset/reflection to produce the
  TS type text for `I`/`O` — one subset definition, no duplication.

**Bounded Zig→TS subset (pragmatic core):** struct of — ints/floats→`number`, `bool`→`boolean`,
`[]const u8`→`string`, `?T`→`T | null`, `[]T`→`T[]` (`[]const u8` special-cased to `string`),
nested structs→named TS interfaces (recursive, deduped), Zig enums→string-literal unions,
`std.json.Value`→`unknown`. Everything else (bare pointers, tagged unions, opaque, fn types,
comptime-only) → `@compileError`.

**A5. Dispatch thunk.** `buildRoutes` (comptime) wraps each typed handler into a
`fn(*RouteEvent) anyerror!http.Response` thunk — the existing dispatch signature — that parses
`Input`, builds `Req(Input)`, calls the handler, serializes `Output`→200 (or 204), and maps
`RouteError`→status+message. The dispatch core (`server.dispatchCustom`, auth enforcement, path
matching) is reused unchanged. The raw handler type stays internal; it is not user-facing.

**A6. Route metadata for codegen.** `buildRoutes` also records, per route, the comptime metadata the
generator needs: `method`, `path`, derived `name`, `auth`, and the `Input`/`Output` types — exposed
on the `App` type the generator already imports (alongside `.collections`).

**A7. Name-from-path.** `identifiers.routeMethodName(path)`: drop the `--api-prefix` and `:param`
segments, camel-join the rest (`/api/bookings/:id/confirm`→`bookingsConfirm`,
`/api/golfsim/health`→`golfsimHealth`). `.name` overrides. Two routes resolving to the same method
name → `@compileError` (the break-early discipline of the collection guards).

### B. Generator typed RPC

**B1. RPC surface.** For each typed route, emit under a new `zb.rpc.*` namespace:
```ts
rpc.bookingsConfirm(params: { id: string }, input: ConfirmInput, opts?: SendOptions): Promise<Booking>;
```
- Call shape (chosen): a typed **params object** present iff the route has path params (omitted for
  param-less routes), then the typed **input** present iff `Input` is not `void`, then optional opts.
- `<Name>Input` / `<Name>Output` TS interfaces emitted from the reflected types (named from the
  route's method name); `Output` `void` → `Promise<void>`.
- GET/DELETE → `input` encoded as the query string; POST/PUT/PATCH → JSON body. Path params are
  interpolated into the URL. The `--api-prefix` (finally consumed) builds the URL + strips the
  prefix when deriving names.
- Implemented as a thin wrapper over the base client's existing `send` (no new runtime).

**B2. `zb.rpc` on the client.** `createClient` gains a `rpc: { … }` object alongside `db`/`realtime`/
`files`. Untyped `send`/`fetch` remain for ad-hoc calls (not a raw-route escape hatch — there are no
raw routes — just generic HTTP).

## What it emits & mapping rules

| Zig (route I/O) | TS |
| --- | --- |
| `i*/u*/f32/f64` | `number` |
| `bool` | `boolean` |
| `[]const u8` | `string` |
| `?T` | `T \| null` |
| `[]T` (T ≠ u8) | `T[]` |
| nested `struct` | named `interface` (recursive) |
| `enum` | string-literal union |
| `std.json.Value` | `unknown` |
| anything else | `@compileError` (route + field + type) |

`:param` path segments → `string` fields on the method's params object. Method name from path
(camel-join non-param segments) or `.name`. HTTP method picks body-vs-query for `Input`.

## Validation & testing

- **Zig unit tests:** the reflection (each subset type maps correctly; each unsupported type triggers
  the `@compileError` path — tested via a compile-error harness or a representability predicate),
  `routeMethodName` derivation + collision, `RouteError`→status mapping, body-vs-query input parsing.
- **Typed-route fixture:** migrate golfsim's four routes (`confirmBooking`, `cancelBooking`,
  `listingAvailability`, `health`) to typed handlers as the worked example — covering path params,
  input+output, GET-query input, `void` output, and each `RouteError`.
- **Type-level `*.test-d.ts`:** the generated `zb.rpc.*` methods — params/input/output typing,
  `void` cases, `@ts-expect-error` negatives (wrong input field, missing param, etc.).
- **Live e2e:** drive `zb.rpc.*` against the real golfsim binary (confirm a booking, hit a GET with
  query input, exercise a `RouteError`→client-throw).
- **Golden + `--check`:** the generated route surface is committed and staleness-gated like the
  collection client.

## Scope / out of scope

**In:** the typed-only route handler (`Req`/`RouteError`), comptime reflection + bounded-subset
validation + the thunk, route metadata for codegen, name-from-path, the generator's `zb.rpc.*`
surface + Input/Output interfaces, golfsim migration, the test suites + CI.

**Out (later / explicitly):**
- **Raw/streaming route responses** (file downloads, SSE) — handled by built-in file serving, not
  custom routes; custom routes are typed-only.
- **Typed handler-side path params** (`req.params.id` as a comptime struct) — handler reads
  `req.param("id")` (string) for now; the client types params from the path. A possible later nicety.
- **Tagged unions / maps** in the type subset (the "rich" tier) — YAGNI now.
- **The runtime-introspection client** → SP3.

## Decomposition (two plans)

- **SP2.2a — framework typed-routes:** route spec change, `Req`/`RouteError`, the `route_types.zig`
  reflection + comptime validation, the dispatch thunk, route metadata, name-from-path; golfsim
  migrated; Zig unit tests. Deliverable: typed routes work server-side, `zig build` rejects
  unrepresentable I/O.
- **SP2.2b — generator typed RPC:** the generator reads route metadata and emits `zb.rpc.*` +
  Input/Output interfaces; golden + type-level + live e2e + CI. Deliverable: the typed RPC client
  end-to-end.

## Carry-forwards / consistency with SP2.1
- Reuse `identifiers.zig` casing helpers + the `@compileError`-on-collision guard discipline.
- Reuse the base client `send` + the SP1 throw-on-non-2xx behavior (no new transport).
- The generated `zbase.gen.ts` gains a `rpc` surface; `db`/`realtime`/`files` unchanged.
- `--api-prefix`, parsed-but-unused since SP2.1b, is finally consumed.
