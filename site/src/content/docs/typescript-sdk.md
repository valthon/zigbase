---
title: TypeScript SDK
description: The official @zigbase/client TypeScript SDK — auth, records, offset + cursor pagination, files, realtime, and the live store.
order: 4
group: guides
---

# ZigBase TypeScript SDK

The official TypeScript client (`@zigbase/client`) — zero dependencies; runs in browsers,
Node 18+, Bun, Deno, and edge runtimes. It wraps the ZigBase HTTP REST + realtime WebSocket
API ([API reference](./api)) in a typed, ergonomic surface: auth + stores, records, offset and
cursor pagination, files, low-level realtime subscriptions, and a high-level **live store**.

## Install

> **Pre-release:** `@zigbase/client` is not yet published to npm. Until the first
> release you can build it from source (`clients/typescript/`). The `npm install`
> command below will work once the first `client-v*` release is published.

```bash
npm install @zigbase/client
```

## Create a client

```ts
import { createClient, LocalAuthStore } from "@zigbase/client";

const zb = createClient("http://127.0.0.1:8090", {
  authStore: new LocalAuthStore(), // browser-persistent; omit for SSR-safe in-memory
});
```

`createClient(baseUrl, options?)` returns a `Client`. Useful options:

| Option | Default | Purpose |
| --- | --- | --- |
| `authStore` | `MemoryAuthStore` | Where the token + auth record live. |
| `autoRefresh` | `false` | Retry once on a 401 by refreshing the token (needs `authCollection`). |
| `authCollection` | — | The auth collection used for automatic refresh (e.g. `"users"`). |
| `fetch` | `globalThis.fetch` | Override the HTTP transport (exotic runtimes, tests). |
| `WebSocket` | `globalThis.WebSocket` | Override the realtime transport. |
| `lang` | — | `Accept-Language` for localized server errors. |
| `maxRetries` | `3` | Network-retry budget for idempotent requests. |

## Auth + stores

Three stores ship in the box:

- **`MemoryAuthStore`** — the default. SSR-safe, never touches the DOM.
- **`LocalAuthStore`** — persists to `localStorage`; survives reloads in the browser.
- **`CookieAuthStore`** — `exportToCookie()` / `loadFromCookie()` for SSR handoff.

```ts
// password auth — saves { token, record } into the store on success
await zb.collection("users").authWithPassword("you@example.com", "secret");

zb.authStore.isValid;  // decodes the JWT `exp` locally — UX hint only (see note)
zb.authStore.record;   // the authenticated record
zb.authStore.token;    // the raw JWT

// refresh + logout
await zb.collection("users").authRefresh();
await zb.collection("users").logout(); // clears the store

// react to login/logout/refresh anywhere
const off = zb.authStore.onChange((token, record) => {
  console.log("auth changed", record?.id ?? "(signed out)");
});
```

### OAuth2 (Authorization-Code + PKCE)

```ts
import { createPkceChallenge, randomState } from "@zigbase/client";

// Discover configured providers (name, authURL, clientId, scopes):
const { providers } = await zb.collection("users").listAuthProviders();

const { verifier, challenge } = await createPkceChallenge();
const state = randomState();
// 1. redirect the user to the provider authorize URL with `challenge` + `state`
// 2. on callback, exchange the code:
await zb.collection("users").authWithOAuth2({
  provider: "github",
  code,
  codeVerifier: verifier,
  redirectUrl: "https://app.example.com/callback",
  state,
});
```

### Verification + password reset

```ts
await zb.collection("users").requestVerification("you@example.com");
await zb.collection("users").confirmVerification(tokenFromEmail);

await zb.collection("users").requestPasswordReset("you@example.com");
await zb.collection("users").confirmPasswordReset(tokenFromEmail, "new-secret");
```

### Security notes

- **`isValid` is not authorization.** It decodes the JWT `exp` claim **client-side** purely so
  the UI can pre-empt an expired session; it is never a security boundary. The **server**
  authorizes every request — never gate sensitive UI on `isValid` alone.
