# ZigBase TypeScript SDK — SP1: Base Runtime SDK

**Status:** Design approved, pending spec review
**Date:** 2026-06-16
**Scope:** Sub-project 1 of 2 (the base runtime SDK). SP2 (codegen + typed layer) is designed separately and depends on this.

## Context & motivation

ZigBase needs a client SDK, starting with TypeScript, that is competitive with the
PocketBase / TrailBase offerings while leaning into ZigBase's distinguishing strength:
a schema (and, for framework consumers, custom routes) that is known **at compile time**.

The full vision is a two-layer SDK:

- **Base runtime SDK** (`@zigbase/client`) — fully dynamic, standalone-usable, zero
  runtime dependencies. Works against *any* ZigBase backend with no codegen. This is
  the "usable without customization" pillar and the foundation everything else wraps.
- **Generated typed layer** (SP2) — a committed, Prisma-style generated file that layers
  full type safety (typed records, `expand` return-narrowing, a typed filter builder, and
  typed RPC for comptime custom routes) on top of the base. Fed by **one shared emitter**
  with **two front-ends**: a comptime `build.zig` step (the blessed path) and runtime
  introspection of `GET /api/collections` (the stock-binary fallback).

This document specifies **SP1 only**: the base runtime SDK. It is independently shippable
and is validated end-to-end against a real `zigbase serve` binary before SP2 builds on it.

### Why this decomposition

Custom routes only exist when ZigBase is used as a *framework* (the consumer compiles
their own binary), so typed RPC belongs exclusively to the comptime codegen path — the
stock/introspected binary has no custom routes to describe and needs no route manifest.
That asymmetry is correct, not a wart, and it lets SP1 ignore codegen entirely and focus
on a rock-solid dynamic wire client.

## Design principles

1. **Usable without customization.** `npm i @zigbase/client` against a stock backend is
   productive in 30 seconds, fully dynamic, `any`-typed records. Typing is a strict opt-in
   enhancement (SP2), never a prerequisite.
2. **Ship only what's appropriate.** Tree-shakeable ESM modules with `"sideEffects": false`.
   A backend with no realtime / no file fields / no auth collection results in those modules
   tree-shaking out of the consumer bundle. The SP2 generated file imports only what the
   schema uses.
3. **Aim for awesome.** Beyond parity with PocketBase: cursor pagination and a high-level
   live store (same API as one-shot reads, but live) are first-class in the base SDK.
4. **Zero runtime dependencies.** Platform globals only (`fetch`, `WebSocket`,
   `crypto.subtle`), injectable for exotic runtimes. Runs in browser, Node 18+, Bun, Deno,
   and edge/workers.
5. **Honest about the wire.** Where the SDK synthesizes a capability the server doesn't
   natively expose (cursor pagination, live-list membership), this is documented, and the
   public API is shaped so a future native server capability can slot in unchanged.

## Repo placement & packaging

- **Location:** in-repo monorepo directory `clients/typescript/`, published to npm as
  **`@zigbase/client`**. In-repo keeps it inside this project's doc/example-sync discipline
  and lets CI build the exact binary the SDK integration tests run against.
- **Build:** ESM-first with a CJS build via `tsup`; target ES2022; `"sideEffects": false`.
- **Dependencies:** none at runtime. Dev-only: `tsup`, `vitest`, `typescript`.
- **Runtimes:** browser, Node 18+, Bun, Deno, edge/workers. `fetch` and `WebSocket` are
  read from globals by default and overridable via client options.

## Module layout

Tree-shakeable modules so SP2's generated file (and direct users) pull in only what they touch:

| Module | Responsibility |
| --- | --- |
| `client.ts` | `createClient(baseUrl, opts)` → `Client`; owns config, AuthStore, transport, lazy `realtime`/`files` accessors, and `collection(name)` / `send()`. |
| `transport.ts` | fetch pipeline: URL + query building, headers (Bearer from AuthStore), JSON vs multipart bodies, response parsing, `429` backoff, optional one-shot auto-refresh on `401`, `AbortSignal`. |
| `errors.ts` | `ZigbaseError { status, message, data }` + `isZigbaseError()`, mapping the `{code,message,data}` response body. |
| `auth.ts` | auth service methods bound to a collection; writes through to the AuthStore. |
| `auth-store.ts` | `AuthStore` interface + `MemoryAuthStore`, `LocalAuthStore`, `CookieAuthStore`; local JWT-exp decode. |
| `records.ts` | `RecordService`: offset + cursor pagination, CRUD, multipart upload. |
| `query.ts` | safe `filter\`…\`` template tag; the **filter evaluator + sort comparator** engine shared by cursors and the live store. |
| `realtime.ts` | low-level WebSocket client **and** the high-level live store. |
| `files.ts` | file URL + access-token helpers. |
| `index.ts` | public re-exports + subpath export map. |

