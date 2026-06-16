# @zigbase/client

Official TypeScript client for [ZigBase](../../README.md). Zero dependencies; runs in
browsers, Node 18+, Bun, Deno, and edge runtimes.

For the full guide (framework bindings, security notes, known limitations) see
[docs/typescript-sdk.md](../../docs/typescript-sdk.md).

## Install

```bash
npm install @zigbase/client
```

## Quick start

```ts
import { createClient } from "@zigbase/client";

const zb = createClient("http://127.0.0.1:8090");

// Authenticate (saves the token + record into the auth store)
await zb.collection("users").authWithPassword("you@example.com", "secret");

// Read records — pass a type parameter so dynamic fields are typed (see below)
import type { ZbRecord } from "@zigbase/client";
interface Post extends ZbRecord { title: string; status: string }
const posts = await zb.collection("posts").getList<Post>(1, 30);
console.log(posts.items[0]?.title);

// Call any endpoint directly
const health = await zb.send("GET", "/api/health");
```

## Auth + stores

Three stores ship in the box:

- **`MemoryAuthStore`** — the default. SSR-safe, never touches the DOM.
- **`LocalAuthStore`** — persists to browser `localStorage`; survives reloads.
- **`CookieAuthStore`** — `exportToCookie()` / `loadFromCookie()` for SSR token handoff.

```ts
import { createClient, LocalAuthStore } from "@zigbase/client";

const zb = createClient(url, { authStore: new LocalAuthStore() });

await zb.collection("users").authWithPassword("you@example.com", "secret");
zb.authStore.isValid; // local JWT-exp check (UX only — see security note)
zb.authStore.record;  // the authenticated record
await zb.collection("users").authRefresh();
await zb.collection("users").logout(); // clears the store

// react to login / logout / refresh anywhere
const off = zb.authStore.onChange((token, record) => {
  console.log("auth changed", record?.id ?? "(signed out)");
});
```

### OAuth2 (Authorization-Code + PKCE)

```ts
import { createPkceChallenge, randomState } from "@zigbase/client";

const { providers } = await zb.collection("users").listAuthProviders();
const { verifier, challenge } = await createPkceChallenge();
const state = randomState();
// 1. redirect to the provider authorize URL with `challenge` + `state`
// 2. on the callback, exchange the code:
await zb.collection("users").authWithOAuth2({
  provider: "github",
  code,
  codeVerifier: verifier,
  redirectUrl: "https://app.example.com/callback",
  state,
});
```

> **Security.** `isValid` decodes the JWT `exp` **client-side** — it is a UX/expiry hint
> only, never an authorization decision (the server authorizes every request). `LocalAuthStore`
> tokens live in `localStorage` and are therefore reachable by XSS — a standard SPA tradeoff;
> for SSR or stricter setups prefer `CookieAuthStore` with `secure: true` (and an `HttpOnly`
> cookie, which only the **server** can set — JS cannot).

## Records

The base SDK is dynamically typed: a plain `ZbRecord` has `id: string` and every other field
typed `unknown`. **Pass a type parameter** (`getOne<Post>()`, `getList<Post>()`, …) so reads
return your shape — otherwise reading `post.title` won't compile. You can also cast. Declare your
row type by **extending `ZbRecord`** (it carries the `id` plus the index signature the cursor
methods require):

```ts
import type { ZbRecord } from "@zigbase/client";

interface Post extends ZbRecord {
  title: string;
  status: "draft" | "published";
  author: string;
  cover: string;
}

const posts = zb.collection("posts");

const page = await posts.getList<Post>(1, 30, {
  filter: "status = 'published'",
  sort: "-created,title",
  expand: "author",
});
page.items[0]?.title; // typed as string

const post = await posts.getOne<Post>("REC_ID", { expand: "author" });
const first = await posts.getFirstListItem<Post>("status = 'draft'"); // throws 404 if none
const created = await posts.create<Post>({ title: "Hi", status: "draft", author: "u1" });
const updated = await posts.update<Post>(created.id, { title: "Edited" });
await posts.delete(created.id);
```

### Safe filters

Use the `filter` tagged template to interpolate user input without injection risk. Strings are
quoted (the tag picks `'…'`, or `"…"` when the value contains a single quote, so `O'Brien`
works), numbers/booleans inline, and `Date` becomes an ISO string:

```ts
import { filter } from "@zigbase/client";

const q = userInput; // even "' || 1=1 --" is safely quoted
await posts.getList<Post>(1, 30, {
  filter: filter`status = ${"published"} && author ~ ${q}`,
});
```

> **One limitation:** a value containing **both** a single and a double quote throws (the
> server's filter grammar can't yet represent it). This is lifted once server PR #16 —
> backslash escapes — ships.

