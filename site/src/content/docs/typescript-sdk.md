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
are quoted against the grammar: the tag picks `'…'`, or `"…"` when the value already contains a
single quote (so `O'Brien` works), numbers/booleans inline, and `Date` becomes an ISO string.

```ts
import { filter } from "@zigbase/client";

const q = userInput;
const f = filter`status = ${"published"} && author ~ ${q}`;
// => status = 'published' && author ~ '…'
const list = await posts.getList<Post>(1, 30, { filter: f });
```

> **Limitation:** a value containing **both** a single and a double quote throws — the server's
> filter grammar can't yet represent it. This is lifted once server PR #16 (backslash escapes)
> ships.

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
offsets. The cursor engine always carries an `id` tiebreaker (its direction follows your last
sort term), so paging is deterministic; cursors are opaque base64url tokens.

> The cursor engine is synthesized client-side over the offset+filter wire today. The public
> surface is shaped so a future native server cursor can replace the synthesis without any code
> change on your side.

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

## Realtime + live store

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

## Escape hatch — `send()`

`zb.send(method, path, opts?)` calls any endpoint the typed surface doesn't cover, while still
applying the auth header, retries, and `ZigbaseError` mapping:

```ts
const stats = await zb.send<{ users: number }>("GET", "/api/custom/stats", {
  query: { window: "7d" },
});
await zb.send("POST", "/api/custom/reindex", { body: { collection: "posts" } });
```

## Known limitations / fast-follow

- **No dedicated realtime entry point yet.** A `@zigbase/client/realtime` subpath for full
  tree-shaking of the realtime/live/filter-eval graph is planned; today that graph is only
  pulled in lazily on first `.realtime` access, so a REST-only app already avoids it at runtime.
- **`fields` not honored on cursor/iterate/live.** `getList`/`getOne` accept a `fields`
  projection, but the cursor (`getPage`/`iterate`/`getFullList`) and live-store option bags do
  not yet pass it through.
- **No built-in auto-cancellation / `requestKey`.** Pass an `AbortSignal` via `opts.signal` to
  cancel in-flight requests yourself; there is no automatic last-write-wins cancellation.
- **Both-quotes filter values throw.** A filter value containing both `'` and `"` throws until
  server PR #16 (backslash escapes) ships.
- **No raw `Response` from `send()`.** `send()` returns parsed JSON; raw-`Response` access for
  streaming/headers is planned.

## See also

- [API reference](./api) — the underlying HTTP + WebSocket protocol.
- [Recipes](./recipes) — schema provisioning, owner-scoped rules, signup flows.
- [Tutorial](./tutorial) — build an app on ZigBase end to end.