## Client surface

PocketBase-*familiar* but explicitly **not** API-compatible.

```ts
const zb = createClient('http://127.0.0.1:8090', { authStore });

zb.collection('posts')        // RecordService (+ auth methods; dynamic, so both present)
zb.authStore                  // current token / record / isValid
zb.realtime                   // RealtimeService (low-level) + .collection() (live store), lazy
zb.files                      // file URL / token helpers
zb.send(method, path, opts)   // escape hatch for any custom/unknown endpoint
```

### Client options

```ts
interface ClientOptions {
  authStore?: AuthStore;          // default: MemoryAuthStore (SSR-safe)
  autoRefresh?: boolean;          // default false; one-shot auth-refresh on 401 then retry
  fetch?: typeof fetch;           // override platform global
  WebSocket?: typeof WebSocket;   // override platform global
  lang?: string;                  // Accept-Language passthrough
  maxRetries?: number;            // 429 backoff attempts (default 3)
}
```

## Transport, errors, auth

### Transport

- **Default auth: Bearer header** from the AuthStore. Works in every runtime and sidesteps
  CSRF entirely. Cookie mode is opt-in (for SSR), not the default.
- Non-2xx responses become `ZigbaseError`.
- `429` → bounded exponential backoff honoring `Retry-After`, up to `maxRetries`.
- Opt-in `autoRefresh`: on a `401` where the AuthStore holds a locally-decoded-expired token,
  attempt one `auth-refresh`, then retry the original request once.
- All requests accept an `AbortSignal`.

### Errors

```ts
class ZigbaseError extends Error {
  status: number;                 // HTTP status
  data: Record<string, { code: string; message: string }>;  // field validation map (400s)
  response?: Response;
}
function isZigbaseError(e: unknown): e is ZigbaseError;
```

Maps the server body `{ code, message, data }` (see `src/api/error.zig`). Field-level
validation errors (`400`) populate `data`.

### AuthStore

```ts
interface AuthStore {
  token: string | null;
  record: AuthRecord | null;
  isValid: boolean;                       // computed by decoding JWT exp locally
  save(token: string, record: AuthRecord): void;
  clear(): void;
  onChange(cb: (token: string | null, record: AuthRecord | null) => void): () => void;
  exportToCookie?(): string;              // for SSR handoff
  loadFromCookie?(cookie: string): void;
}
```

Shipped implementations:

- **`MemoryAuthStore`** (default) — SSR-safe, touches no globals.
- **`LocalAuthStore`** — browser `localStorage`, cross-tab `onChange` via storage events.
- **`CookieAuthStore`** — export/parse a cookie string for SSR token handoff.

