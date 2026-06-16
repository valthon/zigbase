# @zigbase/client

Official TypeScript client for [ZigBase](../../README.md). Zero dependencies; runs in
browsers, Node 18+, Bun, Deno, and edge runtimes.

## Install

```bash
npm install @zigbase/client
```

## Quick start

```ts
import { createClient } from "@zigbase/client";

const zb = createClient("http://127.0.0.1:8090");

// Authenticate
await zb.collection("users").authWithPassword("you@example.com", "secret");

// Call any endpoint
const health = await zb.send("GET", "/api/health");
```

## Auth stores

- `MemoryAuthStore` (default, SSR-safe)
- `LocalAuthStore` (browser `localStorage`)
- `CookieAuthStore` (SSR token handoff)

```ts
import { createClient, LocalAuthStore } from "@zigbase/client";
const zb = createClient(url, { authStore: new LocalAuthStore() });
```

## Records & CRUD

```ts
const posts = zb.collection("posts");

const list = await posts.getList(1, 30, {
  filter: "status = 'published'",
  sort: "-created,title",
  expand: "author,tags",
});

const post = await posts.getOne("REC_ID", { expand: "author" });
const first = await posts.getFirstListItem("slug = 'hello'"); // throws 404 if none
const created = await posts.create({ title: "Hi", views: 0 });
const updated = await posts.update(created.id, { title: "Edited" });
await posts.delete(created.id);
```

### Safe filters

Use the `filter` template tag to interpolate user input without injection risk —
strings are single-quoted and escaped, numbers/booleans inline, `Date` -> ISO:

```ts
import { filter } from "@zigbase/client";

const q = userInput; // even "' || 1=1 --" is safely quoted
await posts.getList(1, 30, {
  filter: filter`status = ${"published"} && author.name ~ ${q}`,
});
```

## Cursor (keyset) pagination

Stable under inserts, no deep-offset cost — ideal for feeds and infinite scroll.
The SDK auto-appends an `id` tiebreaker (its direction follows your last sort term),
so the order is always deterministic. Cursors are opaque base64url tokens.

```ts
let page = await posts.getPage({ limit: 20, sort: "-created" });
render(page.items);
while (page.hasNext) {
  page = await posts.getPage({ limit: 20, sort: "-created", cursor: page.nextCursor! });
  render(page.items);
}

// Or iterate everything (stable even while rows are inserted mid-iteration):
for await (const post of posts.iterate({ sort: "-created" })) {
  handle(post);
}
const all = await posts.getFullList({ filter: "status = 'published'" });
```

> Cursor pagination is currently synthesized client-side over the offset+filter API.
> The public surface is shaped so a future native server cursor can replace the
> synthesis without any code change on your side.

## File uploads & URLs

A `create`/`update` body containing a `File`/`Blob` (or an array of them) is sent as
multipart automatically — no special method:

```ts
const rec = await posts.create({ title: "Hi", cover: fileInput.files[0] });

// Build a URL to the stored file:
const url = zb.files.getUrl(rec, rec.cover as string, { thumb: "100x100" });

// Protected files: mint a short-lived access token for <img src> / emails:
const token = await zb.files.getToken();
const protectedUrl = zb.files.getUrl(rec, rec.cover as string, { token });
```