- **`localStorage` tokens are exposed to XSS.** `LocalAuthStore` is the conventional SPA choice
  and accepts that tradeoff. For SSR or stricter setups prefer **`CookieAuthStore`**, and when
  you write the cookie set **`secure: true`** (HTTPS-only). A true `HttpOnly` cookie (unreadable
  by JS) can only be set by the **server** on its `Set-Cookie` — the client cannot.

```ts
import { CookieAuthStore } from "@zigbase/client";

// server: hand the token back to the browser as a hardened cookie
const store = new CookieAuthStore();
res.setHeader("Set-Cookie", store.exportToCookie({ secure: true, sameSite: "strict" }));

// SSR request handler: rehydrate from the incoming Cookie header
store.loadFromCookie(req.headers.cookie ?? "");
```

## Records

The base SDK is **dynamically typed**: a plain `ZbRecord` has `id: string` and every other field
typed `unknown`. To read fields safely, **pass a type parameter** on every read so the result is
your shape — otherwise `post.title` won't compile. (You can also cast, but the generic is cleaner.)
Declare your row type by **extending `ZbRecord`** — it provides `id` plus the index signature the
cursor methods (`getPage`/`iterate`/`getFullList`) require, so the same type works everywhere.

```ts
import type { ZbRecord } from "@zigbase/client";

interface Post extends ZbRecord {
  title: string;
  status: "draft" | "published";
  author: string;
  cover: string;
}

const posts = zb.collection("posts");

// list with filter + sort + relation expansion
const page = await posts.getList<Post>(1, 30, {
  filter: "status = 'published'",
  sort: "-created",
  expand: "author",
});
page.items[0]?.title; // typed string

const one = await posts.getOne<Post>("REC123", { expand: "author" });

// create — multipart is auto-detected when the body contains a Blob/File
const made = await posts.create<Post>({ title: "Hi", status: "draft", author: "u1" });

const updated = await posts.update<Post>("REC123", { title: "Edited" });
await posts.delete("REC123");

// getFirstListItem — getList(1, 1) sugar; throws a 404 ZigbaseError when nothing matches
const draft = await posts.getFirstListItem<Post>("status = 'draft'");
```

> Without a type parameter, `posts.getOne("REC123")` returns a `ZbRecord` whose fields are
> `unknown`. That is the right shape for generic tooling, but to read `.title` you must supply
> `<Post>` (as above) or cast — TypeScript will reject a bare field access on `unknown`.

### Safe filters

