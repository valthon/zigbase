# ZigBase TypeScript SDK — SP2: Bespoke Comptime-Generated Client

**Status:** Design approved, pending spec review
**Date:** 2026-06-16
**Scope:** Sub-project 2 of the TS SDK effort — the flagship comptime-generated typed client. Decomposed into **SP2.1** (typed core + collection/record/query codegen) and **SP2.2** (typed RPC + framework typed-routes). This doc covers both; SP2.1 is specified for first implementation.

## Context & strategy

The ZigBase client SDK is three tiers, in deliberate capability order:

1. **Base SDK (SP1, shipped, `@zigbase/client`)** — hand-written, dynamic, zero-customization.
2. **Bespoke comptime SDK (SP2 — this document, the flagship)** — generated from **comptime
   introspection** of the actual `.collections` + `.routes` at `zig build` time. Beautiful,
   efficient, *everything this backend needs and nothing it doesn't*: exact typed records, typed
   filters, typed `expand`, typed RPC, tree-shaken to only the surface this backend exposes.
3. **Enhanced dynamic client (SP3, later)** — *derived from* SP2 by feeding its reusable parts
   from runtime introspection. Explicitly better than the base SDK but a deliberate subset of SP2.

**Ordering rule:** design the comptime SDK standalone and unconstrained first. Do not let
"runtime introspection can't do that" reasoning leak into its design — SP2 may use everything
comptime offers, including things runtime introspection structurally cannot (custom routes,
compile-time guarantees, precise dead-code elimination). SP3 reuses what it can, later.

## Design principles

1. **Comptime does the work; the client ships less.** Mirror ZigBase's own ethos: resolve types,
   field metadata, and feature selection at generation time so the runtime branches less than the
   dynamic SDK. Node is never required to *generate* — only to typecheck/test.
