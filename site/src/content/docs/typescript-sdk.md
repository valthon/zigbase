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

- **`MemoryAuthStore`** — default, SSR-safe, never touches the DOM.
- **`LocalAuthStore`** — persists to `localStorage`; survives reloads in the browser.
- **`CookieAuthStore`** — `exportToCookie()` / `loadFromCookie()` for SSR handoff.

```ts
// password auth — saves { token, record } into the store on success
await zb.collection("users").authWithPassword("you@example.com", "secret");

zb.authStore.isValid;  // decodes the JWT `exp` locally — no round-trip
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

## Records

```ts
const posts = zb.collection("posts");

// list with filter + sort + relation expansion
const page = await posts.getList(1, 30, {
  filter: "status = 'published'",
  sort: "-created",
  expand: "author",
});

const one = await posts.getOne("REC123", { expand: "author" });

// create — multipart is auto-detected when the body contains a Blob/File
const made = await posts.create({ title: "Hi", cover: fileInput.files[0] });

const updated = await posts.update("REC123", { title: "Edited" });
await posts.delete("REC123");

// getFirstListItem — getList(1, 1) sugar; throws a 404 ZigbaseError when nothing matches
const draft = await posts.getFirstListItem("status = 'draft'");
```

### Safe filters

Build filter strings without injection using the `filter` tagged template (interpolated
values are quoted/escaped against the grammar):

```ts
import { filter } from "@zigbase/client";

const f = filter`status = ${"published"} && views > ${10}`;
// => status = 'published' && views > 10
const list = await posts.getList(1, 30, { filter: f });
```

## Pagination — offset + cursor

```ts
// offset (random access, exact totals)
const p = await posts.getList(2, 30);
p.totalItems; // total across all pages

// cursor / keyset (stable under inserts; ideal for feeds)
const c = await posts.getPage({ limit: 30, sort: "-created" });
c.items; c.nextCursor; c.hasNext;
const next = await posts.getPage({ limit: 30, sort: "-created", cursor: c.nextCursor! });

// async-iterate every matching record over the stable cursor engine
for await (const post of posts.iterate({ sort: "-created" })) {
  // ...
}
const all = await posts.getFullList({ filter: "status = 'published'" });
```

The cursor engine is synthesized client-side over the offset+filter wire and always carries
an `id` tiebreaker, so paging is stable even while rows are inserted.

## Files

```ts
// build a (optionally thumbnailed) file URL
const url = zb.files.getUrl(record, record.cover, { thumb: "100x100" });

// short-lived token for protected-file access
const token = await zb.files.getToken();
const protectedUrl = zb.files.getUrl(record, record.cover, { token });
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

Anonymous subscriptions are allowed only for `@public`-view collections (server-enforced).
The client does not pre-gate — it surfaces the server's `error` frame (rejecting the pending
`subscribe()` and/or calling your `onError` hook).

### High-level live store — "same API, now live"

`zb.realtime.collection(name)` mirrors the record read API, but returns **live** objects that
stay in sync as events arrive — backed by one shared per-collection record cache so the same
record id is one object across every view.

```ts
const live = zb.realtime.collection("posts");

// a live record: looks exactly like the record, patched IN PLACE on update events
const post = await live.getOne("REC123");
post.title;                          // reads through to the current data
post.subscribe(() => render(post));  // observable: subscribe() / get() / version
post.deleted;                        // flips to true on a delete event

// a live list: ordered items kept in sync as events arrive
const list = await live.getList(1, 30, { sort: "-created" });
list.items;                          // LiveRecord[] ordered by the query sort
list.subscribe(() => render(list.items));

// cursor-seeded live list
const feed = await live.getPage({ limit: 30, sort: "-created" });
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

### Tiered correctness

Membership of a record in a filtered live list is decided with a two-tier strategy that is
**always correct**:

- **Precise (own-field filters).** When a filter references only the record's own scalar
  fields (`status = 'published' && views > 10`), the list evaluates membership client-side and
  applies surgical insert / remove / move on each event — zero extra requests.
- **Re-fetch fallback (relations / macros).** When a filter traverses a relation
  (`author.name = 'Ada'`) or uses a macro (`@request.auth.id = owner`) the client can't
  evaluate locally, the list degrades to a **debounced re-fetch** of the query — still live,
  still correct, just coalesced to one request per burst of events.

## Runtime overrides

The SDK reads `fetch` and `WebSocket` from globals but lets you inject either — handy for
SSR, tests, or runtimes without a global WebSocket:

```ts
createClient(url, { fetch: customFetch, WebSocket: customWS });
```

## Error handling

Every non-2xx response rejects with a `ZigbaseError` carrying `status`, `message`, `url`, and
per-field validation errors:

```ts
import { isZigbaseError } from "@zigbase/client";

try {
  await posts.create({ title: "" });
} catch (err) {
  if (isZigbaseError(err) && err.status === 400) {
    console.log(err.data); // { title: { code, message }, ... }
  }
}
```

## See also

- [API reference](./api) — the underlying HTTP + WebSocket protocol.
- [Recipes](./recipes) — schema provisioning, owner-scoped rules, signup flows.
- [Tutorial](./tutorial) — build an app on ZigBase end to end.
