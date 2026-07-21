# ZigBase blog example

A minimal real-world application built on **ZigBase as a library**. It imports
the `zigbase` module, declares a comptime schema, and registers record hooks and
a custom route — everything else (HTTP API, SQLite storage, auth, realtime,
CLI) comes straight from the framework.

This example is also a packaging proof: building it demonstrates that the SQLite
C sources and zap dependency travel transitively through the published `zigbase`
module into a downstream consumer package.

> **Pre-1.0:** ZigBase is pre-1.0 — the hook-config shape and module API may
> change between releases.

## What the blog example demonstrates

| ZigBase feature | How it's used |
|---|---|
| Comptime schema | `users` (auth) + `posts` with 7 fields, provisioned on startup |
| `beforeCreate` hook | `slugify` — derives URL slug from title |
| `beforeCreate` hook | `setAuthor` — stamps author from auth identity |
| `beforeCreate` + `beforeUpdate` hook | `computeReadingTime` — words/200, min 1 |
| Relation field | `author` → `users` with `maxSelect = 1` |
| Autodate field | `updated_at` stamped on create and every update |
| Access rules | Author-scoped update/delete (`@request.auth.id = author`) |
| Custom route | `GET /api/blog/posts/:slug` returns one published post |
| Cron job | Hourly heartbeat log (background scheduling demo) |
| Realtime WebSocket | `PostList` subscribes to live post create/update/delete events |
| Static-files mode | `--serve-static frontend/dist` serves the Astro build |
| Pagination config | `.pagination = .{ .cursor_token = .signed }` — HMAC-signed cursor tokens for the post feed (offset still on) |
| Built-in magic-link auth | `users.auth.methods.magic_link` — email-based passwordless login (auto_create, 1 h TTL) |
| `ZIGBASE_PUBLIC_URL` | Set to `http://blog.test/` (fake) so the emailed link is a full clickable URL; override to your host to actually click it |
| Comptime `.indexes` | `NOCASE` unique index on `users.email` — prevents case-variant duplicate accounts |

## Schema

```zig
.posts = .{
    .fields = .{
        .{ .name = "title",        .type = .text,     .required = true, .max = 200 },
        .{ .name = "slug",         .type = .text,     .max = 220 },
        .{ .name = "body",         .type = .text,     .max = 20000 },
        .{ .name = "status",       .type = .select,   .values = .{ "draft", "published" } },
        .{ .name = "author",       .type = .relation, .target = "users", .maxSelect = 1 },
        .{ .name = "updated_at",   .type = .autodate, .onCreate = true, .onUpdate = true },
        .{ .name = "reading_time", .type = .number,   .mode = .int },
    },
    .rules = .{
        .list   = "status = 'published'",
        .view   = "status = 'published'",
        .create = "@request.auth.id != ''",
        .update = "@request.auth.id = author",
        .delete = "@request.auth.id = author",
    },
},
```

## Hooks

The framework accepts one handler per phase. Multiple hooks are composed in a
chain function:

```zig
/// beforeCreate chain: slugify -> setAuthor -> computeReadingTime
fn postsBeforeCreate(ctx: *zigbase.Ctx, ev: *zigbase.RecordEvent) anyerror!void {
    try slugify(ctx, ev);
    try setAuthor(ctx, ev);
    try computeReadingTime(ctx, ev);
}
```

**Allocator discipline**: hook mutations MUST use `ev.arena.a`. `ev.arena` is a
typed `RequestArena` — not a bare `std.mem.Allocator`, so a general-purpose
allocator can't be passed to an arena-scoped API by accident — and `.a` is the
request-scoped allocator inside it, the one that owns `ev.record`. Need the app
itself? Use `ctx.app`.

### `slugify` (beforeCreate)
Derives a URL slug from the post title when one isn't supplied.
`"Hello, World!"` → `"hello-world"`.

### `setAuthor` (beforeCreate)
Stamps the `author` field with the authenticated user's id from `ev.rctx.auth`.
Creates the ownership link that the access rules rely on.