## Pagination — offset + cursor

```ts
// Offset: random page access + exact totals.
const p = await posts.getList<Post>(2, 30);
p.totalItems; // total across all pages
p.totalPages;

// Cursor (keyset): stable under inserts, no deep-offset cost.
let c = await posts.getPage<Post>({ limit: 20, sort: "-created" });
render(c.items);
while (c.hasNext && c.nextCursor) {
  c = await posts.getPage<Post>({ limit: 20, sort: "-created", cursor: c.nextCursor });
  render(c.items);
}

// Iterate every matching record (stable even while rows are inserted):
for await (const post of posts.iterate<Post>({ sort: "-created" })) {
  handle(post);
}
const all = await posts.getFullList<Post>({ filter: "status = 'published'" });
```

**Which one?** Use **offset** (`getList`) when you need jump-to-page-N or a total count. Use
**cursor** (`getPage` / `iterate` / `getFullList`) for stable feeds and infinite scroll where
deep offsets get slow. The cursor engine auto-appends an `id` tiebreaker (its direction follows
your last sort term) and emits opaque base64url tokens.

> Cursor pagination is currently synthesized client-side over the offset+filter API. The public
> surface is shaped so a future native server cursor can drop in without code changes on your side.

## File uploads & URLs

A `create`/`update` body containing a `File`/`Blob` (or an array of them) is sent as multipart
automatically — no special method:

```ts
// Send a file from an <input type=file> — multipart is auto-detected:
const rec = await posts.create<Post>({
  title: "Hi",
  status: "draft",
  author: "u1",
  cover: fileInput.files![0]!,
} as Record<string, unknown>);

// Build a URL to the stored file (cover is typed string on Post):
const url = zb.files.getUrl(rec, rec.cover, { thumb: "100x100" });

// Protected files: mint a short-lived access token for <img src> / emails:
const token = await zb.files.getToken();
const protectedUrl = zb.files.getUrl(rec, rec.cover, { token });
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

await unsub(); // stop this callback; the socket closes when the last topic goes away
```

A single shared WebSocket multiplexes every topic, auto-reconnects with backoff, and re-auths
from the auth store on login/logout/refresh. Anonymous subscriptions require a `@public` view
rule on the collection (server-enforced).

### High-level live store

`zb.realtime.collection(name)` returns **live** objects kept in sync as events arrive. You
**must** call `close()` when done to release the realtime subscription and cache refs.

```ts
const live = zb.realtime.collection("posts");

// Live record — patched in place on update, `deleted` flips true on delete.
const post = await live.getOne("REC123");
post.subscribe(() => render(post.get()));
// ... later:
post.close(); // REQUIRED — releases the subscription + cache ref (idempotent)

// Live list — ordered items kept in sync; bind via the observable contract.
const list = await live.getList(1, 30, { sort: "-created" });
const unbind = list.subscribe(() => render(list.get()));
list.mode; // "precise" | "refetch" (see below)
// ... later:
unbind();
list.close(); // REQUIRED
```

`list.mode` is **`"precise"`** when the filter references only the record's own scalar fields
(membership is evaluated locally with surgical insert/move/remove) and **`"refetch"`** when the
filter traverses a relation or uses a macro (the list debounces a re-fetch of the query instead).

### React binding

`list.get()` / `list.items` is a **stable, mutated** array, so subscribe and key your snapshot
on `list.version` to force re-renders:

```tsx
import { useSyncExternalStore, useEffect, useState } from "react";

function Feed({ zb }) {
  const [list, setList] = useState<LiveList | null>(null);

  useEffect(() => {
    let live: Awaited<ReturnType<typeof zb.realtime.collection>["getList"]>;
    let cancelled = false;
    zb.realtime.collection("posts").getList(1, 30, { sort: "-created" }).then((l) => {
      if (cancelled) l.close();
      else { live = l; setList(l); }
    });
    return () => { cancelled = true; live?.close(); }; // cleanup closes the list
  }, [zb]);

  const version = useSyncExternalStore(
    (cb) => (list ? list.subscribe(cb) : () => {}),
    () => list?.version ?? 0,
  );

  if (!list) return null;
  return <ul>{list.get().map((r) => <li key={r.id}>{String(r.get().title)}</li>)}</ul>;
}
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
    console.log(err.data.title?.message); // field-level error
  }
}
```

## Escape hatch — `send()`

Call any endpoint the typed surface doesn't cover. The auth header, retries, and error mapping
still apply:

```ts
const stats = await zb.send<{ users: number }>("GET", "/api/custom/stats", {
  query: { window: "7d" },
});
await zb.send("POST", "/api/custom/reindex", { body: { collection: "posts" } });
```