Build filter strings without injection using the `filter` tagged template. Interpolated values
are always single-quoted and escaped against the server lexer (`'`, `\`, and newline/tab/CR are
backslash-escaped), numbers/booleans inline, and `Date` becomes an ISO string. Any string is
representable, including values that mix both quote characters.

```ts
import { filter } from "@zigbase/client";

const q = userInput;
const f = filter`status = ${"published"} && author ~ ${q}`;
// => status = 'published' && author ~ '…'
const list = await posts.getList<Post>(1, 30, { filter: f });

// Mixed quotes are fine — single-quote the value and escape only the single quotes:
filter`title = ${`he said "hi" to O'Brien`}`;
// => title = 'he said "hi" to O\'Brien'
```

> **Injection safety.** The closing single quote can only appear escaped, so an interpolated
> value can never break out of its literal — even `' || 1=1 --` becomes one inert token.

## Pagination — offset + cursor

```ts
// Offset: random page access + exact totals.
const p = await posts.getList<Post>(2, 30);
p.totalItems; // total across all pages
p.totalPages;

// Cursor / keyset: stable under inserts; ideal for feeds and infinite scroll.
let c = await posts.getPage<Post>({ limit: 30, sort: "-created" });
c.items; c.nextCursor; c.hasNext;
while (c.hasNext && c.nextCursor) {
  c = await posts.getPage<Post>({ limit: 30, sort: "-created", cursor: c.nextCursor });
}

// async-iterate every matching record over the stable cursor engine
for await (const post of posts.iterate<Post>({ sort: "-created" })) {
  // ...
}
const all = await posts.getFullList<Post>({ filter: "status = 'published'" });
```

**Which one to use?** Reach for **offset** (`getList`) when you need jump-to-page-N navigation
or an exact total count. Reach for **cursor** (`getPage` / `iterate` / `getFullList`) for stable
feeds and infinite scroll: it is stable under concurrent inserts and avoids the cost of deep
offsets.

Cursor pagination is **native server-side keyset pagination**. The server mints an **opaque**
token (its internal format — stateless, signed, or stateful — is chosen server-side); the client
treats `nextCursor`/`prevCursor` as opaque strings and simply forwards whatever the server
returned on the next `getPage` call. There is no client-side keyset predicate or `id` tiebreaker —
the server owns determinism. By default the server **skips the total count** in cursor mode (it's
the expensive part); pass `withTotal: true` to a `getPage` to include `totalItems`. `getPage`
sends `limit` (defaulting to 30) — sending it with no `cursor` requests the first page.

## Files

A `create`/`update` body containing a `File`/`Blob` (or an array of them) is sent as multipart
automatically — no special method. Note that on a plain `ZbRecord` the file field is typed
`unknown`, so either type the record (`cover: string`) or cast the filename argument.

```ts
// build a (optionally thumbnailed) file URL — `record.cover` is typed string on Post
const url = zb.files.getUrl(record, record.cover, { thumb: "100x100" });

// short-lived token for protected-file access (<img src>, emails)
const token = await zb.files.getToken();
const protectedUrl = zb.files.getUrl(record, record.cover, { token });

// you can also pass collection + id explicitly instead of a record object:
const url2 = zb.files.getUrl("posts", "REC123", "cover.png", { download: true });
```

## Typed client — `@zigbase/client/typed`

`@zigbase/client/typed` is the **generic typed core** that a generated `zbase.gen.ts` file
instantiates into a fully type-safe, schema-aware client. The generator reads your ZigBase
schema (via the `pub const App` export in your `main.zig`) and emits a thin declarative
wrapper. The `examples/golfsim` example ships a live generated client at
`examples/golfsim/clients/typescript/zbase.gen.ts` — regenerate it with `zig build
gen-client` from the `examples/golfsim/` directory. The SDK's own coverage fixture is
`fixtures/dating/schema.zig`, validated by a type-level `*.test-d.ts` suite and a live e2e
against a `dating-server` binary.

The subpath exports runtime factories and type utilities:

| Export | Kind | Purpose |
| --- | --- | --- |
| `makeRecordService` | factory | Build a typed CRUD service over SP1's `CollectionService`. |
| `makeTypedRealtime` | factory | Build a typed realtime/live surface. |
| `makeTypedFiles` | factory | Build a typed file-URL helper. |
| `makeFilterBuilder` | factory | Build a fluent filter builder (a `Proxy` over field names). |
| `compileWhere` | function | Compile a `where`-DSL object into an SP1 filter string. |
| `compileIn` | function | Compile an `in`-list into a disjunction of `<field> = <value>` clauses (OR-joined). |
| `OP_MAP` | object | Operator-to-filter-operator mapping (e.g. `eq` → `=`). |
| `fieldMeta` | helper | Look up a `FieldMeta` by name from a `CollectionMeta` (`fieldMeta(meta, name): FieldMeta \| undefined`). |
| `Expr`, `FieldExpr` | classes | Fluent filter expression nodes. |
| `CollectionMeta`, `FieldMeta`, `FieldType` | types | Runtime metadata descriptors. |
| `WithExpand` | type | Narrow a record type to include one or more expanded relations. |
| `StringOps`, `NumberOps`, `BoolOps`, `DateOps`, `EnumOps`, `RelOps` | types | Operator-object types for generated `*Where` interfaces. |
| `TypedFieldExpr` | type | Per-field operand type for the fluent builder. |

A generated (or hand-authored) consumer file imports from `@zigbase/client/typed`, declares
concrete record types and metadata, then assembles a typed client:

```ts
import { createClient as baseCreateClient } from "@zigbase/client";
import { withRealtime } from "@zigbase/client/realtime";
import {
  makeRecordService,
  makeTypedRealtime,
  makeTypedFiles,
  type CollectionMeta,
  type WithExpand,
} from "@zigbase/client/typed";

// Declare per-collection metadata (the generator emits this from your schema):
const postsMeta: CollectionMeta = {
  name: "posts",
  fields: { title: { type: "text" }, status: { type: "select" } /* … */ },
  fileFields: ["cover"],
  expandable: ["author", "tags"],
  isAuth: false,
};

// Build the typed service — compiles `where` → SP1 filter strings under the hood:
const base = withRealtime(baseCreateClient("http://127.0.0.1:8090"));
const posts = makeRecordService(base, postsMeta) as unknown as PostsService;

// Every call is narrowed by the generated concrete interface:
const page = await posts.getList({ where: { status: "published" }, sort: "-created" });
// page.items[0]?.title — typed string

// Expand-narrowed getOne (PostRelations = { author: User; tags: Tag[] }):
const post = await posts.getOne("REC123", { expand: ["author"] });
// post.expand?.author — User (not unknown)
```

The `@zigbase/client/typed` subpath tree-shakes independently of `@zigbase/client/realtime` —
importing just the typed core adds only the where-compiler and factory code, not the
realtime / live-store graph.

## Typed RPC — `zb.rpc.*`

When a generated `zbase.gen.ts` declares typed routes (registered via the Zig server's `.routes` config), the generated client exposes them under `zb.rpc.<name>(params?, input?, opts?)`:

- **`params` object** is present IFF the route path contains `:param` segments (e.g. `{ id: string }`).
- **`input` argument** is present IFF the route's `Input` type is non-void (POST/PUT/PATCH bodies).
- GET/DELETE routes pass non-param fields as **query string** parameters; POST/PUT/PATCH routes serialize them as the **request body**.
- Throws a `ZigbaseError` on non-2xx — the same throw/parse behavior as `zb.send` and the typed collection methods.
- An optional final `opts` argument accepts `SendOptions` (`signal`, `requestKey`, custom headers).

The `rpc` namespace sits alongside `db`, `realtime`, and `files` on the generated client — it is only present when the Zig app declares at least one typed route.

**golfsim example** — the golfsim server declares four typed routes; `zig build gen-client` (from `examples/golfsim/`) emits the following `rpc` interface:

```ts
// examples/golfsim/clients/typescript/zbase.gen.ts (excerpt)
rpc: {
  bookingsConfirm(params: { id: string }, opts?: SendOptions): Promise<unknown>;
  bookingsCancel(params: { id: string }, opts?: SendOptions): Promise<unknown>;
  listingsAvailability(params: { id: string }, opts?: SendOptions): Promise<unknown>;
  golfsimHealth(opts?: SendOptions): Promise<HealthOut>;
}
```

Usage in the golfsim e2e test:

```ts
// bookingsConfirm: POST /api/bookings/:id/confirm — params object; output is unknown
const confirmed = await zb.rpc.bookingsConfirm({ id: booking.id }) as Booking;
expect(confirmed.status).toBe("confirmed");

// golfsimHealth: GET /api/golfsim/health — no params; typed HealthOut output
const health = await zb.rpc.golfsimHealth();
// health.status === "ok"
```

`unknown` outputs correspond to Zig `std.json.Value` return types — cast to a concrete interface for type-safe field access.

## Realtime + live store

Realtime ships behind a **dedicated entry point**, `@zigbase/client/realtime`, so a REST-only
app never bundles the realtime / live-store / filter-eval graph. Opt in with `withRealtime`:

```ts
import { createClient } from "@zigbase/client";
import { withRealtime } from "@zigbase/client/realtime";

const zb = withRealtime(createClient(url, { WebSocket }));
// `zb.realtime` is now available; everything else on `zb` is unchanged.
```

> **Tree-shaking.** Because the realtime graph is reachable only through
> `@zigbase/client/realtime`, an app that imports just `createClient` and uses `.collection()`
> drops `tokenize` / `reconnect` / `LiveList` / `analyzeFilter` entirely — roughly 13 KB
> (minified) of code a REST-only client never pays for.

### Low-level subscriptions

```ts
const unsub = await zb.realtime.subscribe(
  "posts",
  (e) => {
    e.action; // "create" | "update" | "delete"
    e.record; // the record (a delete carries only { id })
  },
  { filter: "status = 'published'" },
);

// single-record topic
await zb.realtime.subscribe("posts/REC123", (e) => {
  /* fires on update/delete of one record */
});

await unsub(); // stop this callback (the socket closes when the last topic goes away)
```

A **single shared WebSocket** to `/api/realtime` is created lazily on the first `subscribe`
and multiplexes every topic. It:

- **auto-reconnects** with bounded exponential backoff after a drop,
- **re-auths** from the `AuthStore` on login / logout / refresh,
- **resubscribes** every active topic after a reconnect,
- and coalesces multiple callbacks on the same `(topic, filter)` onto one wire subscription.

Anonymous subscriptions are allowed only for collections with a `@public` view rule
(server-enforced). The client does not pre-gate — it surfaces the server's `error` frame
(rejecting the pending `subscribe()` and/or calling your `onError` hook).

### High-level live store — "same API, now live"

`zb.realtime.collection(name)` mirrors the record read API but returns **live** objects that
stay in sync as events arrive — backed by one shared per-collection record cache, so the same
record id is one object across every view.

> **You must call `close()`** on a live record or list when you're done with it. `close()`
> drops the realtime subscription and releases the cache ref(s); skipping it leaks the
> subscription and keeps records pinned in the cache. Both `close()` methods are idempotent.

```ts
const live = zb.realtime.collection("posts");

// A live record: looks exactly like the record, patched IN PLACE on update events.
const post = await live.getOne("REC123");
post.get();                          // current backing data
post.subscribe(() => render(post.get())); // observable: subscribe() / get() / version
post.deleted;                        // flips to true on a delete event
post.close();                        // REQUIRED when done — releases subscription + cache ref

// A live list: ordered items kept in sync as events arrive.
const list = await live.getList(1, 30, { sort: "-created" });
list.get();                          // LiveRecord[] ordered by the query sort (alias: list.items)
const unbind = list.subscribe(() => render(list.get()));
// ... teardown:
unbind();
list.close();                        // REQUIRED

// cursor-seeded live list
const feed = await live.getPage({ limit: 30, sort: "-created" });
// ... feed.close() when done
```

On a `create`/`update`/`delete` event the list surgically inserts (at the sorted position),
patches in place, re-positions when a sort key changes, or removes — and notifies observers.
`LiveRecord` and `LiveList` both implement the same observable contract:

```ts
interface Observable<T> {
  subscribe(cb: () => void): () => void;
  get(): T;
  readonly version: number;
}
```

### Correctness modes — `list.mode`

Membership of a record in a filtered live list is decided with a two-tier strategy that is
**always correct**. Read `list.mode` (`"precise" | "refetch"`) to see which tier a list is in:

- **`"precise"` (own-field filters).** When the filter references only the record's own scalar
  fields (`status = 'published' && views > 10`), the list evaluates membership client-side and
  applies surgical insert / remove / move on each event — zero extra requests.
- **`"refetch"` (relations / macros).** When the filter traverses a relation
  (`author.name = 'Ada'`) or uses a macro (`@request.auth.id = owner`), the client can't
  evaluate it locally, so the list degrades to a **debounced re-fetch** of the query — still
  live, still correct, just coalesced to one request per burst of events.

### React binding

`list.get()` / `list.items` is a **stable, mutated** reference — the array identity does not
change when items move. Bind through `useSyncExternalStore`, keying your snapshot on
`list.version` so React re-renders when the list mutates, and `close()` the list in cleanup:

```tsx
import { useSyncExternalStore, useEffect, useState } from "react";
import type { LiveList } from "@zigbase/client";

function Feed({ zb }: { zb: ReturnType<typeof createClient> }) {
  const [list, setList] = useState<LiveList | null>(null);

  useEffect(() => {
    let live: LiveList | undefined;
    let cancelled = false;
    zb.realtime.collection("posts").getList(1, 30, { sort: "-created" }).then((l) => {
      if (cancelled) l.close();
      else { live = l; setList(l); }
    });
    return () => { cancelled = true; live?.close(); }; // cleanup closes the list
  }, [zb]);

  // Re-render keyed on the list version (the items array is a stable mutated ref).
  useSyncExternalStore(
    (cb) => (list ? list.subscribe(cb) : () => {}),
    () => list?.version ?? 0,
  );

  if (!list) return null;
  return <ul>{list.get().map((r) => <li key={r.id}>{String(r.get().title)}</li>)}</ul>;
}
```

## Runtime overrides

The SDK reads `fetch` and `WebSocket` from globals but lets you inject either — handy for
SSR, tests, or runtimes without a global WebSocket:

```ts
createClient(url, { fetch: customFetch, WebSocket: customWS });
```

## Error handling

Every non-2xx response rejects with a `ZigbaseError` carrying `status`, `message`, `url`, and
per-field validation errors in `data`:

```ts
import { isZigbaseError } from "@zigbase/client";

try {
  await posts.create<Post>({ title: "" } as Record<string, unknown>);
} catch (err) {
  if (isZigbaseError(err) && err.status === 400) {
    console.log(err.data);              // { title: { code, message }, ... }
    console.log(err.data.title?.message); // a single field's message
  }
}
```

## Field projection — `fields`

`fields` trims the server response to the listed fields and is honored on **every** read path:
`getList` / `getOne`, the cursor engine (`getPage` / `iterate` / `getFullList`), and the live
store (`collection().getList` / `getPage` / `getOne` seed fetches).

```ts
await posts.getFullList({ sort: "-created", fields: "id,title" });
for await (const p of posts.iterate({ fields: "id,slug" })) { /* ... */ }
const live = await zb.realtime.collection("posts").getList(1, 30, { fields: "id,title" });
```

## Auto-cancellation — `requestKey`

Every read/mutation option bag (and `send` / `fetch`) accepts an optional `requestKey` for
**opt-in** last-write-wins de-duplication: issuing a new request with a given key aborts any
in-flight request sharing that key. Omitting the key disables auto-cancellation entirely (the
default — concurrent requests never interfere). The key composes with a user-supplied `signal`
(either one aborts the request), and an aborted request rejects with a `DOMException` whose
`name` is `"AbortError"`.

```ts
// Typeahead: only the most recent query survives.
const page = await posts.getList(1, 20, { filter, requestKey: "search" });
```

## Escape hatches — `send()` and raw `fetch()`

`zb.send(method, path, opts?)` calls any endpoint the typed surface doesn't cover, while still
applying the auth header, retries, and `ZigbaseError` mapping (returning parsed JSON):

```ts
const stats = await zb.send<{ users: number }>("GET", "/api/custom/stats", {
  query: { window: "7d" },
});
await zb.send("POST", "/api/custom/reindex", { body: { collection: "posts" } });
```

When you need the **raw `Response`** — binary or text bodies, response headers, or streaming —
use `zb.fetch(method, path, opts?)`. It passes through `query` / `body` / `headers` / `signal` /
`requestKey` and the auth header, but does **not** JSON-parse and does **not** throw on a non-2xx
status; you receive the `Response` as-is:

```ts
const res = await zb.fetch("GET", "/api/export.csv", { query: { format: "csv" } });
if (res.ok) {
  const blob = await res.blob();
  console.log(res.headers.get("content-type"));
}
```

## See also

- [API reference](./api) — the underlying HTTP + WebSocket protocol.
- [Recipes](./recipes) — schema provisioning, owner-scoped rules, signup flows.
- [Tutorial](./tutorial) — build an app on ZigBase end to end.