### `computeReadingTime` (beforeCreate + beforeUpdate)
Counts words in `body`, computes `ceil(words / 200)`, minimum 1. Stored in
`reading_time` and displayed in the post list as "N min read".


## Magic-link auth

The blog uses the built-in magic-link method — no custom routes or backend code needed.

### How it works

1. User enters their email and clicks **Send magic link** in the write page's login form.
2. The frontend POSTs to `POST /api/collections/users/auth/magic_link/initiate` — the server always returns 204 (enumeration-safe: no indication of whether the email exists).
3. The server sends an email (or logs the link to the server console in local dev) containing a link to:
   ```
   GET <public_url>/api/collections/users/auth/magic-link/consume?token=…&redirect=/
   ```
4. The user clicks the link. The server validates the token, sets `zb_auth` and `zb_csrf` session cookies, and 302-redirects to `/`. No token-handling page is needed in the frontend.
5. On landing at `/`, the frontend detects the cookie session via `POST /api/collections/users/auth-refresh` and shows the logged-in state.

### `public_url` — the fake `blog.test` URL

This example sets `ZIGBASE_PUBLIC_URL=http://blog.test/` in the run command. `blog.test` is a **deliberately fake domain** that does not resolve. It makes the emailed link a proper clickable URL in the server log and in any email client — but you cannot actually navigate to it.

**To click the link in local dev**, override the env var to your own server host:

```sh
ZIGBASE_PUBLIC_URL=http://127.0.0.1:8090 ./zig-out/bin/blog serve \
  --insecure-cookies --data-dir ./zb_data --serve-static frontend/dist
```

The link then resolves on `localhost` and clicking it in the server log opens the browser and completes sign-in.

If you omit `ZIGBASE_PUBLIC_URL` entirely, the server falls back to emailing/logging the raw token; the built-in consume endpoint still works if you manually construct the URL.

### `auto_create = true`

New visitors who have never signed up get an account created automatically when they first click a magic link. Existing accounts are found by email.

### Email index

```zig
.indexes = .{
    .{ .name = "users_email_nocase", .fields = .{"email"}, .unique = true, .collation = .nocase },
},
```

The `NOCASE` collation ensures `Bob@x.com` and `bob@x.com` are treated as the same address, preventing duplicate accounts from case variants.

## Custom route

```zig
// Typed route: `void` input, `std.json.Value` output (a dynamic record). The
// thunk serializes the returned record to a 200 JSON body.
fn getPostBySlug(req: *zigbase.Req(void)) zigbase.RouteError!std.json.Value {
    const slug = req.param("slug") orelse return req.fail(404, "not found");
    if (!isSafeSlug(slug)) return req.fail(400, "invalid slug");

    // Read through the per-request capability object — `req.ctx.records()` manages
    // the pooled connection itself (no manual acquireReader / Data wiring).
    const filter = std.fmt.allocPrint(req.ctx.arena.a,
        "slug = '{s}' && status = 'published'", .{slug}) catch return error.RouteFailed;
    const result = req.ctx.records().list("posts", .{ .filter = filter, .perPage = 1 }) catch return error.RouteFailed;
    if (result.items.len == 0) return error.NotFound;
    return result.items[0];
}
```

Registered alongside the existing ping route:

```zig
.routes = .{
    .{ .method = .GET, .path = "/api/blog/ping",          .handler = ping,           .auth = .public },
    .{ .method = .GET, .path = "/api/blog/posts/:slug",   .handler = getPostBySlug,  .auth = .public },
},
```

## Realtime live-updating post list

`PostList.tsx` subscribes to `ws://<host>/api/realtime` on mount:

```ts
const unsub = subscribePosts((ev) => {
  if (ev.action === 'create') setPosts((prev) => [ev.record, ...prev!]);
  if (ev.action === 'update') setPosts((prev) => prev!.map(p => p.id === ev.record.id ? ev.record : p));
  if (ev.action === 'delete') setPosts((prev) => prev!.filter(p => p.id !== ev.record.id));
});
return unsub; // cleanup on unmount
```