2. **Concrete where it matters, generic only where unavoidable.** Templating (concrete generated
   code) wherever it improves DX or runtime; a single generic reserved for `expand`
   return-narrowing, whose type genuinely depends on a runtime argument. Larger generated
   artifacts are acceptable for large schemas (the file is the consumer's own, tree-shakeable).
3. **The hard TypeScript is hand-written and tested, not generated.** All intricate type-level
   machinery lives in a hand-authored generic "typed core"; the generator emits a thin,
   mostly-declarative layer that instantiates it.
4. **Built on SP1, not around it.** The generated client is a typed layer over SP1's runtime
   primitives (transport/auth/realtime/live/files); networking is never reinvented.
5. **Hand-rolled feel.** The consumer should feel each surface was written by hand — crisp
   autocomplete, clean hovers, actionable errors, fast tooling.

## Architecture & components

Three pieces, one new:

### 1. `@zigbase/client/typed` — the hand-written generic typed core
A new tree-shakeable subpath of the existing `@zigbase/client` package, authored once and
vitest-tested. Backend-agnostic; holds everything intricate:
- `WithExpand<Rec, Relations, Keys>` — the single expand-narrowing generic.
- The `where`-DSL → SP1-`filter`-string compiler.
- The fluent-builder operator helpers (`eq/neq/gt/gte/lt/lte/like/nlike/in`).
- The typed-service runtime factory (typed CRUD/list/getPage over SP1's `RecordService`).
- Typed wrappers for realtime/live and files.

It is a thin typed layer over SP1's `@zigbase/client` primitives — no networking is reinvented.
Shipping it as a subpath keeps a single install and tree-shakes out for base-SDK users.

### 2. The pure-Zig generator — a `build.zig` helper
ZigBase ships a generator module exposed as a build helper the *consumer* adds to their build:
```zig
// consumer's build.zig
const gen = zigbase.genClientStep(b, App(cfg), .{ .out = "src/zbase.gen.ts", .apiPrefix = "/api" });
// invoked via `zig build gen-client`
```
It builds a tiny generator executable (consumer's app module + ZigBase's emitter), runs it, and
the emitter walks the same comptime `.collections`/`.routes` structures `provision.zig`/`events.zig`
already build (via `@typeInfo` reflection), writing the `.ts`. **Pure Zig — no Node in the
generation path.** This is the comptime path by construction; the stock-binary/runtime path is SP3.

### 3. The generated `zbase.gen.ts` — committed in the consumer repo
Concrete per-backend types + a one-line `createClient`, importing `@zigbase/client` +
`@zigbase/client/typed`. Tree-shaken so only the surfaces this backend uses ship.

### Decomposition (SP2 is two specs)
- **SP2.1** — the typed core + **collection/record/query** codegen: records, `where`+fluent
  filters, nested relations, expand-narrowing, typed services, realtime/live, files, the
  `zbase.db.*` surface. *No framework change.* Introduces the Zig→TS mapper for *field* types.
- **SP2.2** — **typed RPC + the framework typed-routes change**: routes declare `.input`/`.output`,
  typed handlers with no raw request/response access, the Zig→TS mapper generalized to structs,
  the `zbase.rpc.*` surface, and migration of in-repo examples. Depends on SP2.1.

Implement **SP2.1 first**; SP2.2 layers on.

## SP2.1 — generated surface & field mapping

### Field → TS mapping
| Field type | TS type |
| --- | --- |
| `text`, `email`, `url`, `editor` | `string` |
| `number` | `number` |
| `bool` | `boolean` |
| `date`, `autodate` | `string` (ISO 8601) |
| `json` | `unknown` |
| `select` (maxSelect 1) | string-literal union of `.values` |
| `select` (maxSelect > 1) | `Array<union>` |
| `relation` (maxSelect 1) | `string` (id) + typed expand edge |
| `relation` (maxSelect > 1) | `string[]` (ids) + typed expand edge |
| `file` (maxSelect 1 / >1) | `string` / `string[]` (filenames) |

System fields (`id`, `created`, `updated`; auth `email`, `verified`, …) are always present on
reads. Hidden fields are never emitted.

### Per-collection generated artifacts (concrete)
```ts
interface Post { id: string; title: string; status: 'draft'|'published';
                 author: string; cover: string; created: string; updated: string }
type PostCreate = { title: string; status?: 'draft'|'published'; author?: string; cover?: File|Blob };
type PostUpdate = Partial<PostCreate>;
type PostWhere  = { title?: StringOps|string; status?: ('draft'|'published')|EnumOps<'draft'|'published'>;
                    price?: NumberOps|number; author?: string|RelOps|UserWhere /* nested, 1 level */;
                    AND?: PostWhere[]; OR?: PostWhere[] };
type PostRelations = { author: User };   // feeds WithExpand
type PostExpand    = 'author';           // expandable keys
// + the fluent accessor type: f.status.eq(...), f.price.gte(...)
```

### Typed service (over SP1's runtime)
```ts
zbase.db.posts.getList({ where, sort, expand })            // → ListResult<Post>
zbase.db.posts.getOne(id, { expand: ['author'] })          // → Post & { expand: { author: User } }
zbase.db.posts.getFirstListItem({ where })                 // → Post
zbase.db.posts.getPage({ where, limit, cursor })           // native cursor, typed CursorPage<Post>
zbase.db.posts.iterate({ where })                          // AsyncIterable<Post>
zbase.db.posts.getFullList({ where })                      // → Post[]
zbase.db.posts.create(data: PostCreate)                    // → Post
zbase.db.posts.update(id, data: PostUpdate)                // → Post
zbase.db.posts.delete(id)                                  // → void
zbase.db.posts.filter(f => f.status.eq('published').or(f.author.eq(uid)))  // fluent → filter string
```

### The one generic: `expand` narrowing
`getOne`/`getList` return types use `WithExpand<Post, PostRelations, Keys>` to narrow on the typed
`expand` argument. Top-level relations are concretely typed (`{ expand: { author: User } }`); deeper
dotted expands (`author.company`) still pass through as strings but narrow only at the first level —
bounded, no combinatorial blowup.

### Filters: both surfaces, nested
- **`where` DSL** (Prisma-familiar) — the everyday case, concise, great autocomplete.
- **Fluent builder** — `zbase.db.posts.filter(f => …)` for complex boolean logic / operator
  discovery.
Both compile to SP1's `filter` string; the raw `filter` string remains the ultimate escape hatch.
**Nested relation filtering** generates a `UserWhere` reachable from `PostWhere.author`,
cycle-guarded, one level deep by default (opt-in deeper).

### Cross-cutting surfaces (typed, tree-shaken to what's used)
- **Realtime/live:** `zbase.realtime.posts.subscribe(e => e.record /* Post */, { where })` and
  `zbase.realtime.posts.getList(…)` (typed `LiveList<Post>`). Emitted only if realtime is enabled.
- **Files:** `zbase.files.url(post, 'cover')` — `'cover'` is typed to that collection's file fields.
- **Auth:** login/refresh/oauth on auth collections (`zbase.db.users.authWithPassword`), with the
  auth record typed; shared session at `zbase.authStore` (from SP1).
- **Escape hatches:** `zbase.send(...)` / `zbase.fetch(...)`.

### Top-level shape (terse, concern-namespaced)
```ts
const zbase = createClient('http://…');
zbase.db.<collection>.*     // typed collection services
zbase.realtime.<collection>.*   // typed subscribe + live store
zbase.rpc.<route>           // typed custom routes (SP2.2)
zbase.files.url(record, field)
zbase.authStore, zbase.send, zbase.fetch
```
Collections are sandboxed under `db`, so a collection named `rpc`/`files`/`realtime` cannot
collide with top-level accessors — no reserved-name guard needed.

## SP2.2 — typed routes

**Every custom route is typed — no opt-in, no raw access.** A route declares optional
`.input`/`.output` Zig types; **defaults are empty input and raw-`string` output**. The handler is a
pure typed function with **no access to the raw request body or raw response** — the framework owns
parse, validate, and serialize:
```zig
.{ .method = .POST, .path = "/api/bookings/:id/confirm",
   .input = ConfirmReq, .output = BookingResult, .auth = .authed, .handler = confirmBooking }
//  fn confirmBooking(ctx: RouteCtx, input: ConfirmReq) !BookingResult
```
- **Handler signatures** follow what's declared: `fn(ctx) ![]const u8` (defaults),
  `fn(ctx, input: In) !Out`, etc. `RouteCtx` exposes path params (`ctx.param("id")`), auth
  (`ctx.auth`), and DB (`ctx.reader()/writer()`) — **not** the raw body or response. Body→`input`
  parse/validation failure → a 400 `ZigbaseError` (field data); the returned `output` is serialized
  by the framework.
- **Name derives from the path:** strip a leading `/api`, drop `:param` segments, camelCase-join
  the rest → `/api/bookings/:id/confirm` ⇒ `zbase.rpc.bookingsConfirm(id, input)`. A name collision
  is a **`@compileError`** (resolve by adjusting paths).
- **No backward compatibility:** existing untyped `*RouteEvent` handlers **fail to compile** until
  migrated. SP2.2 migrates the in-repo examples (blog, golfsim) as part of the work.

**Generated client:**
```ts
zbase.rpc.bookingsConfirm(id: string, input: ConfirmReq): Promise<BookingResult>
zbase.rpc.blogPing(): Promise<string>   // a default (empty input, string output) route
```

### Zig→TS mapper — a small, documented subset
Generalizes SP2.1's field mapper:
- `struct` → `interface` (nested structs → nested interfaces)
- ints/floats → `number`; `bool` → `boolean`; `[]const u8`/`[]u8` → `string`
- `enum` → string-literal union; `?T` → optional / `T | null`; `[]T` → `T[]`
- tagged `union(enum)` → discriminated union
- **Anything else** (pointers, `anytype`, maps, comptime-only types, non-exhaustive enums, …) →
  a clear **`@compileError`** naming the route, field, and unsupported type.

Constraining route I/O to plain serializable shapes is all an RPC boundary should carry, and keeps
the mapper total and tractable.

## Codegen mechanics

- **Run model:** `genClientStep` builds a generator executable (consumer app module + ZigBase
  emitter), runs it as `zig build gen-client`, and writes `.out`. Reflection over the comptime
  `.collections`/`.routes` structures; no Node.
- **Structured emit-helpers, not concatenation:** one Zig fn per TS fragment — `emitImports`,
  `emitRecordType`, `emitCreateType`, `emitWhereType`, `emitFluentAccessors`, `emitRelationsMap`,
  `emitServiceWiring`, `emitRpcType`, `emitClientFactory`. The Zig→TS type mapper is a shared helper
  used by both field and route-I/O emission.
- **Deterministic & committed:** output preserves declared order, carries a
  `// generated by zigbase — do not edit` header + a schema hash, and is committed (Prisma-style).
  `zig build gen-client --check` re-emits to a buffer and fails if it differs from the committed
  file — a CI guard against stale/hand-edited output. Regeneration is explicit, so normal `zig build`
  stays fast.

## Packaging

- **`@zigbase/client/typed`** — the generic typed core, a new subpath of the existing package
  (single install, tree-shakeable). Imports SP1 primitives from `@zigbase/client`.
- **Generated file** — committed at the consumer-chosen `.out` (default suggestion `src/zbase.gen.ts`),
  importing both `@zigbase/client` and `@zigbase/client/typed`, exporting a typed `createClient`.

## Testing strategy

- **Zig unit tests:** emit-helpers and the Zig→TS mapper (given a field/Zig type → assert the exact
  TS fragment), and path→name derivation. **Compile-fail tests** for the `@compileError` paths
  (unsupported route type, name collision).
- **Golden-file tests:** generate `zbase.gen.ts` for a representative fixture `App` config; snapshot
  it; assert stable, diff-clean output.
- **Type-level tests (crucial):** typecheck the generated file + a usage suite under strict `tsc`,
  with `tsd`/`expectTypeOf` assertions — expand-narrowing yields the right type; the `where` DSL and
  fluent builder **reject** wrong operand types / unknown fields (`expectError`); rpc input/output
  types are exact. This protects the hand-written typed core's machinery.
- **Runtime integration:** build a fixture backend (known schema + typed routes), launch it, run the
  *generated* client end-to-end — CRUD, `where`/fluent filters, expand, native cursor, realtime, and
  a typed `rpc` call — mirroring SP1's integration tier.

## Out of scope

- **SP3** — the runtime-introspection-derived enhanced dynamic client (designed only after SP2 is
  dialed in; explicitly a lesser tier).
- Concretely-typed nested `expand` beyond the first level (passes through as strings; narrows at
  level one).
- Typed `json`-field payloads (default `unknown`; a comptime-declared TS type for `json` fields is a
  possible later nicety).
- Any non-TypeScript target language.

## SP2.1 / SP2.2 boundary (for the implementation plans)

- **SP2.1 delivers:** `@zigbase/client/typed` core; the `genClientStep` build helper + emit-helpers;
  field Zig→TS mapping; generated records/create/update/where/fluent/relations/expand/services;
  realtime/live/files surfaces; `zbase.db.*`/`zbase.realtime.*`/`zbase.files`; golden + type-level +
  runtime tests; the `--check` CI guard. Works for any comptime backend's collections with **no
  framework change**.
- **SP2.2 delivers:** the framework typed-routes change (declaration, `RouteCtx`, typed handlers,
  parse/validate/serialize boundary, name derivation, `@compileError` guards); the generalized
  Zig→TS struct mapper; the generated `zbase.rpc.*`; migration of in-repo example routes; tests for
  all of it.