`isValid` decodes the JWT `exp` claim locally (no signature verification — that is the
server's job) so the client knows when to refresh.

### Auth service methods

Bound to a collection via `zb.collection(name)`; every success writes through to the AuthStore:

- `authWithPassword(identity, password)`
- `authRefresh()`
- `authWithOAuth2({ provider, code, codeVerifier, redirectUrl, state? })`
- `listAuthProviders()` → provider metadata (`authURL`, `clientId`, `scopes`)
- `oauth2Init(provider)` → optional server-issued `state` for CSRF defense
- PKCE helper (`crypto.subtle`) to generate `codeVerifier` / `codeChallenge`
- `requestVerification(email)` / `confirmVerification(token)`
- `requestPasswordReset(email)` / `confirmPasswordReset(token, password)`
- `logout()` (clears AuthStore; calls `auth-logout` to drop cookies when in cookie mode)

Wire endpoints (per `src/api/auth.zig`, `src/api/oauth.zig`):
`/api/collections/:col/auth-with-password`, `auth-refresh`, `auth-logout`,
`request-verification`, `confirm-verification`, `request-password-reset`,
`confirm-password-reset`, `oauth2-providers`, `oauth2-init`, `auth-with-oauth2`.

## Records & pagination

`RecordService` from `zb.collection(name)`, matching the wire (`src/api/records.zig`).

### Offset pagination (familiar, random-access, exact totals)

```ts
getList(page = 1, perPage = 30, opts?: ListOpts): Promise<ListResult<T>>
getOne(id, opts?: { expand?: string }): Promise<T>
getFirstListItem(filter, opts?): Promise<T>      // getList(1,1) sugar
create(body, opts?: { expand?: string }): Promise<T>   // 201; multipart auto-detected
update(id, body, opts?): Promise<T>
delete(id): Promise<void>                          // 204

interface ListOpts { filter?: string; sort?: string; expand?: string; fields?: string; skipTotal?: boolean }
interface ListResult<T> { page: number; perPage: number; totalItems: number; totalPages: number; items: T[] }
```

`perPage` is clamped to the server max of 500. In the base SDK `T` defaults to a permissive
`Record = { id: string; [k: string]: unknown }`; SP2 substitutes real types.

### Cursor (keyset) pagination — first-class, often better

Stable under inserts, no deep-offset cost; ideal for feeds and infinite scroll.

```ts
getPage(opts: { cursor?: string; limit?: number; filter?: string; sort?: string;
                expand?: string; withTotal?: boolean }): Promise<CursorPage<T>>
iterate(opts?: { filter?: string; sort?: string; expand?: string; batch?: number }): AsyncIterable<T>

interface CursorPage<T> {
  items: T[];
  nextCursor: string | null;
  prevCursor: string | null;
  hasNext: boolean;
  hasPrev: boolean;
  totalItems?: number;   // only when withTotal
}
```

**Implementation (client-synthesized over the offset+filter wire — no backend change in SP1):**

- The cursor is an **opaque base64 token** encoding the sort-key values of the boundary row
  plus direction.
- On the next call, the SDK appends a **keyset predicate** to the user's `filter`
  (e.g. `created < <last> || (created = <last> && id < <lastId>)`) and reuses the `sort`.
- The SDK **auto-appends `id` as a final sort tiebreaker** to guarantee a deterministic total
  order (and therefore stable keyset boundaries).
- `getFullList` is re-backed by this keyset engine so it is stable even while rows are
  inserted mid-iteration.

**Documented constraints:** cursors require a deterministic sort (SDK enforces the `id`
tiebreaker); cannot random-access "page N"; skip `totalItems` by default for speed
(`withTotal` opts back in). The public API is shaped so a **future native server cursor**
can replace the client synthesis without changing the SDK surface.

### Multipart uploads (automatic)

If `body` contains a `File`/`Blob` (or an array of them), the service builds `FormData`
instead of a JSON body. No special upload method — `create({ title, avatar: file })` just works.

### Safe filter construction

filter/sort/expand are passed through as the documented query strings. The base SDK ships a
**`filter` template tag** that quotes/escapes interpolated values against the grammar
(`src/query/`):

```ts
zb.collection('posts').getList(1, 30, {
  filter: filter`status = ${'published'} && author.name ~ ${q}`,
  sort: '-created,title',
  expand: 'author,tags',
});
```

SP2's typed builder compiles down to the **same bound-string representation**, so nothing
underneath changes when typing is added.

## Realtime — low-level protocol + high-level live store

### Low-level client (the transport)

One shared `WebSocket` to `/api/realtime` per client, created lazily on first `subscribe`
(`src/realtime/`).

```ts
const unsub = await zb.realtime.subscribe('posts', (e) => { e.action; e.record }, { filter });
await zb.realtime.subscribe('posts/REC123', cb);   // single-record topic
await unsub();                                       // or zb.realtime.unsubscribe(topic, cb)
```

Lifecycle the client manages:

- On open, read the `connect`/`clientId` frame; send an `auth` frame whenever a token is
  present and **re-auth automatically** when the AuthStore changes (login/logout/refresh).
- **Auto-reconnect** with bounded backoff, then **resubscribe every active topic** and
  re-send `auth`. Subscriptions survive drops transparently.
- Dispatch `event` frames (`create`/`update`/`delete`) to callbacks for that topic; `delete`
  events carry only `{ id }` (server strips the snapshot).
- Surface `error` frames (e.g. subscription-limit) by rejecting the relevant `subscribe` /
  emitting to an `onError` hook.

Anonymous subscriptions work only for `@public`-view collections (server-enforced); the
client does not pre-gate, it surfaces the server's `error`.

Client message format (`src/realtime/protocol.zig`): `{ action: "auth"|"subscribe"|"unsubscribe", topic?, filter?, token? }`.
Server frames: `connect`, `auth`, `ack`, `event`, `error`.

### High-level live store (the adoption promise)

Swap `zb.collection` → `zb.realtime.collection`, keep the same read calls, and results become live.

```ts
// before — one-shot fetch
const list = await zb.collection('posts').getList(1, 30, { sort: '-created' });
render(list.items);

// after — same call shape, now live & cached
const live = zb.realtime.collection('posts').getList(1, 30, { sort: '-created' });
live.subscribe(() => render(live.items));   // items mutate in place as events arrive
```

**Two primitives, one shared cache:**

- **Live record** — `zb.realtime.collection('posts').getOne(id)` returns a wrapped record that
  *looks exactly like the record it wraps* (same keys; reads as `post.title`) but whose fields
  are **patched in place** on `update` events and marked `deleted` on `delete`. Object identity
  is stable, so a held reference always reflects current data.
- **Live list** — `getList`/`getPage` return an ordered, observable result whose `items` array
  gains a member on a matching `create`, drops one on `delete` or on an `update` that moves it
  out of the query, and **re-sorts in place** when an update changes a sort key.

A single **per-collection cache keyed by record id** is the source of truth: both primitives
hand out the *same* wrapped object for a given id, so one event updates every view at once.
Records are retained while something subscribes and **ref-count evicted** when nothing does.

**Framework-agnostic observable contract** — every wrapped record and live list exposes:

```ts
interface Observable<T> { subscribe(cb: () => void): () => void; get(): T; version: number }
```

Enough to bind React/Preact/Solid/Svelte via thin adapters later; no framework is baked in now.

**The shared engine:** a small **client-side filter evaluator + sort comparator** for the query
grammar. The live list uses it to decide membership/order on each event; cursor pagination uses
the *same comparator* for keyset predicates. Built once in `query.ts`.

**Correctness — tiered and graceful** (the subtle part; the implementation plan must pin the
exact behavior against the server's realtime delivery semantics in `src/realtime/`):

- Filter references only the record's **own scalar fields** → membership is evaluated precisely
  client-side (surgical inserts/removes/moves).
- Filter uses **relation traversal or macros** the client can't evaluate locally → the live list
  **degrades to a debounced re-fetch** of the affected query on relevant events. Still live, just
  less surgical, and always correct.
- Reconnect re-auths and resubscribes (low-level layer), so liveness survives drops.

Mental model stays clean — "same API, now live" — while never silently showing wrong data.

## Files

```ts
zb.files.getUrl(record, filename, opts?: { download?: boolean; token?: string; thumb?: string }): string
zb.files.getToken(): Promise<string>     // POST /api/files/token, for protected-file URLs
```

`getUrl` builds `/api/files/:col/:rec/:name` (`src/api/files.zig`). Uploads/downloads otherwise
ride the multipart records path. `getToken` mints a short-lived file-access token for
embedding protected files in emails or `<img src>`.

## Testing

Two tiers, mirroring this repo's hard-won lesson that unit-green ≠ end-to-end-green.

- **Unit (vitest, mocked `fetch`/`WebSocket`):** transport URL/header/body building, error
  mapping, `429` backoff, JWT-exp decode, all three AuthStore impls, `filter` tag escaping,
  the filter evaluator + sort comparator, cursor token encode/decode + keyset predicate
  generation, realtime frame dispatch + resubscribe logic, live-store membership transitions.
- **Integration (vitest against a real binary):** a fixture builds `zigbase` and launches
  `zigbase serve --insecure-cookies` on an ephemeral port with a seeded schema (an auth
  collection + a `posts`-like collection, at least one `@public`), then exercises the real
  wire: full auth lifecycle, CRUD, offset + cursor list with filter/sort/expand, multipart
  upload + download, and a realtime `create` → `event` round-trip plus a live-store update.
- **CI:** a new job (build binary → run vitest integration) added alongside the existing Zig
  unit and Playwright browser jobs in `.github/workflows/ci.yml`.

## Docs

Per CLAUDE.md sync discipline:

- New `docs/typescript-sdk.md`, mirrored to `site/src/content/`.
- `clients/typescript/README.md` (npm-facing).
- A short pointer from the top-level `README.md`.
- PR uses the repo's `.github/pull_request_template.md` sync checklist; build the site
  (`cd site && npm run build`) when docs change.

## Out of scope for SP1

Deferred to SP2 or later:

- All codegen: the schema descriptor, the shared TS emitter, the comptime `build.zig`
  front-end, and the introspection front-end.
- Typed records, `expand` return-narrowing, the typed filter builder, typed RPC.
- Non-TypeScript languages.
- A request/response interceptor plugin system.
- OpenAPI export / route manifest endpoint.
- Native **server-side** cursor pagination (the SDK API is forward-compatible with it).

## SP2 preview (for context only — not part of this plan)

SP2 wraps the proven SP1 base with generated types: one shared emitter consuming a normalized
schema descriptor, two front-ends (comptime `build.zig` step that serializes `.collections`
plus declared route input/output types; and `typegen` introspecting `GET /api/collections`),
producing a committed `zigbase.gen.ts` that exports a typed `createClient()` with typed records,
`expand` return-narrowing, the typed filter builder (compiling to SP1's bound-string filters),
and typed RPC stubs for comptime custom routes.