New posts appear immediately without a page refresh.

## Using ZigBase in your own project

Add the dependency:

```sh
zig fetch --save git+https://github.com/valthon/zigbase
```

Wire the module into your `build.zig`:

```zig
const zigbase = b.dependency("zigbase", .{ .target = target, .optimize = optimize });
exe_mod.addImport("zigbase", zigbase.module("zigbase"));
```

Your executable module must `.link_libc = true` (SQLite needs libc).

## Building and running this example

From `examples/blog/`:

```sh
mise exec zig@0.16.0 -- zig build           # produces ./zig-out/bin/blog
./zig-out/bin/blog superuser create --email you@example.com --password <pw> --data-dir ./zb_data
# --insecure-cookies: local dev over plain HTTP (auth cookies are Secure by default).
# A random JWT secret is generated + persisted at zb_data/.jwt_secret on first run.
# Set ZIGBASE_PUBLIC_URL so the emailed magic-link is a full URL.
# blog.test is intentionally fake — override to http://127.0.0.1:8090 to click the link locally.
ZIGBASE_PUBLIC_URL=http://blog.test/ ./zig-out/bin/blog serve \
  --insecure-cookies --data-dir ./zb_data
```

Then create a `posts` record without a `slug` and the hook fills it in from the
`title`; `reading_time` is computed from the `body` word count.

## Using the base TypeScript SDK (`@zigbase/client`)

This example demonstrates **Tier 1 — the base dynamic client**: address collections by
name (`zb.collection("posts")`), bring your own types. No code generation required.

Install:

```sh
npm install @zigbase/client
```

```ts
import { createClient } from "@zigbase/client";

const zb = createClient("http://127.0.0.1:8090");

// Sign up and authenticate against the `users` auth collection.
await zb.collection("users").create({
  email: "writer@example.com",
  password: "my-password",
  passwordConfirm: "my-password",
  name: "Ada",
});
await zb.collection("users").authWithPassword("writer@example.com", "my-password");

// Create a published post (the server hooks derive slug, author, and reading_time).
const post = await zb.collection("posts").create({
  title: "Hello from the base SDK",
  body: "Dynamic client, no codegen.",
  status: "published",
});

// List published posts.
const list = await zb.collection("posts").getList(1, 20, { filter: "status = 'published'" });

// Read, update, delete.
const one = await zb.collection("posts").getOne(post.id);
await zb.collection("posts").update(post.id, { title: "Edited title" });
await zb.collection("posts").delete(post.id);
```

For a fully-typed client, see golfsim (comptime-generated) and the
[TypeScript SDK docs](../../docs/typescript-sdk.md).

To run the committed e2e test:

```sh
mise exec node@24 -- npm install && npm run test:e2e
```

## Frontend (Astro + React islands)

`frontend/` is an Astro site with React islands: a public post list with live
updates, post detail, a magic-link login form ("Send magic link" → "Check your
email"), and a post-write form. The nav displays logged-in state via a small
`AuthStatus` island after a magic-link consume redirect.

```sh
cd frontend && npm install && npm run build && cd ..
mise exec zig@0.16.0 -- zig build
# --insecure-cookies for plain-HTTP local dev. The frontend is served from this same
# binary, so the live post-list WebSocket is same-origin and allowed by default; only a
# separate-origin browser app needs --realtime-origins.
ZIGBASE_PUBLIC_URL=http://blog.test/ ./zig-out/bin/blog serve --insecure-cookies \
  --data-dir ./zb_data --serve-static frontend/dist
# open http://127.0.0.1:8090/
# To click the magic-link in local dev: ZIGBASE_PUBLIC_URL=http://127.0.0.1:8090 instead
```

This demonstrates ZigBase's **default static-files mode**: the binary serves
`frontend/dist` at the root path because you passed `--serve-static`. The other
modes (comptime-hardcoded dir, fully embedded) are shown by the golfsim and
plugins examples.
